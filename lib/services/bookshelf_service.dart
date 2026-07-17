/// 书库服务：管理书籍的导入、存储、读取
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../utils/encoding.dart';
import 'epub_parser.dart' deferred as epub;
import 'pdf_parser.dart';
import 'mobi_parser.dart';
import 'file_service.dart';

/// 书库服务（单例）
class BookshelfService {
  static final BookshelfService _instance = BookshelfService._();
  static BookshelfService get instance => _instance;
  BookshelfService._();

  static const _kBooksKey = 'yuedu_books';
  static const _kPositionsKey = 'yuedu_positions';
  static const _kContentKeyPrefix = 'yuedu_content_';
  static const _kVersionKey = 'yuedu_version';

  /// 当前数据版本，升级时递增，用于触发数据迁移
  static const _currentVersion = 4;

  /// 内存中的书库
  final List<Book> _books = [];

  /// 是否已从持久化加载
  bool _loaded = false;

  /// 获取所有书籍
  List<Book> get books => List.unmodifiable(_books);

  /// 书库变更回调
  final List<void Function()> _listeners = [];

  /// 添加变更监听
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// 移除变更监听
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// 从SharedPreferences加载书库数据
  Future<void> loadFromStorage() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final prefs = await SharedPreferences.getInstance();

      // 加载书籍列表
      final booksJson = prefs.getString(_kBooksKey);
      if (booksJson != null) {
        try {
          final list = jsonDecode(booksJson) as List;
          _books.clear();
          for (final item in list) {
            try {
              final book = Book.fromMap(item as Map<String, dynamic>);
              _books.add(book);
            } catch (_) {
              // 单本书反序列化失败不影响其他书
            }
          }
        } catch (_) {}
      }

