/// 高亮与笔记数据模型
///
/// 与 Bookmark 类似的实现，但记录一段文字区间 [startOffset, endOffset]
/// 而不是一个点。position 字段用于跳转定位，与书签一致：
/// - 大文件存 byteOffset
/// - 小文件存 startOffset（字符偏移）
library;

/// 一个高亮段落
class Highlight {
  /// 唯一ID
  final String id;

  /// 所属书籍ID
  final String bookId;

  /// 高亮起始字符偏移（小文件）或字节偏移起始（大文件锚点）
  final int startOffset;

  /// 高亮结束字符偏移（不含）
  final int endOffset;

  /// 跳转锚点：大文件=byteOffset、小文件=startOffset
  /// 与 Bookmark.position 同口径，方便复用 toc 面板的 onJump
  final int position;

  /// 摘要（高亮区段文本）
  final String preview;

  /// 高亮颜色索引（0=黄 1=绿 2=蓝 3=红 4=紫）
  final int colorIndex;

  /// 创建时间
  final DateTime createdAt;

  /// 笔记内容（可选）
  final String? note;

  /// 章节标题（可选，便于在面板中识别位置）
  final String? chapterTitle;

  Highlight({
    required this.id,
    required this.bookId,
    required this.startOffset,
    required this.endOffset,
    required this.position,
    required this.preview,
    required this.colorIndex,
    required this.createdAt,
    this.note,
    this.chapterTitle,
  });

  factory Highlight.fromMap(Map<String, dynamic> map) {
    return Highlight(
      id: map['id'] as String,
      bookId: map['bookId'] as String,
      startOffset: map['startOffset'] as int,
      endOffset: map['endOffset'] as int,
      position: map['position'] as int,
      preview: map['preview'] as String,
      colorIndex: map['colorIndex'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      note: map['note'] as String?,
      chapterTitle: map['chapterTitle'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'bookId': bookId,
      'startOffset': startOffset,
      'endOffset': endOffset,
      'position': position,
      'preview': preview,
      'colorIndex': colorIndex,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'note': note,
      'chapterTitle': chapterTitle,
    };
  }

  Highlight copyWith({
    String? id,
    String? bookId,
    int? startOffset,
    int? endOffset,
    int? position,
    String? preview,
    int? colorIndex,
    DateTime? createdAt,
    String? note,
    String? chapterTitle,
  }) {
    return Highlight(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      startOffset: startOffset ?? this.startOffset,
      endOffset: endOffset ?? this.endOffset,
      position: position ?? this.position,
      preview: preview ?? this.preview,
      colorIndex: colorIndex ?? this.colorIndex,
      createdAt: createdAt ?? this.createdAt,
      note: note ?? this.note,
      chapterTitle: chapterTitle ?? this.chapterTitle,
    );
  }
}

/// 高亮颜色预设
class HighlightColors {
  static const List<int> argbs = [
    0xFFFFEB3B, // 黄
    0xFFA5D6A7, // 绿
    0xFF90CAF9, // 蓝
    0xFFEF9A9A, // 红/粉
    0xFFCE93D8, // 紫
  ];

  static int colorToIndex(int argb) {
    final i = argbs.indexOf(argb);
    return i < 0 ? 0 : i;
  }

  static int indexToArgb(int index) {
    if (index < 0 || index >= argbs.length) return argbs[0];
    return argbs[index];
  }
}
