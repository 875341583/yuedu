/// PPTX 文本提取器
///
/// PPTX 是 ZIP 包，每张幻灯片位于 ppt/slides/slideN.xml，结构为：
///   <a:p> 段落
///     <a:r> 文本运行
///       <a:t>实际文本</a:t>
///     </a:r>
///   </a:p>
///
/// 本提取器返回每张幻灯片的文本列表（List<String>，按页码顺序），
/// 供 PptxReaderPage 按页展示。
library;

import 'dart:convert';
import 'package:archive/archive.dart';

class PptxSlides {
  /// 每张幻灯片的文本（index 0 = 第1页），按页码顺序
  final List<String> pages;

  PptxSlides(this.pages);

  int get pageCount => pages.length;
}

class PptxTextExtractor {
  /// 从 pptx 字节流提取每页文本
  static PptxSlides extract(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw Exception('无效的 PPTX 文件：解压失败 ($e)');
    }

    // 收集 ppt/slides/slideN.xml，按 N 数字升序
    final slideFiles = <int, ArchiveFile>{};
    for (final f in archive) {
      final m = RegExp(r'^ppt/slides/slide(\d+)\.xml$').firstMatch(f.name);
      if (m != null) {
        final idx = int.parse(m.group(1)!);
        slideFiles[idx] = f;
      }
    }
    if (slideFiles.isEmpty) {
      throw Exception('PPTX 文件未找到幻灯片（ppt/slides/slideN.xml）');
    }
    final sortedKeys = slideFiles.keys.toList()..sort();

    final pages = <String>[];
    for (final idx in sortedKeys) {
      final f = slideFiles[idx]!;
      final xml = _decodeFile(f);
      pages.add(_parseSlide(xml));
    }
    return PptxSlides(pages);
  }

  /// 解析单张幻灯片，按 <a:p> 段落分行，<a:t> 拼接
  static String _parseSlide(String xml) {
    final buffer = StringBuffer();
    // 移除 namespace 有时让 <a:p> 匹配更宽松（已包含 <a:t> 限定已足够）
    // 按 <a:p 切段
    final splitRE = RegExp(r'<a:p[\s/>]');
    final parts = xml.split(splitRE);
    for (var i = 1; i < parts.length; i++) {
      var segment = parts[i];
      final endIdx = segment.indexOf('</a:p>');
      if (endIdx >= 0) {
        segment = segment.substring(0, endIdx);
      }
      final tRE = RegExp(r'<a:t(?:\s[^>]*)?>([^<]*)</a:t>');
      final lineBuf = StringBuffer();
      for (final m in tRE.allMatches(segment)) {
        lineBuf.write(_decodeXmlEntities(m.group(1) ?? ''));
      }
      // <a:br/> 换行
      if (segment.contains('<a:br')) {
        lineBuf.write('\n');
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
      // pptx 内 XML 强制 UTF-8，必须用 utf8.decode 正确解析多字节中文
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
