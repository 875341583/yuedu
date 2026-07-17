/// MOBI解析服务
/// 通过Rust FFI调用mobi crate提取MOBI文本内容
library;

import 'dart:io';

import '../typeset/rust_ffi.dart';
import '../models/book.dart';

/// MOBI解析结果
class MobiBook {
  final String title;
  final String author;
  final List<Chapter> chapters;
  final String fullText;

  MobiBook({
    required this.title,
    required this.author,
    required this.chapters,
    required this.fullText,
  });
}

class MobiParser {
  /// 解析MOBI文件，提取文本和章节信息
  static Future<MobiBook?> parse(String filePath) async {
    final engine = RustTypesetEngine();
    try {
      final text = engine.extractMobiText(filePath);
      if (text == null || text.trim().isEmpty) return null;

      // 从文件路径推导标题
      final title = _deriveTitleFromPath(filePath);

      // MOBI内容已经由Rust端去HTML标签，
      // 按连续两个换行符分段，识别章节
      final chapters = _extractChapters(text);

      return MobiBook(
        title: title,
        author: '未知',
        chapters: chapters,
        fullText: text,
      );
    } catch (e) {
      return null;
    } finally {
      engine.dispose();
    }
  }

  /// 从文件路径推导标题
  static String _deriveTitleFromPath(String path) {
    final fileName = File(path).uri.pathSegments.last;
    return fileName.replaceAll(RegExp(r'\.\w+$'), '');
  }

  /// 从全文提取章节信息
  static List<Chapter> _extractChapters(String text) {
    final chapters = <Chapter>[];
    final lines = text.split('\n');
    int currentOffset = 0;

    for (final line in lines) {
      final trimmed = line.trim();
      // 匹配中文章节格式
      final cnMatch = RegExp(r'^(第[一二三四五六七八九十百千万零\d]+[章节回集卷篇])[：:\s]*(.*)$').firstMatch(trimmed);
      // 匹配英文章节格式
      final enMatch = RegExp(r'^(Chapter|Part|Section)\s+(\d+\.?\d*)\s*(.*)$', caseSensitive: false).firstMatch(trimmed);

      if (cnMatch != null || enMatch != null) {
        final title = cnMatch != null
            ? (cnMatch.group(2)?.isNotEmpty == true
                ? '${cnMatch.group(1)} ${cnMatch.group(2)}'
                : cnMatch.group(1)!)
            : (enMatch!.group(3)?.isNotEmpty == true
                ? '${enMatch.group(1)} ${enMatch.group(2)} ${enMatch.group(3)}'
                : '${enMatch.group(1)} ${enMatch.group(2)}');

        chapters.add(Chapter(
          title: title,
          startOffset: currentOffset,
          endOffset: currentOffset + trimmed.length,
        ));
      }

      currentOffset += line.length + 1; // +1 for \n
    }

    return chapters;
  }
}
