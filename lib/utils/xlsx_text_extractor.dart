/// XLSX 文本提取器
///
/// XLSX 是 ZIP 包，关键文件：
///   - xl/sharedStrings.xml  → 全局共享字符串表 <sst><si><t>文本</t></si></sst>
///   - xl/workbook.xml       → sheet 名称与顺序
///   - xl/worksheets/sheetN.xml → 每个 sheet 的单元格数据
///                              <c r="A1" t="s"><v>0</v></c>  (t="s"引用共享表下标0)
///                              <c r="B2"><v>123</v></c>       (无 t，数字直接取 <v>)
///                              <c r="C3" t="inlineStr"><is><t>内联</t></is></c>
///
/// 输出：每个 sheet 一段，标题为 "=== Sheet名 ==="，行内单元格用 \t 分隔。
///
/// v0.5.3 关键修复：
///   1. archive 包内置 ZipDecoder 在某些 xlsx 上抛 RangeError 导致整个解析失败。
///      本提取器先尝试 archive，若失败或返回异常数据，再用手写 ZIP 解析器兜底。
///   2. 把 archive.file.content 的 RangeError 当作"此 sheet 解压失败"计入 sheetFailures，
///      并把失败原因写进错误消息暴露给用户。
///   3. _parseSheet 完全 try-catch 包裹，绝不向 sheet 循环抛异常。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart' as archive;

class XlsxTextExtractor {
  static String extract(List<int> bytes) {
    // 文件头检测：区分 .xlsx（ZIP，PK\x03\x04）与 .xls（OLE2，D0CF11E0）
    if (bytes.length < 4) {
      throw Exception('文件过小，不是有效的 XLSX 文件');
    }
    // OLE2 复合文档头（.xls 旧格式）
    if (bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) {
      throw Exception('此文件是旧版 .xls 格式（二进制），请在电脑上用 Excel 另存为 .xlsx 格式后再导入');
    }
    // ZIP 头检测
    if (!(bytes[0] == 0x50 && bytes[1] == 0x4B)) {
      throw Exception('文件格式不正确（不是有效的 .xlsx 压缩包），请确认文件未损坏');
    }

    // v0.5.3 新方案：先尝试 archive 包，失败再用手写 ZIP 解析器
    final files = <String, Uint8List>{};
    var archiveOk = false;
    String? archiveError;
    try {
      final arc = archive.ZipDecoder().decodeBytes(bytes);
      archiveOk = true;
      for (final f in arc) {
        try {
          final data = f.content as dynamic;
          if (data is String) {
            files[f.name] = Uint8List.fromList(utf8.encode(data));
          } else if (data is List) {
            files[f.name] = Uint8List.fromList(List<int>.from(data));
          }
        } catch (e) {
          // 单个文件解压失败跳过，但记录原因
          archiveError ??= '$e';
        }
      }
    } catch (e) {
      archiveError = '$e';
    }

    // 如果 archive 包没拿到任何文件，或拿到的关键文件不全，用手写 ZIP 解析器兜底
    if (!archiveOk || files.isEmpty || !files.containsKey('xl/workbook.xml')) {
      try {
        final manualFiles = _ManualZip.parse(bytes);
        // 仅补充 archive 没拿到的文件
        for (final entry in manualFiles.entries) {
          files.putIfAbsent(entry.key, () => entry.value);
        }
      } catch (_) {
        // 手写解析器也失败，继续用已有的 files（即使不完整）
      }
    }

    if (files.isEmpty) {
      throw Exception(
          'XLSX 解压失败：archive 包报错($archiveError)，手写解析器也未提取到任何文件，文件可能已损坏或加密');
    }

    // 1. 解析 sharedStrings（可能不存在；解析失败则置空，t="s" 单元格将跳过）
    final sharedStrings = <String>[];
    final ssBytes = files['xl/sharedStrings.xml'];
    if (ssBytes != null) {
      try {
        final xml = utf8.decode(ssBytes, allowMalformed: true);
        final siRE = RegExp(r'<si[\s>](.*?)</si>', dotAll: true);
        final tRE = RegExp(r'<t(?:\s[^>]*)?>([^<]*)</t>');
        for (final siMatch in siRE.allMatches(xml)) {
          final siContent = siMatch.group(1) ?? '';
          final buf = StringBuffer();
          for (final tMatch in tRE.allMatches(siContent)) {
            buf.write(tMatch.group(1));
          }
          sharedStrings.add(_decodeXmlEntities(buf.toString()));
        }
      } catch (_) {
        // sharedStrings 损坏不致命，继续解析表格
      }
    }

    // 2. 解析 workbook.xml 获取 sheet 名称顺序
    final sheetNames = <String>[];
    final wbBytes = files['xl/workbook.xml'];
    if (wbBytes != null) {
      try {
        final wbXml = utf8.decode(wbBytes, allowMalformed: true);
        final nameRE = RegExp(r'<sheet\s[^>]*?name="([^"]+)"');
        for (final m in nameRE.allMatches(wbXml)) {
          sheetNames.add(_decodeXmlEntities(m.group(1)!));
        }
      } catch (_) {
        // workbook 解析失败不致命，sheet 名退化为 SheetN
      }
    }

    // 3. 收集所有 sheetN.xml，按 N 数字升序
    final sheetFiles = <int, Uint8List>{};
    for (final entry in files.entries) {
      final m = RegExp(r'^xl/worksheets/sheet(\d+)\.xml$').firstMatch(entry.key);
      if (m != null) {
        final idx = int.parse(m.group(1)!);
        sheetFiles[idx] = entry.value;
      }
    }
    final sortedKeys = sheetFiles.keys.toList()..sort();

    final buffer = StringBuffer();
    final failureReasons = <String>[];
    for (var i = 0; i < sortedKeys.length; i++) {
      final idx = sortedKeys[i];
      final f = sheetFiles[idx]!;
      final sheetTitle = i < sheetNames.length ? sheetNames[i] : 'Sheet$idx';

      String sheetText = '';
      try {
        final xml = utf8.decode(f, allowMalformed: true);
        sheetText = _parseSheet(xml, sharedStrings);
      } catch (e) {
        // 单 sheet 解析失败，记录具体原因，不阻止其他表
        failureReasons.add('$sheetTitle: $e');
        continue;
      }
      if (sheetText.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write('=== $sheetTitle ===\n');
        buffer.write(sheetText);
      }
    }

    if (buffer.isEmpty) {
      if (failureReasons.isNotEmpty) {
        // 把失败原因拼到错误消息里，方便定位真实问题
        final reasons = failureReasons.take(3).join('；');
        final more = failureReasons.length > 3
            ? '；等共 ${failureReasons.length} 个工作表失败'
            : '';
        return '（表格解析失败：${failureReasons.length} 个工作表无法读取。'
            '原因：$reasons$more）';
      }
      // 空表格不抛异常，返回友好提示（纯图表/图片型表格）
      return '（此表格无可读文本单元格，可能为纯图表或图片型表格）';
    }
    return buffer.toString();
  }

