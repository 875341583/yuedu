/// 阅读页面：使用排版引擎渲染书籍内容
/// 支持大文件按需加载——不再一次性读取全文，而是按字节窗口读取
/// 支持翻页动画、阅读主题、可调边距、进度拖拽跳转、鼠标滚轮翻页
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';

import '../models/book.dart';
import '../models/bookmark.dart';
import '../models/highlight.dart';
import '../services/bookshelf_service.dart';
import '../services/bookmark_service.dart';
import '../services/highlight_service.dart';
import '../typeset/types.dart';
import '../typeset/typeset_engine_provider.dart';
import '../utils/chapter_parser.dart';
import '../widgets/typeset_renderer.dart';
import '../widgets/toc_bookmark_panel.dart';
import '../plugins/plugin_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── 翻页模式 ───────────────────────────────────────────────

enum PageTurnMode {
  slide, // 滑动翻页（推式）
  cover, // 覆盖翻页
  fade,  // 淡入淡出
  flip,  // 3D翻转
  none,  // 无动画
}

const _pageTurnModeNames = <PageTurnMode, String>{
  PageTurnMode.slide: '滑动',
  PageTurnMode.cover: '覆盖',
  PageTurnMode.fade: '淡入',
  PageTurnMode.flip: '翻转',
  PageTurnMode.none: '无动画',
};

// ─── 阅读主题定义 ───────────────────────────────────────────

class _ReadingTheme {
  final String name;
  final Color bg;
  final Color text;
  final Color surface;
  final Color panel;
  final Color border;
  final Color hint;
  final bool isDark;

  const _ReadingTheme({
    required this.name,
    required this.bg,
    required this.text,
    required this.surface,
    required this.panel,
    required this.border,
    required this.hint,
    required this.isDark,
  });
}

const _themes = <_ReadingTheme>[
  _ReadingTheme(
    name: '白色',
    bg: Color(0xFFFFFFFF),
    text: Color(0xFF1A1A1A),
    surface: Color(0xFFF8F8F8),
    panel: Color(0xFFFAFAFA),
    border: Color(0xFFE0E0E0),
    hint: Color(0xFF999999),
    isDark: false,
  ),
  _ReadingTheme(
    name: '护眼',
    bg: Color(0xFFF5F0E8),
    text: Color(0xFF5B4636),
    surface: Color(0xFFEDE6D6),
    panel: Color(0xFFF2EBD9),
    border: Color(0xFFD5C9AF),
    hint: Color(0xFF9A8B70),
    isDark: false,
  ),
  _ReadingTheme(
    name: '深色',
    bg: Color(0xFF1A1A2E),
    text: Color(0xFFD0D0E0),
    surface: Color(0xFF252540),
    panel: Color(0xFF2A2A45),
    border: Color(0xFF3A3A55),
    hint: Color(0xFF888899),
    isDark: true,
  ),
  _ReadingTheme(
    name: '浅绿',
    bg: Color(0xFFC7EDCC),
    text: Color(0xFF2D4A2D),
    surface: Color(0xFFB5E5BA),
    panel: Color(0xFFBDE5C2),
    border: Color(0xFF9AD0A0),
    hint: Color(0xFF6A8C6E),
    isDark: false,
  ),
];

// ─── 页面数据 ───────────────────────────────────────────────

/// 一页的排版数据
class _PageData {
  /// 本页文本在文本窗口中的起始偏移
  final int startOffset;

  /// 本页文本在文本窗口中的结束偏移（不含）
  final int endOffset;

  /// 排版结果
  final TypesetResult result;

  const _PageData({
    required this.startOffset,
    required this.endOffset,
    required this.result,
  });
}

// ─── 阅读页面 ───────────────────────────────────────────────

class ReaderPage extends StatefulWidget {
  final Book book;

