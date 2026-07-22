/// PDF 阅读页面
///
/// 使用 pdfrx（PDFium 引擎）将 PDF 每页渲染为图片显示，
/// 支持任意 PDF（文本型/扫描型/加密）。
/// 提供两种视图模式：
///   - scroll：连续滚动（PdfViewer）
///   - page：单页分页翻页（PageView + PdfPageView，跟手滑动）
/// 与排版阅读页（ReaderPage）解耦：PDF 书走本页，其他格式仍走排版引擎。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../services/bookshelf_service.dart';
import '../pdf/pdf_engines.dart';
import '../plugins/plugin_manager.dart';
import '../plugins/plugin.dart';
import '../plugins/builtin/ai_layout_plugin.dart';

/// PDF 视图模式：scroll=连续滚动，page=单页分页翻页
enum PdfViewMode { scroll, page }

/// 分页模式下的翻页效果（和 ReaderPage 一致）
enum PdfPageTurnMode {
  slide, // 滑动（PageView 原生跟手）
  cover, // 覆盖
  fade,  // 淡入（渐变扫光）
  flip,  // 3D翻转
  none,  // 无动画
}

const _pdfTurnModeNames = <PdfPageTurnMode, String>{
  PdfPageTurnMode.slide: '滑动',
  PdfPageTurnMode.cover: '覆盖',
  PdfPageTurnMode.fade: '淡入',
  PdfPageTurnMode.flip: '翻转',
  PdfPageTurnMode.none: '无动画',
};

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
const _kPdfTurnModeKey = 'yuedu_pdf_turn_mode';
const _kPdfHighlightsPrefix = 'yuedu_pdf_highlights_';

/// PDF 矩形高亮的 5 种颜色（与排版阅读器 Highlight 系统一致）
const _pdfHighlightColors = <Color>[
  Color(0xFFFFEB3B), // 黄
  Color(0xFFA5D6A7), // 绿
  Color(0xFF90CAF9), // 蓝
  Color(0xFFEF9A9A), // 红
  Color(0xFFCE93D8), // 紫
];

/// PDF 矩形高亮数据模型
///
/// 使用相对坐标（0~1）存储，便于不同屏幕尺寸下复现。
class PdfRectHighlight {
  final String id;
  final int page;
  final double relX, relY, relW, relH; // 相对页面区域（0~1）
  final int colorIndex;

  const PdfRectHighlight({
    required this.id,
    required this.page,
    required this.relX,
    required this.relY,
    required this.relW,
    required this.relH,
    required this.colorIndex,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'page': page,
        'x': relX,
        'y': relY,
        'w': relW,
        'h': relH,
        'c': colorIndex,
      };

  factory PdfRectHighlight.fromJson(Map<String, dynamic> j) =>
      PdfRectHighlight(
        id: j['id'] as String? ?? '',
        page: (j['page'] as num?)?.toInt() ?? 1,
        relX: (j['x'] as num?)?.toDouble() ?? 0,
        relY: (j['y'] as num?)?.toDouble() ?? 0,
        relW: (j['w'] as num?)?.toDouble() ?? 0,
        relH: (j['h'] as num?)?.toDouble() ?? 0,
        colorIndex: (j['c'] as num?)?.toInt() ?? 0,
      );
}

class PdfReaderPage extends StatefulWidget {
  final Book book;

  const PdfReaderPage({super.key, required this.book});

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage>
    with SingleTickerProviderStateMixin {
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

  /// 分页模式下的翻页效果
  PdfPageTurnMode _turnMode = PdfPageTurnMode.slide;

  // ─── 跟手翻页状态（非 slide 分页模式）─────────────────────
  double _dragExtent = 0;
  bool _isDragging = false;
  late final AnimationController _turnController;
  double _animFromExtent = 0;
  double _animTargetExtent = 0;
  double _pageFullWidth = 0;
  int _dragDir = 0;

  /// 分页模式的 PdfDocument（独立于 PdfViewer）
  PdfDocument? _document;
  bool _docLoading = false;
  String? _docError;

  /// 初始页码（从持久化读取）
  int _initialPage = 1;

  /// 异步初始化是否完成
  bool _initialized = false;

  // ─── PDF 矩形高亮（v0.5.3 新增）─────────────────────────────
  /// 按页码分组的高亮列表
  final Map<int, List<PdfRectHighlight>> _highlightsByPage = {};

  /// 是否正在创建高亮（长按启动）
  bool _isMarking = false;

  /// 标记模式下的起点/当前点（相对 PDF 页面 widget 的局部坐标）
  Offset? _markStart;
  Offset? _markCurrent;

  /// 当页选中的高亮 id（用于删除）
  String? _selectedHighlightId;

  /// 当前选中的颜色索引
  int _highlightColorIndex = 0;

  // ─── v0.8.0 PDF 增强功能 ────────────────────────────────────
  /// 裁白边模式
  CropMode _cropMode = CropMode.off;

  /// 适配模式
  PdfFitMode _fitMode = PdfFitMode.fitWidth;

  /// 逐页裁切结果缓存（pageNumber → PdfCropRegion）
  final Map<int, PdfCropRegion> _cropRegions = {};

  /// 统一裁切结果
  PdfCropRegion? _unifiedCropRegion;

  /// 裁切计算是否进行中
  bool _cropComputing = false;

  /// 裁切计算进度（已计算页数 / 总页数）
  double _cropProgress = 0.0;

  /// 手动裁切：是否正在拖动画裁切区域
  bool _isManualCropping = false;

  /// 手动裁切：拖动起点（屏幕坐标，相对于 PdfPageView 区域）
  Offset? _manualCropStart;

  /// 手动裁切：当前拖动点
  Offset? _manualCropCurrent;

  /// 手动裁切：已确认的裁切区域（相对页面 0~1 比例坐标）
  Rect? _manualCropRect;

  // ── v0.9.0: AI 重排状态 ──
  bool _aiReflowing = false;

  /// AI 插件是否已启用
  bool _isAiPluginEnabled = false;

  /// 分栏检测结果缓存（pageNumber → ColumnDetectionResult）
  final Map<int, ColumnDetectionResult> _columnResults = {};

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // PDF 默认跟随系统方向（不强制）
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _turnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _turnController.addListener(_onTurnAnimTick);
    _turnController.addStatusListener(_onTurnAnimStatus);
    _initAsync();
  }