  static String _parseSheet(String xml, List<String> sharedStrings) {
    final buffer = StringBuffer();
    final rowRE = RegExp(r'<row\s[^>]*>(.*?)</row>', dotAll: true);
    final cellRE = RegExp(r'<c\s+([^>]*)>(.*?)</c>', dotAll: true);
    final vRE = RegExp(r'<v>([^<]*)</v>');
    final isRE = RegExp(r'<is>(.*?)</is>', dotAll: true);
    final tInlineRE = RegExp(r'<t(?:\s[^>]*)?>([^<]*)</t>');

    for (final rowMatch in rowRE.allMatches(xml)) {
      final rowContent = rowMatch.group(2) ?? '';
      final lineBuf = StringBuffer();
      for (final cellMatch in cellRE.allMatches(rowContent)) {
        final attrs = cellMatch.group(1) ?? '';
        final cellContent = cellMatch.group(2) ?? '';
        String? value;
        final tAttrMatch = RegExp(r't="([^"]+)"').firstMatch(attrs);
        final tAttr = tAttrMatch?.group(1);
        if (tAttr == 's') {
          final vMatch = vRE.firstMatch(cellContent);
          if (vMatch != null) {
            final v = vMatch.group(1);
            final idx = v == null ? -1 : (int.tryParse(v) ?? -1);
            if (idx >= 0 && idx < sharedStrings.length) {
              value = sharedStrings[idx];
            }
          }
        } else if (tAttr == 'inlineStr') {
          final isMatch = isRE.firstMatch(cellContent);
          if (isMatch != null) {
            final isContent = isMatch.group(1) ?? '';
            final buf = StringBuffer();
            for (final tMatch in tInlineRE.allMatches(isContent)) {
              buf.write(tMatch.group(1) ?? '');
            }
            value = _decodeXmlEntities(buf.toString());
          }
        } else {
          final vMatch = vRE.firstMatch(cellContent);
          if (vMatch != null) {
            value = vMatch.group(1);
          }
        }
        if (value != null && value.isNotEmpty) {
          if (lineBuf.isNotEmpty) lineBuf.write('\t');
          lineBuf.write(value);
        }
      }
      final line = lineBuf.toString();
      if (line.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line);
      }
    }
    return buffer.toString();
  }

  static String _decodeXmlEntities(String s) {
    try {
      return s
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .replaceAllMapped(
            RegExp(r'&#(\d+);'),
            (m) => String.fromCharCodes([int.parse(m.group(1)!)]),
          )
          .replaceAllMapped(
            RegExp(r'&#x([0-9a-fA-F]+);'),
            (m) => String.fromCharCodes([int.parse(m.group(1)!, radix: 16)]),
          );
    } catch (_) {
      return s;
    }
  }
}

