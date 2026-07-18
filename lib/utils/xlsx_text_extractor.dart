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
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw Exception('无效的 XLSX 文件：解压失败 ($e)');
    }

    // 1. 解析 sharedStrings
    final sharedStrings = <String>[];
    final ssFile = archive.findFile('xl/sharedStrings.xml');
    if (ssFile != null) {
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

    // 3. 收集所有 sheetN.xml，按 N 数字升序
    final sheetFiles = <int, ArchiveFile>{};
    for (final f in archive) {
      final name = f.name;
      final m = RegExp(r'^xl/worksheets/sheet(\d+)\.xml$').firstMatch(name);
      if (m != null) {
        final idx = int.parse(m.group(1)!);
        sheetFiles[idx] = f;
      }
    }
    final sortedKeys = sheetFiles.keys.toList()..sort();

    final buffer = StringBuffer();
    for (var i = 0; i < sortedKeys.length; i++) {
      final idx = sortedKeys[i];
      final f = sheetFiles[idx]!;
      final sheetTitle = i < sheetNames.length ? sheetNames[i] : 'Sheet$idx';
      final xml = _decodeFile(f);
      final sheetText = _parseSheet(xml, sharedStrings);
      if (sheetText.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write('=== $sheetTitle ===\n');
        buffer.write(sheetText);
      }
    }
    if (buffer.isEmpty) {
      throw Exception('XLSX 文件无可读单元格');
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
    final data = file.content as dynamic;
    if (data is String) return data;
    if (data is List) {
      final bytes = List<int>.from(data);
      // xlsx 内 XML 强制 UTF-8，必须用 utf8.decode 正确解析多字节中文
      return utf8.decode(bytes, allowMalformed: true);
    }
    return data.toString();
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
