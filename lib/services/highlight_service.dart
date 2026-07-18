/// 高亮服务：管理高亮与笔记的增删查改，持久化到 SharedPreferences
///
/// 与 BookmarkService 同样的单例 + listener 模式，key='yuedu_highlights'
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/highlight.dart';

class HighlightService {
  static final HighlightService _instance = HighlightService._();
  static HighlightService get instance => _instance;
  HighlightService._();

  static const _kHighlightsKey = 'yuedu_highlights';

  /// 内存中的高亮列表
  final List<Highlight> _highlights = [];

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
      final json = prefs.getString(_kHighlightsKey);
      if (json != null) {
        final list = jsonDecode(json) as List;
        _highlights.clear();
        for (final item in list) {
          _highlights.add(Highlight.fromMap(item as Map<String, dynamic>));
        }
        _highlights.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_highlights.map((h) => h.toMap()).toList());
      await prefs.setString(_kHighlightsKey, json);
    } catch (_) {}
  }

  /// 获取某本书的所有高亮（按位置升序）
  List<Highlight> getHighlightsForBook(String bookId) {
    return _highlights
        .where((h) => h.bookId == bookId)
        .toList()
      ..sort((a, b) => a.position.compareTo(b.position));
  }

  /// 获取某本书中位置落在 [startPos, endPos）区间内的高亮（用于当前页聚合渲染）
  /// position 字段用作粗过滤；再用 startOffset/endOffset 精细判断（小文件相同口径）
  List<Highlight> getHighlightsInRange(
      String bookId, int startPos, int endPos) {
    return _highlights.where((h) {
      if (h.bookId != bookId) return false;
      // 区间相交判断
      return h.startOffset < endPos && h.endOffset > startPos;
    }).toList();
  }

  /// 添加高亮
  Future<Highlight> addHighlight({
    required String bookId,
    required int startOffset,
    required int endOffset,
    required int position,
    required String preview,
    required int colorIndex,
    String? note,
    String? chapterTitle,
  }) async {
    await loadFromStorage();

    final highlight = Highlight(
      id: 'hl_${DateTime.now().millisecondsSinceEpoch}',
      bookId: bookId,
      startOffset: startOffset,
      endOffset: endOffset,
      position: position,
      preview: preview,
      colorIndex: colorIndex,
      createdAt: DateTime.now(),
      note: note,
      chapterTitle: chapterTitle,
    );

    _highlights.add(highlight);
    _highlights.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await _save();
    _notifyListeners();
    return highlight;
  }

  /// 删除高亮
  Future<void> removeHighlight(String highlightId) async {
    await loadFromStorage();
    _highlights.removeWhere((h) => h.id == highlightId);
    await _save();
    _notifyListeners();
  }

  /// 更新笔记
  Future<void> updateNote(String highlightId, String note) async {
    await loadFromStorage();
    final idx = _highlights.indexWhere((h) => h.id == highlightId);
    if (idx >= 0) {
      _highlights[idx] = _highlights[idx].copyWith(note: note);
      await _save();
      _notifyListeners();
    }
  }

  /// 更新颜色
  Future<void> updateColor(String highlightId, int colorIndex) async {
    await loadFromStorage();
    final idx = _highlights.indexWhere((h) => h.id == highlightId);
    if (idx >= 0) {
      _highlights[idx] = _highlights[idx].copyWith(colorIndex: colorIndex);
      await _save();
      _notifyListeners();
    }
  }
}
