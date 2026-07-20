/// 书架页面（首页）
library;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../models/book.dart';
import '../services/bookshelf_service.dart';
import '../services/tag_service.dart';
import '../plugins/plugin_manager.dart';
import '../utils/encoding.dart';
import 'reader_page.dart';
import 'pdf_reader_page.dart';
import 'pptx_reader_page.dart';
import 'xlsx_reader_page.dart';
import 'plugin_center_page.dart';

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  final _service = BookshelfService.instance;
  final _pluginMgr = PluginManager.instance;
  final _tagService = TagService.instance;

  /// 是否显示分类视图
  bool _categoryView = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
    _pluginMgr.addListener(_onChanged);
    _tagService.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    _pluginMgr.removeListener(_onChanged);
    _tagService.removeListener(_onChanged);
    super.dispose();
  }

  bool get _categoryEnabled => _pluginMgr.isEnabled('file_category');

  @override
  Widget build(BuildContext context) {
    final books = _service.books;
    final showCategoryEntry = _categoryEnabled && books.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text('阅界${books.length > 0 ? " (${books.length})" : ""}'),
        centerTitle: true,
        actions: [
          if (showCategoryEntry)
            IconButton(
              icon: Icon(_categoryView ? Icons.grid_view : Icons.category_outlined),
              tooltip: _categoryView ? '普通视图' : '分类视图',
              onPressed: () => setState(() => _categoryView = !_categoryView),
            ),
          IconButton(
            icon: const Icon(Icons.extension),
            tooltip: '插件中心',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PluginCenterPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: '从文件导入',
            onPressed: _importFromFile,
          ),
          IconButton(
            icon: const Icon(Icons.edit_note),
            tooltip: '粘贴文本导入',
            onPressed: _importFromPaste,
          ),
        ],
      ),
      body: books.isEmpty
          ? _buildEmpty()
          : (_categoryView && _categoryEnabled
              ? _buildCategoryView(books)
              : _buildBookGrid(books)),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text('书架空空如也', style: TextStyle(fontSize: 18, color: Colors.grey.shade500)),
          const SizedBox(height: 8),
          Text('点击右上角按钮导入书籍', style: TextStyle(fontSize: 14, color: Colors.grey.shade400)),
        ],
      ),
    );
  }

  Widget _buildBookGrid(List<Book> books) {
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth < 360 ? 2 : 3;

    return Scrollbar(
      thumbVisibility: true,
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: 0.62,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: books.length,
        itemBuilder: (context, index) => _BookCard(
          book: books[index],
          onTap: () => _openBook(books[index]),
          onLongPress: () => _showBookTagsDialog(books[index]),
        ),
      ),
    );
  }

  /// 分类视图：按格式分组 + 按标签分组（Tab 切换）
  Widget _buildCategoryView(List<Book> books) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.folder_outlined), text: '按格式'),
              Tab(icon: Icon(Icons.label_outline), text: '按标签'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildByFormatView(books),
                _buildByTagView(books),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 按格式分组视图
  Widget _buildByFormatView(List<Book> books) {
    final byFormat = <BookFormat, List<Book>>{};
    for (final b in books) {
      byFormat.putIfAbsent(b.format, () => []).add(b);
    }
    // 按格式枚举顺序排列
    final ordered = BookFormat.values.where((f) => byFormat.containsKey(f)).toList();

    if (ordered.isEmpty) {
      return const Center(child: Text('暂无书籍'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: ordered.length,
      itemBuilder: (ctx, i) {
        final format = ordered[i];
        final formatBooks = byFormat[format]!;
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ExpansionTile(
            initiallyExpanded: i == 0,
            leading: CircleAvatar(
              backgroundColor: Colors.indigo.withOpacity(0.1),
              child: Text(
                _formatLabelShort(format),
                style: const TextStyle(fontSize: 10, color: Colors.indigo, fontWeight: FontWeight.bold),
              ),
            ),
            title: Text('${_formatLabelShort(format)} (${formatBooks.length})'),
            children: formatBooks.map((b) => _buildBookListTile(b)).toList(),
          ),
        );
      },
    );
  }

  /// 按标签分组视图
  Widget _buildByTagView(List<Book> books) {
    final allTags = _tagService.allTags;
    if (allTags.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.label_off, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('暂无标签', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            const Text('长按书籍可添加自定义标签', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: allTags.length,
      itemBuilder: (ctx, i) {
        final tag = allTags[i];
        final bookIds = _tagService.booksWithTag(tag);
        final taggedBooks = books.where((b) => bookIds.contains(b.id)).toList();
        if (taggedBooks.isEmpty) return const SizedBox.shrink();
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ExpansionTile(
            initiallyExpanded: i == 0,
            leading: CircleAvatar(
              backgroundColor: Colors.amber.withOpacity(0.15),
              child: const Icon(Icons.label, color: Colors.amber, size: 20),
            ),
            title: Text('$tag (${taggedBooks.length})'),
            children: taggedBooks.map((b) => _buildBookListTile(b)).toList(),
          ),
        );
      },
    );
  }

  Widget _buildBookListTile(Book book) {
    return ListTile(
      leading: Icon(Icons.menu_book, color: Colors.indigo.shade300, size: 28),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        book.author.isNotEmpty ? book.author : _formatLabelShort(book.format),
        style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      onTap: () => _openBook(book),
      onLongPress: () => _showBookTagsDialog(book),
    );
  }

  String _formatLabelShort(BookFormat f) {
    switch (f) {
      case BookFormat.txt: return 'TXT';
      case BookFormat.epub: return 'EPUB';
      case BookFormat.pdf: return 'PDF';
      case BookFormat.mobi: return 'MOBI';
      case BookFormat.docx: return 'DOCX';
      case BookFormat.pptx: return 'PPTX';
      case BookFormat.xlsx: return 'XLSX';
      case BookFormat.ofd: return 'OFD';
    }
  }

  /// 长按书籍：标签管理对话框
  Future<void> _showBookTagsDialog(Book book) async {
    await showDialog(
      context: context,
      builder: (ctx) => _BookTagsDialog(book: book),
    );
  }

  void _openBook(Book book) {
    // PDF 走独立的页面渲染阅读页（pdfrx/PDFium）
    // PPTX 走独立幻灯片展示页（按页 + 横屏）
    // 其他格式走排版引擎阅读页
    Widget page;
    switch (book.format) {
      case BookFormat.pdf:
        page = PdfReaderPage(book: book);
        break;
      case BookFormat.pptx:
        page = PptxReaderPage(book: book);
        break;
      case BookFormat.xlsx:
        page = XlsxReaderPage(book: book);
        break;
      default:
        page = ReaderPage(book: book);
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  /// 从本地文件导入TXT/EPUB/PDF/MOBI/DOCX/PPTX/XLSX/OFD
  Future<void> _importFromFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub', 'pdf', 'mobi', 'docx', 'pptx', 'xlsx', 'ofd'],
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    for (final pickedFile in result.files) {
      // Web平台：文件在内存中（bytes），Native平台：有实际文件路径
      if (pickedFile.path != null) {
        // Native平台：有实际文件路径
        final path = pickedFile.path!;
        final lower = path.toLowerCase();
        Book? book;
        if (lower.endsWith('.mobi')) {
          book = await _service.importMobi(path);
        } else if (lower.endsWith('.pdf')) {
          book = await _service.importPdf(path);
        } else if (lower.endsWith('.epub')) {
          book = await _service.importEpub(path);
        } else if (lower.endsWith('.docx')) {
          book = await _service.importDocx(path);
        } else if (lower.endsWith('.pptx')) {
          book = await _service.importPptx(path);
        } else if (lower.endsWith('.xlsx')) {
          book = await _service.importXlsx(path);
        } else if (lower.endsWith('.ofd')) {
          book = await _service.importOfd(path);
        } else {
          book = await _service.importTxt(path);
        }
        if (book != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已导入: ${book.title}'), duration: const Duration(seconds: 2)),
          );
        }
      } else if (pickedFile.bytes != null) {
        // Web平台：异步解码（支持UTF-8/GBK等）
        final content = await decodeTextBytesAsync(pickedFile.bytes!);
        final book = _service.importFromContent(
          title: pickedFile.name.replaceAll(RegExp(r'\.\w+$'), ''),
          content: content,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已导入: ${book.title}'), duration: const Duration(seconds: 2)),
          );
        }
      }
    }
  }

  /// 粘贴文本导入
  Future<void> _importFromPaste() async {
    final result = await showDialog<_PasteResult>(
      context: context,
      builder: (ctx) => _ImportDialog(),
    );
    if (result == null || result.content.isEmpty) return;

    final book = _service.importFromContent(
      title: result.title.isNotEmpty ? result.title : '未命名文本',
      content: result.content,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入: ${book.title}'), duration: const Duration(seconds: 2)),
      );
    }
  }

  /// 删除书籍（长按触发）
  Future<void> _deleteBook(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定要删除《${book.title}》吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) {
      _service.removeBook(book.id);
    }
  }
}

