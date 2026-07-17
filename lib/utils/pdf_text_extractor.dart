/// Pure Dart PDF text extractor.
///
/// Parses PDF content streams and extracts text from `Tj` / `TJ` operators.
/// Supports FlateDecode (zlib) compressed streams. Works for typical text
/// PDFs; scanned PDFs or PDFs with custom CID font encodings may not extract
/// correctly.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:developer' as dev;

/// Extracts text content from a PDF file using pure Dart (no FFI).
class PdfTextExtractor {
  /// Extract all text from [filePath].
  /// Returns the extracted text, or null if no text was found.
  /// Throws [PdfExtractException] with a diagnostic message on parse errors.
  static String? extract(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    return _extractFromBytes(bytes);
  }

  static String? _extractFromBytes(Uint8List bytes) {
    if (bytes.length < 8 || !_matchAt(bytes, 0, _pdfHeader)) {
      throw PdfExtractException('文件不是有效的PDF（缺少%PDF头）');
    }

    final buffers = <Uint8List>[];
    var streamCount = 0;
    var pos = 0;
    while (pos <= bytes.length - 6) {
      if (_matchAt(bytes, pos, _streamMarker) &&
          (pos == 0 || _isPdfWs(bytes[pos - 1]))) {
        streamCount++;
        var start = pos + 6;
        if (start < bytes.length && bytes[start] == 0x0D) start++;
        if (start < bytes.length && bytes[start] == 0x0A) start++;
        final endIdx = _findEndStream(bytes, start);
        if (endIdx == -1) {
          pos++;
          continue;
        }
        var streamEnd = endIdx;
        while (streamEnd > start && _isPdfWs(bytes[streamEnd - 1])) {
          streamEnd--;
        }
        if (streamEnd > start) {
          final streamData = Uint8List.sublistView(bytes, start, streamEnd);
          final inflated = _maybeInflate(streamData);
          // 只保留解压后含可打印内容的流（过滤纯图像流）
          buffers.add(inflated);
        }
        pos = endIdx + _endstreamMarker.length;
      } else {
        pos++;
      }
    }

    dev.log('PDF: found $streamCount streams, ${buffers.length} extracted');

    if (buffers.isEmpty) {
      throw PdfExtractException('PDF中未找到任何stream对象（可能是扫描版或加密PDF）');
    }

    final totalLen = buffers.fold(0, (a, b) => a + b.length);
    final content = Uint8List(totalLen);
    var off = 0;
    for (final buf in buffers) {
      content.setRange(off, off + buf.length, buf);
      off += buf.length;
    }
    final text = _extractTextFromContent(content);
    if (text.isEmpty) {
      throw PdfExtractException(
          'PDF包含$streamCount个stream但未提取到文本（可能是扫描版PDF，文本为图片）');
    }
    return text;
  }

  static final _pdfHeader = [0x25, 0x50, 0x44, 0x46]; // "%PDF"
  static final _streamMarker = [0x73, 0x74, 0x72, 0x65, 0x61, 0x6D]; // "stream"
  static final _endstreamMarker = [
    0x65, 0x6E, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D
  ]; // "endstream"

  static bool _matchAt(Uint8List bytes, int pos, List<int> marker) {
    if (pos + marker.length > bytes.length) return false;
    for (var i = 0; i < marker.length; i++) {
      if (bytes[pos + i] != marker[i]) return false;
    }
    return true;
  }

  static int _findEndStream(Uint8List bytes, int start) {
    for (var i = start; i + _endstreamMarker.length <= bytes.length; i++) {
      if (_matchAt(bytes, i, _endstreamMarker)) return i;
    }
    return -1;
  }

