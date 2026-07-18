/// DOCX 文本提取器
///
/// DOCX 是 ZIP 包，正文位于 word/document.xml，结构为：
///   <w:p> 段落
///     <w:r> 文本运行
///       <w:t>实际文本</w:t>
///     </w:r>
///   </w:p>
///
/// 本提取器解包后按 <w:p> 切段，提取每个段落内所有 <w:t> 拼接为一行，
/// 段落之间用换行分隔，输出纯文本。
library;

import 'dart:convert';
import 'package:archive/archive.dart';

class DocxTextExtractor {
  /// 从 docx 字节流提取纯文本
  static String extract(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw Exception('无效的 DOCX 文件：解压失败 ($e)');
    }

    final docFile = archive.findFile('word/document.xml');
    if (docFile == null) {
      throw Exception('无效的 DOCX 文件：缺少 word/document.xml');
    }
    final xml = _decodeFile(docFile);
    return _parseDocumentXml(xml);
  }

  static String _parseDocumentXml(String xml) {
    final buffer = StringBuffer();
    // 按 <w:p> 或 <w:p ...> 切段（段落）
    final paragraphSplitRE = RegExp(r'<w:p[\s/>]');
    final parts = xml.split(paragraphSplitRE);
    // parts[0] 是 <w:p 之前的内容，跳过
    for (var i = 1; i < parts.length; i++) {
      var segment = parts[i];
      // 截到 </w:p>
      final endIdx = segment.indexOf('</w:p>');
      if (endIdx >= 0) {
        segment = segment.substring(0, endIdx);
      }
      // 提取该段落所有 <w:t>...</w:t> 或 <w:t xml:space="preserve">...</w:t>
      final tRE = RegExp(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>');
      final lineBuf = StringBuffer();
      for (final m in tRE.allMatches(segment)) {
        lineBuf.write(_decodeXmlEntities(m.group(1) ?? ''));
      }
      // <w:tab/> → 制表符；<w:br/> → 换行
      if (segment.contains('<w:tab')) {
        lineBuf.write('\t');
      }
      final line = lineBuf.toString();
      if (line.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line);
      }
    }
    return buffer.toString();
  }

  /// 解码 ArchiveFile 为字符串（兼容 archive 4.0 的 content 类型）
  static String _decodeFile(ArchiveFile file) {
    final data = file.content as dynamic;
    if (data is String) return data;
    if (data is List) {
      final bytes = List<int>.from(data);
      // docx 内 XML 强制 UTF-8，必须用 utf8.decode 正确解析多字节中文
      return utf8.decode(bytes, allowMalformed: true);
    }
    return data.toString();
  }

  /// 解码 XML 常见实体
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