/// 书籍卡片
class _BookCard extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _BookCard({required this.book, required this.onTap, required this.onLongPress});

  /// 格式化阅读时间
  static String _formatReadTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${time.month}/${time.day}';
  }

  /// 格式标签文本
  static String _formatLabel(BookFormat f) {
    switch (f) {
      case BookFormat.txt:
        return 'TXT';
      case BookFormat.epub:
        return 'EPUB';
      case BookFormat.pdf:
        return 'PDF';
      case BookFormat.mobi:
        return 'MOBI';
      case BookFormat.docx:
        return 'DOCX';
      case BookFormat.pptx:
        return 'PPTX';
      case BookFormat.xlsx:
        return 'XLSX';
      case BookFormat.ofd:
        return 'OFD';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Color((book.colorSeed & 0xFFFF) | 0xFF6750A4);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color.withOpacity(0.8), color.withOpacity(0.5)],
          ),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(2, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 格式标签
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _formatLabel(book.format),
                  style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 10),
                ),
              ),
              const Spacer(),
              Text(
                book.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                book.author,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // 阅读进度条
              if (book.lastPosition > 0) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: 0.3, // 占位，实际需要知道总长度
                    backgroundColor: Colors.white.withOpacity(0.2),
                    valueColor: AlwaysStoppedAnimation(Colors.white.withOpacity(0.7)),
                    minHeight: 3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatReadTime(book.lastReadTime),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 10,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 粘贴导入的结果
class _PasteResult {
  final String title;
  final String content;
  const _PasteResult({required this.title, required this.content});
}

/// 导入对话框
class _ImportDialog extends StatefulWidget {
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('粘贴导入'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '书名（可选）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contentController,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: '粘贴文本内容...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(
            _PasteResult(title: _titleController.text, content: _contentController.text),
          ),
          child: const Text('导入'),
        ),
      ],
    );
  }
}