  const ReaderPage({super.key, required this.book});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with TickerProviderStateMixin {
  /// 文本窗口：当前加载的文本块（约32KB字符）
  String _textWindow = '';

  // ignore: unused_field
  /// 文本窗口在全文中的起始字符偏移
  int _windowStartChar = 0;

  /// 全文总字符数（小文件=文本长度，大文件=估算值）
  int _totalChars = 0;

  /// 当前页起始字符偏移（相对于全文）
  int _offset = 0;

  /// 是否正在加载内容
  bool _isLoading = true;

  /// 是否正在翻页加载（异步加载新窗口时）
  bool _isPaging = false;

  /// 加载错误信息（null表示无错误）
  String? _loadError;

  /// 当前页的排版数据
  _PageData? _currentPage;

  /// 下一页的起始偏移（相对于全文）
  int _nextPageOffset = -1;

  /// 排版配置
  TypesetConfig _config = const TypesetConfig(
    fontSize: 18.0,
    lineHeightRatio: 1.8,
    containerWidth: 360.0,
  );

  /// SharedPreferences键名
  static const _kFontSizeKey = 'yuedu_font_size';
  static const _kLineHeightKey = 'yuedu_line_height';
  static const _kDarkModeKey = 'yuedu_dark_mode';
  static const _kReadingThemeKey = 'yuedu_reading_theme';
  static const _kMarginHKey = 'yuedu_margin_h';
  static const _kPageModeKey = 'yuedu_page_mode';

  /// 阅读主题索引（0=白色 1=护眼 2=深色 3=浅绿）
  int _readingTheme = 0;

  /// 水平边距（左右各多少像素）
  double _marginH = 24.0;

  /// 是否显示菜单栏
  bool _showMenu = false;

  /// 是否显示设置面板
  bool _showSettings = false;

  /// 焦点节点（用于接收键盘事件）
  final FocusNode _focusNode = FocusNode();

  /// 翻页方向（1=前进，-1=后退）
  int _pageDirection = 1;

  // ─── 跟手翻页状态 ───────────────────────────────────────
  /// 当前拖拽的水平偏移（px）。正值=向右拖（露出上一页），
  /// 负值=向左拖（露出下一页）。0 表示静止。
  double _dragExtent = 0;

  /// 是否正在拖拽
  bool _isDragging = false;

  /// 松手后的完成/回弹动画控制器（值域 0..1，配合 _animFromExtent）
  late final AnimationController _turnController;

  /// 动画起始偏移（拖拽松手时的 _dragExtent 快照）
  double _animFromExtent = 0;

  /// 动画目标偏移（±屏宽=翻页，0=回弹）
  double _animTargetExtent = 0;

  /// 当前屏宽（含边距，用于跟手动画范围）
  double _pageFullWidth = 0;

  /// 上次 build 的可用高度（手势回调里预计算相邻页用）
  double _lastAvailableHeight = 0;

  /// 拖拽中预计算的相邻页排版数据（按方向只算需要的那一侧）
  _PageData? _dragNeighborPage;

  /// 拖拽方向对应的相邻页偏移（-1=上一页，1=下一页，0=无）
  int _dragDir = 0;

  /// 翻页模式
  PageTurnMode _pageMode = PageTurnMode.slide;

  /// 拖拽进度时临时值（null=未在拖拽）
  double? _seekProgress;

  /// 书签列表
  List<Bookmark> _bookmarks = [];

  /// 高亮列表（当前书）
  List<Highlight> _highlights = [];

  // ─── 文本选区（长按拖动选取）状态 ───────────────────────
  /// 是否在选区模式（长按后置 true，松手或取消后置 false）
  bool _isSelecting = false;
  /// 选区起止 glyph 索引（在当前页 result.glyphs 中）
  int _selStartGlyph = -1;
  int _selEndGlyph = -1;
  /// 选区起止屏幕坐标（用于工具栏定位）
  Offset _selAnchorOffset = Offset.zero;

  /// 是否正在解析章节
  bool _isParsingChapters = false;

  // ignore: unused_field
  /// 当前引擎类型
  final String _engineName = TypesetEngineProvider.engineName;

  /// 是否为大文件模式
  bool _isLargeFile = false;

  /// 大文件总字节数
  int _totalBytes = 0;

  /// 大文件当前字节偏移
  int _byteOffset = 0;

  /// 大文件文本窗口大小（字节）
  static const _windowBytes = 64 * 1024; // 64KB

  /// 鼠标滚轮防抖
  DateTime? _lastScrollTime;

  _ReadingTheme get _theme => _themes[_readingTheme];

  @override
  void initState() {
    super.initState();
    _turnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _turnController.addListener(_onTurnAnimTick);
    _turnController.addStatusListener(_onTurnAnimStatus);
    _loadSettings();
    _loadContent();
    _loadBookmarks();
    _loadHighlights();
    _ensureChapters();
  }

  /// 加载书签
  Future<void> _loadBookmarks() async {
    await BookmarkService.instance.loadFromStorage();
    if (mounted) {
      setState(() {
        _bookmarks = BookmarkService.instance.getBookmarksForBook(widget.book.id);
      });
    }
  }

  /// 加载高亮
  Future<void> _loadHighlights() async {
    await HighlightService.instance.loadFromStorage();
    if (mounted) {
      setState(() {
        _highlights = HighlightService.instance.getHighlightsForBook(widget.book.id);
      });
    }
  }

  /// 确保章节已解析（首次打开时触发）
  Future<void> _ensureChapters() async {
    if (widget.book.chapters.isNotEmpty || _isParsingChapters) return;

    // EPUB/PDF/MOBI格式在readContent时已解析章节
    if (widget.book.format == BookFormat.epub || widget.book.format == BookFormat.pdf || widget.book.format == BookFormat.mobi) return;

    _isParsingChapters = true;
    try {
      final service = BookshelfService.instance;
      final isLarge = await service.isLargeFile(widget.book);

      List<Chapter> chapters;
      if (isLarge) {
        // 大文件：窗口扫描
        chapters = await ChapterParser.parseLargeFile(
          readWindow: (offset, length) =>
              service.readTextWindow(widget.book, offset, length),
          totalBytes: await service.getBookFileSize(widget.book),
        );
      } else {
        // 小文件：全文解析
        final content = await service.readContent(widget.book);
        chapters = ChapterParser.parse(content);
      }

      if (chapters.isNotEmpty && mounted) {
        widget.book.chapters = chapters;
        BookshelfService.instance.updateChapters(widget.book.id, chapters);
        setState(() {});
      }
    } catch (_) {} finally {
      _isParsingChapters = false;
    }
  }

  @override
  void dispose() {
    _savePosition();
    _turnController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ─── 跟手翻页：动画状态回调 ───────────────────────────────

  /// 每帧驱动：把 _dragExtent 从起始值插值到目标值
  void _onTurnAnimTick() {
    final t = _turnController.value;
    setState(() {
      _dragExtent =
          _animFromExtent + (_animTargetExtent - _animFromExtent) * t;
    });
  }

  void _onTurnAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _turnController.value = 0;
    // 动画结束：若目标偏移超过半屏则完成翻页，否则已回弹归位
    if (_animTargetExtent.abs() > _pageFullWidth * 0.5) {
      _commitTurn(_animTargetExtent > 0 ? -1 : 1);
    } else {
      setState(() {
        _dragExtent = 0;
        _dragNeighborPage = null;
        _dragDir = 0;
      });
    }
  }

  /// 完成翻页：真正切换 _offset 并重置拖拽状态。
  /// 使用跟手时预计算的相邻页 startOffset，保证切换前后内容一致、无闪烁。
  void _commitTurn(int dir) {
    final neighbor = _dragNeighborPage;
    final newOffset = neighbor?.startOffset ?? -1;
    setState(() {
      _dragExtent = 0;
      _dragNeighborPage = null;
      _dragDir = 0;
    });
    if (neighbor != null && newOffset >= 0 && newOffset != _offset) {
      _pageDirection = dir;
      setState(() {
        _offset = newOffset;
      });
      _savePosition();
    } else {
      // 兜底：边界情况走原翻页逻辑
      if (dir < 0) {
        _prevPage();
      } else {
        _nextPage();
      }
    }
  }

  Future<void> _loadContent() async {
    try {
      final service = BookshelfService.instance;
      final isLarge = await service.isLargeFile(widget.book);

      if (isLarge) {
        // 大文件模式：按需读取
        _isLargeFile = true;
        _totalBytes = await service.getBookFileSize(widget.book);

        // 从上次阅读位置开始，或从0开始
        _byteOffset = widget.book.lastPosition > 0
            ? (widget.book.lastPosition).clamp(0, _totalBytes)
            : 0;

        // 估算总字符数（GBK约2字节/字，UTF-8约3字节/中文字符）
        _totalChars = (_totalBytes * 0.4).floor(); // 粗略估算

        // 加载第一窗口
        _textWindow = await service.readTextWindow(widget.book, _byteOffset, _windowBytes);
        _windowStartChar = _byteOffset;
        _offset = 0; // 窗口内偏移

        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      } else {
        // 小文件模式：全文加载
        final content = await service.readContent(widget.book);
        if (mounted) {
          setState(() {
            _textWindow = content;
            _windowStartChar = 0;
            _totalChars = content.length;
            _offset = widget.book.lastPosition;
            if (_offset >= _totalChars) _offset = 0;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = '$e';
          _isLoading = false;
        });
      }
    }
  }

  /// 基于排版结果计算精确分页（仅对当前文本窗口操作）
  _PageData _computePage(int startOffset, double availableHeight) {
    if (_textWindow.isEmpty || startOffset >= _textWindow.length) {
      return _PageData(
        startOffset: startOffset,
        endOffset: startOffset,
        result: const TypesetResult(glyphs: [], lines: [], totalHeight: 0),
      );
    }

    final engine = TypesetEngineProvider.engine;

    // 取比估算多3倍的文本（确保够一页），但不超过窗口
    final charArea = _config.fontSize * (_config.fontSize * _config.lineHeightRatio);
    final estimatedChars = ((_config.containerWidth * availableHeight) / charArea).floor();
    final fetchEnd = (startOffset + estimatedChars * 4).clamp(0, _textWindow.length);

    final text = _textWindow.substring(startOffset, fetchEnd);

    TypesetResult result;
    try {
      result = engine.typeset(text, _config);
    } catch (e) {
      // 排版引擎异常（FFI崩溃等），返回空页避免灰屏
      return _PageData(
        startOffset: startOffset,
        endOffset: fetchEnd,
        result: const TypesetResult(glyphs: [], lines: [], totalHeight: 0),
      );
    }

    // 如果排版高度不够（说明文本短），直接返回整段
    if (result.totalHeight <= availableHeight || result.lines.isEmpty) {
      return _PageData(
        startOffset: startOffset,
        endOffset: fetchEnd,
        result: result,
      );
    }

    // 根据可用高度，找到最后一行的索引
    int lastLineIndex = 0;
    for (int i = 0; i < result.lines.length; i++) {
      final line = result.lines[i];
      final lineBottom = line.y + _config.fontSize * _config.lineHeightRatio;
      if (lineBottom <= availableHeight) {
        lastLineIndex = i;
      } else {
        break;
      }
    }

    // 该页包含的行数 = lastLineIndex + 1
    final pageLineCount = lastLineIndex + 1;
    final lastLine = result.lines[lastLineIndex];

    // 计算该页文本对应的结束偏移
    int lastGlyphIndex = lastLine.startGlyphIndex + lastLine.glyphCount - 1;
    int charCount = 0;
    for (int i = 0; i <= lastGlyphIndex && i < result.glyphs.length; i++) {
      if (!result.glyphs[i].isCjkLatinSpacing) {
        charCount++;
      }
    }

    final pageEndOffset = (startOffset + charCount).clamp(0, _textWindow.length);

    // 直接截取排版结果
    final pageLines = result.lines.sublist(0, pageLineCount);
    final pageGlyphEnd = lastLine.startGlyphIndex + lastLine.glyphCount;
    final pageGlyphs = result.glyphs.sublist(0, pageGlyphEnd);
    final pageHeight = lastLine.y + _config.fontSize * _config.lineHeightRatio;

    return _PageData(
      startOffset: startOffset,
      endOffset: pageEndOffset,
      result: TypesetResult(glyphs: pageGlyphs, lines: pageLines, totalHeight: pageHeight),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pageSize = MediaQuery.of(context).size;
    final safePadding = MediaQuery.of(context).padding;
    final availableWidth = pageSize.width - 2 * _marginH;
    final availableHeight = pageSize.height - safePadding.top - safePadding.bottom - 16;

    // 缓存供手势回调使用
    _pageFullWidth = pageSize.width;
    _lastAvailableHeight = availableHeight;

    _config = TypesetConfig(
      fontSize: _config.fontSize,
      lineHeightRatio: _config.lineHeightRatio,
      containerWidth: availableWidth,
      fontFamily: _config.fontFamily,
    );

    // 加载中状态
    if (_isLoading) {
      return Scaffold(
        body: Container(
          color: _theme.bg,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.indigo),
                const SizedBox(height: 16),
                 Text('正在打开书籍...', style: TextStyle(color: _theme.hint, fontSize: 14)),
             ],
           ),
         ),
       ),
     );
   }