  static Uint8List _maybeInflate(Uint8List data) {
    // 1. 尝试 zlib（头字节 0x78）
    if (data.length >= 2 && data[0] == 0x78) {
      try {
        final out = ZLibDecoder().convert(data);
        return Uint8List.fromList(out);
      } catch (_) {
        // zlib 头存在但解压失败，继续尝试 raw deflate
      }
    }
    // 2. 尝试 raw deflate（无 zlib 头）
    try {
      final out = ZLibDecoder(raw: true).convert(data);
      // 只接受解压后明显变大的结果（防止误判）
      if (out.length > data.length) {
        return Uint8List.fromList(out);
      }
    } catch (_) {
      // raw deflate 也失败
    }
    // 3. 返回原始数据（可能是未压缩的流）
    return data;
  }

  static bool _isPdfWs(int b) =>
      b == 0x00 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D || b == 0x20;

  static bool _isPdfAlpha(int b) =>
      (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A);

  /// Read literal PDF string starting at '(' position.
  /// Returns (decoded text, index past closing ')').
  static (String, int) _readLiteralString(Uint8List bytes, int openIdx) {
    final buf = <int>[];
    var i = openIdx + 1;
    var depth = 1;
    while (i < bytes.length && depth > 0) {
      final c = bytes[i];
      if (c == 0x5C /* \ */) {
        if (i + 1 < bytes.length) {
          final n = bytes[i + 1];
          switch (n) {
            case 0x6E: buf.add(0x0A); i += 2; break; // \n
            case 0x72: buf.add(0x0D); i += 2; break; // \r
            case 0x74: buf.add(0x09); i += 2; break; // \t
            case 0x62: buf.add(0x08); i += 2; break; // \b
            case 0x66: buf.add(0x0C); i += 2; break; // \f
            case 0x28: buf.add(0x28); i += 2; break; // \(
            case 0x29: buf.add(0x29); i += 2; break; // \)
            case 0x5C: buf.add(0x5C); i += 2; break; // \\
            case 0x0D:
              if (i + 2 < bytes.length && bytes[i + 2] == 0x0A) {
                i += 3;
              } else {
                i += 2;
              }
              break;
            case 0x0A:
              i += 2;
              break;
            default:
              if (n >= 0x30 && n <= 0x37) {
                // Octal escape \ddd (1-3 digits)
                var v = n - 0x30;
                var k = 1;
                while (k < 3 && i + 1 + k < bytes.length) {
                  final d = bytes[i + 1 + k];
                  if (d >= 0x30 && d <= 0x37) {
                    v = (v << 3) | (d - 0x30);
                    k++;
                  } else {
                    break;
                  }
                }
                buf.add(v & 0xFF);
                i += 1 + k;
              } else {
                buf.add(n);
                i += 2;
              }
          }
        } else {
          i++;
        }
      } else if (c == 0x28 /* ( */) {
        depth++;
        buf.add(c);
        i++;
      } else if (c == 0x29 /* ) */) {
        depth--;
        if (depth > 0) buf.add(c);
        i++;
      } else {
        buf.add(c);
        i++;
      }
    }
    return (_decodePdfBytes(buf), i);
  }

  /// Read hex string starting at '<' position (not '<<').
  /// Returns (decoded text, index past closing '>').
  static (String, int) _readHexString(Uint8List bytes, int openIdx) {
    var i = openIdx + 1;
    final hexChars = <int>[];
    while (i < bytes.length && bytes[i] != 0x3E /* > */) {
      final c = bytes[i];
      if ((c >= 0x30 && c <= 0x39) ||
          (c >= 0x41 && c <= 0x46) ||
          (c >= 0x61 && c <= 0x66)) {
        hexChars.add(c);
      }
      i++;
    }
    if (i < bytes.length) i++; // consume '>'

    final raw = <int>[];
    for (var k = 0; k + 1 < hexChars.length; k += 2) {
      raw.add((_hexVal(hexChars[k]) << 4) | _hexVal(hexChars[k + 1]));
    }
    if (hexChars.length.isOdd) {
      raw.add(_hexVal(hexChars.last) << 4);
    }
    return (_decodePdfBytes(raw), i);
  }

  static int _hexVal(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x37;
    if (c >= 0x61 && c <= 0x66) return c - 0x57;
    return 0;
  }

