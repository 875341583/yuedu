/// Pure Dart MOBI text extractor.
///
/// Parses the PDB container format and decompresses the text records using
/// one of the three Mobipocket compression schemes:
///   * No compression   (compression == 1)
///   * PalmDOC RLE      (compression == 2, the most common case)
///   * Huff/CDIC        (compression == 17480 / 'DH', dictionary Huffman)
///
/// Trailing-entry metadata at the end of every text record (multibyte
/// boundary / extra data, controlled by `extra_flags`) is stripped before
/// decompression — this is required to avoid garbled UTF-8 (especially
/// Chinese) text. HTML tags are then stripped to produce plain text.
///
/// DRM-protected files (encryption != 0) are not supported.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Extracts text content from a MOBI file using pure Dart (no FFI).
class MobiTextExtractor {
  /// Huff/CDIC dictionary-Huffman compression type (0x4448, big-endian 'DH').
  static const int _huffCompression = 17480;

  /// Extract all text from [filePath].
  /// Returns the extracted text, or null if no text was found.
  /// Throws [MobiExtractException] with a diagnostic message on parse errors.
  static String? extract(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    return _extractFromBytes(bytes);
  }

  static String? _extractFromBytes(Uint8List bytes) {
    if (bytes.length < 78) {
      throw MobiExtractException('文件太小，不是有效的MOBI（${bytes.length}字节）');
    }

    // --- PDB header ---
    // numRecords at offset 76 (2 bytes big-endian)
    final numRecords = _beUint16(bytes, 76);
    if (numRecords < 2) {
      throw MobiExtractException('MOBI记录数异常（numRecords=$numRecords）');
    }

    // Record info entries start at offset 78, each 8 bytes (4 offset + 1 attr + 3 uid)
    final offsets = <int>[];
    for (var i = 0; i < numRecords; i++) {
      final off = 78 + i * 8;
      if (off + 4 > bytes.length) {
        throw MobiExtractException('PDB头偏移表越界');
      }
      offsets.add(_beUint32(bytes, off));
    }
    // Sentinel: last record extends to end of file
    offsets.add(bytes.length);

    // Validate offsets are within file bounds
    for (final o in offsets) {
      if (o < 0 || o > bytes.length) {
        throw MobiExtractException('PDB偏移越界（offset=$o, fileSize=${bytes.length}）');
      }
    }

    // --- record 0 = PalmDOC header + MOBI header ---
    final rec0Start = offsets[0];
    final rec0End = offsets[1];
    if (rec0End - rec0Start < 16) {
      throw MobiExtractException('PalmDOC头过短');
    }
    // Independent view of record 0 so that header field offsets are
    // measured from the start of record 0 (matches the Mobipocket spec).
    final rec0 = Uint8List.sublistView(bytes, rec0Start, rec0End);

    // --- PalmDOC header (first 16 bytes of rec0) ---
    // Layout (big-endian, per PalmDOC/MOBI spec):
    //   offset 0  (2B): compression (1=none, 2=PalmDoc RLE, 17480=Huff/CDIC)
    //   offset 2  (2B): unused
    //   offset 4  (4B): textLength (uncompressed total text bytes)
    //   offset 8  (2B): recordCount (number of text records)
    //   offset 10 (2B): recordSize (max 4096)
    //   offset 12 (2B): encryptionType (0=none, 1=old, 2=DRM)
    final compression = _beUint16(rec0, 0);
    final textLength = _beUint32(rec0, 4);
    final recordCount = _beUint16(rec0, 8);
    final encryption = _beUint16(rec0, 12);

    // Encryption check — DRM-protected files cannot be decoded
    if (encryption != 0) {
      throw MobiExtractException(
          'MOBI文件已加密（encryption=$encryption），不支持DRM保护文件');
    }

    // ★ Corrected compression mapping (matches Calibre / Mobipocket spec):
    //   1 = no compression, 2 = PalmDOC RLE, 17480 = Huff/CDIC Huffman.
    // The previous implementation mistakenly treated 1 as RLE and rejected
    // 2 (the standard PalmDOC RLE value used by most MOBI files).
    if (compression != 1 && compression != 2 && compression != _huffCompression) {
      throw MobiExtractException(
          '不支持的MOBI压缩类型（compression=$compression，支持 1=无压缩 / 2=PalmDOC RLE / 17480=Huffman）');
    }

    // --- MOBI header (optional, from offset 16 of rec0) ---
    int? mobiTextEncoding;
    int mobiHeaderLength = 0;
    final mobiMagic = rec0.length >= 20
        ? String.fromCharCodes(rec0.sublist(16, 20))
        : '';
    if (mobiMagic == 'MOBI') {
      if (rec0.length >= 24) {
        mobiHeaderLength = _beUint32(rec0, 20);
      }
      if (rec0.length >= 32) {
        mobiTextEncoding = _beUint32(rec0, 28); // 0=CP1252, 65001=UTF-8
      }
    }

    // extra_flags controls trailing-entry metadata appended to each text
    // record. Only valid when the MOBI header length is in the expected
    // range (Calibre: 0xE4 <= length <= 500). Located at rec0 offset 0xF2.
    int extraFlags = 0;
    if (mobiHeaderLength >= 0xE4 &&
        mobiHeaderLength <= 500 &&
        rec0.length >= 0xF4) {
      extraFlags = _beUint16(rec0, 0xF2);
    }

    // --- Huffman table location (only for compression == 17480) ---
    // Calibre headers.py: huff_offset & huff_number at rec0[0x70:0x78].
    // record[huff_offset]           -> HUFF record
    // record[huff_offset+1 .. +N-1] -> CDIC records
    _HuffReader? huffReader;
    if (compression == _huffCompression) {
      if (rec0.length < 0x78) {
        throw MobiExtractException('Huffman压缩但MOBI头过短，无法定位HUFF/CDIC记录');
      }
      final huffOffset = _beUint32(rec0, 0x70);
      final huffNumber = _beUint32(rec0, 0x74);
      if (huffNumber < 1 ||
          huffOffset < 1 ||
          huffOffset + huffNumber > numRecords) {
        throw MobiExtractException(
            'HUFF/CDIC记录索引异常（huffOffset=$huffOffset, huffNumber=$huffNumber, numRecords=$numRecords）');
      }
      final huffs = <Uint8List>[];
      for (var i = 0; i < huffNumber; i++) {
        final idx = huffOffset + i;
        if (idx + 1 >= offsets.length) break;
        final s = offsets[idx];
        final e = offsets[idx + 1];
        if (e <= s || e > bytes.length) {
          throw MobiExtractException('HUFF/CDIC记录偏移越界（idx=$idx）');
        }
        huffs.add(Uint8List.sublistView(bytes, s, e));
      }
      huffReader = _HuffReader(huffs);
    }

    // --- Decompress text records (record 1 .. recordCount) ---
    final numTextRecords = recordCount > 0 && recordCount + 1 <= numRecords
        ? recordCount
        : numRecords - 1;

    final decompressed = <int>[];
    for (var i = 0; i < numTextRecords; i++) {
      final recIdx = i + 1;
      if (recIdx >= offsets.length - 1) break;
      final start = offsets[recIdx];
      final end = offsets[recIdx + 1];
      if (end <= start || end > bytes.length) continue;

      var recData = Uint8List.sublistView(bytes, start, end);

      // Strip trailing-entry metadata from the end of each text record.
      // Trailing entries encode multibyte character boundaries / extra data
      // and will corrupt UTF-8 text (notably CJK) if not removed first.
      final trail = _sizeofTrailingEntries(recData, extraFlags);
      if (trail > 0 && trail < recData.length) {
        recData = Uint8List.sublistView(recData, 0, recData.length - trail);
      }

      List<int> decoded;
      if (compression == 2) {
        decoded = _palmdocDecompress(recData);
      } else if (compression == _huffCompression) {
        decoded = huffReader!.unpack(recData);
      } else {
        // compression == 1, no compression
        decoded = recData.toList();
      }
      decompressed.addAll(decoded);

      // Stop early if we already have all declared text
      if (textLength > 0 && decompressed.length >= textLength) break;
    }

    if (decompressed.isEmpty) {
      throw MobiExtractException(
          'MOBI解压后内容为空（compression=$compression, recordCount=$recordCount, '
          'numRecords=$numRecords, textLength=$textLength）');
    }

    // Truncate to declared text length
    List<int> textBytes;
    if (textLength > 0 && textLength < decompressed.length) {
      textBytes = decompressed.sublist(0, textLength);
    } else {
      textBytes = decompressed;
    }

    // --- Decode bytes ---
    // Prefer MOBI header's textEncoding if available; otherwise auto-detect.
    String raw;
    if (mobiTextEncoding == 65001) {
      raw = utf8.decode(textBytes, allowMalformed: true);
    } else if (mobiTextEncoding == 1252 || mobiTextEncoding == 0) {
      raw = _decodeCp1252(textBytes);
    } else {
      try {
        raw = utf8.decode(textBytes, allowMalformed: false);
      } catch (_) {
        raw = _decodeCp1252(textBytes);
      }
    }

    // --- Strip HTML tags ---
    final text = _stripHtml(raw);
    if (text.isEmpty) {
      throw MobiExtractException(
          'MOBI去HTML后文本为空（原始${bytes.length}字节，解压${decompressed.length}字节）');
    }
    return text;
  }