    // 加载错误状态
    if (_loadError != null) {
      return Scaffold(
        body: Container(
          color: _theme.bg,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
                  const SizedBox(height: 16),
                  Text('打开失败', style: TextStyle(color: _theme.text, fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(_loadError!, style: TextStyle(color: _theme.hint, fontSize: 12), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('返回书架'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 翻页加载中（有上一页内容可以显示）
    final showPagingOverlay = _isPaging && _currentPage != null;

    // 基于排版精确计算当前页
    _currentPage = _computePage(_offset, availableHeight);

    // 计算下一页起始偏移
    if (_currentPage!.endOffset < _textWindow.length) {
      _nextPageOffset = _currentPage!.endOffset;
    } else if (_isLargeFile && _byteOffset + _windowBytes < _totalBytes) {
      _nextPageOffset = _textWindow.length; // 标记需要加载新窗口
    } else {
      _nextPageOffset = -1; // 没有下一页
    }

    return Scaffold(
      body: PopScope(
        canPop: !_showMenu,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            setState(() {
              _showMenu = false;
              _showSettings = false;
            });
          }
        },
        child: Listener(
        onPointerSignal: _handleScroll,
        child: KeyboardListener(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                  event.logicalKey == LogicalKeyboardKey.pageDown) {
                _nextPage();
              } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                  event.logicalKey == LogicalKeyboardKey.pageUp) {
                _prevPage();
              } else if (event.logicalKey == LogicalKeyboardKey.escape) {
                if (_showMenu) {
                  setState(() { _showMenu = false; _showSettings = false; });
                } else {
                  Navigator.of(context).pop();
                }
              } else if (event.logicalKey == LogicalKeyboardKey.keyM) {
                // M键：切换菜单
                setState(() {
                  _showMenu = !_showMenu;
                  if (!_showMenu) _showSettings = false;
                });
              } else if (event.logicalKey == LogicalKeyboardKey.keyT) {
                // T键：打开目录与书签面板
                _showTocBookmarkPanel();
              } else if (event.logicalKey == LogicalKeyboardKey.keyB) {
                // B键：切换书签
                _toggleBookmark();
              }
            }
          },
          child: Stack(
            children: [
              // ── 主阅读区域 ──
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: _handleTap,
                onHorizontalDragStart: _handleDragStart,
                onHorizontalDragUpdate: _handleDragUpdate,
                onHorizontalDragEnd: _handleDragEnd,
                onLongPressStart: _handleLongPressStart,
                onLongPressMoveUpdate: _handleLongPressUpdate,
                onLongPressEnd: _handleLongPressEnd,
                child: Container(
                  color: _theme.bg,
                  padding: EdgeInsets.only(
                    top: safePadding.top,
                    left: _marginH,
                    right: _marginH,
                    bottom: 0,
                  ),
                  child: SizedBox(
                    height: availableHeight,
                    child: ClipRect(
                      child: _buildPageTurnView(availableHeight),
                    ),
                  ),
                ),
              ),

              // ── 顶部菜单栏 ──
              if (_showMenu) _buildTopBar(safePadding),

              // ── 底部控制栏 ──
              if (_showMenu) _buildBottomBar(safePadding),

              // ── 设置面板（覆盖在底部栏上方）──
              if (_showMenu && _showSettings) _buildSettingsPanel(safePadding),

              // ── 页面进度指示器（菜单隐藏时显示）──
              if (!_showMenu) _buildPageHint(),

              // ── 翻页加载遮罩 ──
              if (showPagingOverlay)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(0.1),
                    child: const Center(child: CircularProgressIndicator(color: Colors.indigo)),
                  ),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  // ─── 跟手翻页渲染 ────────────────────────────────────────

  /// 跟手翻页视图：拖拽/动画过程中实时联动当前页与相邻页；
  /// 静止时仅渲染当前页。
  Widget _buildPageTurnView(double availableHeight) {
    final currentPage = _buildPageContent(availableHeight);

    // 静止或无动画模式：仅当前页
    if ((_dragExtent == 0 && !_turnController.isAnimating) ||
        _pageMode == PageTurnMode.none) {
      return currentPage;
    }

    final w = _pageFullWidth;
    final p = (_dragExtent / w).clamp(-1.0, 1.0); // -1..1
    final absP = p.abs();
    final neighbor = _dragNeighborPage;

    Widget? neighborWidget;
    if (neighbor != null) {
      neighborWidget = SizedBox(
        height: availableHeight,
        child: TypesetRendererWidget(
          result: neighbor.result,
          config: _config,
          textColor: _theme.text,
          bgColor: _theme.bg,
        ),
      );
    }

    // 相邻页在屏幕外的起始偏移：向右拖(p>0)看上一页→左侧；向左拖(p<0)看下一页→右侧
    final neighborBase = p > 0 ? -w : w;

    switch (_pageMode) {
      case PageTurnMode.slide:
        // 推式：当前页随手指平移，相邻页从对侧同步进入（两者不重叠）
        return Stack(
          children: [
            if (neighborWidget != null)
              Transform.translate(
                offset: Offset(neighborBase + _dragExtent, 0),
                child: neighborWidget,
              ),
            Transform.translate(
              offset: Offset(_dragExtent, 0),
              child: currentPage,
            ),
          ],
        );

      case PageTurnMode.cover:
        // 覆盖：当前页不动，相邻页从边缘滑入覆盖
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

      case PageTurnMode.fade:
        // 渐变淡入：从拖拽对侧边缘向本侧扫光（由浅入深）
        final isNext = p < 0; // 看下一页→邻居从右进；看上一页→邻居从左进
        final progress = absP.clamp(0.0, 1.0);
        return Stack(
          children: [
            ShaderMask(
              shaderCallback: (rect) {
                // 当前页：从拖拽起始侧开始变透明
                final beginSide = isNext ? Alignment.centerLeft : Alignment.centerRight;
                final endSide = isNext ? Alignment.centerRight : Alignment.centerLeft;
                return LinearGradient(
                  begin: beginSide,
                  end: endSide,
                  colors: [
                    const Color(0xFFFFFFFF),
                    Color.fromRGBO(255, 255, 255, 1 - progress),
                  ],
                ).createShader(rect);
              },
              blendMode: BlendMode.modulate,
              child: currentPage,
            ),
            if (neighborWidget != null)
              ShaderMask(
                shaderCallback: (rect) {
                  // 邻居页：从拖拽对侧边缘开始显现
                  final beginSide = isNext ? Alignment.centerLeft : Alignment.centerRight;
                  final endSide = isNext ? Alignment.centerRight : Alignment.centerLeft;
                  return LinearGradient(
                    begin: beginSide,
                    end: endSide,
                    colors: [
                      const Color(0x00FFFFFF),
                      Color.fromRGBO(255, 255, 255, progress),
                    ],
                  ).createShader(rect);
                },
                blendMode: BlendMode.modulate,
                child: neighborWidget,
              ),
          ],
        );

      case PageTurnMode.flip:
        // 3D翻转：当前页绕拖拽起始边缘翻转露出相邻页
        // 向右拖(p>0)看上一页：当前页绕左边缘向右翻出（rotateY 负向）
        // 向左拖(p<0)看下一页：当前页绕右边缘向左翻出（rotateY 正向）
        final angle = absP * (math.pi / 2);
        final align = p > 0 ? Alignment.centerLeft : Alignment.centerRight;
        return Stack(
          children: [
            if (neighborWidget != null)
              Opacity(opacity: absP.clamp(0.0, 1.0), child: neighborWidget),
            Transform(
              alignment: align,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.002)
                ..rotateY(angle * (p > 0 ? -1 : 1)),
              child:
                  Opacity(opacity: (1 - absP * 0.6).clamp(0.0, 1.0), child: currentPage),
            ),
          ],
        );

      case PageTurnMode.none:
        return currentPage;
    }
  }

  Widget _buildPageContent(double availableHeight) {
    return SizedBox(
      key: ValueKey(_offset),
      height: availableHeight,
      child: TypesetRendererWidget(
        result: _currentPage!.result,
        config: _config,
        textColor: _theme.text,
        bgColor: _theme.bg,
        highlights: _computeHighlightSpansForPage(_currentPage!),
        selection: _currentSelectionSpan,
      ),
    );
  }

  // ─── 交互处理 ────────────────────────────────────────────

  void _handleTap(TapUpDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    final dx = details.localPosition.dx;

    if (dx < screenWidth / 3) {
      _animateTurnToPage(-1); // 上一页，带翻页动画
    } else if (dx > screenWidth * 2 / 3) {
      _animateTurnToPage(1); // 下一页，带翻页动画
    } else {
      setState(() {
        _showMenu = !_showMenu;
        if (!_showMenu) _showSettings = false;
      });
    }
  }

  /// 点击翻页：从静止状态启动一次完整翻页动画
  /// dir: -1=上一页, 1=下一页
  void _animateTurnToPage(int dir) {
    if (_pageMode == PageTurnMode.none) {
      // 无动画模式直接切
      if (dir < 0) {
        _prevPage();
      } else {
        _nextPage();
      }
      return;
    }
    if (_turnController.isAnimating) return;
    if (_isDragging) return;
    _dragDir = dir;
    _dragNeighborPage = _prepareNeighborPage(dir);
    if (_dragNeighborPage == null) {
      // 无相邻页：直接切
      if (dir < 0) {
        _prevPage();
      } else {
        _nextPage();
      }
      return;
    }
    final w = _pageFullWidth;
    setState(() {
      _dragExtent = 0;
    });
    _animFromExtent = 0;
    _animTargetExtent = dir < 0 ? w : -w;
    _turnController.value = 0;
    _turnController.forward();
  }

  // ─── 跟手翻页：手势处理 ───────────────────────────────────

  /// 预计算相邻页排版数据。dir: -1=上一页, 1=下一页。
  /// 返回 null 表示无相邻页（边界/大文件窗口处）。
  _PageData? _prepareNeighborPage(int dir) {
    final h = _lastAvailableHeight;
    if (h <= 0 || _currentPage == null) return null;
    if (dir < 0) {
      // 上一页
      if (_offset <= 0) {
        // 窗口起点：大文件可回退窗口，但跟手不支持跨窗口，返回 null
        return null;
      }
      final currentPageChars =
          _currentPage!.endOffset - _currentPage!.startOffset;
      final prevOffset =
          (_offset - (currentPageChars * 1.5).floor()).clamp(0, _textWindow.length);
      if (prevOffset >= _offset) return null;
      return _computePage(prevOffset, h);
    } else {
      // 下一页
      if (_nextPageOffset < 0) return null;
      // 大文件需加载新窗口时，跟手不支持
      if (_nextPageOffset == _textWindow.length && _isLargeFile) return null;
      if (_nextPageOffset >= _textWindow.length) return null;
      return _computePage(_nextPageOffset, h);
    }
  }

  void _handleDragStart(DragStartDetails details) {
    _isDragging = true;
    if (_turnController.isAnimating) {
      _turnController.stop();
    }
    _dragDir = 0;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    // 选区模式下，水平拖拽不影响翻页（让选区由 longPressMoveUpdate 主动更新）
    if (_isSelecting) return;
    final delta = details.primaryDelta ?? 0;
    var next = _dragExtent + delta;
    final w = _pageFullWidth;
    // 确定方向（首次越过阈值）
    if (_dragDir == 0 && next.abs() > 6) {
      _dragDir = next > 0 ? -1 : 1;
      _dragNeighborPage = _prepareNeighborPage(_dragDir);
    }
    // 方向确定后禁止变号，避免相邻页来回切换
    if (_dragDir == -1) {
      next = next.clamp(0.0, w);
    } else if (_dragDir == 1) {
      next = next.clamp(-w, 0.0);
    } else {
      next = next.clamp(-w, w);
    }
    // 无相邻页时做橡皮筋衰减（拖动阻力）
    if (_dragNeighborPage == null) {
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

    // 无相邻页：直接回弹
    if (_dragNeighborPage == null || _dragDir == 0) {
      _startTurnAnim(0);
      return;
    }

    bool shouldTurn;
    if (_dragDir == -1) {
      // 向右拖看上一页
      shouldTurn = _dragExtent > w * 0.33 || velocity > 320;
    } else {
      // 向左拖看下一页
      shouldTurn = _dragExtent.abs() > w * 0.33 || velocity < -320;
    }

    final target = shouldTurn
        ? (_dragDir == -1 ? w : -w)
        : 0.0;
    _startTurnAnim(target);
  }

  /// 启动松手后的完成/回弹动画
  void _startTurnAnim(double target) {
    _animFromExtent = _dragExtent;
    _animTargetExtent = target;
    _turnController.value = 0;
    _turnController.forward();
  }

  void _handleScroll(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final now = DateTime.now();
      if (_lastScrollTime != null &&
          now.difference(_lastScrollTime!) < const Duration(milliseconds: 350)) {
        return;
      }
      _lastScrollTime = now;
      if (event.scrollDelta.dy > 0) {
        _nextPage();
      } else if (event.scrollDelta.dy < 0) {
        _prevPage();
      }
    }
  }

  // ─── 文本选区：长按手势 ─────────────────────────────────

  void _handleLongPressStart(LongPressStartDetails details) {
    // 大文件不启用选区（跨窗口偏移复杂），直接返回
    if (_isLargeFile) return;
    // 插件未启用时不响应
    if (!PluginManager.instance.isEnabled('highlight')) return;
    if (_currentPage == null || _currentPage!.result.glyphs.isEmpty) return;

    // localPosition 在 GestureDetector 的 child 内（Container 有 padding）
    // 命中测试需用相对 CustomPaint 的坐标：减去水平 padding（_marginH + safePadding.top）
    final safeTop = MediaQuery.of(context).padding.top;
    final local = Offset(
      details.localPosition.dx - _marginH,
      details.localPosition.dy - safeTop,
    );

    final hit = _hitTestGlyph(local);
    if (hit < 0) return;

    setState(() {
      _isSelecting = true;
      _selStartGlyph = hit;
      _selEndGlyph = hit;
      _selAnchorOffset = details.globalPosition;
    });
    _selectionFeedback();
  }

  void _handleLongPressUpdate(LongPressMoveUpdateDetails details) {
    if (!_isSelecting) return;
    final safeTop = MediaQuery.of(context).padding.top;
    final local = Offset(
      details.localPosition.dx - _marginH,
      details.localPosition.dy - safeTop,
    );
    final hit = _hitTestGlyph(local);
    if (hit < 0) return;
    if (hit != _selEndGlyph) {
      setState(() {
        _selEndGlyph = hit;
      });
    }
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    if (!_isSelecting) return;
    // 短按没拖动 → 视为单字选取（保留 _selStart=_selEnd 的状态，弹出工具栏）
    // 拖动过 → 弹工具栏
    _showSelectionToolbar();
  }

  /// 长按触发瞬间的振动反馈
  void _selectionFeedback() {
    try {
      HapticFeedback.selectionClick();
    } catch (_) {}
  }

  /// 弹出选区工具栏：复制 / 5 色高亮 / 加笔记 / 取消
  void _showSelectionToolbar() {
    if (!_isSelecting || _currentPage == null) return;
    final preview = _selectionPreview;
    if (preview.isEmpty) {
      _clearSelection();
      return;
    }

    // 用 OverlayEntry 在选区附近显示工具栏
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _SelectionToolbar(
        anchor: _selAnchorOffset,
        preview: preview,
        onSelectColor: (colorIdx) async {
          await _commitHighlight(colorIdx, note: null);
          entry.remove();
          _clearSelection();
        },
        onAddNote: () async {
          entry.remove();
          await _promptForNoteAndCreate();
        },
        onCopy: () {
          Clipboard.setData(ClipboardData(text: preview));
          entry.remove();
          _clearSelection();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已复制'), duration: Duration(milliseconds: 800)),
            );
          }
        },
        onCancel: () {
          entry.remove();
          _clearSelection();
        },
      ),
    );
    overlay.insert(entry);
  }

  /// 弹出笔记输入对话框，确认后创建带笔记的高亮
  Future<void> _promptForNoteAndCreate() async {
    if (!_isSelecting) return;
    final preview = _selectionPreview;
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加笔记', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _theme.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              constraints: const BoxConstraints(maxHeight: 100),
              child: SingleChildScrollView(
                child: Text(preview, style: TextStyle(fontSize: 12, color: _theme.text)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 4,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '笔记内容...',
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.all(10),
                hintStyle: TextStyle(color: _theme.hint),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await _commitHighlight(0, note: result);
    }
    _clearSelection();
  }

  /// 实际提交高亮到 HighlightService 并刷新本地列表
  Future<void> _commitHighlight(int colorIndex, {String? note}) async {
    if (!_isSelecting || _currentPage == null) return;
    final (startChar, endChar) = _selectionCharRange;
    if (endChar <= startChar) return;
    final preview = _selectionPreview;

    String? chapterTitle;
    try {
      // 取起点最近的章节标题
      for (int i = widget.book.chapters.length - 1; i >= 0; i--) {
        if (widget.book.chapters[i].startOffset <= startChar) {
          chapterTitle = widget.book.chapters[i].title;
          break;
        }
      }
    } catch (_) {}

    await HighlightService.instance.addHighlight(
      bookId: widget.book.id,
      startOffset: startChar,
      endOffset: endChar,
      position: startChar,
      preview: preview,
      colorIndex: colorIndex,
      note: note,
      chapterTitle: chapterTitle,
    );
    if (mounted) {
      setState(() {
        _highlights = HighlightService.instance.getHighlightsForBook(widget.book.id);
      });
    }
  }

  /// 清除选区状态
  void _clearSelection() {
    if (mounted) {
      setState(() {
        _isSelecting = false;
        _selStartGlyph = -1;
        _selEndGlyph = -1;
      });
    } else {
      _isSelecting = false;
      _selStartGlyph = -1;
      _selEndGlyph = -1;
    }
  }

  void _nextPage() {
    if (_isPaging) return;

    // 检查是否需要加载新窗口
    if (_nextPageOffset == _textWindow.length && _isLargeFile) {
      _loadNextWindow();
      return;
    }

    if (_nextPageOffset > 0 && _nextPageOffset < _textWindow.length) {
      _pageDirection = 1;
      setState(() {
        _offset = _nextPageOffset;
      });
      _savePosition();
    }
  }

  /// 加载下一个文本窗口（大文件模式）
  Future<void> _loadNextWindow() async {
    if (_isPaging) return;
    setState(() => _isPaging = true);

    try {
      final service = BookshelfService.instance;
      _byteOffset = _byteOffset + _windowBytes;
      if (_byteOffset >= _totalBytes) {
        _byteOffset = _totalBytes - 1;
      }

      _textWindow = await service.readTextWindow(widget.book, _byteOffset, _windowBytes);
      _offset = 0;

      if (mounted) {
        setState(() {
          _isPaging = false;
        });
        _savePosition();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isPaging = false);
      }
    }
  }

  /// 加载上一个文本窗口（大文件模式）
  Future<void> _loadPrevWindow() async {
    if (_isPaging) return;
    setState(() => _isPaging = true);

    try {
      final service = BookshelfService.instance;
      _byteOffset = (_byteOffset - _windowBytes).clamp(0, _totalBytes);

      _textWindow = await service.readTextWindow(widget.book, _byteOffset, _windowBytes);
      // 定位到窗口末尾附近
      _offset = (_textWindow.length * 0.8).floor();

      if (mounted) {
        setState(() {
          _isPaging = false;
        });
        _savePosition();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isPaging = false);
      }
    }
  }

