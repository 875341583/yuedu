/// 书签服务：管理书签的增删查改，持久化到SharedPreferences
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookmark.dart';

class BookmarkService {
  static final BookmarkService _instance = BookmarkService._();
  static BookmarkService get instance => _instance;
  BookmarkService._();

  static const _kBookmarksKey = 'yuedu_bookmarks';

  /// 内存中的书签列表
  final List<Bookmark> _bookmarks = [];

  /// 是否已加载
  bool _loaded = false;

  /// 变更回调
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notifyListeners() {
    for (final l in _listeners) {
      l();
    }
  }

  /// 从存储加载
  Future<void> loadFromStorage() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_kBookmarksKey);
      if (json != null) {
        final list = jsonDecode(json) as List;
        _bookmarks.clear();
        for (final item in list) {
          _bookmarks.add(Bookmark.fromMap(item as Map<String, dynamic>));
        }
        // 按创建时间排序（新的在前）
        _bookmarks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }
    } catch (_) {}
  }

  /// 保存到存储
  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_bookmarks.map((b) => b.toMap()).toList());
      await prefs.setString(_kBookmarksKey, json);
    } catch (_) {}
  }

  /// 获取某本书的所有书签（按位置排序）
  List<Bookmark> getBookmarksForBook(String bookId) {
    return _bookmarks
        .where((b) => b.bookId == bookId)
        .toList()
      ..sort((a, b) => a.position.compareTo(b.position));
  }

  /// 添加书签
  Future<Bookmark> addBookmark({
    required String bookId,
    required int position,
    required String preview,
    String? note,
  }) async {
    await loadFromStorage();

    // 检查是否已有相同位置的书签（容差100字符）
    final existing = _bookmarks.where((b) =>
        b.bookId == bookId && (b.position - position).abs() < 100);
    if (existing.isNotEmpty) {
      return existing.first;
    }

    final bookmark = Bookmark(
      id: 'bm_${DateTime.now().millisecondsSinceEpoch}',
      bookId: bookId,
      position: position,
      preview: preview,
      createdAt: DateTime.now(),
      note: note,
    );

    _bookmarks.add(bookmark);
    _bookmarks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _save();
    _notifyListeners();
    return bookmark;
  }

  /// 删除书签
  Future<void> removeBookmark(String bookmarkId) async {
    await loadFromStorage();
    _bookmarks.removeWhere((b) => b.id == bookmarkId);
    await _save();
    _notifyListeners();
  }

  /// 更新书签备注
  Future<void> updateNote(String bookmarkId, String note) async {
    await loadFromStorage();
    final idx = _bookmarks.indexWhere((b) => b.id == bookmarkId);
    if (idx >= 0) {
      _bookmarks[idx] = _bookmarks[idx].copyWith(note: note);
      await _save();
      _notifyListeners();
    }
  }

  /// 检查某个位置附近是否已有书签
  bool hasBookmarkNear(String bookId, int position, {int tolerance = 100}) {
    return _bookmarks.any((b) =>
        b.bookId == bookId && (b.position - position).abs() < tolerance);
  }
}
