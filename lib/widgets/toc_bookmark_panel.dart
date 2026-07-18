/// 目录与书签面板：底部弹出的Tab式面板
/// Tab1: 章节目录列表（点击跳转到对应章节）
/// Tab2: 书签列表（点击跳转、长按删除）
/// Tab3: 高亮列表（点击跳转、左滑删除、长按编辑笔记）
library;

import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/bookmark.dart';
import '../models/highlight.dart';

class TocBookmarkPanel extends StatefulWidget {
  final Book book;
  final List<Chapter> chapters;
  final List<Bookmark> bookmarks;
  final int currentPosition;
  final bool isLargeFile;

  /// 跳转到指定位置（字符偏移或字节偏移）
  final void Function(int position) onJump;

  /// 添加书签
  final Future<void> Function() onAddBookmark;

  /// 删除书签
  final Future<void> Function(String bookmarkId) onRemoveBookmark;

  /// 高亮列表
  final List<Highlight> highlights;

  /// 删除高亮
  final Future<void> Function(String highlightId) onRemoveHighlight;

  /// 编辑高亮笔记
  final Future<void> Function(String highlightId, String note) onUpdateHighlightNote;

  /// 主题色
  final Color bgColor;
  final Color textColor;
  final Color hintColor;
  final Color surfaceColor;
  final Color borderColor;
  final bool isDark;

  const TocBookmarkPanel({
    super.key,
    required this.book,
    required this.chapters,
    required this.bookmarks,
    required this.currentPosition,
    required this.isLargeFile,
    required this.onJump,
    required this.onAddBookmark,
    required this.onRemoveBookmark,
    this.highlights = const [],
    required this.onRemoveHighlight,
    required this.onUpdateHighlightNote,
    required this.bgColor,
    required this.textColor,
    required this.hintColor,
    required this.surfaceColor,
    required this.borderColor,
    required this.isDark,
  });

  @override
  State<TocBookmarkPanel> createState() => _TocBookmarkPanelState();
}