  void _prevPage() {
    if (_isPaging) return;

    if (_offset <= 0) {
      if (_isLargeFile && _byteOffset > 0) {
        _loadPrevWindow();
      }
      return;
    }

    final currentPageChars = _currentPage != null
        ? _currentPage!.endOffset - _currentPage!.startOffset
        : 200;
    final prevOffset = (_offset - (currentPageChars * 1.5).floor()).clamp(0, _textWindow.length);

    _pageDirection = -1;
    setState(() {
      _offset = prevOffset;
    });
    _savePosition();
  }

  /// 拖拽进度跳转
  Future<void> _seekTo(double progress) async {
    _pageDirection = 1;

    if (_isLargeFile) {
      final newByteOffset = (progress * _totalBytes).floor().clamp(0, _totalBytes - 1);
      if (newByteOffset == _byteOffset) return;

      setState(() => _isPaging = true);
      try {
        _byteOffset = newByteOffset;
        _textWindow = await BookshelfService.instance
            .readTextWindow(widget.book, _byteOffset, _windowBytes);
        _offset = 0;
        if (mounted) {
          setState(() => _isPaging = false);
        }
        _savePosition();
      } catch (_) {
        if (mounted) setState(() => _isPaging = false);
      }
    } else {
      setState(() {
        _offset = (progress * _totalChars).floor().clamp(0, _totalChars - 1);
      });
      _savePosition();
    }
  }