  // ==== Trailing-entry handling ====
  // Mirrors Calibre's MobiReader.sizeof_trailing_entry /
  // sizeof_trailing_entries. Each text record may carry variable-length
  // integer(s) at its tail describing multibyte spans / extra data; these
  // must be removed before decompression or they corrupt the stream.

  static int _sizeofTrailingEntry(Uint8List data, int psize) {
    var bitpos = 0;
    var result = 0;
    while (true) {
      if (psize <= 0) return result;
      final v = data[psize - 1];
      result |= (v & 0x7F) << bitpos;
      bitpos += 7;
      psize -= 1;
      if ((v & 0x80) != 0 || bitpos >= 28 || psize == 0) {
        return result;
      }
    }
  }

  static int _sizeofTrailingEntries(Uint8List data, int extraFlags) {
    if (extraFlags == 0) return 0;
    var num = 0;
    final size = data.length;
    var flags = extraFlags >> 1;
    while (flags != 0) {
      if ((flags & 1) != 0) {
        num += _sizeofTrailingEntry(data, size - num);
      }
      flags >>= 1;
    }
    if ((extraFlags & 1) != 0) {
      final off = size - num - 1;
      if (off >= 0 && off < size) {
        num += (data[off] & 0x3) + 1;
      }
    }
    return num;
  }

