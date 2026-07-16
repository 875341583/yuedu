/// EPUB解析服务
/// 解析EPUB文件（ZIP格式），提取文本内容和章节结构
///
/// EPUB结构：
/// 1. META-INF/container.xml → 指向OPF文件路径
/// 2. OPF文件（如content.opf）→ 元数据 + 清单(manifest) + 阅读顺序(spine)
/// 3. toc.ncx → 章节目录（标题与HTML文件对应关系）
/// 4. HTML/XHTML文件 → 实际正文内容
library;

import 'dart:convert';
import 'package:archive/archive.dart';

/// EPUB解析结果
class EpubBook {
  final String title;
  final String author;
  final List<EpubChapter> chapters;

  /// 全文文本（所有章节拼接，用\n\n分隔）
  final String fullText;

  EpubBook({
    required this.title,
    required this.author,
    required this.chapters,
    required this.fullText,
  });
}

/// EPUB章节
class EpubChapter {
  final String title;
  final String text;
  final int startOffset; // 在fullText中的起始偏移

  EpubChapter({
    required this.title,
    required this.text,
    required this.startOffset,
  });
}

class EpubParser {
  /// 解析EPUB字节数据
  static EpubBook parse(List<int> bytes) {
    // 1. 解压ZIP
    final archive = ZipDecoder().decodeBytes(bytes);

    // 2. 读取container.xml，找到OPF路径
    final containerFile = archive.findFile('META-INF/container.xml');
    if (containerFile == null) {
      throw Exception('Invalid EPUB: container.xml not found');
    }
    final containerXml = _decodeFile(containerFile);
    final opfPath = _extractOpfPath(containerXml);

    // 3. 解析OPF
    final opfFile = archive.findFile(opfPath);
    if (opfFile == null) {
      throw Exception('Invalid EPUB: OPF file not found at $opfPath');
    }
    final opfXml = _decodeFile(opfFile);
    final opfData = _parseOpf(opfXml);

    // 4. 解析NCX目录（获取章节标题）
    final ncxTitleMap = <String, String>{};
    if (opfData.ncxPath != null) {
      final ncxFile = archive.findFile(opfData.ncxPath!);
      if (ncxFile != null) {
        final ncxXml = _decodeFile(ncxFile);
        ncxTitleMap.addAll(_parseNcx(ncxXml));
      }
    }

    // 5. 按spine顺序读取HTML文件，提取文本
    final chapters = <EpubChapter>[];
    final textParts = <String>[];
    int currentOffset = 0;

    // OPF所在目录（用于解析相对路径）
    final opfDir = opfPath.contains('/') 
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) 
        : '';

    for (final href in opfData.spineHrefs) {
      final fullPath = opfDir + href;
      final htmlFile = archive.findFile(fullPath);
      if (htmlFile == null) continue;

      final htmlContent = _decodeFile(htmlFile);
      final text = _extractTextFromHtml(htmlContent);

      if (text.trim().isEmpty) continue;

      // 章节标题：优先从NCX获取，否则用文件名
      final chapterTitle = ncxTitleMap[href] ?? _deriveTitleFromHref(href);

      chapters.add(EpubChapter(
        title: chapterTitle,
        text: text,
        startOffset: currentOffset,
      ));

      textParts.add(text);
      currentOffset += text.length + 2; // +2 for \n\n separator
    }

    final fullText = textParts.join('\n\n');