  Future<void> _initAsync() async {
    _viewMode = await _loadViewMode();
    _orientMode = await _loadOrientMode();
    _turnMode = await _loadTurnMode();
    _cropMode = await _loadCropMode();
    _fitMode = await AdaptiveZoomEngine.loadFitMode();
    _applyOrientation(_orientMode);
    _initialPage = await _loadSavedPage();
    await _loadHighlights();
    // 检查 AI 插件是否已启用
    _isAiPluginEnabled = PluginManager.instance.isEnabled('pdf_ai_layout');
    if (!mounted) return;
    setState(() => _initialized = true);
    if (_viewMode == PdfViewMode.page) {
      _pageController = PageController(initialPage: _initialPage - 1);
      _loadDocument();
    }
    // 首次进入提示
    _maybeShowFirstHint();
  }

  /// 加载持久化的高亮数据
  Future<void> _loadHighlights() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('$_kPdfHighlightsPrefix${widget.book.id}');
      if (json == null || json.isEmpty) return;
      final list = jsonDecode(json) as List;
      for (final item in list) {
        final h = PdfRectHighlight.fromJson(item as Map<String, dynamic>);
        _highlightsByPage.putIfAbsent(h.page, () => []).add(h);
      }
    } catch (e) {
      // 高亮加载失败不阻塞阅读，但记录便于排查
      debugPrint('加载高亮失败: $e');
    }
  }

  /// 持久化高亮数据
  Future<void> _saveHighlights() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _highlightsByPage.values
          .expand((l) => l)
          .map((h) => h.toJson())
          .toList();
      await prefs.setString(
          '$_kPdfHighlightsPrefix${widget.book.id}', jsonEncode(list));
    } catch (e) {
      debugPrint('保存高亮失败: $e');
    }
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

  Future<PdfPageTurnMode> _loadTurnMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt(_kPdfTurnModeKey) ?? 0;
      return PdfPageTurnMode.values[
          idx.clamp(0, PdfPageTurnMode.values.length - 1)];
    } catch (_) {
      return PdfPageTurnMode.slide;
    }
  }

  Future<void> _saveTurnMode(PdfPageTurnMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPdfTurnModeKey, mode.index);
    } catch (_) {}
  }

  Future<void> _changeTurnMode(PdfPageTurnMode mode) async {
    if (mode == _turnMode) return;
    setState(() {
      _turnMode = mode;
      _showMenu = false;
      _dragExtent = 0;
      _dragDir = 0;
    });
    await _saveTurnMode(mode);
    if (mode == PdfPageTurnMode.slide) {
      // 切回 slide：跳到当前页
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!mounted) return;
        final cur = (_pageNumber ?? 1) - 1;
        _pageController?.jumpToPage(cur);
      });
    }
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

  // ─── 裁白边模式持久化 ────────────────────────────────────

  static const _kPdfCropModeKey = 'yuedu_pdf_crop_mode';

  Future<CropMode> _loadCropMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt(_kPdfCropModeKey) ?? 0;
      return CropMode.values[idx.clamp(0, CropMode.values.length - 1)];
    } catch (_) {
      return CropMode.off;
    }
  }

  Future<void> _saveCropMode(CropMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPdfCropModeKey, mode.index);
    } catch (_) {}
  }

  Future<void> _changeCropMode(CropMode mode) async {
    if (mode == _cropMode) return;
    setState(() {
      _cropMode = mode;
      _showMenu = false;
    });
    await _saveCropMode(mode);
    // 如果切换到需要裁切数据的模式，启动计算
    if (mode != CropMode.off && _document != null && _cropRegions.isEmpty) {
      _computeCropRegions();
    }
  }

  Future<void> _changeFitMode(PdfFitMode mode) async {
    if (mode == _fitMode) return;
    setState(() => _fitMode = mode);
    await AdaptiveZoomEngine.saveFitMode(mode);
  }

  /// 后台计算裁白边数据
  Future<void> _computeCropRegions() async {
    final doc = _document;
    if (doc == null || _cropComputing) return;
    setState(() {
      _cropComputing = true;
      _cropProgress = 0.0;
    });

    final total = doc.pages.length;
    final perPageResults = <PdfCropRegion?>[];

    for (int i = 0; i < total; i++) {
      try {
        final page = doc.pages[i];
        final region = await AutoCropEngine.computeForPage(page);
        perPageResults.add(region);
        if (region != null) {
          _cropRegions[page.pageNumber] = region;
        }
      } catch (_) {
        perPageResults.add(null);
      }
      if (!mounted) return;
      setState(() {
        _cropProgress = (i + 1) / total;
      });
    }

    // 计算统一裁切
    if (perPageResults.any((r) => r != null)) {
      _unifiedCropRegion = AutoCropEngine.computeUnified(
        perPageResults,
        pageWidth: doc.pages.isNotEmpty ? doc.pages[0].width : 612.0,
        pageHeight: doc.pages.isNotEmpty ? doc.pages[0].height : 792.0,
      );
    }

    if (!mounted) return;
    setState(() {
      _cropComputing = false;
      _cropProgress = 1.0;
    });
  }

  /// 获取指定页的裁切区域
  PdfRect? _getCropBoundsForPage(int pageNumber) {
    switch (_cropMode) {
      case CropMode.off:
        return null;
      case CropMode.perPage:
        return _cropRegions[pageNumber]?.cropBounds;
      case CropMode.unified:
        return _unifiedCropRegion?.cropBounds;
      case CropMode.manual:
        // 手动裁切：将相对坐标矩形转换为 PdfRect（PDF 坐标系）
        final rect = _manualCropRect;
        if (rect == null) return null;
        final doc = _document;
        if (doc == null || pageNumber < 1 || pageNumber > doc.pages.length) return null;
        final page = doc.pages[pageNumber - 1];
        // 相对坐标 → PDF 坐标系（原点左下角，Y 向上）
        final left = rect.left * page.width;
        final right = rect.right * page.width;
        final top = (1.0 - rect.top) * page.height;   // PDF 坐标系 top 对应 Flutter bottom
        final bottom = (1.0 - rect.bottom) * page.height;
        return PdfRect(left, top, right, bottom);
    }
  }

  // ─── 分栏检测 ──────────────────────────────────────────

  Future<void> _detectColumnsForCurrentPage() async {
    final doc = _document;
    if (doc == null) return;
    final current = _pageNumber ?? 1;
    if (_columnResults.containsKey(current)) return;

    try {
      final page = doc.pages[current - 1];
      final result = await ColumnDetector.detectForPage(page);
      if (result != null && mounted) {
        setState(() {
          _columnResults[current] = result;
        });
      }
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
      // 如果裁白边模式开启，启动后台计算
      if (_cropMode != CropMode.off) {
        _computeCropRegions();
      }
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
      // C3: 提示用户文本选择仅在滚动模式可用
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('提示：文本选择和复制仅在滚动模式可用'),
            duration: Duration(seconds: 2),
          ),
        );
      }
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
      if (_turnMode == PdfPageTurnMode.slide) {
        _pageController?.animateToPage(
          page - 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        // 非 slide 模式直接切（滑块跳页不走动画）
        setState(() {
          _pageNumber = page;
          _dragExtent = 0;
          _dragDir = 0;
        });
        _persistPosition();
      }
    } else {
      try {
        _scrollController.goToPage(pageNumber: page);
      } catch (_) {}
    }
  }

  void _nextPage() {
    final current = _pageNumber ?? 1;
    if (current >= _pageCount) return;
    if (_viewMode == PdfViewMode.page && _turnMode != PdfPageTurnMode.slide) {
      _animateTurnToPage(1);
    } else {
      _goToPage(current + 1);
    }
  }

  void _prevPage() {
    final current = _pageNumber ?? 1;
    if (current <= 1) return;
    if (_viewMode == PdfViewMode.page && _turnMode != PdfPageTurnMode.slide) {
      _animateTurnToPage(-1);
    } else {
      _goToPage(current - 1);
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
    _turnController.dispose();
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

  // ─── 分页模式 ──────────────────────────────────────────────

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
    // slide 模式：PageView 原生跟手
    if (_turnMode == PdfPageTurnMode.slide) {
      final controller = _pageController;
      if (controller == null) {
        return const Center(child: CircularProgressIndicator());
      }
      // v0.8.2 修复手势竞争：slide 模式下 PageView 自带拖拽，
      // 外层只注册 tap（三分法翻页）和 longPress（高亮），不冲突。
      // 但 tap 需用 TapGestureRecognizer + 三分法逻辑（和 ReaderPage 一致）。
      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(),
            (TapGestureRecognizer instance) {
              instance.onTapUp = _handleTapUp;
            },
          ),
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
              duration: const Duration(milliseconds: 400),
              postAcceptSlopTolerance: 64.0,
            ),
            (LongPressGestureRecognizer instance) {
              instance.onLongPressStart = _handleLongPressStart;
              instance.onLongPressMoveUpdate = _handleLongPressMove;
              instance.onLongPressEnd = _handleLongPressEnd;
            },
          ),
        },
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
            return _buildPdfPage(doc, index + 1);
          },
        ),
      );
    }
    // 非 slide 模式：跟手 Stack + Transform
    return LayoutBuilder(
      builder: (context, constraints) {
        _pageFullWidth = constraints.maxWidth;
        // v0.8.2 修复手势竞争：非 slide 模式下 onHorizontalDrag 与 onLongPress
        // 同时注册会导致长按被拖拽抢走竞技场。改用 RawGestureDetector：
        //   - 自定义 _LargerSlopHorizontalDragGestureRecognizer 阈值 32px
        //   - LongPress deadline 400ms + postAcceptSlopTolerance 64px
        //   - TapGestureRecognizer 用于三分法翻页
        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(),
              (TapGestureRecognizer instance) {
                instance.onTapUp = _handleTapUp;
              },
            ),
            _LargerSlopHorizontalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                    _LargerSlopHorizontalDragGestureRecognizer>(
              () => _LargerSlopHorizontalDragGestureRecognizer(),
              (_LargerSlopHorizontalDragGestureRecognizer instance) {
                instance.onStart = _handleDragStart;
                instance.onUpdate = _handleDragUpdate;
                instance.onEnd = _handleDragEnd;
              },
            ),
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: const Duration(milliseconds: 400),
                postAcceptSlopTolerance: 64.0,
              ),
              (LongPressGestureRecognizer instance) {
                instance.onLongPressStart = _handleLongPressStart;
                instance.onLongPressMoveUpdate = _handleLongPressMove;
                instance.onLongPressEnd = _handleLongPressEnd;
              },
            ),
          },
          child: _buildPageTurnView(doc),
        );
      },
    );
  }

  /// 渲染单个 PDF 页面（PdfPageView 外层包装 + 高亮层）
  ///
  /// 用 KeyedSubtree 按 pageNumber 标记，避免翻页末帧从多页 Stack 切回裸单页时
  /// 触发 PdfPageView 子树重建（pdfrx 重新解码位图），造成一帧白屏闪屏。
  ///
  /// v0.8.0：支持裁白边（CroppedPageView）和自适应缩放（InteractiveViewer）
  Widget _buildPdfPage(PdfDocument doc, int pageNumber) {
    final cropBounds = _getCropBoundsForPage(pageNumber);
    final isCurrentPage = pageNumber == (_pageNumber ?? 1);
    final showManualCropOverlay = _cropMode == CropMode.manual
        && isCurrentPage
        && _manualCropRect == null; // 确认裁切后不再显示overlay

    return KeyedSubtree(
      key: ValueKey('pdf_page_$pageNumber'),
      child: Container(
        color: const Color(0xFF3A3A3A),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewSize = constraints.biggest;

            // 选择渲染方式
            Widget pageWidget;
            if (cropBounds != null && cropBounds.isNotEmpty) {
              // 裁切模式：使用 CroppedPageView 仅渲染内容区域
              // 手动裁切：拉伸填充全屏；自动裁切：保持宽高比
              pageWidget = CroppedPageView(
                document: doc,
                pageNumber: pageNumber,
                cropBounds: cropBounds,
                backgroundColor: const Color(0xFF3A3A3A),
                stretchToFill: _cropMode == CropMode.manual,
              );
            } else {
              // 标准模式：使用 PdfPageView 渲染整页
              pageWidget = PdfPageView(
                document: doc,
                pageNumber: pageNumber,
                backgroundColor: const Color(0xFF3A3A3A),
              );
            }

            return Stack(
              children: [
                // 自适应缩放包裹：支持双指缩放和双击缩放
                InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5.0,
                  boundaryMargin: const EdgeInsets.all(50),
                  child: pageWidget,
                ),
                // 高亮层：渲染当前页已有高亮 + 正在拖动的矩形
                Positioned.fill(
                  child: _buildHighlightLayer(pageNumber, viewSize),
                ),
                // 手动裁切交互层
                if (showManualCropOverlay)
                  Positioned.fill(
                    child: _buildManualCropOverlay(viewSize),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 手动裁切交互层 — 半透明遮罩 + 拖动画矩形 + 确认/重置按钮
  Widget _buildManualCropOverlay(Size viewSize) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (details) {
        setState(() {
          _isManualCropping = true;
          _manualCropStart = details.localPosition - _kPdfInnerOffset;
          _manualCropCurrent = _manualCropStart;
        });
      },
      onPanUpdate: (details) {
        if (!_isManualCropping) return;
        setState(() {
          _manualCropCurrent = details.localPosition - _kPdfInnerOffset;
        });
      },
      onPanEnd: (details) {
        if (!_isManualCropping) return;
        setState(() {
          _isManualCropping = false;
        });
        // 矩形过小则忽略
        final s = _manualCropStart;
        final c = _manualCropCurrent;
        if (s == null || c == null) return;
        final w = (c - s).dx.abs();
        final h = (c - s).dy.abs();
        if (w < 20 || h < 20) {
          setState(() {
            _manualCropStart = null;
            _manualCropCurrent = null;
          });
          return;
        }
      },
      child: Stack(
        children: [
          // 遮罩层 + 裁切矩形
          Positioned.fill(
            child: CustomPaint(
              size: viewSize,
              painter: _ManualCropPainter(
                cropStart: _manualCropStart,
                cropCurrent: _manualCropCurrent,
                confirmedRect: _manualCropRect,
                innerOffset: _kPdfInnerOffset,
              ),
            ),
          ),
          // 确认/重置按钮
          if (_manualCropStart != null && _manualCropCurrent != null && !_isManualCropping)
            Positioned(
              bottom: 30,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _confirmManualCrop,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('确认裁切'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: _resetManualCrop,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重画'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                    ),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: _clearManualCrop,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('取消裁切'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white38),
                    ),
                  ),
                ],
              ),
            ),
          // 提示文字
          if (_manualCropStart == null && _manualCropCurrent == null && _manualCropRect == null)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  '在页面上拖动画出裁切区域',
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 确认手动裁切区域
  void _confirmManualCrop() {
    final s = _manualCropStart;
    final c = _manualCropCurrent;
    if (s == null || c == null) return;

    final mediaSize = MediaQuery.of(context).size;
    final viewW = mediaSize.width - _kPdfInnerOffset.dx * 2;
    final viewH = mediaSize.height - _kPdfInnerOffset.dy * 2;

    final left = math.min(s.dx, c.dx).clamp(0.0, viewW);
    final top = math.min(s.dy, c.dy).clamp(0.0, viewH);
    final right = math.max(s.dx, c.dx).clamp(0.0, viewW);
    final bottom = math.max(s.dy, c.dy).clamp(0.0, viewH);

    // 转为相对坐标（0~1）
    setState(() {
      _manualCropRect = Rect.fromLTWH(
        left / viewW,
        top / viewH,
        (right - left) / viewW,
        (bottom - top) / viewH,
      );
      _manualCropStart = null;
      _manualCropCurrent = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('裁切区域已应用，内容将拉伸填充全屏。如需重新裁切，请再次点击裁白边按钮选择"手动裁切"'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  /// 重画裁切区域
  void _resetManualCrop() {
    setState(() {
      _manualCropStart = null;
      _manualCropCurrent = null;
      _manualCropRect = null;
    });
  }

  /// 取消手动裁切
  void _clearManualCrop() {
    setState(() {
      _manualCropStart = null;
      _manualCropCurrent = null;
      _manualCropRect = null;
      _cropMode = CropMode.off;
    });
    _saveCropMode(CropMode.off);
  }

  /// 高亮绘制层
  Widget _buildHighlightLayer(int pageNumber, Size size) {
    final existing = _highlightsByPage[pageNumber] ?? [];
    final isCurrentPage = pageNumber == (_pageNumber ?? 1);
    // 检测点击是否命中某个已有高亮矩形
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (details) {
        if (!isCurrentPage || existing.isEmpty) return;
        final tapPos = details.localPosition;
        // 遍历高亮，用相对坐标转换为像素坐标做命中检测
        for (final h in existing) {
          final rect = Rect.fromLTWH(
            h.relX * size.width,
            h.relY * size.height,
            h.relW * size.width,
            h.relH * size.height,
          );
          if (rect.contains(tapPos)) {
            // 选中或取消选中
            if (_selectedHighlightId == h.id) {
              // 已选中 → 弹出删除确认
              _showHighlightDeleteDialog(h.id);
            } else {
             setState(() => _selectedHighlightId = h.id);
            }
            return;
          }
        }
        // 点空白处取消选中
        if (_selectedHighlightId != null) {
          setState(() => _selectedHighlightId = null);
        }
      },
      child: CustomPaint(
        size: Size.infinite,
        painter: _PdfHighlightPainter(
          existing: existing,
          pageSize: size,
          markStart: isCurrentPage ? _markStart : null,
          markCurrent: isCurrentPage ? _markCurrent : null,
          selectedId: isCurrentPage ? _selectedHighlightId : null,
        ),
      ),
    );
  }

  /// 弹出删除确认对话框（点击已选中的高亮时触发）
  void _showHighlightDeleteDialog(String id) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除高亮'),
        content: const Text('确定删除选中的高亮吗？'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setState(() => _selectedHighlightId = null);
            },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _deleteHighlight(id);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 点击翻页或切菜单（屏幕三分法）
  void _handleTapUp(TapUpDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    final dx = details.localPosition.dx;
    if (dx < screenWidth / 3) {
      _prevPage();
    } else if (dx > screenWidth * 2 / 3) {
      _nextPage();
    } else {
      _toggleMenu();
    }
  }

  // ─── 矩形高亮手势处理（v0.5.3 新增）──────────────────────────

  /// _buildPdfPage 内层 Stack 的左上偏移（外层 Container padding 6/10）
  static const _kPdfInnerOffset = Offset(6, 10);

  void _handleLongPressStart(LongPressStartDetails details) {
    setState(() {
      _isMarking = true;
      _selectedHighlightId = null;
      _markStart = details.localPosition - _kPdfInnerOffset;
      _markCurrent = _markStart;
    });
  }

  void _handleLongPressMove(LongPressMoveUpdateDetails details) {
    if (!_isMarking) return;
    setState(() {
      _markCurrent = details.localPosition - _kPdfInnerOffset;
    });
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    if (!_isMarking) return;
    // 矩形过小则视为误触，丢弃
    final s = _markStart;
    final c = _markCurrent;
    if (s == null || c == null) {
      setState(() => _isMarking = false);
      return;
    }
    final w = (c - s).dx.abs();
    final h = (c - s).dy.abs();
    // 矩形太小（<20px）→ 取消
    if (w < 20 || h < 20) {
      setState(() {
        _isMarking = false;
        _markStart = null;
        _markCurrent = null;
      });
      return;
    }
    // 保留拖动矩形，弹出工具栏让用户选颜色 / 取消
    setState(() {
      _isMarking = false; // 拖动结束，但矩形保留显示
    });
    _showHighlightToolbar();
  }

  /// 弹出高亮工具栏（颜色选择 + 删除 + 取消）
  void _showHighlightToolbar() {
    final page = _pageNumber ?? 1;
    final s = _markStart;
    final c = _markCurrent;
    if (s == null || c == null) return;
    final mediaSize = MediaQuery.of(context).size;
    final pageSize = Size(
      mediaSize.width - _kPdfInnerOffset.dx * 2,
      mediaSize.height - _kPdfInnerOffset.dy * 2,
    );
    // 工具栏位置：矩形中心
    final rect = Rect.fromPoints(s, c);
    final anchor = Offset(
      rect.center.dx + _kPdfInnerOffset.dx,
      (rect.bottom + 30).clamp(80.0, mediaSize.height - 80),
    );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return _PdfHighlightToolbar(
          anchor: anchor,
          onColorSelected: (colorIdx) {
            Navigator.of(ctx).pop();
            _commitHighlight(pageNumber: page, start: s, current: c, colorIndex: colorIdx, pageSize: pageSize);
          },
          onCancel: () {
            Navigator.of(ctx).pop();
            setState(() {
              _markStart = null;
              _markCurrent = null;
            });
          },
        );
      },
    ).then((_) {
      // 工具栏被遮罩点击/下拉关闭时，mark 不会被清理，避免幻影拖拽框残留
      // 导致下次长按覆盖 _markStart 以及翻页后同一位置出现幻影框
      if (_markStart != null || _markCurrent != null) {
        setState(() {
          _markStart = null;
          _markCurrent = null;
          _isMarking = false;
        });
      }
    });
  }

  /// 提交一个矩形高亮
  void _commitHighlight({
    required int pageNumber,
    required Offset start,
    required Offset current,
    required int colorIndex,
    required Size pageSize,
  }) {
    if (pageSize.isEmpty) return;
    final left = math.min(start.dx, current.dx);
    final top = math.min(start.dy, current.dy);
    final right = math.max(start.dx, current.dx);
    final bottom = math.max(start.dy, current.dy);
    final highlight = PdfRectHighlight(
      id: 'pdf_h_${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(0xFFFF)}',
      page: pageNumber,
      relX: (left / pageSize.width).clamp(0.0, 1.0),
      relY: (top / pageSize.height).clamp(0.0, 1.0),
      relW: ((right - left) / pageSize.width).clamp(0.0, 1.0),
      relH: ((bottom - top) / pageSize.height).clamp(0.0, 1.0),
      colorIndex: colorIndex.clamp(0, _pdfHighlightColors.length - 1),
    );
    // 使用新列表引用触发 shouldRepaint（避免原地 add 后引用不变不重绘）
    setState(() {
      final existing = _highlightsByPage[pageNumber] ?? [];
      _highlightsByPage[pageNumber] = [...existing, highlight];
      _markStart = null;
      _markCurrent = null;
    });
    // fire-and-forget 保存，内部已 try-catch 并输出日志
    _saveHighlights();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已添加高亮'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  /// 删除指定高亮
  void _deleteHighlight(String id) {
    // 使用新列表引用触发 shouldRepaint（避免原地 removeWhere 不重绘）
    setState(() {
      for (final entry in _highlightsByPage.entries.toList()) {
        if (entry.value.any((h) => h.id == id)) {
          final filtered =
              entry.value.where((h) => h.id != id).toList();
          if (filtered.isEmpty) {
            _highlightsByPage.remove(entry.key);
          } else {
            _highlightsByPage[entry.key] = filtered;
          }
        }
      }
      _selectedHighlightId = null;
    });
    _saveHighlights();
  }

  /// 一键清空当前页所有高亮
  void _clearAllHighlightsOnPage() {
    final page = _pageNumber;
    if (page == null) return;
    setState(() {
      _highlightsByPage.remove(page);
      _selectedHighlightId = null;
    });
    _saveHighlights();
  }

  /// 是否对当前页有高亮（用于菜单栏按钮状态）
  bool get _hasHighlightsOnCurrentPage =>
      (_highlightsByPage[_pageNumber ?? 1]?.isNotEmpty ?? false);

  // ─── AI 重排（v0.9.0）─────────────────────────────────────

  /// 用 AI 重排当前页：提取页面文本 → 调用 AI → 展示结果
  Future<void> _aiReflowCurrentPage() async {
    if (_aiReflowing) return;
    final doc = _document;
    final pageNum = _pageNumber;
    if (doc == null || pageNum == null) return;

    // 找到 AI 插件实例
    final plugin = PluginManager.instance.all
        .where((p) => p.id == 'pdf_ai_layout' && p is AiLayoutPlugin)
        .cast<AiLayoutPlugin>()
        .firstOrNull;
    if (plugin == null) {
      _showSnackBar('AI 重排插件未找到');
      return;
    }
    if (!plugin.isConfigured) {
      _showSnackBar('请先在插件设置中配置 AI API');
      return;
    }

    setState(() => _aiReflowing = true);

    try {
      // 提取当前页文本
      final page = doc.pages[pageNum - 1];
      final pageText = await page.loadText();
      final rawText = pageText.fullText;

      if (rawText.trim().isEmpty) {
        _showSnackBar('当前页无可提取的文本（可能是扫描件/图片页）');
        return;
      }

      // 调用 AI 重排
      final result = await plugin.execute(
        context,
        params: {'text': rawText},
      );

      if (result.type == PluginResultType.error) {
        _showSnackBar(result.message ?? 'AI 重排失败');
        return;
      }

      if (mounted && result.text != null) {
        _showReflowResult(result.text!);
      }
    } catch (e) {
      if (mounted) _showSnackBar('AI 重排失败: $e');
    } finally {
      if (mounted) setState(() => _aiReflowing = false);
    }
  }

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  /// 展示 AI 重排结果
  void _showReflowResult(String text) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        const Icon(Icons.auto_awesome, color: Colors.indigo),
                        const SizedBox(width: 8),
                        const Text('AI 重排结果',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scrollController,
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        text,
                        style: const TextStyle(
                            fontSize: 16, height: 1.8, color: Colors.black87),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: text));
                              Navigator.of(ctx).pop();
                              _showSnackBar('已复制到剪贴板');
                            },
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('复制全文'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(Icons.check, size: 18),
                            label: const Text('完成'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ─── 跟手翻页渲染（非 slide 模式）──────────────────────────

  Widget _buildPageTurnView(PdfDocument doc) {
    final current = (_pageNumber ?? 1).clamp(1, _pageCount);
    final currentPage = _buildPdfPage(doc, current);

    // 静态状态：用 Stack 包装保持 widget 树结构稳定。
    // 避免"动画末帧返回多子 Stack → 静态返回裸 Container"的 runtimeType 突变，
    // 触发 PdfPageView 子树重建重解码位图造成闪屏。
    if ((_dragExtent == 0 && !_turnController.isAnimating) ||
        _turnMode == PdfPageTurnMode.none) {
      return Stack(children: [currentPage]);
    }

    final w = _pageFullWidth;
    final p = (_dragExtent / w).clamp(-1.0, 1.0);
    final absP = p.abs();

    Widget? neighborWidget;
    if (_dragDir != 0) {
      final neighborPage = _dragDir < 0 ? current - 1 : current + 1;
      if (neighborPage >= 1 && neighborPage <= _pageCount) {
        neighborWidget = _buildPdfPage(doc, neighborPage);
      }
    }

    final neighborBase = p > 0 ? -w : w;

    switch (_turnMode) {
      case PdfPageTurnMode.cover:
        return Stack(
          children: [
            currentPage,
            if (neighborWidget != null)
              Transform.translate(
                offset: Offset(neighborBase + _dragExtent, 0),
                child: neighborWidget,
              ),
          ],
        );

      case PdfPageTurnMode.fade:
        // 渐变扫光：移动边界 LinearGradient，soft 随 progress 收缩，
        // progress=1 时当前页全透、邻居页全显，无末尾闪烁
        final isNext = p < 0;
        final progress = absP.clamp(0.0, 1.0);
        final edge = 1.0 - progress;
        final soft = 0.12 * (1.0 - progress);
        final beginSide =
            isNext ? Alignment.centerLeft : Alignment.centerRight;
        final endSide = isNext ? Alignment.centerRight : Alignment.centerLeft;
        return Stack(
          children: [
            ShaderMask(
              shaderCallback: (rect) {
                final s0 = edge.clamp(0.0, 1.0);
                final s1 = (edge + soft).clamp(0.0, 1.0);
                return LinearGradient(
                  begin: beginSide,
                  end: endSide,
                  stops: [0.0, s0, s1, 1.0],
                  colors: const [
                    Color(0xFFFFFFFF),
                    Color(0xFFFFFFFF),
                    Color(0x00FFFFFF),
                    Color(0x00FFFFFF),
                  ],
                ).createShader(rect);
              },
              blendMode: BlendMode.modulate,
              child: currentPage,
            ),
            if (neighborWidget != null)
              ShaderMask(
                shaderCallback: (rect) {
                  final s0 = (edge - soft).clamp(0.0, 1.0);
                  final s1 = edge.clamp(0.0, 1.0);
                  return LinearGradient(
                    begin: beginSide,
                    end: endSide,
                    stops: [0.0, s0, s1, 1.0],
                    colors: const [
                      Color(0x00FFFFFF),
                      Color(0x00FFFFFF),
                      Color(0xFFFFFFFF),
                      Color(0xFFFFFFFF),
                    ],
                  ).createShader(rect);
                },
                blendMode: BlendMode.modulate,
                child: neighborWidget,
              ),
          ],
        );

      case PdfPageTurnMode.flip:
        // 翻书式：装订线固定在左侧，右页绕左边缘翻转
        final angle = absP * (math.pi / 2);
        if (p < 0) {
          return Stack(
            children: [
              if (neighborWidget != null) neighborWidget,
              Transform(
                alignment: Alignment.centerLeft,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.002)
                  ..rotateY(-angle),
                child: Opacity(
                  opacity: (1.0 - absP).clamp(0.0, 1.0),
                  child: currentPage,
                ),
              ),
            ],
          );
        } else {
          return Stack(
            children: [
              currentPage,
              if (neighborWidget != null)
                Transform(
                  alignment: Alignment.centerLeft,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.002)
                    ..rotateY(math.pi / 2 - angle),
                  child: Opacity(
                    opacity: absP.clamp(0.0, 1.0),
                    child: neighborWidget,
                  ),
                ),
            ],
          );
        }

      case PdfPageTurnMode.slide:
      case PdfPageTurnMode.none:
        return currentPage;
    }
  }

  // ─── 跟手翻页：手势处理 ───────────────────────────────────

  void _handleDragStart(DragStartDetails details) {
    _isDragging = true;
    if (_turnController.isAnimating) {
      _turnController.stop();
    }
    _dragDir = 0;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    final delta = details.primaryDelta ?? 0;
    var next = _dragExtent + delta;
    final w = _pageFullWidth;
    final current = _pageNumber ?? 1;
    if (_dragDir == 0 && next.abs() > 6) {
      _dragDir = next > 0 ? -1 : 1;
    }
    if (_dragDir == -1) {
      next = next.clamp(0.0, w);
    } else if (_dragDir == 1) {
      next = next.clamp(-w, 0.0);
    } else {
      next = next.clamp(-w, w);
    }
    // 边界橡皮筋
    final neighborPage = _dragDir < 0 ? current - 1 : current + 1;
    if (_dragDir != 0 && (neighborPage < 1 || neighborPage > _pageCount)) {
      next = next * 0.32;
    }
    setState(() {
      _dragExtent = next;
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    _isDragging = false;
    final velocity = details.primaryVelocity ?? 0;
    final w = _pageFullWidth;
    final current = _pageNumber ?? 1;

    final neighborPage = _dragDir < 0 ? current - 1 : current + 1;
    final hasNeighbor =
        _dragDir != 0 && neighborPage >= 1 && neighborPage <= _pageCount;
    if (!hasNeighbor || _dragDir == 0) {
      _startTurnAnim(0);
      return;
    }

    bool shouldTurn;
    if (_dragDir == -1) {
      shouldTurn = _dragExtent > w * 0.33 || velocity > 320;
    } else {
      shouldTurn = _dragExtent.abs() > w * 0.33 || velocity < -320;
    }
    final target = shouldTurn ? (_dragDir == -1 ? w : -w) : 0.0;
    _startTurnAnim(target);
  }

  void _startTurnAnim(double target) {
    _animFromExtent = _dragExtent;
    _animTargetExtent = target;
    _turnController.value = 0;
    _turnController.forward();
  }

  void _onTurnAnimTick() {
    final t = _turnController.value;
    setState(() {
      _dragExtent =
          _animFromExtent + (_animTargetExtent - _animFromExtent) * t;
    });
  }

  void _onTurnAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // ★ 关键修复：value=0 同步触发 _onTurnAnimTick，会把 _dragExtent 蹦回 _animFromExtent
    // 产生"动画反向跳回起点再被 setState 修正"的单帧闪屏。
    // 先移除 listener，再做状态变更和 value=0，最后恢复 listener。
    _turnController.removeListener(_onTurnAnimTick);
    try {
      if (_animTargetExtent.abs() > _pageFullWidth * 0.5) {
        final dir = _animTargetExtent > 0 ? -1 : 1;
        final current = _pageNumber ?? 1;
        final newPage = (current + dir).clamp(1, _pageCount);
        setState(() {
          _pageNumber = newPage;
          _dragExtent = 0;
          _dragDir = 0;
          _seekProgress = null;
        });
        _persistPosition();
      } else {
        setState(() {
          _dragExtent = 0;
          _dragDir = 0;
        });
      }
      _turnController.value = 0;
    } finally {
      _turnController.addListener(_onTurnAnimTick);
    }
  }

  /// 点击/按钮翻页（非 slide 模式带动画）
  void _animateTurnToPage(int dir) {
    if (_turnMode == PdfPageTurnMode.none) {
      final current = _pageNumber ?? 1;
      final newPage = (current + dir).clamp(1, _pageCount);
      setState(() {
        _pageNumber = newPage;
        _dragExtent = 0;
        _dragDir = 0;
      });
      _persistPosition();
      return;
    }
    if (_turnController.isAnimating) return;
    if (_isDragging) return;
    final current = _pageNumber ?? 1;
    final target = current + dir;
    if (target < 1 || target > _pageCount) return;
    _dragDir = dir;
    final w = _pageFullWidth;
    setState(() {
      _dragExtent = 0;
    });
    _animFromExtent = 0;
    _animTargetExtent = dir < 0 ? w : -w;
    _turnController.value = 0;
    _turnController.forward();
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
    final mode = _viewMode == PdfViewMode.page
        ? '  分页·${_pdfTurnModeNames[_turnMode]}'
        : '  滚动';
    final cropInfo = _cropMode != CropMode.off
        ? '  ·裁切${_cropMode == CropMode.perPage ? '(逐页)' : _cropMode == CropMode.unified ? '(统一)' : '(手动)'}'
        : '';
    final fitInfo = _viewMode == PdfViewMode.page
        ? '  ·${_fitMode == PdfFitMode.fitWidth ? '宽适配' : _fitMode == PdfFitMode.fitHeight ? '高适配' : '页适配'}'
        : '';
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
              '$current / $total  ($percent%)$mode$cropInfo$fitInfo  · 点击呼出菜单',
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
          // 翻页效果切换（仅分页模式显示）
          if (_viewMode == PdfViewMode.page)
            PopupMenuButton<PdfPageTurnMode>(
              icon: _floatIcon(Icons.auto_stories),
              tooltip: '翻页效果',
              onSelected: _changeTurnMode,
              color: Colors.black87,
              itemBuilder: (ctx) => PdfPageTurnMode.values.map((m) {
                return PopupMenuItem<PdfPageTurnMode>(
                  value: m,
                  child: Row(
                    children: [
                      Icon(
                        _turnMode == m
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Text(_pdfTurnModeNames[m]!,
                          style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                );
              }).toList(),
            ),
          if (_viewMode == PdfViewMode.page) const SizedBox(height: 8),
          // ── v0.8.0: 裁白边模式切换 ──
          PopupMenuButton<CropMode>(
            icon: _floatIcon(
              _cropMode == CropMode.off
                  ? Icons.crop_free
                  : _cropMode == CropMode.manual
                      ? Icons.crop
                      : Icons.crop_landscape,
            ),
            tooltip: '裁白边',
            onSelected: _changeCropMode,
            color: Colors.black87,
            itemBuilder: (ctx) {
              final cropNames = {
                CropMode.off: '关闭',
                CropMode.perPage: '逐页裁切',
                CropMode.unified: '统一裁切',
                CropMode.manual: '手动裁切',
              };
              return CropMode.values.map((m) {
                return PopupMenuItem<CropMode>(
                  value: m,
                  child: Row(
                    children: [
                      Icon(
                        _cropMode == m
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Text(cropNames[m]!,
                          style: const TextStyle(color: Colors.white)),
                      if (m == CropMode.perPage)
                        const Text('  (自动·每页独立)',
                            style: TextStyle(color: Colors.white38, fontSize: 11)),
                      if (m == CropMode.unified)
                        const Text('  (自动·所有页统一)',
                            style: TextStyle(color: Colors.white38, fontSize: 11)),
                      if (m == CropMode.manual)
                        const Text('  (自由画区域)',
                            style: TextStyle(color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                );
              }).toList();
            },
          ),
          const SizedBox(height: 8),
          // ── v0.8.0: 适配模式切换（仅分页模式）──
          if (_viewMode == PdfViewMode.page)
            PopupMenuButton<PdfFitMode>(
              icon: _floatIcon(
                _fitMode == PdfFitMode.fitWidth
                    ? Icons.fit_screen
                    : _fitMode == PdfFitMode.fitHeight
                        ? Icons.height_outlined
                        : Icons.fullscreen,
              ),
              tooltip: '适配模式',
              onSelected: _changeFitMode,
              color: Colors.black87,
              itemBuilder: (ctx) {
                const fitNames = {
                  PdfFitMode.fitWidth: '宽度适配',
                  PdfFitMode.fitHeight: '高度适配',
                  PdfFitMode.fitPage: '整页适配',
                };
                return PdfFitMode.values.map((m) {
                  return PopupMenuItem<PdfFitMode>(
                    value: m,
                    child: Row(
                      children: [
                        Icon(
                          _fitMode == m
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 18,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 8),
                        Text(fitNames[m]!,
                            style: const TextStyle(color: Colors.white)),
                      ],
                    ),
                  );
                }).toList();
              },
            ),
          if (_viewMode == PdfViewMode.page) const SizedBox(height: 8),
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
          // ── v0.8.3: 清空本页高亮（仅有高亮时显示）──
          if (_hasHighlightsOnCurrentPage) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                _clearAllHighlightsOnPage();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已清空本页高亮'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
              child: Tooltip(
                message: '清空本页高亮',
                child: _floatIcon(Icons.delete_sweep_outlined),
              ),
            ),
          ],
          // ── v0.9.0: AI 重排按钮（仅当 AI 插件已启用时显示）──
          if (_isAiPluginEnabled) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _aiReflowCurrentPage,
              child: Tooltip(
                message: 'AI 重排当前页',
                child: _floatIcon(_aiReflowing
                    ? Icons.hourglass_top
                    : Icons.auto_awesome_outlined),
              ),
            ),
          ],
          // ── v0.8.0: 裁切计算进度指示器 ──
          if (_cropComputing)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: _cropProgress,
                      strokeWidth: 2.5,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                    Text(
                      '${(_cropProgress * 100).round()}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ],
                ),
              ),
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

/// PDF 高亮矩形画师
class _PdfHighlightPainter extends CustomPainter {
  final List<PdfRectHighlight> existing;
  final Size pageSize;
  final Offset? markStart;
  final Offset? markCurrent;
  final String? selectedId;

  const _PdfHighlightPainter({
    required this.existing,
    required this.pageSize,
    required this.markStart,
    required this.markCurrent,
    required this.selectedId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (pageSize.isEmpty) return;
    // 已有高亮
    for (final h in existing) {
      final rect = Rect.fromLTWH(
        h.relX * pageSize.width,
        h.relY * pageSize.height,
        h.relW * pageSize.width,
        h.relH * pageSize.height,
      );
      final color = _pdfHighlightColors[
          h.colorIndex.clamp(0, _pdfHighlightColors.length - 1)];
      final paint = Paint()
        ..color = color.withOpacity(0.35)
        ..style = PaintingStyle.fill;
      canvas.drawRect(rect, paint);
      // 选中边框
      if (selectedId == h.id) {
        final border = Paint()
          ..color = color.withOpacity(1.0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;
        canvas.drawRect(rect, border);
      }
    }
    // 正在拖动的矩形
    final s = markStart;
    final c = markCurrent;
    if (s != null && c != null) {
      final rect = Rect.fromPoints(s, c);
      final paint = Paint()
        ..color = _pdfHighlightColors[0].withOpacity(0.35)
        ..style = PaintingStyle.fill;
      canvas.drawRect(rect, paint);
      final border = Paint()
        ..color = _pdfHighlightColors[0].withOpacity(1.0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawRect(rect, border);
    }
  }

  @override
  bool shouldRepaint(covariant _PdfHighlightPainter oldDelegate) {
    // 改为值比较：之前用引用比较，原地 add/remove 后引用不变导致不重绘
    if (oldDelegate.existing.length != existing.length) return true;
    if (oldDelegate.markStart != markStart) return true;
    if (oldDelegate.markCurrent != markCurrent) return true;
    if (oldDelegate.selectedId != selectedId) return true;
    // 内容比较（长度相同但 id/颜色变化时也要重绘）
    for (var i = 0; i < existing.length; i++) {
      final a = oldDelegate.existing[i];
      final b = existing[i];
      if (a.id != b.id || a.colorIndex != b.colorIndex) return true;
    }
    return false;
  }
}

/// 高亮工具栏（颜色选择 + 取消）
class _PdfHighlightToolbar extends StatelessWidget {
  final Offset anchor;
  final void Function(int colorIndex) onColorSelected;
  final void Function() onCancel;

  const _PdfHighlightToolbar({
    required this.anchor,
    required this.onColorSelected,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final mediaSize = MediaQuery.of(context).size;
    final width = mediaSize.width;
    // 工具栏放在底部偏上一点
    final top = (anchor.dy).clamp(120.0, mediaSize.height - 160);
    return Material(
      color: Colors.transparent,
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: top,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF2C2C2C).withOpacity(0.96),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 16,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '选择高亮颜色',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (var i = 0; i < _pdfHighlightColors.length; i++)
                          GestureDetector(
                            onTap: () => onColorSelected(i),
                            child: Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: _pdfHighlightColors[i],
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: Colors.white54, width: 1.5),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: onCancel,
                      child: const Text(
                        '取消',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 手动裁切区域画师 — 遮罩 + 裁切矩形
class _ManualCropPainter extends CustomPainter {
  final Offset? cropStart;
  final Offset? cropCurrent;
  final Rect? confirmedRect;
  final Offset innerOffset;

  const _ManualCropPainter({
    required this.cropStart,
    required this.cropCurrent,
    required this.confirmedRect,
    required this.innerOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 半透明遮罩覆盖整个视图
    final overlayPaint = Paint()..color = Colors.black.withOpacity(0.5);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), overlayPaint);

    // 确定裁切矩形
    Rect? cropRect;
    if (confirmedRect != null) {
      // 已确认的裁切矩形（相对坐标 → 屏幕坐标）
      cropRect = Rect.fromLTWH(
        confirmedRect!.left * size.width + innerOffset.dx,
        confirmedRect!.top * size.height + innerOffset.dy,
        confirmedRect!.width * size.width,
        confirmedRect!.height * size.height,
      );
    } else if (cropStart != null && cropCurrent != null) {
      // 正在拖动的矩形
      final s = cropStart! + innerOffset;
      final c = cropCurrent! + innerOffset;
      cropRect = Rect.fromPoints(s, c);
    }

    if (cropRect == null) return;

    // 清除裁切矩形区域的遮罩（镂空效果）
    canvas.save();
    final clearPaint = Paint()..blendMode = BlendMode.clear;
    canvas.drawRect(cropRect!, clearPaint);
    canvas.restore();

    // 绘制裁切矩形边框
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(cropRect!, borderPaint);

    // 绘制四角拖拽手柄
    final handleSize = 12.0;
    final handlePaint = Paint()..color = Colors.white;
    final corners = [
      cropRect!.topLeft,
      cropRect!.topRight,
      cropRect!.bottomLeft,
      cropRect!.bottomRight,
    ];
    for (final corner in corners) {
      canvas.drawRect(
        Rect.fromCenter(center: corner, width: handleSize, height: handleSize),
        handlePaint,
      );
    }

    // 绘制尺寸标注
    if (cropRect!.width > 60 && cropRect!.height > 30) {
      final textStyle = TextStyle(
        color: Colors.white,
        fontSize: 11,
        backgroundColor: Colors.black54,
      );
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${cropRect!.width.round()}x${cropRect!.height.round()}',
          style: textStyle,
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          cropRect!.center.dx - textPainter.width / 2,
          cropRect!.top - textPainter.height - 6,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ManualCropPainter oldDelegate) {
    return oldDelegate.cropStart != cropStart ||
        oldDelegate.cropCurrent != cropCurrent ||
        oldDelegate.confirmedRect != confirmedRect;
  }
}

/// 自定义水平拖拽手势识别器 — 提高初始阈值到 32px，
/// 给长按高亮留出静止识别窗口，避免长按被拖拽抢走竞技场。
/// 复用 ReaderPage 的方案（v0.5.4 修复手势竞争）。
class _LargerSlopHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _LargerSlopHorizontalDragGestureRecognizer({super.supportedDevices}) {
    gestureSettings = const DeviceGestureSettings(touchSlop: 32.0);
  }
}