  // ==== Byte readers ====

  /// Big-endian unsigned 32-bit int at [offset].
  static int _beUint32(Uint8List b, int off) {
    return (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
  }

  /// Big-endian unsigned 16-bit int at [offset].
  static int _beUint16(Uint8List b, int off) {
    return (b[off] << 8) | b[off + 1];
  }

  /// PalmDOC RLE decompression algorithm.
  ///
  /// Byte-by-byte stream decoder:
  /// - 0x00           : copy next byte verbatim
  /// - 0x01..0x08     : copy next N bytes verbatim
  /// - 0x09..0x7F     : literal byte
  /// - 0x80..0xBF     : back-reference (pair = ((c&0x3F)<<8)|next;
  ///                    distance = pair>>3, length = (pair&7)+3). The whole
  ///                    0x80..0xBF range is back-refs (Calibre encodes
  ///                    distances up to 2047, high byte spans 0x80..0xBF).
  /// - 0xC0..0xFF     : output space + (c & 0x7F)
  static List<int> _palmdocDecompress(Uint8List data) {
    final out = <int>[];
    var i = 0;
    final len = data.length;
    while (i < len) {
      final c = data[i];
      i++;
      if (c == 0) {
        if (i < len) {
          out.add(data[i]);
          i++;
        }
      } else if (c <= 8) {
        for (var k = 0; k < c && i < len; k++) {
          out.add(data[i]);
          i++;
        }
      } else if (c <= 0x7F) {
        out.add(c);
      } else if (c <= 0xBF) {
        // 0x80..0xBF are ALL back-references (no space-pair sub-branch).
        // Calibre's encoder produces back-ref codes whose high byte is
        // 0x80 | ((m>>5) & 0x3F); with m in [1,2047] the high byte spans
        // the *entire* 0x80..0xBF range. space+char is encoded only as
        // 0xC0..0xFF (onch ^ 0x80). The previous `pair >= 0x2000` test
        // wrongly treated distance>=1024 back-refs as space-pairs, which
        // garbled everything after the first ~1KB of each record.
        if (i < len) {
          final b = data[i];
          i++;
          final pair = ((c & 0x3F) << 8) | b;
          // Calibre encode: code = 0x8000 + ((m<<3)&0x3ff8) + (n-3), n in [3,10]
          // => distance = pair >> 3, length = (pair & 7) + 3
          final distance = pair >> 3;
          final length = (pair & 7) + 3;
          final startPos = out.length - distance;
          for (var k = 0; k < length; k++) {
            final src = startPos + k;
            if (src >= 0 && src < out.length) {
              out.add(out[src]);
            } else if (src < 0) {
              // Invalid back-reference; emit space as fallback
              out.add(0x20);
            } else {
              break;
            }
          }
        }
      } else {
        // 0xC0..0xFF
        out.add(0x20); // space
        out.add(c & 0x7F);
      }
    }
    return out;
  }

  /// Windows-1252 (CP1252) decoder.
  /// Differs from Latin-1 in the 0x80-0x9F range.
  static final _cp1252Upper = <int>[
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
  ];

  static String _decodeCp1252(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      if (b < 0x80) {
        sb.writeCharCode(b);
      } else if (b < 0xA0) {
        sb.writeCharCode(_cp1252Upper[b - 0x80]);
      } else {
        sb.writeCharCode(b);
      }
    }
    return sb.toString();
  }

