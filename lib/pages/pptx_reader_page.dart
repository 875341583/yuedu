/// PPTX 阅读页面
///
/// PPTX 文件按幻灯片原始顺序逐页展示，每页提取所有 <a:t> 文本。
/// 进入时强制横屏（更符合 PPT 16:9 比例），离开时恢复方向。
/// 跟手 PageView 翻页，支持页码滑块与持久化。
/// 与排版阅读页、PDF 阅读页并列：PPTX 书走本页。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../services/bookshelf_service.dart';
import '../services/file_service.dart';
import '../utils/pptx_text_extractor.dart' deferred as pptx;

const _kPptxPagePrefix = 'yuedu_pptx_page_';

class PptxReaderPage extends StatefulWidget {
  final Book book;

  const PptxReaderPage({super.key, required this.book});

  @override
  State<PptxReaderPage> createState() => _PptxReaderPageState();
}

class _PptxReaderPageState extends State<PptxReaderPage> {
  /// PptxSlides 实例（deferred 加载，类型运行时确定）
  dynamic _slides;
  String? _error;
  bool _loading = true;

  /// 是否显示菜单
  bool _showMenu = false;

  /// 当前页码（1-based）
  int _currentPage = 1;

  PageController? _controller;

  /// 拖拽滑块的临时进度
  double? _seekProgress;

  @override
  void initState() {
    super.initState();
    // PPT 强制横屏显示
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initAsync();
  }

  Future<void> _initAsync() async {
    try {
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
      final target0 = (savedPage - 1).clamp(0, total > 0 ? total - 1 : 0).toInt();
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

  Future<int> _loadSavedPage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final page = prefs.getInt('$_kPptxPagePrefix${widget.book.id}') ?? 1;
      return page < 1 ? 1 : page;
    } catch (_) {
      return 1;
    }
  }

  Future<void> _persistPage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$_kPptxPagePrefix${widget.book.id}', _currentPage);
      final total = _slides?.pageCount ?? 0;
      if (total > 0) {
        try {
          BookshelfService.instance.updateReadPosition(widget.book.id, _currentPage);
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
    _controller?.animateToPage(
      page - 1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _persistPage();
    _controller?.dispose();
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
          Positioned.fill(
            child: GestureDetector(
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
            ),
          ),
          if (_showMenu) _buildTopBar(),
          if (_showMenu) _buildBottomBar(),
          if (!_showMenu) _buildPageHint(),
        ],
      ),
    );
  }

  /// 渲染单张幻灯片（白纸式排版，文本居中自适应）
  Widget _buildSlide(String text) {
    return Container(
      margin: const EdgeInsets.all(24),
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4)),
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
            '$_currentPage / $total  ($percent%)',
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
