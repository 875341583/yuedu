/// 书籍数据模型
library;

/// 一本书
class Book {
  /// 唯一ID
  final String id;

  /// 书名
  final String title;

  /// 作者
  final String author;

  /// 文件路径（本地TXT/EPUB）
  final String filePath;

  /// 文件格式
  final BookFormat format;

  /// 最后阅读位置（字符偏移）
  int lastPosition;

  /// 最后阅读时间
  DateTime lastReadTime;

  /// 封面颜色（用于无封面时的占位）
  final int colorSeed;

  /// 章节列表
  List<Chapter> chapters;

  Book({
    required this.id,
    required this.title,
    required this.author,
    required this.filePath,
    required this.format,
    this.lastPosition = 0,
    DateTime? lastReadTime,
    this.colorSeed = 0,
    this.chapters = const [],
  }) : lastReadTime = lastReadTime ?? DateTime.now();

  /// 从Map反序列化
  factory Book.fromMap(Map<String, dynamic> map) {
    return Book(
      id: map['id'] as String,
      title: map['title'] as String,
      author: map['author'] as String,
      filePath: map['filePath'] as String,
      format: BookFormat.values.firstWhere(
        (f) => f.name == map['format'],
        orElse: () => BookFormat.txt,
      ),
      lastPosition: map['lastPosition'] as int? ?? 0,
      lastReadTime: map['lastReadTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['lastReadTime'] as int)
          : null,
      colorSeed: map['colorSeed'] as int? ?? 0,
      chapters: (map['chapters'] as List?)
              ?.map((c) => Chapter.fromMap(c as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// 序列化为Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'filePath': filePath,
      'format': format.name,
      'lastPosition': lastPosition,
      'lastReadTime': lastReadTime.millisecondsSinceEpoch,
      'colorSeed': colorSeed,
      'chapters': chapters.map((c) => c.toMap()).toList(),
    };
  }
}

/// 章节
class Chapter {
  final String title;
  final int startOffset;
  final int endOffset;

  const Chapter({
    required this.title,
    required this.startOffset,
    this.endOffset = -1,
  });

  factory Chapter.fromMap(Map<String, dynamic> map) {
    return Chapter(
      title: map['title'] as String,
      startOffset: map['startOffset'] as int,
      endOffset: map['endOffset'] as int? ?? -1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'startOffset': startOffset,
      'endOffset': endOffset,
    };
  }
}

/// 书籍文件格式
enum BookFormat {
  txt,
  epub,
}