  /// Strip HTML tags and decode entities, preserving paragraph structure.
  static String _stripHtml(String html) {
    var s = html;

    // Block-level boundaries -> newline before stripping tags
    s = s.replaceAllMapped(
      RegExp(r'<\s*br\s*/?>', caseSensitive: false),
      (_) => '\n',
    );
    s = s.replaceAllMapped(
      RegExp(r'</\s*(p|div|h[1-6]|li|tr)\s*>', caseSensitive: false),
      (_) => '\n',
    );
    s = s.replaceAllMapped(
      RegExp(r'<\s*(p|div|h[1-6]|li|tr)\b[^>]*>', caseSensitive: false),
      (_) => '\n',
    );

    // Remove all remaining tags
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');

    // Decode common named entities (order matters: &amp; last)
    s = s.replaceAll('&nbsp;', ' ');
    s = s.replaceAll('&lt;', '<');
    s = s.replaceAll('&gt;', '>');
    s = s.replaceAll('&quot;', '"');
    s = s.replaceAll('&apos;', "'");
    s = s.replaceAll('&copy;', '\u00A9');
    s = s.replaceAll('&reg;', '\u00AE');
    s = s.replaceAll('&mdash;', '\u2014');
    s = s.replaceAll('&ndash;', '\u2013');
    s = s.replaceAll('&hellip;', '\u2026');
    s = s.replaceAll('&ldquo;', '\u201C');
    s = s.replaceAll('&rdquo;', '\u201D');
    s = s.replaceAll('&lsquo;', '\u2018');
    s = s.replaceAll('&rsquo;', '\u2019');
    s = s.replaceAll('&amp;', '&');

    // Decode numeric entities
    s = s.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) {
        final v = int.tryParse(m.group(1)!) ?? 0;
        return v >= 0 && v < 0x110000 ? String.fromCharCode(v) : '';
      },
    );
    s = s.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (m) {
        final v = int.tryParse(m.group(1)!, radix: 16) ?? 0;
        return v >= 0 && v < 0x110000 ? String.fromCharCode(v) : '';
      },
    );

    // Collapse spaces and tabs, normalize newlines
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
    s = s.replaceAll(RegExp(r' *\n *'), '\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return s;
  }
}