/// 手写 ZIP 解析器（不依赖 archive 包）
///
/// 仅支持 ZIP 格式（PK\x03\x04 local file header），处理常见的 stored(0) 和 deflate(8)
/// 两种压缩方式。deflate 用 dart:io 的 ZLibDecoder(raw: true) 解压。
/// 作为 archive 包在特殊 xlsx 上抛 RangeError 时的兜底方案。
class _ManualZip {
  static Map<String, Uint8List> parse(List<int> bytes) {
    final result = <String, Uint8List>{};
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    var pos = 0;
    while (pos + 4 <= data.length) {
      // Local file header signature: 0x04034b50
      if (data[pos] != 0x50 || data[pos + 1] != 0x4B ||
          data[pos + 2] != 0x03 || data[pos + 3] != 0x04) {
        break;
      }
      if (pos + 30 > data.length) break;

      // 读取 local file header 字段（小端序）
      final compressionMethod = _readUint16(data, pos + 8);
      final compressedSize = _readUint32(data, pos + 18);
      final uncompressedSize = _readUint32(data, pos + 22);
      final fileNameLength = _readUint16(data, pos + 26);
      final extraFieldLength = _readUint16(data, pos + 28);

      final dataStart = pos + 30 + fileNameLength + extraFieldLength;
      if (dataStart > data.length) break;

      // 文件名
      final fileNameBytes = data.sublist(pos + 30, pos + 30 + fileNameLength);
      final fileName = utf8.decode(fileNameBytes, allowMalformed: true);

      // 数据
      final actualCompressedSize = compressedSize > 0
          ? compressedSize
          : _findNextLocalHeader(data, dataStart) - dataStart;
      if (actualCompressedSize <= 0 ||
          dataStart + actualCompressedSize > data.length) {
        // 无法定位下一个 header，停止
        break;
      }

      final compressedData = data.sublist(dataStart, dataStart + actualCompressedSize);
      Uint8List? fileData;
      try {
        if (compressionMethod == 0) {
          // stored
          fileData = compressedData;
        } else if (compressionMethod == 8) {
          // deflate (raw, no zlib header)
          final decoded = ZLibDecoder(raw: true).convert(compressedData.toList());
          fileData = Uint8List.fromList(decoded);
        }
      } catch (_) {
        // 解压失败跳过此文件
      }

      if (fileData != null && fileName.isNotEmpty && !fileName.endsWith('/')) {
        result[fileName] = fileData;
      }

      // 移动到下一个 local file header
      pos = dataStart + actualCompressedSize;
      // 兜底：如果 uncompressedSize 与实际不符，用 actualCompressedSize 推进
      if (uncompressedSize > 0 && compressionMethod == 0) {
        // stored，compressedSize 与 uncompressedSize 相同
      }
    }
    return result;
  }

  static int _readUint16(Uint8List data, int offset) {
    if (offset + 2 > data.length) return 0;
    return data[offset] | (data[offset + 1] << 8);
  }

  static int _readUint32(Uint8List data, int offset) {
    if (offset + 4 > data.length) return 0;
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  /// 当 compressedSize 为 0（data descriptor 模式）时，扫描下一个 local header
  static int _findNextLocalHeader(Uint8List data, int from) {
    for (var i = from; i + 4 <= data.length; i++) {
      if (data[i] == 0x50 && data[i + 1] == 0x4B &&
          data[i + 2] == 0x03 && data[i + 3] == 0x04) {
        return i;
      }
      // Central directory header 也标志着 local files 结束
      if (data[i] == 0x50 && data[i + 1] == 0x4B &&
          data[i + 2] == 0x01 && data[i + 3] == 0x02) {
        return i;
      }
    }
    return data.length;
  }
}
