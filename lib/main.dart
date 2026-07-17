import 'package:flutter/material.dart';

import 'pages/bookshelf_page.dart';
import 'pages/reader_page.dart';
import 'services/bookshelf_service.dart';

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

class YueDuApp extends StatelessWidget {
  final String? openBookTitle;
  const YueDuApp({super.key, this.openBookTitle});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '阅界',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (openBookTitle != null) {
      final books = BookshelfService.instance.books;
      final book = books.firstWhere(
        (b) => b.title == openBookTitle,
        orElse: () => books.first,
      );
      return ReaderPage(book: book);
    }
    return const BookshelfPage();
  }
}
