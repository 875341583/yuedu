/// 章节目录解析器：从文本内容中识别章节标题，生成章节列表
/// 支持常见中文小说章节格式：
///   第X章/节/回/卷、Chapter X、楔子/序章/前言/后记/尾声
library;

import '../models/book.dart';

class ChapterParser {
  ChapterParser._();

  /// 章节标题正则模式列表（按优先级排序）
  /// 每个模式匹配一行开头可能的章节标题
  static final _patterns = <RegExp>[
    // 第一章 / 第123章 / 第十二章 / 第1234回 / 第一节
    RegExp(r'^\s*第[0-9零一二三四五六七八九十百千两\s]+[章回节卷篇部]\s*[^\n]*$'),
    // Chapter 1 / CHAPTER I / Section 2
    RegExp(r'^\s*[Cc][Hh][Aa][Pp][Tt][Ee][Rr]\s+[0-9IVXLivxl]+\.?\s*[^\n]*$'),
    // 序章 / 楔子 / 前言 / 序言 / 引子 / 后记 / 尾声 / 番外
    RegExp(r'^\s*(序章|楔子|前言|序言|引子|引言|后记|尾声|终章|番外篇?\s*[^\n]*)\s*$'),
    // 卷一 / 卷二 / 上篇 / 下篇
    RegExp(r'^\s*[卷篇][零一二三四五六七八九十百千万0-9]\s*[^\n]*$'),
  ];

  /// 最小章节行长度（避免匹配到太短的行）
  static const _minLineLength = 2;

  /// 最大章节标题长度（避免匹配到正文段落）
  static const _maxTitleLength = 60;

  /// 从全文中解析章节列表
  /// [text] 全文内容
  /// [maxChapters] 最大章节数（防止异常情况生成过多章节）
  static List<Chapter> parse(String text, {int maxChapters = 5000}) {
    final chapters = <Chapter>[];
    final lines = text.split('\n');

    // 累积字符偏移（含换行符）
    int charOffset = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      // 偏移推进：当前行长度 + 换行符
      final lineLen = lines[i].length + 1; // +1 for \n

      if (line.length < _minLineLength || line.length > _maxTitleLength) {
        charOffset += lineLen;
        continue;
      }

      // 检查是否匹配章节模式
      if (_isChapterTitle(line)) {
        // 额外验证：下一行应为空行或正文（不是另一个章节标题）
        // 这能过滤掉目录列表中的条目
        final isStandalone = _isStandaloneLine(lines, i);
        if (!isStandalone) {
          charOffset += lineLen;
          continue;
        }

        chapters.add(Chapter(
          title: line,
          startOffset: charOffset,
        ));

        if (chapters.length >= maxChapters) break;
      }

      charOffset += lineLen;
    }

    // 填充 endOffset
    for (int i = 0; i < chapters.length; i++) {
      if (i < chapters.length - 1) {
        chapters[i] = Chapter(
          title: chapters[i].title,
          startOffset: chapters[i].startOffset,
          endOffset: chapters[i + 1].startOffset,
        );
      } else {
        chapters[i] = Chapter(
          title: chapters[i].title,
          startOffset: chapters[i].startOffset,
          endOffset: text.length,
        );
      }
    }

    return chapters;
  }

  /// 判断一行文本是否为章节标题
  static bool _isChapterTitle(String line) {
    for (final pattern in _patterns) {
      if (pattern.hasMatch(line)) return true;
    }
    return false;
  }

  /// 判断章节标题行是否独立（前后有空行或文件边界）
  /// 用于区分正文中提到的"第三章"和真正的章节标题
  static bool _isStandaloneLine(List<String> lines, int index) {
    // 检查上一行是否为空或文件开头
    final prevEmpty = index == 0 || lines[index - 1].trim().isEmpty;

    // 检查下一行是否为空或文件结尾
    final nextEmpty = index >= lines.length - 1 || lines[index + 1].trim().isEmpty;

    // 章节标题前后至少有一个空行（大多数小说格式如此）
    // 放宽条件：只要前一行或后一行为空即可
    return prevEmpty || nextEmpty;
  }

  /// 从大文件中按窗口解析章节（仅扫描每行开头，不加载全文）
  /// [readWindow] 异步读取函数：offset, length → 文本
  /// [totalBytes] 文件总字节数
  /// 返回章节列表（startOffset 为字符偏移近似值）
  static Future<List<Chapter>> parseLargeFile({
    required Future<String> Function(int byteOffset, int byteLength) readWindow,
    required int totalBytes,
    int windowSize = 128 * 1024, // 128KB扫描窗口
    int maxChapters = 5000,
  }) async {
    final chapters = <Chapter>[];
    int globalCharOffset = 0;

    for (int offset = 0; offset < totalBytes && chapters.length < maxChapters;) {
      final text = await readWindow(offset, windowSize);
      if (text.isEmpty) break;

      final lines = text.split('\n');
      int lineStartChar = 0;

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        final lineLen = lines[i].length + 1;

        if (line.length >= _minLineLength &&
            line.length <= _maxTitleLength &&
            _isChapterTitle(line) &&
            _isStandaloneLine(lines, i)) {
          chapters.add(Chapter(
            title: line,
            startOffset: globalCharOffset + lineStartChar,
          ));

          if (chapters.length >= maxChapters) break;
        }

        lineStartChar += lineLen;
      }

      // 推进全局字符偏移
      globalCharOffset += text.length;

      // 推进字节偏移（窗口末尾回退2行以避免行截断）
      int advance = windowSize;
      if (lines.isNotEmpty && offset + windowSize < totalBytes) {
        // 回退最后2行的长度，确保下一窗口从完整行开始
        int backLines = 0;
        int backChars = 0;
        for (int i = lines.length - 1; i >= 0 && backLines < 2; i--) {
          backChars += lines[i].length + 1;
          backLines++;
        }
        // 估算回退字节数（中文约2-3字节/字符）
        advance = windowSize - (backChars * 2).toInt().clamp(0, windowSize ~/ 2);
      }

      offset += advance;
      if (offset <= 0) offset = windowSize; // 防死循环
    }

    // 填充 endOffset
    for (int i = 0; i < chapters.length; i++) {
      if (i < chapters.length - 1) {
        chapters[i] = Chapter(
          title: chapters[i].title,
          startOffset: chapters[i].startOffset,
          endOffset: chapters[i + 1].startOffset,
        );
      } else {
        chapters[i] = Chapter(
          title: chapters[i].title,
          startOffset: chapters[i].startOffset,
          endOffset: -1, // 最后一章到文件末尾
        );
      }
    }

    return chapters;
  }
}
