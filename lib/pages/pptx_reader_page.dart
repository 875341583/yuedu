/// PPTX 阅读页面
///
/// PPTX 文件按幻灯片原始顺序逐页展示，每页提取所有 <a:t> 文本。
/// 不再强制横屏：默认跟随系统方向，顶部栏可切换 自动/横屏/竖屏。
/// 嵌入 5 种翻页模式（与 ReaderPage 一致：滑动/覆盖/淡入/翻转/无动画）。
/// slide 模式用 PageView 跟手，cover/fade/flip 模式用自实现跟手 Stack+Transform，
/// 点击与滑动翻页均带动画。与排版阅读页、PDF 阅读页并列：PPTX 书走本页。
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../services/bookshelf_service.dart';
import '../services/file_service.dart';
import '../utils/pptx_text_extractor.dart' deferred as pptx;

// ─── 翻页模式（与 reader_page.dart 保持一致命名）──────────────

enum PptxPageTurnMode {
  slide, // 滑动翻页（PageView 跟手）
  cover, // 覆盖翻页
  fade,  // 淡入淡出
  flip,  // 3D翻转
  none,  // 无动画
}

const _pptxTurnModeNames = <PptxPageTurnMode, String>{
  PptxPageTurnMode.slide: '滑动',
  PptxPageTurnMode.cover: '覆盖',
  PptxPageTurnMode.fade: '淡入',
  PptxPageTurnMode.flip: '翻转',
  PptxPageTurnMode.none: '无动画',
};

// ─── 屏幕方向模式 ────────────────────────────────────────────

enum PptxOrientationMode {
  auto,      // 跟随系统
  landscape, // 强制横屏
  portrait,  // 强制竖屏
}

const _pptxOrientNames = <PptxOrientationMode, String>{
  PptxOrientationMode.auto: '自动',
  PptxOrientationMode.landscape: '横屏',
  PptxOrientationMode.portrait: '竖屏',
};

const _kPptxPagePrefix = 'yuedu_pptx_page_';
const _kPptxTurnModeKey = 'yuedu_pptx_turn_mode';
const _kPptxOrientKey = 'yuedu_pptx_orient_mode';

class PptxReaderPage extends StatefulWidget {
  final Book book;

  const PptxReaderPage({super.key, required this.book});

  @override
  State<PptxReaderPage> createState() => _PptxReaderPageState();
}