/// Huff/CDIC dictionary-Huffman decompressor.
///
/// Direct Dart port of Calibre's `calibre/ebooks/mobi/huffcdic.py` (Reader +
/// HuffReader). One HUFF record carries the code tables; one or more CDIC
/// records carry the phrase dictionary. Each compressed text record is then
/// decoded bit-by-bit into a concatenation of dictionary phrases.
class _HuffReader {
  /// dict1[0..255]: each entry is [codelen, term, maxcode].
  final List<List<int>> _dict1 = [];

  /// mincode[codelen] / maxcode[codelen] for codelen 0..32.
  final List<int> _mincode = [];
  final List<int> _maxcode = [];

  /// Phrase dictionary: each entry is [Uint8List slice, int flag] or null
  /// (null = currently being recursively unpacked).
  final List<List<dynamic>?> _dictionary = [];

  _HuffReader(List<Uint8List> huffs) {
    if (huffs.isEmpty) {
      throw MobiExtractException('HUFF/CDIC记录为空');
    }
    _loadHuff(huffs[0]);
    for (var i = 1; i < huffs.length; i++) {
      _loadCdic(huffs[i]);
    }
  }

  void _loadHuff(Uint8List huff) {
    // Validate 'HUFF\x00\x00\x00\x18' header
    if (huff.length < 16 ||
        huff[0] != 0x48 || // H
        huff[1] != 0x55 || // U
        huff[2] != 0x46 || // F
        huff[3] != 0x46 || // F
        huff[4] != 0x00 ||
        huff[5] != 0x00 ||
        huff[6] != 0x00 ||
        huff[7] != 0x18) {
      throw MobiExtractException('无效的HUFF记录头');
    }
    final off1 = _beU32(huff, 8);
    final off2 = _beU32(huff, 12);

    // dict1: 256 uint32 entries at off1.
    // Each value v -> (codelen=v&0x1f, term=v&0x80, maxcodeRaw=v>>8)
    // final maxcode = ((maxcodeRaw + 1) << (32 - codelen)) - 1
    if (off1 + 256 * 4 > huff.length) {
      throw MobiExtractException('HUFF dict1越界');
    }
    for (var i = 0; i < 256; i++) {
      final v = _beU32(huff, off1 + i * 4);
      final codelen = v & 0x1f;
      final term = v & 0x80;
      final maxcodeRaw = v >> 8;
      if (codelen == 0) {
        // Calibre asserts codelen != 0; be defensive and treat as unused.
        _dict1.add([0, 0, 0]);
        continue;
      }
      final maxcode = ((maxcodeRaw + 1) << (32 - codelen)) - 1;
      _dict1.add([codelen, term, maxcode]);
    }

    // dict2: 64 uint32 entries at off2 -> 32 (mincode, maxcode) pairs.
    // Index 0 is a placeholder for codelen 0.
    if (off2 + 64 * 4 > huff.length) {
      throw MobiExtractException('HUFF dict2越界');
    }
    _mincode.add(0);
    _maxcode.add(0);
    for (var codelen = 1; codelen <= 32; codelen++) {
      final base = off2 + (codelen - 1) * 8;
      final mincRaw = _beU32(huff, base);
      final maxcRaw = _beU32(huff, base + 4);
      _mincode.add(mincRaw << (32 - codelen));
      _maxcode.add(((maxcRaw + 1) << (32 - codelen)) - 1);
    }
  }

