/// 书签数据模型
library;

/// 一个书签标记
class Bookmark {
  /// 唯一ID
  final String id;

  /// 所属书籍ID
  final String bookId;

  /// 阅读位置（字符偏移/大文件为字节偏移）
  final int position;

  /// 书签摘要（当前位置附近的文本片段）
  final String preview;

  /// 创建时间
  final DateTime createdAt;

  /// 备注（可选）
  final String? note;

  Bookmark({
    required this.id,
    required this.bookId,
    required this.position,
    required this.preview,
    required this.createdAt,
    this.note,
  });

  factory Bookmark.fromMap(Map<String, dynamic> map) {
    return Bookmark(
      id: map['id'] as String,
      bookId: map['bookId'] as String,
      position: map['position'] as int,
      preview: map['preview'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      note: map['note'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'bookId': bookId,
      'position': position,
      'preview': preview,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'note': note,
    };
  }

  Bookmark copyWith({
    String? id,
    String? bookId,
    int? position,
    String? preview,
    DateTime? createdAt,
    String? note,
  }) {
    return Bookmark(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      position: position ?? this.position,
      preview: preview ?? this.preview,
      createdAt: createdAt ?? this.createdAt,
      note: note ?? this.note,
    );
  }
}