  // ─── 目录与书签 ──────────────────────────────────────────

  /// 当前位置是否有书签
  bool get _hasBookmarkAtCurrent {
    final pos = _isLargeFile ? _byteOffset : _offset;
    return BookmarkService.instance.hasBookmarkNear(widget.book.id, pos);
  }

  /// 获取当前位置的阅读预览文本
  String get _currentPreview {
    if (_currentPage != null && _currentPage!.result.glyphs.isNotEmpty) {
      final glyphs = _currentPage!.result.glyphs
          .where((g) => !g.isCjkLatinSpacing && g.char != '\n');
      final chars = glyphs.take(40).map((g) => g.char).join();
      return chars.isEmpty ? '（空白页）' : chars;
    }
    return '位置 ${_isLargeFile ? _byteOffset : _offset}';
  }

  // ─── 高亮：glyph 索引 ↔ 字符偏移 映射 ───────────────────

  /// 给定当前页某 glyph 索引，返回它在文本窗口中的字符偏移。
  /// 与 _computePage 中的 charCount 算法一致：跳过 isCjkLatinSpacing
  int _charOffsetForGlyph(_PageData page, int glyphIndex) {
    int charCount = 0;
    for (int i = 0; i < glyphIndex && i < page.result.glyphs.length; i++) {
      if (!page.result.glyphs[i].isCjkLatinSpacing) {
        charCount++;
      }
    }
    return page.startOffset + charCount;
  }

