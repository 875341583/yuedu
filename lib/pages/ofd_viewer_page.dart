/// OFD 原版式阅读页面
///
/// 使用 liteofd JavaScript 库在 WebView 中渲染 OFD 文件原版式。
/// 支持：滚动浏览、缩放、分页跳转、横屏模式。
/// 字体和 JS 库打包在 assets/ofd_viewer/ 中。
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';

/// 屏幕方向模式
enum OfdOrientationMode {
  auto,
  landscape,
  portrait,
}

const _ofdOrientNames = <OfdOrientationMode, String>{
  OfdOrientationMode.auto: '自动',
  OfdOrientationMode.landscape: '横屏',
  OfdOrientationMode.portrait: '竖屏',
};

const _kOfdOrientKey = 'yuedu_ofd_orient_mode';

class OfdViewerPage extends StatefulWidget {
  final Book book;

  const OfdViewerPage({super.key, required this.book});

  @override
  State<OfdViewerPage> createState() => _OfdViewerPageState();
}

class _OfdViewerPageState extends State<OfdViewerPage>
    with WidgetsBindingObserver {
  InAppWebViewController? _webController;
  final GlobalKey _webViewKey = GlobalKey();

  /// 是否显示顶/底菜单栏
  bool _showMenu = false;

  /// 当前页码（1-based）
  int _currentPage = 1;

  /// 总页数
  int _totalPages = 0;

  /// 是否正在加载
  bool _isLoading = true;

  /// 加载错误信息
  String? _errorMessage;

  /// WebView 资源是否已解压就绪
  bool _assetsReady = false;

  /// 解压后的 HTML 文件路径
  String? _viewerHtmlPath;

  /// 方向模式
  OfdOrientationMode _orientMode = OfdOrientationMode.auto;

  /// 是否已初始化
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAsync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _applyOrientation(OfdOrientationMode.auto);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 屏幕旋转后触发重绘
    if (mounted) setState(() {});
  }

  Future<void> _initAsync() async {
    await _loadSettings();
    await _applyOrientation(_orientMode);
    await _prepareWebViewAssets();
    if (mounted) setState(() => _initialized = true);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final orientIndex = prefs.getInt(_kOfdOrientKey) ?? 0;
    _orientMode = OfdOrientationMode.values[orientIndex.clamp(0, 2)];
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kOfdOrientKey, _orientMode.index);
  }

  Future<void> _applyOrientation(OfdOrientationMode mode) async {
    switch (mode) {
      case OfdOrientationMode.auto:
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        break;
      case OfdOrientationMode.landscape:
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        break;
      case OfdOrientationMode.portrait:
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
        break;
    }
  }

  /// 将 assets/ofd_viewer/ 中的所有资源解压到临时目录，
  /// 使 WebView 能通过 file:// 访问 HTML、JS 和字体文件。
  Future<void> _prepareWebViewAssets() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final viewerDir = '${tempDir.path}/ofd_viewer';

      // 创建目录结构
      await Directory('$viewerDir/assets/fonts').create(recursive: true);

      // 1. 复制 index.html
      final htmlContent =
          await rootBundle.loadString('assets/ofd_viewer/index.html');
      await File('$viewerDir/index.html').writeAsString(htmlContent);

      // 2. 复制 liteofd.js（二进制方式）
      final jsData = await rootBundle.load('assets/ofd_viewer/liteofd.js');
      await File('$viewerDir/liteofd.js')
          .writeAsBytes(jsData.buffer.asUint8List());

      // 3. 复制所有字体文件
      final manifestContent =
          await rootBundle.loadString('AssetManifest.json');
      final manifest = jsonDecode(manifestContent) as Map<String, dynamic>;
      final fontAssets = manifest.keys
          .where((key) => key.startsWith('assets/ofd_viewer/fonts/'))
          .toList();

      for (final fontAsset in fontAssets) {
        final fontName = fontAsset.split('/').last;
        final fontData = await rootBundle.load(fontAsset);
        await File('$viewerDir/assets/fonts/$fontName')
            .writeAsBytes(fontData.buffer.asUint8List());
      }

      _viewerHtmlPath = '$viewerDir/index.html';

      if (mounted) setState(() => _assetsReady = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '资源准备失败: $e';
          _isLoading = false;
        });
      }
    }
  }

  /// 读取并加载 OFD 文件
  Future<void> _loadOfdFile() async {
    if (_webController == null) return;

    try {
      final file = File(widget.book.filePath);
      if (!await file.exists()) {
        setState(() {
          _errorMessage = '文件不存在: ${widget.book.filePath}';
          _isLoading = false;
        });
        return;
      }

      final bytes = await file.readAsBytes();
      final base64Data = base64Encode(bytes);

      // 通过 evaluateJavascript 传递 base64 数据
      await _webController!.evaluateJavascript(
        source: 'window.loadOfdFromBase64("$base64Data");',
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '加载文件失败: $e';
          _isLoading = false;
        });
      }
    }
  }

  /// 处理来自 JS 通道的消息
  void _handleJsMessage(List<dynamic> args) {
    if (args.isEmpty) return;
    try {
      final data = jsonDecode(args.first.toString()) as Map<String, dynamic>;
      final type = data['type'] as String;

      switch (type) {
        case 'ready':
          // JS 就绪，加载 OFD 文件
          break;
        case 'renderComplete':
          if (mounted) {
            setState(() {
              _isLoading = false;
              _totalPages = (data['totalPages'] as num?)?.toInt() ?? 0;
              _currentPage = (data['currentPage'] as num?)?.toInt() ?? 1;
            });
          }
          break;
        case 'pageChange':
          if (mounted) {
            setState(() {
              _currentPage = (data['currentPage'] as num?)?.toInt() ?? 1;
              _totalPages = (data['totalPages'] as num?)?.toInt() ?? 0;
            });
          }
          break;
        case 'error':
          if (mounted) {
            setState(() {
              _isLoading = false;
              _errorMessage = data['message'] as String? ?? '未知错误';
            });
          }
          break;
      }
    } catch (e) {
      // 忽略解析错误
    }
  }

  // ─── 控制方法 ──────────────────────────────────────────────

  void _nextPage() {
    _webController?.evaluateJavascript(source: 'window.ofdNextPage();');
  }

  void _prevPage() {
    _webController?.evaluateJavascript(source: 'window.ofdPrevPage();');
  }

  void _goToPage(int page) {
    _webController?.evaluateJavascript(source: 'window.ofdGoToPage($page);');
  }

  void _zoomIn() {
    _webController?.evaluateJavascript(source: 'window.ofdZoomIn();');
  }

  void _zoomOut() {
    _webController?.evaluateJavascript(source: 'window.ofdZoomOut();');
  }

  void _resetZoom() {
    _webController?.evaluateJavascript(source: 'window.ofdResetZoom();');
  }

  /// 跳转到指定页码（弹出输入框）
  Future<void> _showPageInputDialog() async {
    if (_totalPages == 0) return;
    final controller = TextEditingController(text: '$_currentPage');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳转到页'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '1 - $_totalPages',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            final page = int.tryParse(value);
            if (page != null && page >= 1 && page <= _totalPages) {
              Navigator.of(ctx).pop(page);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final page = int.tryParse(controller.text);
              if (page != null && page >= 1 && page <= _totalPages) {
                Navigator.of(ctx).pop(page);
              }
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    if (result != null && result != _currentPage) {
      _goToPage(result);
    }
  }

  /// 显示方向选择菜单
  void _showOrientationMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('屏幕方向', style: TextStyle(fontSize: 16)),
            ),
            ...OfdOrientationMode.values.map((mode) {
              return RadioListTile<OfdOrientationMode>(
                value: mode,
                groupValue: _orientMode,
                title: Text(_ofdOrientNames[mode]!),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _orientMode = value);
                    _applyOrientation(value);
                    _saveSettings();
                    Navigator.of(ctx).pop();
                  }
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        onTap: () => setState(() => _showMenu = !_showMenu),
        child: Stack(
          children: [
            // WebView 主体
            if (_initialized && _assetsReady && _viewerHtmlPath != null)
              _buildWebView()
            else
              _buildLoadingView(),

            // 顶部菜单栏
            if (_showMenu && !_isLoading)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildTopBar(context),
              ),

            // 底部菜单栏
            if (_showMenu && !_isLoading && _totalPages > 0)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildBottomBar(context),
              ),

            // 加载指示器
            if (_isLoading)
              Positioned.fill(
                child: Container(
                  color: Colors.white70,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          _errorMessage ?? '正在加载OFD文件...',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: _webViewKey,
      initialUrlRequest: URLRequest(
        url: WebUri('file://$_viewerHtmlPath'),
      ),
      initialSettings: InAppWebViewSettings(
        allowFileAccess: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        javaScriptEnabled: true,
        useHybridComposition: true,
        supportZoom: false,
        builtInZoomControls: false,
        displayZoomControls: false,
      ),
      onWebViewCreated: (controller) {
        _webController = controller;
        controller.addJavaScriptHandler(
          handlerName: 'OFDChannel',
          callback: _handleJsMessage,
        );
      },
      onLoadStop: (controller, url) async {
        // 页面加载完成后，加载 OFD 文件
        await _loadOfdFile();
      },
      onConsoleMessage: (controller, consoleMessage) {
        // 仅打印 error 级别
        if (consoleMessage.messageLevel == ConsoleMessageLevel.ERROR) {
          debugPrint('OFD WebView: ${consoleMessage.message}');
        }
      },
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _errorMessage ?? '正在准备阅读器...',
            style: const TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildTopBar(BuildContext context) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: Container(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
        child: SafeArea(
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  widget.book.title,
                  style: const TextStyle(fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.zoom_out),
                onPressed: _zoomOut,
                tooltip: '缩小',
              ),
              IconButton(
                icon: const Icon(Icons.zoom_in),
                onPressed: _zoomIn,
                tooltip: '放大',
              ),
              IconButton(
                icon: const Icon(Icons.center_focus_strong),
                onPressed: _resetZoom,
                tooltip: '重置缩放',
              ),
              IconButton(
                icon: const Icon(Icons.screen_rotation),
                onPressed: _showOrientationMenu,
                tooltip: '屏幕方向',
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.first_page),
                onPressed: _currentPage > 1 ? () => _goToPage(1) : null,
                tooltip: '首页',
              ),
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _currentPage > 1 ? _prevPage : null,
                tooltip: '上一页',
              ),
              Expanded(
                child: GestureDetector(
                  onTap: _showPageInputDialog,
                  child: Center(
                    child: Text(
                      '$_currentPage / $_totalPages',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed:
                    _currentPage < _totalPages ? _nextPage : null,
                tooltip: '下一页',
              ),
              IconButton(
                icon: const Icon(Icons.last_page),
                onPressed:
                    _currentPage < _totalPages ? () => _goToPage(_totalPages) : null,
                tooltip: '末页',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
