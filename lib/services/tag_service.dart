/// 书籍标签服务
///
/// 为文件分类插件提供数据支撑：给书籍打自定义标签、按标签筛选。
/// 标签持久化到 SharedPreferences（bookId -> List<tag>）。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TagService extends ChangeNotifier {
  TagService._();
  static final TagService instance = TagService._();

  static const _kTagsKey = 'yuedu_book_tags';
  static const _kAllTagsKey = 'yuedu_all_tags';

  /// bookId -> 标签列表
  final Map<String, List<String>> _bookTags = {};

  /// 全部标签集合（去重，按使用频率排序）
  final List<String> _allTags = [];

  bool _initialized = false;

  Map<String, List<String>> get bookTags => Map.unmodifiable(_bookTags);
  List<String> get allTags => List.unmodifiable(_allTags);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kTagsKey);
      if (raw != null) {
        // 格式：bookId1:tag1,tag2|bookId2:tag3
        for (final entry in raw.split('|')) {
          if (entry.isEmpty) continue;
          final parts = entry.split(':');
          if (parts.length != 2) continue;
          final bookId = parts[0];
          final tags = parts[1].split(',').where((t) => t.isNotEmpty).toList();
          if (tags.isNotEmpty) _bookTags[bookId] = tags;
        }
      }
      final all = prefs.getStringList(_kAllTagsKey) ?? <String>[];
      _allTags.addAll(all);
    } catch (_) {}
  }

  List<String> tagsOf(String bookId) => _bookTags[bookId] ?? const [];

  /// 给书籍添加标签
  Future<void> addTag(String bookId, String tag) async {
    final t = tag.trim();
    if (t.isEmpty) return;
    _bookTags.putIfAbsent(bookId, () => []);
    if (!_bookTags[bookId]!.contains(t)) {
      _bookTags[bookId]!.add(t);
    }
    if (!_allTags.contains(t)) {
      _allTags.add(t);
    }
    await _persist();
    notifyListeners();
  }

  /// 移除书籍的某个标签
  Future<void> removeTag(String bookId, String tag) async {
    _bookTags[bookId]?.remove(tag);
    if (_bookTags[bookId]?.isEmpty ?? false) {
      _bookTags.remove(bookId);
    }
    // 全局标签不删除（其他书可能还在用，删除逻辑复杂，保留）
    await _persist();
    notifyListeners();
  }

  /// 按标签筛选书籍
  List<String> booksWithTag(String tag) {
    return _bookTags.entries
        .where((e) => e.value.contains(tag))
        .map((e) => e.key)
        .toList();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _bookTags.entries.map((e) =>
          '${e.key}:${e.value.join(',')}').toList();
      await prefs.setString(_kTagsKey, entries.join('|'));
      await prefs.setStringList(_kAllTagsKey, _allTags);
    } catch (_) {}
  }
}
