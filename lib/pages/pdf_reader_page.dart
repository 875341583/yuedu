/// PDF 阅读页面
///
/// 使用 pdfrx（PDFium 引擎）将 PDF 每页渲染为图片显示，
/// 支持任意 PDF（文本型/扫描型/加密）。
/// 提供两种视图模式：
///   - scroll：连续滚动（PdfViewer）
///   - page：单页分页翻页（PageView + PdfPageView，跟手滑动）
/// 与排版阅读页（ReaderPage）解耦：PDF 书走本页，其他格式仍走排版引擎。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../services/bookshelf_service.dart';

/// PDF 视图模式：scroll=连续滚动，page=单页分页翻页
enum PdfViewMode { scroll, page }

/// 屏幕方向模式
enum PdfOrientationMode {
  auto,      // 跟随系统
  landscape, // 强制横屏
  portrait,  // 强制竖屏
}

const _pdfOrientNames = <PdfOrientationMode, String>{
  PdfOrientationMode.auto: '自动',
  PdfOrientationMode.landscape: '横屏',
  PdfOrientationMode.portrait: '竖屏',
};

const _kPdfViewModeKey = 'yuedu_pdf_view_mode';
const _kPdfPagePrefix = 'yuedu_pdf_page_';
const _kPdfOrientKey = 'yuedu_pdf_orient_mode';
const _kPdfFirstHintKey = 'yuedu_pdf_first_hint_shown';

class PdfReaderPage extends StatefulWidget {
  final Book book;

  const PdfReaderPage({super.key, required this.book});

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  // 滚动模式控制器
  final PdfViewerController _scrollController = PdfViewerController();

  // 分页模式控制器
  PageController? _pageController;

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

  /// 当前视图模式
  PdfViewMode _viewMode = PdfViewMode.scroll;

  /// 当前方向模式
  PdfOrientationMode _orientMode = PdfOrientationMode.auto;

  /// 分页模式的 PdfDocument（独立于 PdfViewer）
  PdfDocument? _document;
  bool _docLoading = false;
  String? _docError;

  /// 初始页码（从持久化读取）
  int _initialPage = 1;

