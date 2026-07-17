/// 阅读页面：使用排版引擎渲染书籍内容
/// 支持大文件按需加载——不再一次性读取全文，而是按字节窗口读取
/// 支持翻页动画、阅读主题、可调边距、进度拖拽跳转、鼠标滚轮翻页
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';

import '../models/book.dart';
import '../models/bookmark.dart';
import '../services/bookshelf_service.dart';
import '../services/bookmark_service.dart';
import '../typeset/types.dart';
import '../typeset/typeset_engine_provider.dart';
import '../utils/chapter_parser.dart';
import '../widgets/typeset_renderer.dart';
import '../widgets/toc_bookmark_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _ReaderPageState extends State<ReaderPage> {
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

  /// 拖拽进度时临时值（null=未在拖拽）
  double? _seekProgress;

  /// 书签列表
  List<Bookmark> _bookmarks = [];

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
    _loadSettings();
    _loadContent();
    _loadBookmarks();
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
    _focusNode.dispose();
    super.dispose();
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
    final result = engine.typeset(text, _config);

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
                onHorizontalDragEnd: _handleSwipe,
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
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: _buildPageTransition,
                      child: _buildPageContent(availableHeight),
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

  // ─── 翻页过渡动画 ────────────────────────────────────────

  Widget _buildPageTransition(Widget child, Animation<double> animation) {
    final isNew = child.key == ValueKey(_offset);
    final dir = _pageDirection.toDouble();

    // 新页：从方向滑入；旧页：向相反方向滑出
    final tween = isNew
        ? Tween<Offset>(begin: Offset(dir, 0), end: Offset.zero)
        : Tween<Offset>(begin: Offset.zero, end: Offset(-dir, 0));

    return SlideTransition(
      position: tween.animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: FadeTransition(opacity: animation, child: child),
    );
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
      ),
    );
  }

  // ─── 交互处理 ────────────────────────────────────────────

  void _handleTap(TapUpDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    final dx = details.localPosition.dx;

    if (dx < screenWidth / 3) {
      _prevPage();
    } else if (dx > screenWidth * 2 / 3) {
      _nextPage();
    } else {
      setState(() {
        _showMenu = !_showMenu;
        if (!_showMenu) _showSettings = false;
      });
    }
  }

  void _handleSwipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -300) {
      _nextPage();
    } else if (velocity > 300) {
      _prevPage();
    }
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TocBookmarkPanel(
        book: widget.book,
        chapters: widget.book.chapters,
        bookmarks: _bookmarks,
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
