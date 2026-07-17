/// Pure Dart MOBI text extractor.
///
/// Parses the PDB container format, decompresses PalmDOC RLE records,
/// and strips HTML tags to produce plain text. Works for typical MOBI
/// files with PalmDOC compression (compression type 1) or no compression
/// (type 0). Huffman-compressed files (type 2) and DRM-protected files
/// are not supported — [extract] returns null for them.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Extracts text content from a MOBI file using pure Dart (no FFI).
class MobiTextExtractor {
  /// Extract all text from [filePath].
  /// Returns null if extraction fails; empty string if no text was found.
  static String? extract(String filePath) {
    try {
      final bytes = File(filePath).readAsBytesSync();
      return _extractFromBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  static String? _extractFromBytes(Uint8List bytes) {
    if (bytes.length < 78) return null;

    // --- PDB header ---
    // numRecords at offset 76 (2 bytes big-endian)
    final numRecords = _beUint16(bytes, 76);
    if (numRecords < 2) return null; // record 0 = header + at least 1 text record

    // Record info entries start at offset 78, each 8 bytes (4 offset + 1 attr + 3 uid)
    final offsets = <int>[];
    for (var i = 0; i < numRecords; i++) {
      final off = 78 + i * 8;
      if (off + 4 > bytes.length) return null;
      offsets.add(_beUint32(bytes, off));
    }
    // Sentinel: last record extends to end of file
    offsets.add(bytes.length);

    // Validate offsets are sorted and within file bounds
    for (final o in offsets) {
      if (o < 0 || o > bytes.length) return null;
    }

    // --- PalmDOC header (first 16 bytes of record 0) ---
    final rec0Start = offsets[0];
    final rec0End = offsets[1];
    if (rec0End - rec0Start < 16) return null;

    final compression = _beUint32(bytes, rec0Start);
    final textLength = _beUint32(bytes, rec0Start + 8);
    final recordCount = _beUint16(bytes, rec0Start + 12);

    // Only PalmDOC RLE (1) and no compression (0) are supported.
    // Huffman (2) is too complex; anything else is unknown.
    if (compression != 0 && compression != 1) return null;

    // --- Decompress text records (record 1 .. N) ---
    // Use the declared recordCount when available, else fall back to all
    // remaining records.
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

      final recData = Uint8List.sublistView(bytes, start, end);
      List<int> decoded;
      if (compression == 1) {
        decoded = _palmdocDecompress(recData);
      } else {
        decoded = recData.toList();
      }
      decompressed.addAll(decoded);

      // Stop early if we already have all declared text
      if (textLength > 0 && decompressed.length >= textLength) break;
    }

    if (decompressed.isEmpty) return null;

    // Truncate to declared text length
    List<int> textBytes;
    if (textLength > 0 && textLength < decompressed.length) {
      textBytes = decompressed.sublist(0, textLength);
    } else {
      textBytes = decompressed;
    }

    // --- Decode bytes ---
    // MOBI text encoding is usually UTF-8 (65001) or CP1252 (1252).
    // Try strict UTF-8 first, then fall back to CP1252.
    String raw;
    try {
      raw = utf8.decode(textBytes, allowMalformed: false);
    } catch (_) {
      raw = _decodeCp1252(textBytes);
    }

    // --- Strip HTML tags ---
    final text = _stripHtml(raw);
    if (text.isEmpty) return null;
    return text;
  }

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
  /// - 0x80..0xBF     : pair (c, next); if pair >= 0x2000 output space +
  ///                    (next & 0x7F); else back-reference (distance, length)
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
        if (i < len) {
          final b = data[i];
          i++;
          final pair = ((c & 0x3F) << 8) | b;
          if (pair >= 0x2000) {
            out.add(0x20); // space
            out.add(b & 0x7F);
          } else {
            // Back-reference: sliding window copy (allows overlap)
            final distance = pair >> 3;
            final length = (pair & 7) + 1;
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