class _TocBookmarkPanelState extends State<TocBookmarkPanel>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: widget.bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // ── 顶部Tab栏 ──
          Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: widget.borderColor, width: 0.5),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              labelColor: Colors.indigo,
              unselectedLabelColor: widget.hintColor,
              indicatorColor: Colors.indigo,
              indicatorSize: TabBarIndicatorSize.label,
              tabs: [
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.list, size: 16),
                      const SizedBox(width: 6),
                      Text('目录 (${widget.chapters.length})'),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.bookmark_outline, size: 16),
                      const SizedBox(width: 6),
                      Text('书签 (${widget.bookmarks.length})'),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.border_color_outlined, size: 16),
                      const SizedBox(width: 6),
                      Text('高亮 (${widget.highlights.length})'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ── 内容区 ──
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildChapterList(),
                _buildBookmarkList(),
                _buildHighlightList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── 章节目录列表 ─────────────────────────────────────────

  Widget _buildChapterList() {
    if (widget.chapters.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book, size: 48, color: widget.hintColor.withOpacity(0.3)),
            const SizedBox(height: 12),
            Text('未检测到章节信息', style: TextStyle(color: widget.hintColor, fontSize: 14)),
            const SizedBox(height: 4),
            Text('Txt文件首次打开时自动解析', style: TextStyle(color: widget.hintColor, fontSize: 12)),
          ],
        ),
      );
    }

    // 找到当前阅读位置最近的章节
    int currentChapterIndex = _findCurrentChapter();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.chapters.length,
      itemBuilder: (context, index) {
        final chapter = widget.chapters[index];
        final isCurrent = index == currentChapterIndex;
        return ListTile(
          dense: true,
          leading: isCurrent
              ? Container(
                  width: 3,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Colors.indigo,
                    borderRadius: BorderRadius.circular(2),
                  ),
                )
              : const SizedBox(width: 3),
          title: Text(
            chapter.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              color: isCurrent ? Colors.indigo : widget.textColor,
              fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          trailing: isCurrent
              ? Text('当前', style: TextStyle(fontSize: 11, color: Colors.indigo.shade300))
              : null,
          onTap: () {
            widget.onJump(chapter.startOffset);
            Navigator.of(context).pop();
          },
        );
      },
    );
  }

  int _findCurrentChapter() {
    if (widget.chapters.isEmpty) return -1;
    final pos = widget.currentPosition;
    int found = -1;
    for (int i = 0; i < widget.chapters.length; i++) {
      if (widget.chapters[i].startOffset <= pos) {
        found = i;
      } else {
        break;
      }
    }
    return found;
  }

  // ─── 书签列表 ─────────────────────────────────────────────

  Widget _buildBookmarkList() {
    if (widget.bookmarks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border, size: 48, color: widget.hintColor.withOpacity(0.3)),
            const SizedBox(height: 12),
            Text('暂无书签', style: TextStyle(color: widget.hintColor, fontSize: 14)),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () async {
                await widget.onAddBookmark();
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
              child: const Text('添加当前页书签'),
            ),
          ],
        ),
      );
    }

    final sorted = List<Bookmark>.from(widget.bookmarks)
      ..sort((a, b) => a.position.compareTo(b.position));

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sorted.length + 1, // +1 for add button
      itemBuilder: (context, index) {
        if (index == 0) {
          // 添加书签按钮
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: FilledButton.tonalIcon(
              onPressed: () async {
                await widget.onAddBookmark();
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.bookmark_add, size: 18),
              label: const Text('添加当前页书签'),
            ),
          );
        }

        final bm = sorted[index - 1];
        return Dismissible(
          key: ValueKey(bm.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red.shade400,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) => widget.onRemoveBookmark(bm.id),
          child: ListTile(
            leading: Icon(
              Icons.bookmark,
              color: Colors.amber.shade600,
              size: 20,
            ),
            title: Text(
              bm.preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: widget.textColor),
            ),
            subtitle: Text(
              _formatTime(bm.createdAt),
              style: TextStyle(fontSize: 11, color: widget.hintColor),
            ),
            trailing: bm.note != null && bm.note!.isNotEmpty
                ? Icon(Icons.note_outlined, size: 16, color: widget.hintColor)
                : null,
            onTap: () {
              widget.onJump(bm.position);
              Navigator.of(context).pop();
            },
          ),
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }

  // ─── 高亮列表 ─────────────────────────────────────────────

  Widget _buildHighlightList() {
    if (widget.highlights.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.highlight, size: 48, color: widget.hintColor.withOpacity(0.3)),
            const SizedBox(height: 12),
            Text('暂无高亮', style: TextStyle(color: widget.hintColor, fontSize: 14)),
            const SizedBox(height: 4),
            Text('在阅读页长按文字即可高亮或添加笔记',
                style: TextStyle(color: widget.hintColor, fontSize: 12)),
          ],
        ),
      );
    }

    final sorted = List<Highlight>.from(widget.highlights)
      ..sort((a, b) => a.position.compareTo(b.position));

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final h = sorted[index];
        final color = Color(HighlightColors.indexToArgb(h.colorIndex));
        return Dismissible(
          key: ValueKey(h.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red.shade400,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) => widget.onRemoveHighlight(h.id),
          child: ListTile(
            leading: Container(
              width: 6,
              height: 32,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            title: Text(
              h.preview,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: widget.textColor),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (h.note != null && h.note!.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: widget.surfaceColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.note_outlined, size: 12, color: widget.hintColor),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            h.note!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: widget.hintColor, fontStyle: FontStyle.italic),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (h.chapterTitle != null)
                      Flexible(
                        child: Text(
                          h.chapterTitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: Colors.indigo.shade300),
                        ),
                      ),
                    if (h.chapterTitle != null) const SizedBox(width: 6),
                    Text(_formatTime(h.createdAt),
                        style: TextStyle(fontSize: 11, color: widget.hintColor)),
                  ],
                ),
              ],
            ),
            isThreeLine: true,
            onTap: () {
              widget.onJump(h.position);
              Navigator.of(context).pop();
            },
            onLongPress: () => _showHighlightNoteEditor(h),
          ),
        );
      },
    );
  }

  /// 编辑高亮笔记
  void _showHighlightNoteEditor(Highlight h) {
    final controller = TextEditingController(text: h.note ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑笔记', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: widget.surfaceColor,
                borderRadius: BorderRadius.circular(6),
              ),
              constraints: const BoxConstraints(maxHeight: 100),
              child: SingleChildScrollView(
                child: Text(
                  h.preview,
                  style: TextStyle(fontSize: 12, color: widget.textColor),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 4,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '在此输入笔记内容...',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(10),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              widget.onUpdateHighlightNote(h.id, controller.text.trim());
              Navigator.of(ctx).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