  /// 反向：给定当前页内字符偏移（相对页起点），返回对应 glyph 索引
  /// （找到第 charIndex 个非 spacing glyph 的索引）
  int _glyphIndexForCharOffset(_PageData page, int charOffsetInPage) {
    int count = 0;
    for (int i = 0; i < page.result.glyphs.length; i++) {
      final g = page.result.glyphs[i];
      if (g.isCjkLatinSpacing || g.char == '\n') continue;
      if (count == charOffsetInPage) return i;
      count++;
    }
    return page.result.glyphs.length - 1;
  }

  /// 全文绝对字符偏移（小文件）或字节偏移（大文件）—— 用于高亮 position 字段锚点
  int get _currentPosForBookmark => _isLargeFile ? _byteOffset : _offset;

  /// 计算当前页应渲染的高亮 HighlightSpan 列表
  /// 思路：对每个本页高亮，把它的 startOffset/endOffset 投影到当前页的 glyph 索引区间
  List<HighlightSpan> _computeHighlightSpansForPage(_PageData page) {
    if (_highlights.isEmpty || page.result.glyphs.isEmpty) return [];
    // 小文件模式：高亮的 startOffset/endOffset 是全文字符偏移；
    // 当前页 _currentPage.startOffset 是文本窗口偏移（小文件=_offset，等于全文偏移）
    final pageStartGlobal = page.startOffset + _windowStartChar;
    final pageEndGlobal = page.endOffset + _windowStartChar;
    final spans = <HighlightSpan>[];
    for (final h in _highlights) {
      // 大文件暂时不显示持久化高亮（跨窗口偏移复杂），仅小文件模式启用
      if (_isLargeFile) continue;
      // 区间与当前页相交？
      if (h.startOffset >= pageEndGlobal || h.endOffset <= pageStartGlobal) continue;
      // 投影到页内偏移
      final startInPage = (h.startOffset - pageStartGlobal).clamp(0, pageEndGlobal - pageStartGlobal);
      final endInPage = (h.endOffset - pageStartGlobal).clamp(0, pageEndGlobal - pageStartGlobal);
      if (endInPage <= startInPage) continue;
      final startG = _glyphIndexForCharOffset(page, startInPage);
      final endG = _glyphIndexForCharOffset(page, endInPage - 1) + 1;
      if (endG <= startG) continue;
      spans.add(HighlightSpan(
        startGlyphIndex: startG,
        endGlyphIndex: endG,
        color: Color(HighlightColors.indexToArgb(h.colorIndex)),
      ));
    }
    return spans;
  }

  /// 临时选区 SelectionSpan（如果有）
  SelectionSpan? get _currentSelectionSpan {
    if (!_isSelecting || _selStartGlyph < 0 || _selEndGlyph < 0) return null;
    final start = _selStartGlyph < _selEndGlyph ? _selStartGlyph : _selEndGlyph;
    final end = (_selStartGlyph < _selEndGlyph ? _selEndGlyph : _selStartGlyph) + 1;
    return SelectionSpan(startGlyphIndex: start, endGlyphIndex: end, color: const Color(0xFF607D8B));
  }

  /// 选取区段对应文本（用于高亮 preview 与复制）
  String get _selectionPreview {
    if (!_isSelecting || _currentPage == null) return '';
    final startIdx = _selStartGlyph < _selEndGlyph ? _selStartGlyph : _selEndGlyph;
    final endIdx = (_selStartGlyph < _selEndGlyph ? _selEndGlyph : _selStartGlyph) + 1;
    final sb = StringBuffer();
    for (int i = startIdx; i < endIdx && i < _currentPage!.result.glyphs.length; i++) {
      final g = _currentPage!.result.glyphs[i];
      if (g.isCjkLatinSpacing || g.char == '\n') continue;
      sb.write(g.char);
    }
    return sb.toString();
  }