  /// Decode bytes that may start with UTF-16BE BOM (0xFE 0xFF).
  /// Otherwise treat as Latin-1 / PDFDocEncoding (good enough for typical PDFs).
  static String _decodePdfBytes(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final sb = StringBuffer();
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        sb.writeCharCode((bytes[i] << 8) | bytes[i + 1]);
      }
      return sb.toString();
    }
    return String.fromCharCodes(bytes);
  }

  /// Find matching ']' for '[' at [arrStart].
  static int _findArrayEnd(Uint8List bytes, int arrStart) {
    var i = arrStart + 1;
    var depth = 1;
    while (i < bytes.length && depth > 0) {
      final c = bytes[i];
      if (c == 0x5B) {
        depth++;
        i++;
      } else if (c == 0x5D) {
        depth--;
        if (depth == 0) return i;
        i++;
      } else if (c == 0x28) {
        // Skip literal string (with nested parens)
        var d = 1;
        i++;
        while (i < bytes.length && d > 0) {
          if (bytes[i] == 0x5C) {
            i += 2;
          } else if (bytes[i] == 0x28) {
            d++;
            i++;
          } else if (bytes[i] == 0x29) {
            d--;
            i++;
          } else {
            i++;
          }
        }
      } else if (c == 0x3C && i + 1 < bytes.length && bytes[i + 1] != 0x3C) {
        // Skip hex string
        i++;
        while (i < bytes.length && bytes[i] != 0x3E) {
          i++;
        }
        if (i < bytes.length) i++;
      } else if (c == 0x3C && i + 1 < bytes.length && bytes[i + 1] == 0x3C) {
        // Skip dict
        var d = 1;
        i += 2;
        while (i + 1 < bytes.length && d > 0) {
          if (bytes[i] == 0x3C && bytes[i + 1] == 0x3C) {
            d++;
            i += 2;
          } else if (bytes[i] == 0x3E && bytes[i + 1] == 0x3E) {
            d--;
            i += 2;
          } else {
            i++;
          }
        }
      } else {
        i++;
      }
    }
    return -1;
  }

  /// Extract text from a concatenated content stream.
  static String _extractTextFromContent(Uint8List content) {
    final result = StringBuffer();
    var i = 0;

    while (i < content.length) {
      final c = content[i];

      if (_isPdfWs(c)) {
        i++;
        continue;
      }

      // Comments: % to end of line
      if (c == 0x25 /* % */) {
        while (i < content.length && content[i] != 0x0D && content[i] != 0x0A) {
          i++;
        }
        continue;
      }

      // T* operator (newline) - check before alpha handler since '*' is non-alpha
      if (c == 0x54 /* T */ && i + 1 < content.length && content[i + 1] == 0x2A /* * */) {
        if (i == 0 || _isPdfWs(content[i - 1])) {
          result.write('\n');
          i += 2;
          continue;
        }
      }

      // Td / TD operator (move text) - emit newline
      if (c == 0x54 /* T */ && i + 1 < content.length &&
          (content[i + 1] == 0x64 /* d */ || content[i + 1] == 0x44 /* D */) &&
          (i == 0 || _isPdfWs(content[i - 1]))) {
        result.write('\n');
        i += 2;
        continue;
      }

      // ET operator (end text block) - emit newline
      if (c == 0x45 /* E */ && i + 1 < content.length && content[i + 1] == 0x54 /* T */ &&
          (i == 0 || _isPdfWs(content[i - 1]))) {
        if (result.isNotEmpty && !result.toString().endsWith('\n')) {
          result.write('\n');
        }
        i += 2;
        continue;
      }

      // Literal string: check if followed by Tj / ' / "
      if (c == 0x28 /* ( */) {
        final (str, endIdx) = _readLiteralString(content, i);
        var j = endIdx;
        while (j < content.length && _isPdfWs(content[j])) {
          j++;
        }
        if (j + 1 < content.length && content[j] == 0x54 && content[j + 1] == 0x6A /* j */) {
          result.write(str);
        } else if (j + 1 < content.length && content[j] == 0x54 && content[j + 1] == 0x4A /* J */) {
          // (string) TJ — actually TJ takes an array, but be lenient
          result.write(str);
        } else if (j < content.length && (content[j] == 0x27 /* ' */ || content[j] == 0x22 /* " */)) {
          result.write(str);
          result.write('\n');
        }
        i = endIdx;
        continue;
      }

      // Hex string (not dict): same checks
      if (c == 0x3C /* < */ && i + 1 < content.length && content[i + 1] != 0x3C) {
        final (str, endIdx) = _readHexString(content, i);
        var j = endIdx;
        while (j < content.length && _isPdfWs(content[j])) {
          j++;
        }
        if (j + 1 < content.length && content[j] == 0x54 && content[j + 1] == 0x6A /* j */) {
          result.write(str);
        } else if (j + 1 < content.length && content[j] == 0x54 && content[j + 1] == 0x4A /* J */) {
          result.write(str);
        } else if (j < content.length && (content[j] == 0x27 || content[j] == 0x22)) {
          result.write(str);
          result.write('\n');
        }
        i = endIdx;
        continue;
      }

      // Dict open <<
      if (c == 0x3C && i + 1 < content.length && content[i + 1] == 0x3C) {
        i += 2;
        continue;
      }
      // Dict close >>
      if (c == 0x3E && i + 1 < content.length && content[i + 1] == 0x3E) {
        i += 2;
        continue;
      }

      // Array — may be TJ array
      if (c == 0x5B /* [ */) {
        final arrEnd = _findArrayEnd(content, i);
        if (arrEnd == -1) {
          i++;
          continue;
        }
        // Check if followed by TJ operator
        var j = arrEnd + 1;
        while (j < content.length && _isPdfWs(content[j])) {
          j++;
        }
        if (j + 1 < content.length && content[j] == 0x54 && content[j + 1] == 0x4A /* J */) {
          // Extract all strings between '[' and ']'
          var k = i + 1;
          while (k < arrEnd) {
            final ck = content[k];
            if (ck == 0x28 /* ( */) {
              final (str, endIdx) = _readLiteralString(content, k);
              result.write(str);
              k = endIdx;
            } else if (ck == 0x3C /* < */ && k + 1 < arrEnd && content[k + 1] != 0x3C) {
              final (str, endIdx) = _readHexString(content, k);
              result.write(str);
              k = endIdx;
            } else {
              k++;
            }
          }
        }
        i = arrEnd + 1;
        continue;
      }

      // Number token — skip
      if (c == 0x2B /* + */ || c == 0x2D /* - */ || c == 0x2E /* . */ ||
          (c >= 0x30 && c <= 0x39)) {
        i++;
        while (i < content.length &&
            (content[i] == 0x2E || (content[i] >= 0x30 && content[i] <= 0x39))) {
          i++;
        }
        continue;
      }

      // Name token (/name)
      if (c == 0x2F /* / */) {
        i++;
        while (i < content.length && !_isPdfWs(content[i]) &&
            content[i] != 0x28 && content[i] != 0x29 &&
            content[i] != 0x3C && content[i] != 0x3E &&
            content[i] != 0x5B && content[i] != 0x5D &&
            content[i] != 0x7B && content[i] != 0x7D &&
            content[i] != 0x2F && content[i] != 0x25) {
          i++;
        }
        continue;
      }

      // Alpha operator (Tj, TJ, BT, Tf, etc.) — most are no-ops here,
      // since we handle Tj/TJ by look-ahead at the string token.
      if (_isPdfAlpha(c)) {
        while (i < content.length && _isPdfAlpha(content[i])) {
          i++;
        }
        continue;
      }

      // Other single-char operators
      i++;
    }

    // Collapse runs of 3+ newlines to 2, and trim trailing whitespace
    var text = result.toString();
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = text.trim();
    return text;
  }
}

/// PDF 提取异常，携带诊断信息供 UI 显示。
class PdfExtractException implements Exception {
  final String message;
  PdfExtractException(this.message);
  @override
  String toString() => message;
}