  void _loadCdic(Uint8List cdic) {
    // Validate 'CDIC\x00\x00\x00\x10' header
    if (cdic.length < 16 ||
        cdic[0] != 0x43 || // C
        cdic[1] != 0x44 || // D
        cdic[2] != 0x49 || // I
        cdic[3] != 0x43 || // C
        cdic[4] != 0x00 ||
        cdic[5] != 0x00 ||
        cdic[6] != 0x00 ||
        cdic[7] != 0x10) {
      throw MobiExtractException('无效的CDIC记录头');
    }
    final phrases = _beU32(cdic, 8);
    final bits = _beU32(cdic, 12);
    final already = _dictionary.length;
    var n = 1 << bits;
    final remaining = phrases - already;
    if (remaining < n) n = remaining;
    if (n < 0) n = 0;

    for (var i = 0; i < n; i++) {
      final offPos = 16 + i * 2;
      if (offPos + 2 > cdic.length) break;
      final off = _beU16(cdic, offPos);
      final blenPos = 16 + off;
      if (blenPos + 2 > cdic.length) {
        _dictionary.add([Uint8List(0), 0x8000]);
        continue;
      }
      final blen = _beU16(cdic, blenPos);
      final sliceLen = blen & 0x7fff;
      final flag = blen & 0x8000;
      final sliceStart = blenPos + 2;
      final sliceEnd =
          sliceStart + sliceLen <= cdic.length ? sliceStart + sliceLen : cdic.length;
      final slice = Uint8List.sublistView(cdic, sliceStart, sliceEnd);
      _dictionary.add([slice, flag]);
    }
  }

  /// Bit-by-bit Huffman decoder. Returns the concatenation of all emitted
  /// dictionary phrases as a flat list of bytes.
  List<int> unpack(Uint8List data) {
    if (data.isEmpty) return const <int>[];

    // Append 8 zero bytes so the 64-bit look-ahead never reads past the end.
    final padded = Uint8List(data.length + 8);
    padded.setRange(0, data.length, data);
    final bd = ByteData.sublistView(padded);

    var bitsleft = data.length * 8;
    var pos = 0;
    var x = bd.getUint64(0, Endian.big);
    var n = 32;
    final out = <int>[];

    while (true) {
      if (n <= 0) {
        pos += 4;
        if (pos + 8 > padded.length) break;
        x = bd.getUint64(pos, Endian.big);
        n += 32;
      }
      // 32-bit code window currently aligned at bit position n.
      final code = (x >>> n) & 0xFFFFFFFF;

      final entry = _dict1[code >> 24]; // index by top 8 bits
      var codelen = entry[0];
      if (codelen == 0) break; // unused entry — stop defensively
      final term = entry[1];
      var maxcode = entry[2];
      if (term == 0) {
        // Non-terminal: walk up codelens until code falls in range.
        while (codelen < _mincode.length && code < _mincode[codelen]) {
          codelen += 1;
        }
        if (codelen >= _maxcode.length) break;
        maxcode = _maxcode[codelen];
      }

      n -= codelen;
      bitsleft -= codelen;
      if (bitsleft < 0) break;

      final r = (maxcode - code) >>> (32 - codelen);
      if (r < 0 || r >= _dictionary.length) break;
      final dictEntry = _dictionary[r];
      if (dictEntry == null) break; // defensive: avoid infinite recursion

      Uint8List slice = dictEntry[0] as Uint8List;
      final flag = dictEntry[1] as int;
      if (flag == 0) {
        // Phrase itself is compressed — recursively unpack and cache.
        _dictionary[r] = null;
        slice = Uint8List.fromList(unpack(slice));
        _dictionary[r] = [slice, 0x8000];
      }
      out.addAll(slice);
    }
    return out;
  }

  static int _beU32(Uint8List b, int off) {
    return (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
  }

  static int _beU16(Uint8List b, int off) {
    return (b[off] << 8) | b[off + 1];
  }
}

/// MOBI 提取异常，携带诊断信息供 UI 显示。
class MobiExtractException implements Exception {
  final String message;
  MobiExtractException(this.message);
  @override
  String toString() => message;
}