      // 加载阅读位置
      final positionsJson = prefs.getString(_kPositionsKey);
      if (positionsJson != null) {
        try {
          final map = jsonDecode(positionsJson) as Map<String, dynamic>;
          for (final book in _books) {
            if (map.containsKey(book.id)) {
              book.lastPosition = map[book.id] as int;
            }
          }
        } catch (_) {}
      }
    } catch (_) {
      // SharedPreferences不可用时，继续使用内存数据
    }

    // 合并种子书籍（真书 + 演示书），确保新增的种子书不会因旧数据遗漏
    _mergeSeedBooks();

    _notifyListeners();
  }

  /// 保存书库到SharedPreferences
  Future<void> _saveToStorage() async {
    final prefs = await SharedPreferences.getInstance();

    // 保存书籍列表
    final booksJson = jsonEncode(_books.map((b) => b.toMap()).toList());
    await prefs.setString(_kBooksKey, booksJson);

    // 保存阅读位置
    final positionsMap = <String, int>{};
    for (final book in _books) {
      if (book.lastPosition > 0) {
        positionsMap[book.id] = book.lastPosition;
      }
    }
    await prefs.setString(_kPositionsKey, jsonEncode(positionsMap));
  }

  /// 保存内容缓存到SharedPreferences（Web平台需要）
  Future<void> _saveContentCache(String bookId, String content) async {
    final prefs = await SharedPreferences.getInstance();
    // SharedPreferences有值大小限制，大文本不存（8KB限制）
    if (content.length > 8000) return;
    await prefs.setString('$_kContentKeyPrefix$bookId', content);
  }

  /// 从缓存加载内容
  Future<String?> _loadContentCache(String bookId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_kContentKeyPrefix$bookId');
  }

  /// 从内存内容直接创建书籍（Web平台/粘贴导入）
  Book importFromContent({required String title, required String content}) {
    final book = Book(
      id: 'book_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      author: '未知',
      filePath: '',
      format: BookFormat.txt,
      colorSeed: title.hashCode & 0xFFFF,
    );

    _contentCache[book.id] = content;
    _saveContentCache(book.id, content);

    _books.add(book);
    _saveToStorage();
    _notifyListeners();
    return book;
  }

  /// 内存内容缓存（用于Web平台和粘贴导入的书籍）
  final Map<String, String> _contentCache = {};

  /// 导入本地TXT文件（Native平台）
  Future<Book?> importTxt(String filePath) async {
    final exists = await FileService.fileExists(filePath);
    if (!exists) return null;

    final fileName = FileService.getFileName(filePath);
    final title = fileName.replaceAll(RegExp(r'\.\w+$'), '');

    final book = Book(
      id: 'book_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      author: '未知',
      filePath: filePath,
      format: BookFormat.txt,
      colorSeed: title.hashCode & 0xFFFF,
    );

    _books.add(book);
    _saveToStorage();
    _notifyListeners();
    return book;
  }

  /// 导入本地EPUB文件（Native平台）
  Future<Book?> importEpub(String filePath) async {
    final exists = await FileService.fileExists(filePath);
    if (!exists) return null;

    final fileName = FileService.getFileName(filePath);
    final title = fileName.replaceAll(RegExp(r'\.\w+$'), '');

    final book = Book(
      id: 'book_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      author: '未知',
      filePath: filePath,
      format: BookFormat.epub,
      colorSeed: title.hashCode & 0xFFFF,
    );

    _books.add(book);
    _saveToStorage();
    _notifyListeners();
    return book;
  }

  /// 导入本地PDF文件（Native平台）
  Future<Book?> importPdf(String filePath) async {
    final exists = await FileService.fileExists(filePath);
    if (!exists) return null;

    final fileName = FileService.getFileName(filePath);
    final title = fileName.replaceAll(RegExp(r'\.\w+$'), '');

    final book = Book(
      id: 'book_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      author: '未知',
      filePath: filePath,
      format: BookFormat.pdf,
      colorSeed: title.hashCode & 0xFFFF,
    );

    _books.add(book);
    _saveToStorage();
    _notifyListeners();
    return book;
  }

  /// 导入本地MOBI文件（Native平台）
  Future<Book?> importMobi(String filePath) async {
    final exists = await FileService.fileExists(filePath);
    if (!exists) return null;

    final fileName = FileService.getFileName(filePath);
    final title = fileName.replaceAll(RegExp(r'\.\w+$'), '');

    final book = Book(
      id: 'book_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      author: '未知',
      filePath: filePath,
      format: BookFormat.mobi,
      colorSeed: title.hashCode & 0xFFFF,
    );

    _books.add(book);
    _saveToStorage();
    _notifyListeners();
    return book;
  }

  /// 大文件阈值（字节）：超过此值则按需读取，不一次性加载全文
  static const _largeFileThreshold = 500 * 1024; // 500KB

  /// 大文件的字节偏移缓存：bookId -> 字节偏移量（用于进度计算）
  final Map<String, int> _byteOffsets = {};

  /// 大文件总字节数缓存：bookId -> 文件大小
  final Map<String, int> _fileSizes = {};

  /// EPUB解析结果缓存：bookId → 解析结果(dynamic，延迟加载后才有类型)
  final Map<String, dynamic> _epubCache = {};

  /// PDF解析结果缓存：bookId → 解析结果
  final Map<String, dynamic> _pdfCache = {};

  /// MOBI解析结果缓存：bookId → 解析结果
  final Map<String, dynamic> _mobiCache = {};

  /// 读取书籍全部文本内容（仅用于小文件和EPUB/PDF）
  Future<String> readContent(Book book) async {
    // EPUB格式：用EPUB解析器
    if (book.format == BookFormat.epub) {
      return _readEpubContent(book);
    }

    // PDF格式：用PDF解析器
    if (book.format == BookFormat.pdf) {
      return _readPdfContent(book);
    }

    // MOBI格式：用MOBI解析器
    if (book.format == BookFormat.mobi) {
      return _readMobiContent(book);
    }

    // 先检查内存缓存
    if (_contentCache.containsKey(book.id)) {
      return _contentCache[book.id]!;
    }

    // 尝试从SharedPreferences加载（小文件）
    final cached = await _loadContentCache(book.id);
    if (cached != null) {
      _contentCache[book.id] = cached;
      return cached;
    }

    // 演示书籍
    if (book.filePath.isEmpty) {
      return getDemoContent(book);
    }

    // 本地文件
    final exists = await FileService.fileExists(book.filePath);
    if (!exists) return '';

    try {
      final bytes = await FileService.readFileBytes(book.filePath);
      final content = await decodeTextBytesAsync(bytes);
      // 小文件才缓存
      if (bytes.length < _largeFileThreshold) {
        _contentCache[book.id] = content;
      }
      return content;
    } catch (e) {
      return '';
    }
  }

  /// 读取EPUB书籍内容
  Future<String> _readEpubContent(Book book) async {
    // 检查EPUB缓存
    if (_epubCache.containsKey(book.id)) {
      return (_epubCache[book.id] as dynamic).fullText as String;
    }

    // 检查文本缓存
    if (_contentCache.containsKey(book.id)) {
      return _contentCache[book.id]!;
    }

    if (book.filePath.isEmpty) return '';

    final exists = await FileService.fileExists(book.filePath);
    if (!exists) return '';

    try {
      // 延迟加载epub_parser模块（避免archive包在AOT模式下启动时初始化失败）
      await epub.loadLibrary();
      
      final bytes = await FileService.readFileBytes(book.filePath);
      final epubBook = epub.EpubParser.parse(bytes);
      _epubCache[book.id] = epubBook;

      // 更新章节信息
      if (book.chapters.isEmpty) {
        final chapters = (epubBook as dynamic).chapters as List;
        book.chapters = chapters.asMap().entries.map((e) {
          final ch = e.value as dynamic;
          return Chapter(
            title: ch.title as String,
            startOffset: ch.startOffset as int,
            endOffset: (ch.startOffset as int) + (ch.text as String).length,
          );
        }).toList();
        _saveToStorage();
      }

      return (epubBook as dynamic).fullText as String;
    } catch (e) {
      return '';
    }
  }

  /// 获取EPUB解析结果（含章节信息）
  Future<dynamic> getEpubBook(Book book) async {
    if (book.format != BookFormat.epub) return null;
    if (_epubCache.containsKey(book.id)) {
      return _epubCache[book.id];
    }
    // 触发解析
    await _readEpubContent(book);
    return _epubCache[book.id];
  }

  /// 读取PDF书籍内容
  Future<String> _readPdfContent(Book book) async {
    // 检查PDF缓存
    if (_pdfCache.containsKey(book.id)) {
      return (_pdfCache[book.id] as dynamic).fullText as String;
    }

    // 检查文本缓存
    if (_contentCache.containsKey(book.id)) {
      return _contentCache[book.id]!;
    }

    if (book.filePath.isEmpty) return '';

    final exists = await FileService.fileExists(book.filePath);
    if (!exists) return '';

    try {
      final pdfBook = await PdfParser.parse(book.filePath);
      if (pdfBook == null) {
        throw Exception('PDF文本提取失败，当前设备可能不支持此格式');
      }

      _pdfCache[book.id] = pdfBook;

      // 更新章节信息
      if (book.chapters.isEmpty) {
        book.chapters = pdfBook.chapters;
        _saveToStorage();
      }

      // 缓存全文
      _contentCache[book.id] = pdfBook.fullText;

      return pdfBook.fullText;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('PDF解析异常: $e');
    }
  }

  /// 获取PDF解析结果
  Future<dynamic> getPdfBook(Book book) async {
    if (book.format != BookFormat.pdf) return null;
    if (_pdfCache.containsKey(book.id)) {
      return _pdfCache[book.id];
    }
    await _readPdfContent(book);
    return _pdfCache[book.id];
  }

  /// 读取MOBI书籍内容
  Future<String> _readMobiContent(Book book) async {
    // 检查MOBI缓存
    if (_mobiCache.containsKey(book.id)) {
      return (_mobiCache[book.id] as dynamic).fullText as String;
    }

    // 检查文本缓存
    if (_contentCache.containsKey(book.id)) {
      return _contentCache[book.id]!;
    }

    if (book.filePath.isEmpty) return '';

    final exists = await FileService.fileExists(book.filePath);
    if (!exists) return '';

    try {
      final mobiBook = await MobiParser.parse(book.filePath);
      if (mobiBook == null) {
        throw Exception('MOBI文本提取失败，当前设备可能不支持此格式');
      }

      _mobiCache[book.id] = mobiBook;

      // 更新章节信息
      if (book.chapters.isEmpty) {
        book.chapters = mobiBook.chapters;
        _saveToStorage();
      }

      // 缓存全文
      _contentCache[book.id] = mobiBook.fullText;

      return mobiBook.fullText;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('MOBI解析异常: $e');
    }
  }

  /// 获取MOBI解析结果
  Future<dynamic> getMobiBook(Book book) async {
    if (book.format != BookFormat.mobi) return null;
    if (_mobiCache.containsKey(book.id)) {
      return _mobiCache[book.id];
    }
    await _readMobiContent(book);
    return _mobiCache[book.id];
  }

  /// 判断书籍是否为大文件（需要按需加载）
  /// EPUB、PDF和MOBI文件不按字节窗口加载，解析后全文在内存中
  Future<bool> isLargeFile(Book book) async {
    if (book.filePath.isEmpty) return false;
    if (book.format == BookFormat.epub) return false;
    if (book.format == BookFormat.pdf) return false;
    if (book.format == BookFormat.mobi) return false;
    final size = await getBookFileSize(book);
    return size >= _largeFileThreshold;
  }

  /// 获取书籍文件总字节数
  Future<int> getBookFileSize(Book book) async {
    if (_fileSizes.containsKey(book.id)) {
      return _fileSizes[book.id]!;
    }
    if (book.filePath.isEmpty) return 0;
    final exists = await FileService.fileExists(book.filePath);
    if (!exists) return 0;
    final size = await FileService.fileSize(book.filePath);
    _fileSizes[book.id] = size;
    return size;
  }

  /// 按字节范围读取并解码文本窗口
  /// [byteOffset] 起始字节偏移
  /// [byteLength] 读取字节数
  /// 返回解码后的文本
  ///
  /// GBK边界处理：当byteOffset > 0时，读取位置可能落在GBK双字节字符中间，
  /// 导致窗口首字符乱码。通过_findCharBoundary向前扫描找到有效字符边界。
  Future<String> readTextWindow(Book book, int byteOffset, int byteLength) async {
    if (book.filePath.isEmpty) {
      // 演示书：从内存取
      final content = getDemoContent(book);
      // 演示书用字符偏移近似
      final charOffset = (byteOffset ~/ 3).clamp(0, content.length);
      final charLength = (byteLength ~/ 3).clamp(0, content.length - charOffset);
      return content.substring(charOffset, charOffset + charLength);
    }

    final exists = await FileService.fileExists(book.filePath);
    if (!exists) return '';

    try {
      int readOffset = byteOffset;

      // GBK边界处理：非文件起始位置时，找到有效的字符边界
      if (byteOffset > 0) {
        readOffset = await _findCharBoundary(book.filePath, byteOffset);
      }

      final bytes = await FileService.readFileRange(book.filePath, readOffset, byteLength);
      return await decodeTextBytesAsync(bytes);
    } catch (e) {
      return '';
    }
  }

  /// 查找给定偏移量处或之前最近的GBK字符边界
  /// 通过向前读取256字节，找到ASCII字节（保证是单字节字符）作为已知对齐点，
  /// 再从该点前向扫描GBK双字节字符，精确定位字符边界。
  /// 中文文本中换行符(\n=0x0A)等ASCII字符频繁出现，256字节内几乎必能找到。
  /// 如果确实没有ASCII字节（纯双字节中文段落），则不调整——原偏移大概率已对齐。
  Future<int> _findCharBoundary(String filePath, int offset) async {
    if (offset <= 0) return 0;

    // 读取offset前256字节用于扫描
    const scanRange = 256;
    final scanStart = (offset - scanRange).clamp(0, offset);
    final scanLen = offset - scanStart;
    if (scanLen == 0) return 0;

    final prefixBytes = await FileService.readFileRange(filePath, scanStart, scanLen);

    // 从后往前找最后一个ASCII字节（其后面必然是干净的字节边界）
    int asciiPos = -1;
    for (int i = prefixBytes.length - 1; i >= 0; i--) {
      if (prefixBytes[i] <= 0x7F) {
        asciiPos = i;
        break;
      }
    }

    if (asciiPos < 0) {
      // 256字节内没有ASCII字符（极罕见的长段落），不调整
      // 原偏移大概率已对齐，_decodeGbkChunked的try-catch会兜底
      return offset;
    }

    // 从ASCII字节后开始，前向扫描GBK字符，找到offset处的精确边界
    int pos = asciiPos + 1;
    while (pos < prefixBytes.length) {
      final b = prefixBytes[pos];
      if (b <= 0x7F) {
        // ASCII单字节
        pos++;
      } else if (b >= 0x81 && b <= 0xFE) {
        // GBK双字节首字节
        if (pos + 1 < prefixBytes.length) {
          pos += 2;
        } else {
          // 首字节就在offset前一个位置，offset是尾字节，需跳过
          return offset + 1;
        }
      } else {
        // 无效字节，跳过
        pos++;
      }
    }

    return scanStart + pos;
  }

  /// 读取书籍部分内容（按字符偏移和长度，仅小文件）
  Future<String> readContentRange(Book book, {int offset = 0, int? length}) async {
    final content = await readContent(book);
    final end = length != null ? (offset + length).clamp(0, content.length) : content.length;
    return content.substring(offset.clamp(0, content.length), end);
  }

  /// 删除书籍
  void removeBook(String bookId) {
    _contentCache.remove(bookId);
    _books.removeWhere((b) => b.id == bookId);
    _saveToStorage();
    _notifyListeners();
  }

  /// 更新阅读位置
  void updateReadPosition(String bookId, int position) {
    final idx = _books.indexWhere((b) => b.id == bookId);
    if (idx >= 0) {
      _books[idx].lastPosition = position;
      _books[idx].lastReadTime = DateTime.now();
      _saveToStorage();
      _notifyListeners();
    }
  }

  /// 更新书籍章节列表并持久化
  void updateChapters(String bookId, List<Chapter> chapters) {
    final idx = _books.indexWhere((b) => b.id == bookId);
    if (idx >= 0) {
      _books[idx].chapters = chapters;
      _saveToStorage();
    }
  }

  /// 合并种子书籍 & 执行数据迁移
  void _mergeSeedBooks() {
    final existingIds = _books.map((b) => b.id).toSet();
    bool changed = false;

    // === 数据迁移：v3 → v4 ===
    // 移除旧版硬编码 Windows 路径的 realBooks 种子书
    _books.removeWhere((b) =>
        b.id.startsWith('real_') &&
        b.filePath.contains('TeleAgent'));
    if (_books.map((b) => b.id).toSet().length != existingIds.length) {
      changed = true;
    }

    // 演示书种子
    final demos = [
      ('百年孤独', '加西亚·马尔克斯'),
      ('三体', '刘慈欣'),
      ('人间词话', '王国维'),
    ];
    for (final (title, author) in demos) {
      final id = 'demo_${title.hashCode}';
      if (!existingIds.contains(id)) {
        _books.add(Book(
          id: id,
          title: title,
          author: author,
          filePath: '',
          format: BookFormat.txt,
          colorSeed: title.hashCode & 0xFFFF,
        ));
        changed = true;
      }
    }

    if (changed) {
      _saveToStorage();
    }

    // 更新数据版本
    _updateVersion();
  }

  /// 更新数据版本号
  Future<void> _updateVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getInt(_kVersionKey) ?? 0;
      if (current < _currentVersion) {
        await prefs.setInt(_kVersionKey, _currentVersion);
      }
    } catch (_) {}
  }

  /// 获取演示书籍内容
  String getDemoContent(Book book) {
    final demo = _demoBooks.firstWhere(
      (d) => 'demo_${d.title.hashCode}' == book.id,
      orElse: () => _demoBooks.first,
    );
    return demo.content;
  }

  static final _demoBooks = [
    _DemoBook(
      title: '百年孤独',
      author: '加西亚·马尔克斯',
      content: '很多年以后，面对行刑队，奥雷里亚诺·布恩迪亚上校将会回想起父亲带他去见识冰块的那个遥远的下午。当时，马孔多是个20户人家的村庄，一座座土房都建在河岸上，河水清澈，沿着遍布石头的河床流去，河里的石头光滑、洁白，活像史前的巨蛋。这块天地还是新开辟的，许多东西都叫不出名字，不得不用手指指点点。每年3月，一家衣衫褴褛的吉卜赛人都要在村边搭起帐篷，在笛鼓的喧嚣声中，向马孔多的居民介绍科学家们的最新发明。他们首先带来的是磁铁。一个身躯粗壮的吉卜赛人，自称梅尔基亚德斯，把那磁铁当众一晃，当即就有20多座土房里的铁锅铁盆铁壶铁罐叮当跌落，在泥地上打滚，而那些多年不曾有人记起的铁器铁具铁杵铁炉也纷纷从无人知晓的角落现身，仿佛被那磁铁用某种神奇的力量唤醒了似的。\n\n世界新生伊始，许多事物还没有名字，提到的时候尚需用手指指点点。每年三月，一家衣衫褴褛的吉卜赛人都会来到村边扎下帐篷，在笛鼓的喧嚣中，向马孔多的居民介绍新近的发明。他们先带来了磁铁。一个身材高大的吉卜赛人，自称梅尔基亚德斯，满脸络腮胡子，手指瘦得像鸟的爪子，他夸张地展示了他所谓的马其顿炼金术士创造的第八大奇迹。他挨家挨户地拖着两块磁铁，人人都惊异不已地看到铁锅、铁盆、铁钳、铁炉纷纷从原地落下，木板因铁钉和螺钉没命地挣脱出来而嘎嘎作响，甚至连那些丢失很久的东西也从人们寻找最勤的地方现身了。\n\n何塞·阿尔卡蒂奥·布恩迪亚那狂热的想象力总是超越大自然的创造力，甚至比奇迹和魔术走得更远。他认为这种毫无用处的发明可以用来开采地底的黄金。梅尔基亚德斯是个诚实的人，他警告说："磁铁不能用于那种目的。"然而何塞·阿尔卡蒂奥·布恩迪亚那时还不了解吉卜赛人的狡诈，花了一匹骡子和两只山羊换了两块磁铁。他的妻子乌尔苏拉·伊瓜兰原本指望用这些动物来增加家计，却没能劝住他。\n\n"很快我们的金子就会多得够铺房子的地板了。"丈夫回答道。接下来的几个月里，他费尽心力想让磁铁发挥作用。他拿着两块磁铁在河里探测，在山脊上游走，在全村每一寸土地上搜索，结果只从地下挖出了一副十五世纪的铠甲。\n\n三月间，吉卜赛人又来了。这次他们带来的是望远镜和巨鼓。他们声称那是阿姆斯特丹犹太人的最新发明。他们让一个吉卜赛女人坐在村子的一头，把望远镜架在帐篷入口处，声称可以看到那女人在村子另一头的举动。同时他们敲响巨鼓，引得全村人都跑来观看。\n\n何塞·阿尔卡蒂奥·布恩迪亚设想，利用这种战时发明，可以让敌方的武器变得毫无用处。他又用两块磁铁和三枚殖民地金币换下了望远镜。乌尔苏拉为此哭了一场。那些金币是她父亲辛勤劳碌一辈子攒下的，本打算给女儿做嫁妆，如今却被丈夫拿来换了看星星的管子。\n\n"我可以看星星看得更清楚了。"何塞·阿尔卡蒂奥·布恩迪亚说。他把望远镜架在房间中央，整夜整夜地观测天体。他绘制了精确的星图，计算出了恒星的位置和运行轨迹，却始终没能发现宇宙的终极奥秘。他变得越来越沉默，越来越固执，整日把自己关在房间里做实验，连饭都顾不上吃。\n\n乌尔苏拉试图阻止丈夫的疯狂行为，但每次都以争吵告终。她不得不独自承担起养家的重担，靠制作糖果小动物来赚钱。她的勤劳和坚韧如同一条绳索，维持着这个家庭的运转。而何塞·阿尔卡蒂奥·布恩迪亚则越来越沉迷于炼金术，越发不问世事。\n\n就这样，马孔多的人口不断增长，村庄逐渐变成了一个热闹的小镇。人们建造了更好的房屋，铺设了街道，还建立了教堂。黎巴嫩人沿着河岸开起了商店，出售五颜六色的纺织品和闪闪发光的小饰品。但是，这个被世界遗忘的角落依然没有被任何一张地图标注。直到有一天，一个人骑着一匹瘦骨嶙峋的母马，从沼泽地那边走来了。他就是奥雷里亚诺·布恩迪亚上校。',
    ),
    _DemoBook(
      title: '三体',
      author: '刘慈欣',
      content: '科学边界不是一个正规的组织，更像是一个松散的学术交流群体。成员大多是国家基础科学领域的研究者，他们在各自的学科中已经走到了尽头，感到了前所未有的困惑。用汪淼的话说，科学边界就是一群在悬崖边上散步的人。他们看到的是同一幅图景：在基础科学领域，物理学正在走向末路。这听起来似乎危言耸听，但事实正是如此。自20世纪后半叶以来，物理学就没有出现过真正革命性的突破，所有的进展都只是在现有理论框架内的修补。弦理论曾经被寄予厚望，但半个世纪过去了，它除了产生越来越多的数学外，没有给出任何可与实验对比的预言。\n\n汪淼走进会议室时，他的眼睛首先看到的是坐在角落里的叶文洁。这位天体物理学家已经年过七旬，满头白发，但她那双眼睛依然深邃如夜空。没有人知道，正是这个看起来和蔼的老教授，在四十多年前做出了一个改变人类命运的决定。\n\n事情要从1969年说起。那时的叶文洁还是清华大学物理系的一名研究生，她的父亲叶哲泰是著名的理论物理学家。在文化大革命中，叶哲泰被批斗致死。叶文洁亲眼目睹了父亲被红卫兵殴打致死的过程，这一创伤性的经历彻底改变了她对人类文明的看法。\n\n后来叶文洁被下放到内蒙古的生产建设兵团，在那里她参加了一个绝密的军事项目——红岸工程。红岸基地建在大兴安岭的一个山巅上，名义上是一个普通的军事雷达站，实际上它的真正目的是向太空发送信号，试图与外星文明建立联系。\n\n叶文洁在红岸基地工作期间，利用基地的大功率发射天线向宇宙发送了地球的信息。她的信号被四光年之外的三体文明接收到了。三体人生活在一个三颗恒星组成的恒星系统中，他们饱受三体问题的困扰——行星的运行轨道无法预测，文明不断地被毁灭和重建。\n\n当三体人收到叶文洁的信号后，他们意识到这是一个稳定的恒星系统，一颗恒星就能提供稳定的光和热。对于三体人来说，太阳系就是他们梦寐以求的天堂。于是，三体舰队启航了，以光速的百分之一向太阳系飞来，预计四百年后到达地球。\n\n但三体人并不傻。他们知道人类的技术可能在四百年内超越他们。为了保证入侵的成功，三体人向地球发射了"智子"——一种利用量子纠缠技术制造的微观粒子。智子可以实时监控地球上的所有活动，并且能够干扰粒子加速器的实验结果，从而锁死人类的基础科学发展。从智子到达地球的那一刻起，人类就在物理学上被判了死刑。\n\n汪淼发现的"倒计时"正是智子的杰作。这个倒计时出现在他拍摄的每一张照片上，数字在精确地递减。他不知道的是，这个倒计时的终点就是三体舰队的到达时间。在倒计时归零之前，人类必须找到对抗三体入侵的方法。\n\n危机爆发后，联合国成立了行星防御理事会（PDC），开始组织全球力量应对三体入侵。面壁计划是这个时期最奇特也最具争议的战略：选出四位面壁者，赋予他们几乎不受限制的权力和资源去制定对抗三体人的战略——但他们的真实计划只能藏在自己的大脑中，因为智子可以监控一切物质层面的活动，唯独无法读取人的思维。\n\n四位面壁者分别是：前联合国秘书长弗雷德里克·泰勒、哲学家曼努尔·雷迪亚兹、社会学家比尔·希恩斯，以及一个名不见经传的中国学者罗辑。没有人理解为什么罗辑会被选中，连罗辑自己也不知道。但叶文洁在临死前给他的那句忠告——"宇宙社会学"的两个公理——将在后来改变一切。\n\n第一公理：生存是文明的第一需要。第二公理：文明不断增长和扩张，但宇宙中的物质总量保持不变。从这两条看似简单的公理出发，罗辑最终推导出了令人不寒而栗的"黑暗森林法则"：宇宙就像一片黑暗森林，每个文明都是带枪的猎人，在林中小心翼翼地潜行。如果他发现了别的生命，能做的只有一件事——开枪消灭之。在这片森林中，他人就是地狱，就是永恒的威胁。\n\n黑暗森林法则解释了为什么费米悖论成立——我们之所以没有发现外星文明，不是因为它们不存在，而是因为它们都在沉默。任何暴露自己位置的文明都将很快被其他文明消灭。而三体人之所以要入侵地球，正是因为叶文洁向宇宙广播了地球的位置。但在故事的最后，罗辑利用这个法则，以向全宇宙广播太阳系坐标为威胁，成功阻止了三体人的入侵，建立了脆弱的威慑平衡。',
    ),
    _DemoBook(
      title: '人间词话',
      author: '王国维',
      content: '词以境界为最上。有境界则自成高格，自有名句。五代北宋之词所以独绝者在此。\n\n有有我之境界，有无我之境界。"泪眼问花花不语，乱红飞过秋千去"，有我之境界也。"采菊东篱下，悠然见南山"，无我之境界也。有我之境，以我观物，故物皆著我之色彩。无我之境，以物观物，故不知何者为我，何者为物。古人为词，写有我之境者为多，然未始不能写无我之境，此在豪杰之士能自树立耳。\n\n"红杏枝头春意闹"，著一"闹"字而境界全出。"云破月来花弄影"，著一"弄"字而境界全出矣。\n\n境界有大小，不以是而分优劣。"细雨鱼儿出，微风燕子斜"，何遽不若"落日照大旗，马鸣风萧萧"。"宝帘闲挂小银钩"，何遽不若"雾失楼台，月迷津渡"也。\n\n古今之成大事业、大学问者，必经过三种之境界："昨夜西风凋碧树，独上高楼，望尽天涯路"，此第一境也。"衣带渐宽终不悔，为伊消得人憔悴"，此第二境也。"众里寻他千百度，蓦然回首，那人却在灯火阑珊处"，此第三境也。此等语皆非大词人不能道。然遽以此意解释诸词，恐为晏、欧诸公所不许也。\n\n客观之诗人，不可不多阅世。阅世愈深，则材料愈丰富、愈变化，《水浒传》、《红楼梦》之作者是也。主观之诗人，不必多阅世。阅世愈浅，则性情愈真，李后主是也。\n\n纳兰容若以自然之眼观物，以自然之舌言情。初入中原，未染汉人风气，故能真切如此。北宋以来，一人而已。\n\n大家之作，其言情也必沁人心脾，其写景也必豁人耳目，其辞脱口而出，无矫揉妆束之态。以其所见者真，所知者深也。诗词皆然。持此以衡古今之作者，可无大误矣。\n\n诗人对宇宙人生，须入乎其内，又须出乎其外。入乎其内，故能写之；出乎其外，故能观之。入乎其内，故有生气；出乎其外，故有高致。\n\n自然中之物，互相关系，互相限制。然其写之于文学及美术中也，必遗其关系限制之处。故虽写实家，亦理想家也。又虽如何虚构之境，其材料必求之于自然，而其构造亦必从自然之法则。故虽理想家，亦写实家也。\n\n有造境，有写境，此"理想"与"写实"二派之所由分。然二者颇难分别，因大诗人所造之境必合乎自然，所写之境亦必邻于理想故也。\n\n词人者，不失其赤子之心者也。故生于深宫之中，长于妇人之手，是后主为人君所短处，亦即为词人所长处。\n\n词至李后主而眼界始大，感慨遂深，遂变伶工之词而为士大夫之词。周介存谓"毛嫱、西施，天下美妇人也，严妆佳，淡妆亦佳，粗服乱头，不掩国色。飞卿，严妆也；端己，淡妆也；后主则粗服乱头矣。"余谓后主之词真所谓以血书者也。宋道君皇帝《燕山亭》词亦略似之。然道君不过自道身世之戚，后主则俨有释迦、基督担荷人类罪恶之意，其大小固不同矣。\n\n唐五代之词，有句而无篇；南宋名家之词，有篇而无句；有篇有句，唯李后主降宋后之作及永叔、子瞻、少游、美成、稼轩数人而已。\n\n词之雅郑，在神不在貌。永叔、少游虽作艳语，终有品格。方之美成，便有淑女与倡伎之别。\n\n温飞卿之词，句秀也；韦端己之词，骨秀也；李重光之词，神秀也。\n\n南唐中主词："菡萏香销翠叶残，西风愁起绿波间。"大有"众芳芜秽""美人迟暮"之感。乃古今独赏其"细雨梦回鸡塞远，小楼吹彻玉笙寒"，故知解人正不易得。\n\n冯正中词虽不失五代风格，而堂庑特大，开北宋一代风气。与中后二主词皆在《花间》范围之外，宜《花间集》中不登其只字也。\n\n幼安之佳处，在有性情，有境界。即以气象论，亦有"傍素波、干青云"之概，宁后世龌龊小生所可拟耶？',
    ),
  ];
}

class _DemoBook {
  final String title;
  final String author;
  final String content;
  const _DemoBook({required this.title, required this.author, required this.content});
}
