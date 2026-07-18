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
library;

import 'dart:convert';
import 'package:archive/archive.dart';

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

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw Exception('XLSX 解压失败，文件可能已损坏或加密 ($e)');
    }

    // 1. 解析 sharedStrings（可能不存在；解析失败则置空，t="s" 单元格将跳过）
    final sharedStrings = <String>[];
    final ssFile = archive.findFile('xl/sharedStrings.xml');
    if (ssFile != null) {
      try {
        final xml = _decodeFile(ssFile);
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
    final wbFile = archive.findFile('xl/workbook.xml');
    if (wbFile != null) {
      final wbXml = _decodeFile(wbFile);
      // <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
      final nameRE = RegExp(r'<sheet\s[^>]*?name="([^"]+)"');
      for (final m in nameRE.allMatches(wbXml)) {
        sheetNames.add(_decodeXmlEntities(m.group(1)!));
      }
    }

    // 3. 收集所有 sheetN.xml，按 N 数字升序（仅读文件名，不解压）
    final sheetFiles = <int, ArchiveFile>{};
    try {
      for (final f in archive) {
        final name = f.name;
        final m = RegExp(r'^xl/worksheets/sheet(\d+)\.xml$').firstMatch(name);
        if (m != null) {
          final idx = int.parse(m.group(1)!);
          sheetFiles[idx] = f;
        }
      }
    } catch (_) {
      // 迭代异常时回退：逐个 findFile 尝试常见 sheet 序号
      for (var n = 1; n <= 32; n++) {
        final f = archive.findFile('xl/worksheets/sheet$n.xml');
        if (f != null) {
          sheetFiles[n] = f;
        }
      }
    }
    final sortedKeys = sheetFiles.keys.toList()..sort();

    final buffer = StringBuffer();
    int sheetFailures = 0;
    for (var i = 0; i < sortedKeys.length; i++) {
      final idx = sortedKeys[i];
      final f = sheetFiles[idx]!;
      final sheetTitle = i < sheetNames.length ? sheetNames[i] : 'Sheet$idx';
      String sheetText;
      try {
        final xml = _decodeFile(f);
        sheetText = _parseSheet(xml, sharedStrings);
      } catch (_) {
        sheetFailures++;
        continue; // 单个工作表解析失败不阻止其他表
      }
      if (sheetText.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write('=== $sheetTitle ===\n');
        buffer.write(sheetText);
      }
    }
    if (buffer.isEmpty) {
      if (sheetFailures > 0) {
        return '（表格解析失败：$sheetFailures 个工作表无法读取，可能使用了不支持的特性或文件损坏）';
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
            final idx = int.tryParse(vMatch.group(1)!) ?? -1;
            if (idx >= 0 && idx < sharedStrings.length) {
              value = sharedStrings[idx];
            }
          }
        } else if (tAttr == 'inlineStr') {
          final isMatch = isRE.firstMatch(cellContent);
          if (isMatch != null) {
            final isContent = isMatch.group(1)!;
            final buf = StringBuffer();
            for (final tMatch in tInlineRE.allMatches(isContent)) {
              buf.write(tMatch.group(1));
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

  static String _decodeFile(ArchiveFile file) {
    try {
      final data = file.content as dynamic;
      if (data is String) return data;
      if (data is List) {
        final bytes = List<int>.from(data);
        // xlsx 内 XML 强制 UTF-8，必须用 utf8.decode 正确解析多字节中文
        return utf8.decode(bytes, allowMalformed: true);
      }
      return data.toString();
    } catch (_) {
      // 解压/解码失败（如 archive 抛 RangeError）返回空串，调用方跳过该部件
      return '';
    }
  }

  static String _decodeXmlEntities(String s) {
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
  }
}