/// 书籍标签管理 + 删除对话框（长按书籍触发）
class _BookTagsDialog extends StatefulWidget {
  final Book book;
  const _BookTagsDialog({required this.book});

  @override
  State<_BookTagsDialog> createState() => _BookTagsDialogState();
}

class _BookTagsDialogState extends State<_BookTagsDialog> {
  final _tagService = TagService.instance;
  final _service = BookshelfService.instance;
  final _newTagController = TextEditingController();

  @override
  void dispose() {
    _newTagController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tagService.tagsOf(widget.book.id);
    final allTags = _tagService.allTags;
    // 推荐标签：已有标签中本书未添加的
    final suggested = allTags.where((t) => !tags.contains(t)).take(8).toList();

    return AlertDialog(
      title: Text(widget.book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('已添加标签', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            if (tags.isEmpty)
              const Text('暂无标签', style: TextStyle(color: Colors.grey, fontSize: 12))
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: tags.map((t) {
                  return Chip(
                    label: Text(t, style: const TextStyle(fontSize: 12)),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () => _tagService.removeTag(widget.book.id, t),
                  );
                }).toList(),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _newTagController,
              decoration: const InputDecoration(
                hintText: '输入新标签',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _addTag(),
            ),
            const SizedBox(height: 8),
            if (suggested.isNotEmpty) ...[
              const Text('推荐标签', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: suggested.map((t) {
                  return ActionChip(
                    label: Text(t, style: const TextStyle(fontSize: 11)),
                    onPressed: () => _tagService.addTag(widget.book.id, t),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          onPressed: () async {
            final ok = await _confirmDelete();
            if (ok == true && mounted) {
              _service.removeBook(widget.book.id);
              Navigator.pop(context);
            }
          },
          child: const Text('删除书籍'),
        ),
      ],
    );
  }

  void _addTag() {
    final t = _newTagController.text.trim();
    if (t.isEmpty) return;
    _tagService.addTag(widget.book.id, t);
    _newTagController.clear();
  }

  Future<bool?> _confirmDelete() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定要删除《${widget.book.title}》吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
