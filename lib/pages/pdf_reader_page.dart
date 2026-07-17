/// PDF 阅读页面
///
/// 使用 pdfrx（PDFium 引擎）将 PDF 每页渲染为图片显示，
/// 支持任意 PDF（文本型/扫描型/加密），缩放、滚动、页码跳转。
/// 与排版阅读页（ReaderPage）解耦：PDF 书走本页，其他格式仍走排版引擎。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../services/bookshelf_service.dart';

class PdfReaderPage extends StatefulWidget {
  final Book book;

  const PdfReaderPage({super.key, required this.book});

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  final PdfViewerController _controller = PdfViewerController();

  /// 是否显示顶/底菜单栏
  bool _showMenu = false;

  /// 当前页码（1-based）
  int? _pageNumber;

  /// 总页数
  int _pageCount = 0;

  /// 视图是否就绪
  bool _isReady = false;

  /// 拖拽滑块时的临时进度（0~1），null=未在拖拽
  double? _seekProgress;

  /// 记录上次的纵向亮度遮罩比例（暂留接口）
  static const _kPdfPagePrefix = 'yuedu_pdf_page_';

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _persistPosition();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// 持久化当前页码
  Future<void> _persistPosition() async {
    final page = _pageNumber;
    if (page != null && page > 0) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('$_kPdfPagePrefix${widget.book.id}', page);
        // 同步到书库阅读位置（用于书架排序/展示）
        if (_pageCount > 0) {
          BookshelfService.instance
              .updateReadPosition(widget.book.id, page);
        }
      } catch (_) {}
    }
  }

  /// 读取上次的页码（用于 initialPageNumber）
  Future<int> _loadSavedPage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final page = prefs.getInt('$_kPdfPagePrefix${widget.book.id}') ?? 1;
      return page < 1 ? 1 : page;
    } catch (_) {
      return 1;
    }
  }

  void _toggleMenu() {
    setState(() => _showMenu = !_showMenu);
    if (_showMenu) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<int>(
        future: _loadSavedPage(),
        builder: (context, snapshot) {
          final initialPage = snapshot.data ?? 1;
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return _buildBody(initialPage);
        },
      ),
    );
  }

  Widget _buildBody(int initialPage) {
    return Stack(
      children: [
        // ── PDF 渲染主体 ──
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _toggleMenu,
            child: PdfViewer.file(
              widget.book.filePath,
              controller: _controller,
              initialPageNumber: initialPage,
              params: PdfViewerParams(
                backgroundColor: const Color(0xFF3A3A3A),
                pageAnchor: PdfPageAnchor.top,
                enableTextSelection: true,
                onViewerReady: (document, controller) {
                  setState(() {
                    _isReady = true;
                    _pageCount = document.pages.length;
                    _pageNumber ??= initialPage;
                  });
                },
                onPageChanged: (pageNumber) {
                  setState(() {
                    _pageNumber = pageNumber;
                    _seekProgress = null;
                  });
                  _persistPosition();
                },
                errorBannerBuilder: (context, error, stackTrace, documentRef) {
                  return _buildErrorBanner(error);
                },
              ),
            ),
          ),
        ),

        // ── 顶部菜单栏 ──
        if (_showMenu) _buildTopBar(),

        // ── 底部控制栏 ──
        if (_showMenu) _buildBottomBar(),

        // ── 页码提示（菜单隐藏时）──
        if (!_showMenu && _isReady) _buildPageHint(),
      ],
    );
  }

  // ─── 顶部栏 ────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.black54, Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(
                    widget.book.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.first_page, color: Colors.white),
                  tooltip: '第一页',
                  onPressed: _isReady
                      ? () => _controller.goToPage(pageNumber: 1)
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.last_page, color: Colors.white),
                  tooltip: '最后一页',
                  onPressed: _isReady && _pageCount > 0
                      ? () => _controller.goToPage(pageNumber: _pageCount)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── 底部栏（页码滑块）────────────────────────────────────

  Widget _buildBottomBar() {
    final current = _pageNumber ?? 1;
    final total = _pageCount > 0 ? _pageCount : 1;
    final progress = _seekProgress ?? (current - 1) / (total - 1 > 0 ? total - 1 : 1);

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.black54, Colors.transparent],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '$current',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    Expanded(
                      child: Slider(
                        value: progress.clamp(0.0, 1.0),
                        onChanged: _isReady && total > 1
                            ? (v) {
                                setState(() => _seekProgress = v);
                              }
                            : null,
                        onChangeEnd: _isReady && total > 1
                            ? (v) {
                                final target =
                                    (v * (total - 1)).round() + 1;
                                _controller.goToPage(pageNumber: target);
                              }
                            : null,
                        activeColor: Colors.indigoAccent,
                        inactiveColor: Colors.white24,
                      ),
                    ),
                    Text(
                      '/ $total',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── 页码浮标 ──────────────────────────────────────────────

  Widget _buildPageHint() {
    final current = _pageNumber ?? 1;
    final total = _pageCount > 0 ? _pageCount : 0;
    final percent =
        total > 0 ? (current / total * 100).toStringAsFixed(1) : '0.0';
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$current / $total  ($percent%)',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    );
  }

  // ─── 错误提示 ──────────────────────────────────────────────

  Widget _buildErrorBanner(Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 56),
            const SizedBox(height: 16),
            const Text(
              'PDF 打开失败',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回书架'),
            ),
          ],
        ),
      ),
    );
  }
}
