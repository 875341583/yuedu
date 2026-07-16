/// 阅读页面：使用排版引擎渲染书籍内容
/// 支持大文件按需加载——不再一次性读取全文，而是按字节窗口读取
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';
import '../services/bookshelf_service.dart';
import '../typeset/types.dart';
import '../typeset/typeset_engine_provider.dart';
import '../widgets/typeset_renderer.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class ReaderPage extends StatefulWidget {
  final Book book;

  const ReaderPage({super.key, required this.book});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  /// 文本窗口：当前加载的文本块（约32KB字符）
  String _textWindow = '';

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

  /// 是否为深色模式
  bool _darkMode = false;

  /// 是否显示菜单栏
  bool _showMenu = false;

  /// 是否显示设置面板
  bool _showSettings = false;

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

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadContent();
  }

  @override
  void dispose() {
    _savePosition();
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
    final availableWidth = pageSize.width - 32;
    final availableHeight = pageSize.height - safePadding.top - safePadding.bottom - 96;

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
          color: _bgColor,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('正在打开书籍...', style: TextStyle(color: _hintColor, fontSize: 14)),
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
          color: _bgColor,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
                  const SizedBox(height: 16),
                  Text('打开失败', style: TextStyle(color: _textColor, fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(_loadError!, style: TextStyle(color: _hintColor, fontSize: 12), textAlign: TextAlign.center),
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
      // 窗口已到末尾，但大文件还有更多内容
      _nextPageOffset = _textWindow.length; // 标记需要加载新窗口
    } else {
      _nextPageOffset = -1; // 没有下一页
    }

    return Scaffold(
      body: KeyboardListener(
        focusNode: FocusNode(),
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
              Navigator.of(context).pop();
            }
          }
        },
        child: Stack(
          children: [
            // 主阅读区域
            Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _handleTap,
                    onHorizontalDragEnd: _handleSwipe,
                    child: Container(
                      color: _bgColor,
                      padding: EdgeInsets.only(
                        top: safePadding.top + 8,
                        left: 16,
                        right: 16,
                        bottom: 8,
                      ),
                      child: Column(
                        children: [
                          if (_showSettings) _buildSettingsPanel(),
                          Expanded(
                            child: SingleChildScrollView(
                              child: TypesetRendererWidget(
                                result: _currentPage!.result,
                                config: _config,
                                textColor: _textColor,
                                bgColor: _bgColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // 底部导航栏
                _buildBottomBar(),
              ],
            ),

            // 顶部菜单栏
            if (_showMenu) _buildTopBar(),

            // 页面指示器
            _buildPageHint(),

            // 翻页加载遮罩
            if (showPagingOverlay)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black.withOpacity(0.1),
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

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
        _showSettings = false;
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

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top,
          left: 8,
          right: 8,
          bottom: 8,
        ),
        decoration: BoxDecoration(
          color: _surfaceColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_darkMode ? 0.3 : 0.1),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back, color: _textColor),
              onPressed: () => Navigator.of(context).pop(),
              tooltip: '返回',
            ),
            Expanded(
              child: Text(
                widget.book.title,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _textColor),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _engineName,
                style: TextStyle(fontSize: 10, color: Colors.indigo.shade700, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              icon: Icon(Icons.settings, color: _textColor),
              onPressed: () => setState(() {
                _showSettings = !_showSettings;
                _showMenu = false;
              }),
              tooltip: '排版设置',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageHint() {
    return Positioned(
      bottom: 56,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '${(_progress * 100).toStringAsFixed(0)}%',
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      ),
    );
  }

  void _nextPage() {
    if (_isPaging) return; // 防止重复触发

    // 检查是否需要加载新窗口
    if (_nextPageOffset == _textWindow.length && _isLargeFile) {
      // 需要加载下一个窗口
      _loadNextWindow();
      return;
    }

    if (_nextPageOffset > 0 && _nextPageOffset < _textWindow.length) {
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
      // 在窗口开头，需要加载上一个窗口
      if (_isLargeFile && _byteOffset > 0) {
        _loadPrevWindow();
      }
      return;
    }

    final currentPageChars = _currentPage != null
        ? _currentPage!.endOffset - _currentPage!.startOffset
        : 200;
    final prevOffset = (_offset - (currentPageChars * 1.5).floor()).clamp(0, _textWindow.length);
    setState(() {
      _offset = prevOffset;
    });
    _savePosition();
  }

  // 深色模式颜色
  Color get _bgColor => _darkMode ? const Color(0xFF1A1A2E) : Colors.white;
  Color get _textColor => _darkMode ? const Color(0xFFE0E0E0) : Colors.black;
  Color get _surfaceColor => _darkMode ? const Color(0xFF252540) : Colors.white;
  Color get _panelColor => _darkMode ? const Color(0xFF2A2A45) : Colors.grey.shade50;
  Color get _borderColor => _darkMode ? const Color(0xFF3A3A55) : Colors.grey.shade300;
  Color get _hintColor => _darkMode ? const Color(0xFF888899) : Colors.grey.shade600;

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
      final darkMode = prefs.getBool(_kDarkModeKey) ?? false;
      if (mounted) {
        setState(() {
          _config = TypesetConfig(
            fontSize: fontSize,
            lineHeightRatio: lineHeight,
            containerWidth: _config.containerWidth,
            fontFamily: _config.fontFamily,
          );
          _darkMode = darkMode;
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
      await prefs.setBool(_kDarkModeKey, _darkMode);
    } catch (_) {}
  }

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

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _surfaceColor,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(_darkMode ? 0.3 : 0.05), blurRadius: 4, offset: const Offset(0, -2))],
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios, size: 18),
            onPressed: _hasPrevPage ? _prevPage : null,
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: _darkMode ? const Color(0xFF3A3A55) : Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation(Colors.indigo),
                ),
                const SizedBox(height: 2),
                Text(
                  '${(_progress * 100).toStringAsFixed(1)}%',
                  style: TextStyle(fontSize: 10, color: _hintColor),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward_ios, size: 18),
            onPressed: _hasNextPage ? _nextPage : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _panelColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('排版设置', style: TextStyle(color: _textColor, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('字号: '),
              Expanded(
                child: Slider(
                  value: _config.fontSize,
                  min: 12,
                  max: 28,
                  divisions: 8,
                  label: _config.fontSize.toStringAsFixed(0),
                  onChanged: (v) => setState(() {
                    _config = TypesetConfig(
                      fontSize: v,
                      lineHeightRatio: _config.lineHeightRatio,
                      containerWidth: _config.containerWidth,
                      fontFamily: _config.fontFamily,
                    );
                    _saveSettings();
                  }),
                ),
              ),
              Text(_config.fontSize.toStringAsFixed(0)),
            ],
          ),
          Row(
            children: [
              const Text('行高: '),
              Expanded(
                child: Slider(
                  value: _config.lineHeightRatio,
                  min: 1.2,
                  max: 2.5,
                  divisions: 13,
                  label: _config.lineHeightRatio.toStringAsFixed(1),
                  onChanged: (v) => setState(() {
                    _config = TypesetConfig(
                      fontSize: _config.fontSize,
                      lineHeightRatio: v,
                      containerWidth: _config.containerWidth,
                      fontFamily: _config.fontFamily,
                    );
                    _saveSettings();
                  }),
                ),
              ),
              Text(_config.lineHeightRatio.toStringAsFixed(1)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('深色模式: ', style: TextStyle(color: _textColor)),
              Switch(
                value: _darkMode,
                onChanged: (v) => setState(() {
                  _darkMode = v;
                  _saveSettings();
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
