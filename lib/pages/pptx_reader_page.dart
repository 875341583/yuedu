/// PPTX 阅读页面
///
/// PPTX 文件按幻灯片原始顺序逐页展示，每页提取所有 <a:t> 文本。
/// 不再强制横屏：默认跟随系统方向，顶部栏可切换 自动/横屏/竖屏。
/// 嵌入 5 种翻页模式（与 ReaderPage 一致：滑动/覆盖/淡入/翻转/无动画），
/// 滑动模式用 PageView 跟手，其余模式用 AnimatedSwitcher + 手势触发。
/// 与排版阅读页、PDF 阅读页并列：PPTX 书走本页。
library;

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

  /// 非滑动模式下的 AnimatedSwitcher key（变化时触发动画）
  int _switchKey = 0;

  /// 翻页动画控制器（非 slide 模式）
  late final AnimationController _animController;

  @override
  void initState() {
    super.initState();
    // 默认跟随系统方向（不强制横屏）
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
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
        _switchKey = target0;
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
      _playTurnAnim();
      setState(() {
        _currentPage = page;
        _switchKey = page - 1;
      });
      _persistPage();
    }
  }

  void _nextPage() {
    final total = _slides?.pageCount ?? 0;
    if (_currentPage < total) _goToPage(_currentPage + 1);
  }

  void _prevPage() {
    if (_currentPage > 1) _goToPage(_currentPage - 1);
  }

  void _playTurnAnim() {
    _animController.forward(from: 0.0);
  }

  /// 切换翻页模式
  Future<void> _changeTurnMode(PptxPageTurnMode mode) async {
    if (mode == _turnMode) return;
    setState(() {
      _turnMode = mode;
      _showMenu = false;
    });
    await _saveTurnMode(mode);
    // 切换到非 slide 模式时，需要用 _switchKey 对齐当前页
    if (mode != PptxPageTurnMode.slide) {
      setState(() {
        _switchKey = _currentPage - 1;
      });
    } else {
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
    // 非滑动模式：AnimatedSwitcher + 手势左右滑动触发翻页
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _toggleMenu,
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v < -300) {
          _nextPage();
        } else if (v > 300) {
          _prevPage();
        }
      },
      child: AnimatedSwitcher(
        duration: _turnDuration,
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) =>
            _buildTransition(child, anim, _turnMode),
        child: _buildSlide(
          slides.pages[_currentPage - 1],
          key: ValueKey(_switchKey),
        ),
      ),
    );
  }

  Duration get _turnDuration {
    switch (_turnMode) {
      case PptxPageTurnMode.none:
        return const Duration(milliseconds: 1);
      case PptxPageTurnMode.fade:
        return const Duration(milliseconds: 300);
      case PptxPageTurnMode.flip:
        return const Duration(milliseconds: 450);
      case PptxPageTurnMode.cover:
        return const Duration(milliseconds: 350);
      case PptxPageTurnMode.slide:
        return const Duration(milliseconds: 300);
    }
  }

  Widget _buildTransition(
      Widget child, Animation<double> anim, PptxPageTurnMode mode) {
    switch (mode) {
      case PptxPageTurnMode.fade:
        return FadeTransition(opacity: anim, child: child);
      case PptxPageTurnMode.cover:
        // 新页从右侧覆盖
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        );
      case PptxPageTurnMode.flip:
        // 3D Y轴翻转
        return ScaleTransition(
          scale: Tween(begin: 0.8, end: 1.0).animate(anim),
          child: RotationTransition(
            turns: Tween(begin: 0.5, end: 0.0).animate(anim),
            alignment: Alignment.center,
            child: child,
          ),
        );
      case PptxPageTurnMode.slide:
      case PptxPageTurnMode.none:
        return child;
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