    return EpubBook(
      title: opfData.title,
      author: opfData.author,
      chapters: chapters,
      fullText: fullText,
    );
  }

  /// 解码Archive文件为字符串（UTF-8）
  static String _decodeFile(ArchiveFile file) {
    final data = file.content as dynamic;
    if (data is String) return data;
    if (data is List) {
      final bytes = List<int>.from(data);
      return utf8.decode(bytes, allowMalformed: true);
    }
    return data.toString();
  }

  /// 从container.xml提取OPF文件路径
  static String _extractOpfPath(String xml) {
    // 简单正则提取 full-path 属性
    final match = RegExp(r'full-path="([^"]+)"').firstMatch(xml);
    return match?.group(1) ?? 'content.opf';
  }

  /// 解析OPF文件
  static _OpfData _parseOpf(String xml) {
    String title = '';
    String author = '';
    final manifest = <String, String>{}; // id → href
    final spineIdrefs = <String>[];
    String? ncxPath;

    // 提取标题
    final titleMatch = RegExp(r'<dc:title[^>]*>([^<]+)</dc:title>').firstMatch(xml);
    if (titleMatch != null) {
      title = _decodeHtmlEntities(titleMatch.group(1)!.trim());
    }

    // 提取作者
    final authorMatch = RegExp(r'<dc:creator[^>]*>([^<]+)</dc:creator>').firstMatch(xml);
    if (authorMatch != null) {
      author = _decodeHtmlEntities(authorMatch.group(1)!.trim());
    }

    // 提取manifest中的所有item（id → href）
    final itemPattern = RegExp(r'<item\s+[^>]*?id="([^"]*)"[^>]*?href="([^"]*)"[^>]*?media-type="([^"]*)"[^>]*?/?\s*>');
    for (final match in itemPattern.allMatches(xml)) {
      final id = match.group(1)!;
      final href = match.group(2)!;
      final mediaType = match.group(3)!;
      manifest[id] = href;
      if (mediaType == 'application/x-dtbncx+xml') {
        ncxPath = href;
      }
    }

    // 也尝试不按固定属性顺序的匹配
    if (manifest.isEmpty) {
      final itemPattern2 = RegExp(r'<item\s+([^>]*?)/?>');
      for (final match in itemPattern2.allMatches(xml)) {
        final attrs = match.group(1)!;
        final idMatch = RegExp(r'id="([^"]*)"').firstMatch(attrs);
        final hrefMatch = RegExp(r'href="([^"]*)"').firstMatch(attrs);
        final typeMatch = RegExp(r'media-type="([^"]*)"').firstMatch(attrs);
        if (idMatch != null && hrefMatch != null) {
          final id = idMatch.group(1)!;
          final href = hrefMatch.group(1)!;
          manifest[id] = href;
          if (typeMatch != null && typeMatch.group(1) == 'application/x-dtbncx+xml') {
            ncxPath = href;
          }
        }
      }
    }

    // 提取spine中的itemref idref（阅读顺序）
    final spinePattern = RegExp(r'<itemref\s+[^>]*?idref="([^"]*)"');
    for (final match in spinePattern.allMatches(xml)) {
      spineIdrefs.add(match.group(1)!);
    }

    // 将spine idref转换为href
    final spineHrefs = spineIdrefs
        .where((id) => manifest.containsKey(id))
        .map((id) => manifest[id]!)
        .toList();

    return _OpfData(
      title: title,
      author: author,
      spineHrefs: spineHrefs,
      ncxPath: ncxPath,
    );
  }

  /// 解析NCX目录，返回 href → 标题 的映射
  static Map<String, String> _parseNcx(String xml) {
    final result = <String, String>{};
    // 匹配navPoint中的label text和content src
    final navPattern = RegExp(
      r'<navPoint[^>]*>.*?<text>([^<]+)</text>.*?<content\s+src="([^"]+)"',
      dotAll: true,
    );
    for (final match in navPattern.allMatches(xml)) {
      final title = _decodeHtmlEntities(match.group(1)!.trim());
      var src = match.group(2)!;
      // 去掉锚点（#xxx）
      final hashIdx = src.indexOf('#');
      if (hashIdx >= 0) src = src.substring(0, hashIdx);
      result[src] = title;
    }
    return result;
  }

  /// 从HTML/XHTML中提取纯文本
  /// 转换<p>为段落分隔，<br>为换行，去除所有标签
  static String _extractTextFromHtml(String html) {
    var text = html;

    // 移除<head>部分（不需要样式和标题）
    text = text.replaceAll(RegExp(r'<head[^>]*>.*?</head>', dotAll: true), '');

    // 移除HTML注释
    text = text.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    // 移除<script>和<style>
    text = text.replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), '');
    text = text.replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), '');

    // 页面分隔标记
    text = text.replaceAll(RegExp(r'<div[^>]*class="mbp_pagebreak"[^>]*>.*?</div>', dotAll: true), '\n\n');

    // <br>转换为换行
    text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');

    // </p>转换为段落分隔
    text = text.replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n');
    text = text.replaceAll(RegExp(r'</div\s*>', caseSensitive: false), '\n\n');

    // </h1>~<h6>转换为段落分隔（标题）
    text = text.replaceAll(RegExp(r'</h[1-6]\s*>', caseSensitive: true), '\n\n');

    // 去除所有剩余HTML标签
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');

    // 解码HTML实体
    text = _decodeHtmlEntities(text);

    // 清理多余空白
    // 合并连续空格为单个空格（但保留换行）
    text = text.replaceAll(RegExp(r'[^\S\n]+'), ' ');
    // 合并3个以上换行为2个
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // 去除每行首尾空格
    text = text.split('\n').map((line) => line.trim()).join('\n');
    // 去除首尾空白
    text = text.trim();

    return text;
  }

  /// 解码常见HTML实体
  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&mdash;', '——')
        .replaceAll('&ndash;', '—')
        .replaceAll('&hellip;', '……')
        .replaceAll('&ldquo;', '\u201C')
        .replaceAll('&rdquo;', '\u201D')
        .replaceAll('&lsquo;', '\u2018')
        .replaceAll('&rsquo;', '\u2019')
        // 数字实体 &#1234; 和 &#x4D2;
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (m) => String.fromCharCodes([int.parse(m.group(1)!)]),
        )
        .replaceAllMapped(
          RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCodes([int.parse(m.group(1)!, radix: 16)]),
        );
  }

  /// 从href推导章节标题
  static String _deriveTitleFromHref(String href) {
    final fileName = href.split('/').last;
    final nameWithoutExt = fileName.replaceAll(RegExp(r'\.\w+$'), '');
    return nameWithoutExt;
  }
}

/// OPF解析结果
class _OpfData {
  final String title;
  final String author;
  final List<String> spineHrefs; // 按阅读顺序排列的HTML文件路径
  final String? ncxPath;

  _OpfData({
    required this.title,
    required this.author,
    required this.spineHrefs,
    this.ncxPath,
  });
}