  /// 异步初始化是否完成
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // PDF 默认跟随系统方向（不强制）
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _initAsync();
  }

  Future<void> _initAsync() async {
    _viewMode = await _loadViewMode();
    _orientMode = await _loadOrientMode();
    _applyOrientation(_orientMode);
    _initialPage = await _loadSavedPage();
    if (!mounted) return;
    setState(() => _initialized = true);
    if (_viewMode == PdfViewMode.page) {
      _pageController = PageController(initialPage: _initialPage - 1);
      _loadDocument();
    }
    // 首次进入提示
    _maybeShowFirstHint();
  }

  Future<void> _maybeShowFirstHint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kPdfFirstHintKey) == true) return;
      await prefs.setBool(_kPdfFirstHintKey, true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('点击屏幕呼出菜单 · 右下角按钮切换滚动/分页 · 翻页模式随时可切'),
          duration: Duration(seconds: 4),
        ),
      );
    } catch (_) {}
  }

  Future<PdfOrientationMode> _loadOrientMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt(_kPdfOrientKey) ?? 0;
      return PdfOrientationMode.values[
          idx.clamp(0, PdfOrientationMode.values.length - 1)];
    } catch (_) {
      return PdfOrientationMode.auto;
    }
  }

  Future<void> _saveOrientMode(PdfOrientationMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPdfOrientKey, mode.index);
    } catch (_) {}
  }

  void _applyOrientation(PdfOrientationMode mode) {
    switch (mode) {
      case PdfOrientationMode.auto:
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        break;
      case PdfOrientationMode.landscape:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        break;
      case PdfOrientationMode.portrait:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        break;
    }
  }

  Future<void> _changeOrientMode(PdfOrientationMode mode) async {
    if (mode == _orientMode) return;
    setState(() => _orientMode = mode);
    _applyOrientation(mode);
    await _saveOrientMode(mode);
  }

  Future<PdfViewMode> _loadViewMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_kPdfViewModeKey);
      return v == 'page' ? PdfViewMode.page : PdfViewMode.scroll;
    } catch (_) {
      return PdfViewMode.scroll;
    }
  }

  Future<void> _saveViewMode(PdfViewMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kPdfViewModeKey, mode == PdfViewMode.page ? 'page' : 'scroll');
    } catch (_) {}
  }

  Future<int> _loadSavedPage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final page = prefs.getInt('$_kPdfPagePrefix${widget.book.id}') ?? 1;
      return page < 1 ? 1 : page;
    } catch (_) {
      return 1;
    }
  }

  Future<void> _savePage(int page) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$_kPdfPagePrefix${widget.book.id}', page);
    } catch (_) {}
  }

  /// 加载 PdfDocument（分页模式用）
  Future<void> _loadDocument() async {
    if (_document != null || _docLoading) return;
    setState(() {
      _docLoading = true;
      _docError = null;
    });
    try {
      final doc = await PdfDocument.openFile(widget.book.filePath);
      if (!mounted) {
        doc.dispose();
        return;
      }
      setState(() {
        _document = doc;
        _pageCount = doc.pages.length;
        _isReady = true;
        _pageNumber ??= _initialPage;
        _docLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _docError = '$e';
        _docLoading = false;
      });
    }
  }

  /// 切换视图模式
  Future<void> _switchMode(PdfViewMode newMode) async {
    if (newMode == _viewMode) return;
    final currentPage = _pageNumber ?? _initialPage;
    await _savePage(currentPage);

    setState(() {
      _viewMode = newMode;
      _showMenu = false;
    });
    await _saveViewMode(newMode);

    if (newMode == PdfViewMode.page) {
      // 分页模式：先确保文档已加载
      if (_document == null) {
        await _loadDocument();
      }
      // 用真实页数创建 PageController
      _pageController?.dispose();
      final maxIndex = _pageCount > 0 ? _pageCount - 1 : 0;
      final initialIndex = (currentPage - 1).clamp(0, maxIndex);
      _pageController = PageController(initialPage: initialIndex);
      setState(() {});
    } else {
      // 切回滚动模式：延迟跳转到当前页
      setState(() {});
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        try {
          _scrollController.goToPage(pageNumber: currentPage);
        } catch (_) {}
      });
    }
  }

  /// 跳转到指定页（自动适配两种模式）
  void _goToPage(int page) {
    if (page < 1 || (_pageCount > 0 && page > _pageCount)) return;
    if (_viewMode == PdfViewMode.page) {
      _pageController?.animateToPage(
        page - 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      try {
        _scrollController.goToPage(pageNumber: page);
      } catch (_) {}
    }
  }

  /// 持久化当前页码
  Future<void> _persistPosition() async {
    final page = _pageNumber;
    if (page != null && page > 0) {
      await _savePage(page);
      if (_pageCount > 0) {
        try {
          BookshelfService.instance.updateReadPosition(widget.book.id, page);
        } catch (_) {}
      }
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
  void dispose() {
    _persistPosition();
    _pageController?.dispose();
    _document?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _buildContent()),
          if (_showMenu) _buildTopBar(),
          if (_showMenu) _buildBottomBar(),
          if (!_showMenu && _isReady) _buildPageHint(),
          // 常驻浮动控件栏（不受菜单状态影响，保证随时可切视图）
          if (_isReady) _buildFloatingControls(),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_viewMode == PdfViewMode.page) {
      return _buildPageView();
    }
    return _buildScrollView();
  }

  // ─── 滚动模式 ──────────────────────────────────────────────

  Widget _buildScrollView() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _toggleMenu,
      child: PdfViewer.file(
        widget.book.filePath,
        controller: _scrollController,
        initialPageNumber: _initialPage,
        params: PdfViewerParams(
          backgroundColor: const Color(0xFF3A3A3A),
          pageAnchor: PdfPageAnchor.top,
          enableTextSelection: true,
          onViewerReady: (document, controller) {
            setState(() {
              _isReady = true;
              _pageCount = document.pages.length;
              _pageNumber ??= _initialPage;
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
    );
  }

  // ─── 分页模式（跟手翻页）──────────────────────────────────

  Widget _buildPageView() {
    if (_docLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_docError != null) {
      return _buildErrorBanner(_docError!);
    }
    final doc = _document;
    if (doc == null || _pageCount == 0) {
      return const Center(child: CircularProgressIndicator());
    }
    final controller = _pageController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _toggleMenu,
      child: PageView.builder(
        controller: controller,
        itemCount: _pageCount,
        onPageChanged: (index) {
          setState(() {
            _pageNumber = index + 1;
            _seekProgress = null;
          });
          _persistPosition();
        },
        itemBuilder: (context, index) {
          return Container(
            color: const Color(0xFF3A3A3A),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            child: PdfPageView(
              document: doc,
              pageNumber: index + 1,
              backgroundColor: const Color(0xFF3A3A3A),
            ),
          );
        },
      ),
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
                // ── 视图模式切换 ──
                IconButton(
                  icon: Icon(
                    _viewMode == PdfViewMode.page
                        ? Icons.view_stream
                        : Icons.menu_book_outlined,
                    color: Colors.white,
                  ),
                  tooltip: _viewMode == PdfViewMode.page
                      ? '切换为滚动模式'
                      : '切换为分页模式',
                  onPressed: () {
                    _switchMode(_viewMode == PdfViewMode.page
                        ? PdfViewMode.scroll
                        : PdfViewMode.page);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.first_page, color: Colors.white),
                  tooltip: '第一页',
                  onPressed: _isReady ? () => _goToPage(1) : null,
                ),
                IconButton(
                  icon: const Icon(Icons.last_page, color: Colors.white),
                  tooltip: '最后一页',
                  onPressed: _isReady && _pageCount > 0
                      ? () => _goToPage(_pageCount)
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
    final progress =
        _seekProgress ?? (current - 1) / (total - 1 > 0 ? total - 1 : 1);

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
            child: Row(
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
                            final target = (v * (total - 1)).round() + 1;
                            _goToPage(target);
                            setState(() => _seekProgress = null);
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
          ),
        ),
      ),
    );
  }

  // ─── 页码浮标（可点击呼出菜单） ─────────────────────────────

  Widget _buildPageHint() {
    final current = _pageNumber ?? 1;
    final total = _pageCount > 0 ? _pageCount : 0;
    final percent =
        total > 0 ? (current / total * 100).toStringAsFixed(1) : '0.0';
    final mode = _viewMode == PdfViewMode.page ? '  分页' : '  滚动';
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _toggleMenu,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$current / $total  ($percent%)$mode  · 点击呼出菜单',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }

  // ─── 常驻浮动控件栏（右下角，始终可见） ────────────────────────

  Widget _buildFloatingControls() {
    return Positioned(
      bottom: 16,
      right: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 视图模式切换
          GestureDetector(
            onTap: () {
              _switchMode(_viewMode == PdfViewMode.page
                  ? PdfViewMode.scroll
                  : PdfViewMode.page);
            },
            child: Tooltip(
              message: _viewMode == PdfViewMode.page
                  ? '切换为滚动模式'
                  : '切换为分页模式',
              child: _floatIcon(_viewMode == PdfViewMode.page
                  ? Icons.view_stream
                  : Icons.menu_book_outlined),
            ),
          ),
          const SizedBox(height: 8),
          // 方向切换
          PopupMenuButton<PdfOrientationMode>(
            icon: _floatIcon(Icons.screen_rotation),
            tooltip: '屏幕方向',
            onSelected: _changeOrientMode,
            color: Colors.black87,
            itemBuilder: (ctx) => PdfOrientationMode.values.map((m) {
              return PopupMenuItem<PdfOrientationMode>(
                value: m,
                child: Row(
                  children: [
                    Icon(
                      _orientMode == m
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 8),
                    Text(_pdfOrientNames[m]!,
                        style: const TextStyle(color: Colors.white)),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _floatIcon(IconData icon) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: 22),
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