class _PptxReaderPageState extends State<PptxReaderPage>
    with SingleTickerProviderStateMixin {
  /// PptxSlides 实例（deferred 加载，类型运行时确定）
  dynamic _slides;
  String? _error;
  bool _loading = true;

  /// 是否显示菜单
  bool _showMenu = false;

  /// 当前页码（1-based）
  int _currentPage = 1;

  /// 翻页模式
  PptxPageTurnMode _turnMode = PptxPageTurnMode.slide;

  /// 方向模式
  PptxOrientationMode _orientMode = PptxOrientationMode.auto;

  PageController? _controller;

  /// 拖拽滑块的临时进度
  double? _seekProgress;

  // ─── 跟手翻页状态（非 slide 模式）─────────────────────────
  /// 当前拖拽的水平偏移（px）。正值=向右拖（看上一页），负值=向左拖（看下一页）。
  double _dragExtent = 0;
  bool _isDragging = false;
  double _animFromExtent = 0;
  double _animTargetExtent = 0;
  double _pageFullWidth = 0;
  int _dragDir = 0; // -1=上一页, 1=下一页, 0=无

  /// 翻页动画控制器（非 slide 模式的跟手收尾动画）
  late final AnimationController _animController;

  @override
  void initState() {
    super.initState();
    // 默认跟随系统方向（不强制横屏）
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _animController.addListener(_onTurnAnimTick);
    _animController.addStatusListener(_onTurnAnimStatus);
    _initAsync();
  }

  Future<void> _initAsync() async {
    try {
      _turnMode = await _loadTurnMode();
      _orientMode = await _loadOrientMode();
      _applyOrientation(_orientMode);
      final exists = await FileService.fileExists(widget.book.filePath);
      if (!exists) {
        throw Exception('文件不存在');
      }
      final bytes = await FileService.readFileBytes(widget.book.filePath);
      await pptx.loadLibrary();
      final slides = pptx.PptxTextExtractor.extract(bytes);
      final savedPage = await _loadSavedPage();
      if (!mounted) return;
      final total = slides.pageCount;
      final target0 =
          (savedPage - 1).clamp(0, total > 0 ? total - 1 : 0).toInt();
      setState(() {
        _slides = slides;
        _controller = PageController(initialPage: target0);
        _currentPage = target0 + 1;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // ─── 持久化 ────────────────────────────────────────────────

  Future<int> _loadSavedPage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final page = prefs.getInt('$_kPptxPagePrefix${widget.book.id}') ?? 1;
      return page < 1 ? 1 : page;
    } catch (_) {
      return 1;
    }
  }

  Future<PptxPageTurnMode> _loadTurnMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt(_kPptxTurnModeKey) ?? 0;
      return PptxPageTurnMode.values[
          idx.clamp(0, PptxPageTurnMode.values.length - 1)];
    } catch (_) {
      return PptxPageTurnMode.slide;
    }
  }

  Future<void> _saveTurnMode(PptxPageTurnMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPptxTurnModeKey, mode.index);
    } catch (_) {}
  }

  Future<PptxOrientationMode> _loadOrientMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt(_kPptxOrientKey) ?? 0;
      return PptxOrientationMode.values[
          idx.clamp(0, PptxOrientationMode.values.length - 1)];
    } catch (_) {
      return PptxOrientationMode.auto;
    }
  }

  Future<void> _saveOrientMode(PptxOrientationMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPptxOrientKey, mode.index);
    } catch (_) {}
  }

  void _applyOrientation(PptxOrientationMode mode) {
    switch (mode) {
      case PptxOrientationMode.auto:
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        break;
      case PptxOrientationMode.landscape:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        break;
      case PptxOrientationMode.portrait:
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        break;
    }
  }

  Future<void> _persistPage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$_kPptxPagePrefix${widget.book.id}', _currentPage);
      final total = _slides?.pageCount ?? 0;
      if (total > 0) {
        try {
          BookshelfService.instance
              .updateReadPosition(widget.book.id, _currentPage);
        } catch (_) {}
      }
    } catch (_) {}
  }

  void _toggleMenu() {
    setState(() => _showMenu = !_showMenu);
    if (_showMenu) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _goToPage(int page) {
    final total = _slides?.pageCount ?? 0;
    if (page < 1 || page > total) return;
    if (_turnMode == PptxPageTurnMode.slide) {
      _controller?.animateToPage(
        page - 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      // 非 slide 模式：直接切（滑块跳页不走动画）
      setState(() {
        _currentPage = page;
        _dragExtent = 0;
        _dragDir = 0;
      });
      _persistPage();
    }
  }

  void _nextPage() {
    final total = _slides?.pageCount ?? 0;
    if (_currentPage < total) {
      if (_turnMode == PptxPageTurnMode.slide) {
        _goToPage(_currentPage + 1);
      } else {
        _animateTurnToPage(1);
      }
    }
  }

  void _prevPage() {
    if (_currentPage > 1) {
      if (_turnMode == PptxPageTurnMode.slide) {
        _goToPage(_currentPage - 1);
      } else {
        _animateTurnToPage(-1);
      }
    }
  }

  /// 点击翻页：从静止状态启动一次完整翻页动画
  void _animateTurnToPage(int dir) {
    if (_turnMode == PptxPageTurnMode.none) {
      setState(() {
        _currentPage += dir;
        _dragExtent = 0;
        _dragDir = 0;
      });
      _persistPage();
      return;
    }
    if (_animController.isAnimating) return;
    if (_isDragging) return;
    final total = _slides?.pageCount ?? 0;
    final target = _currentPage + dir;
    if (target < 1 || target > total) return;
    _dragDir = dir;
    final w = _pageFullWidth;
    setState(() {
      _dragExtent = 0;
    });
    _animFromExtent = 0;
    _animTargetExtent = dir < 0 ? w : -w;
    _animController.value = 0;
    _animController.forward();
  }

  /// 切换翻页模式
  Future<void> _changeTurnMode(PptxPageTurnMode mode) async {
    if (mode == _turnMode) return;
    setState(() {
      _turnMode = mode;
      _showMenu = false;
      _dragExtent = 0;
      _dragDir = 0;
    });
    await _saveTurnMode(mode);
    if (mode == PptxPageTurnMode.slide) {
      // 切回 slide：跳到当前页
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!mounted) return;
        _controller?.jumpToPage(_currentPage - 1);
      });
    }
  }

  /// 切换方向模式
  Future<void> _changeOrientMode(PptxOrientationMode mode) async {
    if (mode == _orientMode) return;
    setState(() => _orientMode = mode);
    _applyOrientation(mode);
    await _saveOrientMode(mode);
  }

  @override
  void dispose() {
    _persistPage();
    _controller?.dispose();
    _animController.dispose();
    // 恢复方向（允许所有方向）
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildError(_error!),
      );
    }
    final slides = _slides!;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildContent(slides)),
          if (_showMenu) _buildTopBar(),
          if (_showMenu) _buildBottomBar(),
          if (!_showMenu) _buildPageHint(),
          if (!_showMenu) _buildNavArrows(),
        ],
      ),
    );
  }

  Widget _buildContent(dynamic slides) {
    if (_turnMode == PptxPageTurnMode.slide) {
      // 滑动模式：PageView 跟手
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleMenu,
        child: PageView.builder(
          controller: _controller,
          itemCount: slides.pageCount,
          onPageChanged: (index) {
            setState(() {
              _currentPage = index + 1;
              _seekProgress = null;
            });
            _persistPage();
          },
          itemBuilder: (context, index) {
            return _buildSlide(slides.pages[index]);
          },
        ),
      );
    }
    // 非 slide 模式：跟手 Stack + Transform
    return LayoutBuilder(
      builder: (context, constraints) {
        _pageFullWidth = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: _handleTapUp,
          onHorizontalDragStart: _handleDragStart,
          onHorizontalDragUpdate: _handleDragUpdate,
          onHorizontalDragEnd: _handleDragEnd,
          child: _buildPageTurnView(slides),
        );
      },
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

  // ─── 跟手翻页渲染 ────────────────────────────────────────

  Widget _buildPageTurnView(dynamic slides) {
    final currentPage =
        _buildSlide(slides.pages[_currentPage - 1], key: ValueKey('pptx_page_$_currentPage'));

    // 静态状态：用 Stack 包装保持 widget 树结构稳定。
    // 避免"动画末帧返回多子 Stack → 静态返回裸 Slide"的 runtimeType 突变，
    // 触发 Slide 子树重建（含 SingleChildScrollView+Text 列表），造成一帧闪屏。
    if ((_dragExtent == 0 && !_animController.isAnimating) ||
        _turnMode == PptxPageTurnMode.none) {
      return Stack(children: [currentPage]);
    }

    final w = _pageFullWidth;
    final p = (_dragExtent / w).clamp(-1.0, 1.0);
    final absP = p.abs();

    // 相邻页索引：dir=-1(上一页)→当前-2，dir=1(下一页)→当前
    Widget? neighborWidget;
    if (_dragDir != 0) {
      final neighborIndex = _dragDir < 0 ? _currentPage - 2 : _currentPage;
      if (neighborIndex >= 0 && neighborIndex < slides.pageCount) {
        neighborWidget = _buildSlide(slides.pages[neighborIndex],
            key: ValueKey('pptx_page_${neighborIndex + 1}'));
      }
    }

    final neighborBase = p > 0 ? -w : w;

    switch (_turnMode) {
      case PptxPageTurnMode.cover:
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

      case PptxPageTurnMode.fade:
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

      case PptxPageTurnMode.flip:
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

      case PptxPageTurnMode.slide:
      case PptxPageTurnMode.none:
        return currentPage;
    }
  }

  // ─── 跟手翻页：手势处理 ───────────────────────────────────

  void _handleDragStart(DragStartDetails details) {
    _isDragging = true;
    if (_animController.isAnimating) {
      _animController.stop();
    }
    _dragDir = 0;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    final delta = details.primaryDelta ?? 0;
    var next = _dragExtent + delta;
    final w = _pageFullWidth;
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
    setState(() {
      _dragExtent = next;
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    _isDragging = false;
    final velocity = details.primaryVelocity ?? 0;
    final w = _pageFullWidth;
    final total = _slides?.pageCount ?? 0;

    // 边界检查
    final neighborIndex = _dragDir < 0 ? _currentPage - 2 : _currentPage;
    final hasNeighbor =
        _dragDir != 0 && neighborIndex >= 0 && neighborIndex < total;
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
    _animController.value = 0;
    _animController.forward();
  }

  void _onTurnAnimTick() {
    final t = _animController.value;
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
    _animController.removeListener(_onTurnAnimTick);
    try {
      if (_animTargetExtent.abs() > _pageFullWidth * 0.5) {
        // 完成翻页
        final dir = _animTargetExtent > 0 ? -1 : 1;
        final newPage = _currentPage + dir;
        final total = _slides?.pageCount ?? 0;
        setState(() {
          _currentPage = (newPage.clamp(1, total)).toInt();
          _dragExtent = 0;
          _dragDir = 0;
        });
        _persistPage();
      } else {
        setState(() {
          _dragExtent = 0;
          _dragDir = 0;
        });
      }
      _animController.value = 0;
    } finally {
      _animController.addListener(_onTurnAnimTick);
    }
  }

  /// 渲染单张幻灯片（白纸式排版，文本居中自适应）
  Widget _buildSlide(String text, {Key? key}) {
    return Container(
      key: key,
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
              color: Colors.black54, blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: _buildSlideLines(text),
        ),
      ),
    );
  }

  List<Widget> _buildSlideLines(String text) {
    final lines = text.split('\n').where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Text(
            '（本页无文本内容）',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 16),
          ),
        ),
      ];
    }
    final widgets = <Widget>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // 第一行作为标题，加粗大字
      final isTitle = i == 0 && line.length <= 60;
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            line,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isTitle ? 24 : 18,
              fontWeight: isTitle ? FontWeight.bold : FontWeight.normal,
              color: Colors.black87,
              height: 1.5,
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  // ─── 左右翻页箭头（非菜单状态下常驻小按钮）─────────────────
  Widget _buildNavArrows() {
    final total = _slides?.pageCount ?? 0;
    return Positioned(
      bottom: 60,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_currentPage > 1)
            _navArrow(Icons.chevron_left, _prevPage, alignment: Alignment.centerLeft),
          if (_currentPage < total)
            _navArrow(Icons.chevron_right, _nextPage, alignment: Alignment.centerRight),
        ],
      ),
    );
  }

  Widget _navArrow(
    IconData icon,
    VoidCallback onTap, {
    required Alignment alignment,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black38,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white70, size: 28),
          ),
        ),
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
                        fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // ── 翻页模式切换 ──
                PopupMenuButton<PptxPageTurnMode>(
                  icon: const Icon(Icons.auto_stories, color: Colors.white),
                  tooltip: '翻页模式',
                  onSelected: _changeTurnMode,
                  itemBuilder: (ctx) => PptxPageTurnMode.values.map((m) {
                    return PopupMenuItem<PptxPageTurnMode>(
                      value: m,
                      child: Row(
                        children: [
                          Icon(
                            _turnMode == m
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(_pptxTurnModeNames[m]!),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                // ── 方向切换 ──
                PopupMenuButton<PptxOrientationMode>(
                  icon: const Icon(Icons.screen_rotation, color: Colors.white),
                  tooltip: '屏幕方向',
                  onSelected: _changeOrientMode,
                  itemBuilder: (ctx) => PptxOrientationMode.values.map((m) {
                    return PopupMenuItem<PptxOrientationMode>(
                      value: m,
                      child: Row(
                        children: [
                          Icon(
                            _orientMode == m
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(_pptxOrientNames[m]!),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                IconButton(
                  icon: const Icon(Icons.first_page, color: Colors.white),
                  tooltip: '第一页',
                  onPressed: () => _goToPage(1),
                ),
                IconButton(
                  icon: const Icon(Icons.last_page, color: Colors.white),
                  tooltip: '最后一页',
                  onPressed: _slides != null
                      ? () => _goToPage(_slides!.pageCount)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── 底部栏 ────────────────────────────────────────────────
  Widget _buildBottomBar() {
    final total = _slides?.pageCount ?? 1;
    final current = _currentPage;
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
                    onChanged: total > 1
                        ? (v) {
                            setState(() => _seekProgress = v);
                          }
                        : null,
                    onChangeEnd: total > 1
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

  // ─── 页码浮标 ──────────────────────────────────────────────
  Widget _buildPageHint() {
    final total = _slides?.pageCount ?? 0;
    final percent =
        total > 0 ? (_currentPage / total * 100).toStringAsFixed(1) : '0.0';
    final mode = _pptxTurnModeNames[_turnMode]!;
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
            '$_currentPage / $total  ($percent%)  $mode',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _buildError(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 56),
            const SizedBox(height: 16),
            const Text(
              'PPTX 打开失败',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              error,
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
