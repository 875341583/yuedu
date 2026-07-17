/// 书架页面（首页）
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../models/book.dart';
import '../services/bookshelf_service.dart';
import '../utils/encoding.dart';
import 'reader_page.dart';
import 'pdf_reader_page.dart';

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  final _service = BookshelfService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final books = _service.books;

    return Scaffold(
      appBar: AppBar(
        title: Text('阅界${books.length > 0 ? " (${books.length})" : ""}'),
        centerTitle: true,
        actions: [
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
          : _buildBookGrid(books),
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
          onLongPress: () => _deleteBook(books[index]),
        ),
      ),
    );
  }

  void _openBook(Book book) {
    // PDF 走独立的页面渲染阅读页（pdfrx/PDFium）
    // 其他格式走排版引擎阅读页
    final page = book.format == BookFormat.pdf
        ? PdfReaderPage(book: book)
        : ReaderPage(book: book);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  /// 从本地文件导入TXT/EPUB
  Future<void> _importFromFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub', 'pdf', 'mobi'],
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    for (final pickedFile in result.files) {
      // Web平台：文件在内存中（bytes），Native平台：有实际文件路径
      if (pickedFile.path != null) {
        // Native平台：有实际文件路径
        final path = pickedFile.path!;
        final isEpub = path.toLowerCase().endsWith('.epub');
        final isPdf = path.toLowerCase().endsWith('.pdf');
        final isMobi = path.toLowerCase().endsWith('.mobi');
        final book = isMobi
            ? await _service.importMobi(path)
            : isPdf
                ? await _service.importPdf(path)
                : isEpub
                    ? await _service.importEpub(path)
                    : await _service.importTxt(path);
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
                  book.format == BookFormat.txt ? 'TXT' : book.format == BookFormat.epub ? 'EPUB' : book.format == BookFormat.pdf ? 'PDF' : 'MOBI',
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
