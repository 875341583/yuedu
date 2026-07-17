import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'models/book.dart';
import 'pages/bookshelf_page.dart';
import 'pages/reader_page.dart';
import 'services/bookshelf_service.dart';

// 临时截图/命令路径（调试用，发布时清理）
const _tempDir = r'C:\Users\Administrator\Desktop\TeleAgent的工作空间\.temp';
const _screenshotTrigger = '$_tempDir\\screenshot_trigger.txt';
const _screenshotOutput = '$_tempDir\\flutter_screenshot.png';
const _commandFile = '$_tempDir\\command.txt';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 命令行参数 --open-book=书名：直接打开某本书（支持桌面快捷方式/深链接）
  String? openBookTitle;
  for (final arg in args) {
    if (arg.startsWith('--open-book=')) {
      openBookTitle = arg.substring('--open-book='.length);
    }
  }

  await BookshelfService.instance.loadFromStorage();
  runApp(YueDuApp(openBookTitle: openBookTitle));
}

class YueDuApp extends StatefulWidget {
  final String? openBookTitle;
  const YueDuApp({super.key, this.openBookTitle});

  @override
  State<YueDuApp> createState() => _YueDuAppState();
}

class _YueDuAppState extends State<YueDuApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _screenshotBoundaryKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 启动截图和命令轮询
    _startPolling();
  }

  void _startPolling() {
    Future.delayed(const Duration(seconds: 2), () {
      _pollScreenshot();
      _pollCommand();
    });
  }

  void _pollScreenshot() {
    Future.delayed(const Duration(milliseconds: 500), () {
      try {
        final file = File(_screenshotTrigger);
        if (file.existsSync()) {
          final content = file.readAsStringSync().trim();
          file.deleteSync();
          _takeScreenshot(content);
        }
      } catch (_) {}
      _pollScreenshot();
    });
  }

  void _pollCommand() {
    Future.delayed(const Duration(milliseconds: 500), () {
      try {
        final file = File(_commandFile);
        if (file.existsSync()) {
          final cmd = file.readAsStringSync().trim();
          file.deleteSync();
          _executeCommand(cmd);
        }
      } catch (_) {}
      _pollCommand();
    });
  }

  void _executeCommand(String cmd) {
    debugPrint('Command received: $cmd');
    if (cmd.startsWith('import_mobi:')) {
      final path = cmd.substring('import_mobi:'.length);
      _importMobiFile(path);
    } else if (cmd.startsWith('open_book:')) {
      final title = cmd.substring('open_book:'.length);
      _openBookByTitle(title);
    }
  }

  Future<void> _importMobiFile(String path) async {
    try {
      final book = await BookshelfService.instance.importMobi(path);
      if (book != null) {
        debugPrint('MOBI imported: ${book.title}');
      } else {
        debugPrint('MOBI import failed');
      }
    } catch (e) {
      debugPrint('MOBI import error: $e');
    }
  }

  void _openBookByTitle(String title) {
    final books = BookshelfService.instance.books;
    final book = books.firstWhere(
      (b) => b.title == title,
      orElse: () => books.first,
    );
    final context = _navigatorKey.currentContext;
    if (context != null) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReaderPage(book: book)),
      );
    }
  }

  Future<void> _takeScreenshot(String tag) async {
    try {
      final context = _navigatorKey.currentContext;
      if (context == null) return;

      final boundary = _screenshotBoundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        debugPrint('Screenshot: boundary is null');
        return;
      }

      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final buffer = byteData.buffer.asUint8List();
      File(_screenshotOutput).writeAsBytesSync(buffer);
      debugPrint('Screenshot saved: $_screenshotOutput (tag: $tag)');
    } catch (e) {
      debugPrint('Screenshot error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _screenshotBoundaryKey,
      child: MaterialApp(
        title: '阅界',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        navigatorKey: _navigatorKey,
        home: _buildHome(),
      ),
    );
  }

  Widget _buildHome() {
    if (widget.openBookTitle != null) {
      final books = BookshelfService.instance.books;
      final book = books.firstWhere(
        (b) => b.title == widget.openBookTitle,
        orElse: () => books.first,
      );
      return ReaderPage(book: book);
    }
    return const BookshelfPage();
  }
}