  /// 命中测试：根据屏幕坐标（相对 CustomPaint 容器）找出命中的 glyph 索引
  /// 返回 -1 表示未命中。注意 localPosition 来自 GestureDetector，需要减去 padding
  int _hitTestGlyph(Offset localPos) {
    if (_currentPage == null || _currentPage!.result.glyphs.isEmpty) return -1;
    final glyphs = _currentPage!.result.glyphs;
    // y 在 [glyph.y - fontSize*0.85, glyph.y + fontSize*0.15) 区间视为本行
    final fontSize = _config.fontSize;
    // 先找最近的行
    int bestIdx = -1;
    double bestDist = 1e18;
    for (int i = 0; i < glyphs.length; i++) {
      final g = glyphs[i];
      if (g.isCjkLatinSpacing || g.char == '\n') continue;
      // 取字符中心点
      final cx = g.x + g.width / 2;
      final cy = g.y - fontSize * 0.35;
      final d = (cx - localPos.dx) * (cx - localPos.dx) +
          (cy - localPos.dy) * (cy - localPos.dy);
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /// 当前选区在文本窗口中的起止字符偏移
  (int, int) get _selectionCharRange {
    if (_currentPage == null || !_isSelecting) return (0, 0);
    final startIdx = _selStartGlyph < _selEndGlyph ? _selStartGlyph : _selEndGlyph;
    final endIdx = (_selStartGlyph < _selEndGlyph ? _selEndGlyph : _selStartGlyph) + 1;
    final startChar = _charOffsetForGlyph(_currentPage!, startIdx);
    final endChar = _charOffsetForGlyph(_currentPage!, endIdx - 1) + 1;
    return (startChar, endChar);
  }

  /// 添加/移除当前页书签
  Future<void> _toggleBookmark() async {
    final pos = _isLargeFile ? _byteOffset : _offset;
    final existing = BookmarkService.instance.getBookmarksForBook(widget.book.id);
    final near = existing.where((b) => (b.position - pos).abs() < 100);

    if (near.isNotEmpty) {
      // 移除已有书签
      await BookmarkService.instance.removeBookmark(near.first.id);
    } else {
      // 添加新书签
      await BookmarkService.instance.addBookmark(
        bookId: widget.book.id,
        position: pos,
        preview: _currentPreview,
      );
    }

    if (mounted) {
      setState(() {
        _bookmarks = BookmarkService.instance.getBookmarksForBook(widget.book.id);
      });
    }
  }

  /// 显示目录与书签面板
  void _showTocBookmarkPanel() {
    final pos = _isLargeFile ? _byteOffset : _offset;
    // 打开面板前刷新一次高亮列表，确保最新
    final highlights = HighlightService.instance.getHighlightsForBook(widget.book.id);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TocBookmarkPanel(
        book: widget.book,
        chapters: widget.book.chapters,
        bookmarks: _bookmarks,
        highlights: highlights,
        currentPosition: pos,
        isLargeFile: _isLargeFile,
        onJump: _jumpToChapter,
        onAddBookmark: () async {
          await _toggleBookmark();
        },
        onRemoveBookmark: (id) async {
          await BookmarkService.instance.removeBookmark(id);
          if (mounted) {
            setState(() {
              _bookmarks = BookmarkService.instance.getBookmarksForBook(widget.book.id);
            });
          }
        },
        onRemoveHighlight: (id) async {
          await HighlightService.instance.removeHighlight(id);
          if (mounted) {
            setState(() {
              _highlights = HighlightService.instance.getHighlightsForBook(widget.book.id);
            });
          }
        },
        onUpdateHighlightNote: (id, note) async {
          await HighlightService.instance.updateNote(id, note);
          if (mounted) {
            setState(() {
              _highlights = HighlightService.instance.getHighlightsForBook(widget.book.id);
            });
          }
        },
        bgColor: _theme.bg,
        textColor: _theme.text,
        hintColor: _theme.hint,
        surfaceColor: _theme.surface,
        borderColor: _theme.border,
        isDark: _theme.isDark,
      ),
    );
  }

  /// 跳转到章节/书签位置
  Future<void> _jumpToChapter(int targetOffset) async {
    _pageDirection = 1;

    if (_isLargeFile) {
      // 大文件：targetOffset 是字符偏移，需转换为字节偏移
      // 章节解析时用的是全文扫描，startOffset是字符近似值
      // 估算：字符偏移 / 总字符数 * 总字节数
      if (_totalChars > 0 && _totalBytes > 0) {
        final byteTarget = (targetOffset / _totalChars * _totalBytes).floor()
            .clamp(0, _totalBytes - 1);
        setState(() => _isPaging = true);
        try {
          _byteOffset = byteTarget;
          _textWindow = await BookshelfService.instance
              .readTextWindow(widget.book, _byteOffset, _windowBytes);
          _offset = 0;
          if (mounted) setState(() => _isPaging = false);
          _savePosition();
        } catch (_) {
          if (mounted) setState(() => _isPaging = false);
        }
      }
    } else {
      // 小文件：直接字符偏移跳转
      setState(() {
        _offset = targetOffset.clamp(0, _totalChars - 1);
      });
      _savePosition();
    }
  }

  // ─── 读写位置 & 设置持久化 ────────────────────────────────

  void _savePosition() {
    if (_isLargeFile) {
      BookshelfService.instance.updateReadPosition(widget.book.id, _byteOffset);
    } else {
      BookshelfService.instance.updateReadPosition(widget.book.id, _offset);
    }
  }

  /// 从SharedPreferences加载阅读设置
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fontSize = prefs.getDouble(_kFontSizeKey) ?? 18.0;
      final lineHeight = prefs.getDouble(_kLineHeightKey) ?? 1.8;
      final marginH = prefs.getDouble(_kMarginHKey) ?? 24.0;
      final pageModeIdx = prefs.getInt(_kPageModeKey) ?? 0;

      // 兼容旧版dark mode设置
      int themeIdx = prefs.getInt(_kReadingThemeKey) ?? -1;
      if (themeIdx < 0) {
        final darkMode = prefs.getBool(_kDarkModeKey) ?? false;
        themeIdx = darkMode ? 2 : 0;
      }

      if (mounted) {
        setState(() {
          _config = TypesetConfig(
            fontSize: fontSize,
            lineHeightRatio: lineHeight,
            containerWidth: _config.containerWidth,
            fontFamily: _config.fontFamily,
          );
          _marginH = marginH;
          _readingTheme = themeIdx.clamp(0, _themes.length - 1);
          _pageMode = PageTurnMode.values[
              pageModeIdx.clamp(0, PageTurnMode.values.length - 1)];
        });
      }
    } catch (_) {}
  }

  /// 保存阅读设置到SharedPreferences
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kFontSizeKey, _config.fontSize);
      await prefs.setDouble(_kLineHeightKey, _config.lineHeightRatio);
      await prefs.setDouble(_kMarginHKey, _marginH);
      await prefs.setInt(_kReadingThemeKey, _readingTheme);
      await prefs.setInt(_kPageModeKey, _pageMode.index);
    } catch (_) {}
  }

  // ─── 进度计算 ────────────────────────────────────────────

  double get _progress {
    if (_isLargeFile) {
      if (_totalBytes == 0) return 0;
      return (_byteOffset / _totalBytes).clamp(0.0, 1.0);
    }
    if (_totalChars == 0) return 0;
    return (_offset / _totalChars).clamp(0.0, 1.0);
  }

  bool get _hasNextPage {
    if (_isLargeFile) {
      return _nextPageOffset > 0 || _byteOffset + _windowBytes < _totalBytes;
    }
    return _nextPageOffset > 0 && _nextPageOffset < _textWindow.length;
  }

  bool get _hasPrevPage {
    if (_isLargeFile) {
      return _offset > 0 || _byteOffset > 0;
    }
    return _offset > 0;
  }

  // ─── UI 构建 ──────────────────────────────────────────────

  Widget _buildTopBar(EdgeInsets safePadding) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.only(
          top: safePadding.top,
          left: 8,
          right: 8,
          bottom: 8,
        ),
        decoration: BoxDecoration(
          color: _theme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_theme.isDark ? 0.4 : 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back, color: _theme.text),
              onPressed: () => Navigator.of(context).pop(),
              tooltip: '返回',
            ),
            IconButton(
              icon: Icon(Icons.menu_book_outlined, color: _theme.text, size: 20),
              onPressed: _showTocBookmarkPanel,
              tooltip: '目录与书签',
            ),
            Expanded(
              child: Text(
                widget.book.title,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _theme.text),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 书签按钮
            IconButton(
              icon: Icon(
                _hasBookmarkAtCurrent ? Icons.bookmark : Icons.bookmark_border,
                color: _hasBookmarkAtCurrent ? Colors.amber.shade600 : _theme.text,
                size: 20,
              ),
              onPressed: _toggleBookmark,
              tooltip: _hasBookmarkAtCurrent ? '移除书签' : '添加书签',
            ),
            IconButton(
              icon: Icon(
                _showSettings ? Icons.close : Icons.tune,
                color: _theme.text,
                size: 20,
              ),
              onPressed: () => setState(() {
                _showSettings = !_showSettings;
              }),
              tooltip: '阅读设置',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(EdgeInsets safePadding) {
    final displayProgress = _seekProgress ?? _progress;
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 10,
          bottom: safePadding.bottom + 10,
        ),
        decoration: BoxDecoration(
          color: _theme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_theme.isDark ? 0.4 : 0.06),
              blurRadius: 6,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          children: [
            // 上一页
            IconButton(
              icon: Icon(Icons.chevron_left, color: _hasPrevPage ? _theme.text : _theme.border),
              onPressed: _hasPrevPage ? _prevPage : null,
              iconSize: 22,
              visualDensity: VisualDensity.compact,
            ),
            // 百分比
            SizedBox(
              width: 42,
              child: Text(
                '${(displayProgress * 100).toStringAsFixed(0)}%',
                style: TextStyle(fontSize: 11, color: _theme.hint),
                textAlign: TextAlign.center,
              ),
            ),
            // 进度滑块
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: Colors.indigo,
                  inactiveTrackColor: _theme.border,
                  thumbColor: Colors.indigo,
                ),
                child: Slider(
                  value: displayProgress.clamp(0.0, 1.0),
                  onChanged: (v) => setState(() => _seekProgress = v),
                  onChangeEnd: (v) {
                    _seekTo(v);
                    setState(() => _seekProgress = null);
                  },
                ),
              ),
            ),
            // 字数统计
            SizedBox(
              width: 80,
              child: Text(
                _isLargeFile
                    ? '${(_byteOffset / 1024).toStringAsFixed(0)}K/${(_totalBytes / 1024).toStringAsFixed(0)}K'
                    : '${(_offset / 1000).toStringAsFixed(1)}k/${(_totalChars / 1000).toStringAsFixed(1)}k',
                style: TextStyle(fontSize: 10, color: _theme.hint),
                textAlign: TextAlign.center,
              ),
            ),
            // 下一页
            IconButton(
              icon: Icon(Icons.chevron_right, color: _hasNextPage ? _theme.text : _theme.border),
              onPressed: _hasNextPage ? _nextPage : null,
              iconSize: 22,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsPanel(EdgeInsets safePadding) {
    return Positioned(
      bottom: 72 + safePadding.bottom,
      left: 12,
      right: 12,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _theme.panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _theme.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(_theme.isDark ? 0.5 : 0.12),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 字号 ──
              _buildSettingRow(
                label: '字号',
                value: _config.fontSize.toStringAsFixed(0),
                sliderValue: _config.fontSize,
                min: 12,
                max: 28,
                divisions: 8,
                onChanged: (v) {
                  setState(() {
                    _config = TypesetConfig(
                      fontSize: v,
                      lineHeightRatio: _config.lineHeightRatio,
                      containerWidth: _config.containerWidth,
                      fontFamily: _config.fontFamily,
                    );
                  });
                  _saveSettings();
                },
                onDecrease: () {
                  final v = (_config.fontSize - 1).clamp(12.0, 28.0);
                  setState(() {
                    _config = TypesetConfig(
                      fontSize: v,
                      lineHeightRatio: _config.lineHeightRatio,
                      containerWidth: _config.containerWidth,
                      fontFamily: _config.fontFamily,
                    );
                  });
                  _saveSettings();
                },
                onIncrease: () {
                  final v = (_config.fontSize + 1).clamp(12.0, 28.0);
                  setState(() {
                    _config = TypesetConfig(
                      fontSize: v,
                      lineHeightRatio: _config.lineHeightRatio,
                      containerWidth: _config.containerWidth,
                      fontFamily: _config.fontFamily,
                    );
                  });
                  _saveSettings();
                },
              ),
              const SizedBox(height: 4),
              // ── 行距 ──
              _buildSettingRow(
                label: '行距',
                value: _config.lineHeightRatio.toStringAsFixed(1),
                sliderValue: _config.lineHeightRatio,
                min: 1.2,
                max: 2.5,
                divisions: 13,
                onChanged: (v) {
                  setState(() {
                    _config = TypesetConfig(
                      fontSize: _config.fontSize,
                      lineHeightRatio: v,
                      containerWidth: _config.containerWidth,
                      fontFamily: _config.fontFamily,
                    );
                  });
                  _saveSettings();
                },
                onDecrease: () {
                  final v = (_config.lineHeightRatio - 0.1).clamp(1.2, 2.5);
                  setState(() {
                    _config = TypesetConfig(
                      fontSize: _config.fontSize,
                      lineHeightRatio: v,
                      containerWidth: _config.containerWidth,
                      fontFamily: _config.fontFamily,
                    );
                  });
                  _saveSettings();
                },
                onIncrease: () {
                  final v = (_config.lineHeightRatio + 0.1).clamp(1.2, 2.5);
                  setState(() {
                    _config = TypesetConfig(
                      fontSize: _config.fontSize,
                      lineHeightRatio: v,
                      containerWidth: _config.containerWidth,
                      fontFamily: _config.fontFamily,
                    );
                  });
                  _saveSettings();
                },
              ),
              const SizedBox(height: 4),
              // ── 边距 ──
              _buildSettingRow(
                label: '边距',
                value: _marginH.toStringAsFixed(0),
                sliderValue: _marginH,
                min: 8,
                max: 48,
                divisions: 10,
                onChanged: (v) {
                  setState(() => _marginH = v);
                  _saveSettings();
                },
                onDecrease: () {
                  setState(() => _marginH = (_marginH - 4).clamp(8.0, 48.0));
                  _saveSettings();
                },
                onIncrease: () {
                  setState(() => _marginH = (_marginH + 4).clamp(8.0, 48.0));
                  _saveSettings();
                },
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              // ── 翻页模式选择 ──
              Row(
                children: [
                  Text('翻页', style: TextStyle(color: _theme.hint, fontSize: 13)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: _pageTurnModeNames.entries.map((entry) {
                        final mode = entry.key;
                        final name = entry.value;
                        final selected = _pageMode == mode;
                        return GestureDetector(
                          onTap: () {
                            setState(() => _pageMode = mode);
                            _saveSettings();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: selected ? Colors.indigo : _theme.surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: selected ? Colors.indigo : _theme.border,
                              ),
                            ),
                            child: Text(
                              name,
                              style: TextStyle(
                                color: selected ? Colors.white : _theme.text,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              // ── 主题选择 ──
              Row(
                children: [
                  Text('主题', style: TextStyle(color: _theme.hint, fontSize: 13)),
                  const SizedBox(width: 16),
                  ..._themes.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final t = entry.value;
                    final selected = _readingTheme == idx;
                    return GestureDetector(
                      onTap: () {
                        setState(() => _readingTheme = idx);
                        _saveSettings();
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 10),
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: t.bg,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? Colors.indigo : t.border,
                            width: selected ? 2.5 : 1,
                          ),
                        ),
                        child: selected
                            ? Icon(Icons.check, size: 18, color: t.text)
                            : null,
                      ),
                    );
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingRow({
    required String label,
    required String value,
    required double sliderValue,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required VoidCallback onDecrease,
    required VoidCallback onIncrease,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 32,
          child: Text(label, style: TextStyle(color: _theme.hint, fontSize: 13)),
        ),
        IconButton(
          icon: Icon(Icons.remove_circle_outline, size: 18, color: _theme.hint),
          onPressed: onDecrease,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
        ),
        Expanded(
          child: Slider(
            value: sliderValue,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            activeColor: Colors.indigo,
            inactiveColor: _theme.border,
            thumbColor: Colors.indigo,
          ),
        ),
        IconButton(
          icon: Icon(Icons.add_circle_outline, size: 18, color: _theme.hint),
          onPressed: onIncrease,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
        ),
        SizedBox(
          width: 32,
          child: Text(
            value,
            style: TextStyle(color: _theme.text, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildPageHint() {
    return Positioned(
      bottom: 12,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.25),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '${(_progress * 100).toStringAsFixed(1)}%',
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w400),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// 选区工具栏（Overlay 浮层）
// ─────────────────────────────────────────────────────────────

class _SelectionToolbar extends StatelessWidget {
  final Offset anchor;
  final String preview;
  final Future<void> Function(int colorIndex) onSelectColor;
  final Future<void> Function() onAddNote;
  final VoidCallback onCopy;
  final VoidCallback onCancel;

  const _SelectionToolbar({
    required this.anchor,
    required this.preview,
    required this.onSelectColor,
    required this.onAddNote,
    required this.onCopy,
    required this.onCancel,
  });

  static const _colorArgs = <int>[0xFFFFEB3B, 0xFFA5D6A7, 0xFF90CAF9, 0xFFEF9A9A, 0xFFCE93D8];

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final top = (anchor.dy - 110).clamp(mq.padding.top + 8.0, mq.size.height - 160);

    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: Center(
        child: Material(
          elevation: 8,
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2C),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 5 色高亮
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < _colorArgs.length; i++)
                      GestureDetector(
                        onTap: () => onSelectColor(HighlightColors.colorToIndex(_colorArgs[i])),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: Color(_colorArgs[i]).withOpacity(0.55),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24, width: 1.5),
                          ),
                        ),
                      ),
                    const SizedBox(width: 8),
                    Container(width: 1, height: 24, color: Colors.white24),
                    const SizedBox(width: 8),
                    _iconBtn(Icons.note_add, '笔记', onAddNote),
                    _iconBtn(Icons.copy, '复制', onCopy),
                    _iconBtn(Icons.close, '取消', onCancel),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}
