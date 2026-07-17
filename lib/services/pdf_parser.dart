/// PDF解析服务
/// 通过Rust FFI调用pdf-extract crate提取PDF文本内容；
/// FFI不可用时回退到纯Dart提取器（PdfTextExtractor）。
library;

import 'dart:io';

import '../typeset/rust_ffi.dart';
import '../utils/pdf_text_extractor.dart';
import '../models/book.dart';

/// PDF解析结果
class PdfBook {
  final String title;
  final String author;
  final int pageCount;
  final List<Chapter> chapters;
  final String fullText;

  PdfBook({
    required this.title,
    required this.author,
    required this.pageCount,
    required this.chapters,
    required this.fullText,
  });
}

class PdfParser {
  /// 解析PDF文件，提取文本和章节信息
  /// 失败时抛出 [Exception]，携带具体诊断信息。
  static Future<PdfBook?> parse(String filePath) async {
    // 1. 先尝试 Rust FFI
    String? text;
    final engine = RustTypesetEngine();
    try {
      text = engine.extractPdfText(filePath);
    } catch (_) {
      text = null;
    } finally {
      engine.dispose();
    }

    // 2. FFI 失败或返回空 → 回退到纯 Dart 提取器（Android 等无 FFI 平台兜底）
    if (text == null || text.trim().isEmpty) {
      // PdfTextExtractor.extract 失败时会抛出 PdfExtractException（含诊断信息）
      text = PdfTextExtractor.extract(filePath);
    }

    if (text == null || text.trim().isEmpty) {
      throw Exception('PDF文本提取返回空结果');
    }

    // 从文件路径推导标题
    final title = _deriveTitleFromPath(filePath);

    // 简单分页：按连续两个换行符分段，每段视为一页/章节
    final pages = text.split(RegExp(r'\n{2,}'));
    final chapters = <Chapter>[];
    int currentOffset = 0;

    for (int i = 0; i < pages.length; i++) {
      final pageText = pages[i].trim();
      if (pageText.isEmpty) continue;

      // 尝试从页面文本开头提取章节标题
      final chapterTitle = _extractChapterTitle(pageText) ?? '第${i + 1}页';

      chapters.add(Chapter(
        title: chapterTitle,
        startOffset: currentOffset,
        endOffset: currentOffset + pageText.length,
      ));

      currentOffset += pageText.length + 2; // +2 for \n\n
    }

    return PdfBook(
      title: title,
      author: '未知',
      pageCount: pages.where((p) => p.trim().isNotEmpty).length,
      chapters: chapters,
      fullText: text,
    );
  }

  /// 从文件路径推导标题
  static String _deriveTitleFromPath(String path) {
    final fileName = File(path).uri.pathSegments.last;
    return fileName.replaceAll(RegExp(r'\.\w+$'), '');
  }

  /// 尝试从文本开头提取章节标题
  /// 匹配常见格式如"第一章 xxx"、"Chapter 1 xxx"等
  static String? _extractChapterTitle(String text) {
    final lines = text.split('\n');
    if (lines.isEmpty) return null;

    final firstLine = lines.first.trim();
    // 匹配中文章节格式
    final cnMatch = RegExp(r'^(第[一二三四五六七八九十百千万零\d]+[章节回集卷篇])[：:\s]*(.*)$').firstMatch(firstLine);
    if (cnMatch != null) {
      return cnMatch.group(2)?.isNotEmpty == true
          ? '${cnMatch.group(1)} ${cnMatch.group(2)}'
          : cnMatch.group(1);
    }

    // 匹配英文章节格式
    final enMatch = RegExp(r'^(Chapter|Part|Section)\s+(\d+\.?\d*)\s*(.*)$', caseSensitive: false).firstMatch(firstLine);
    if (enMatch != null) {
      return enMatch.group(3)?.isNotEmpty == true
          ? '${enMatch.group(1)} ${enMatch.group(2)} ${enMatch.group(3)}'
          : '${enMatch.group(1)} ${enMatch.group(2)}';
    }

    // 如果首行很短（<=20字符），可能是标题
    if (firstLine.length <= 20 && firstLine.length >= 2) {
      return firstLine;
    }

    return null;
  }
}
