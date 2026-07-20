/// XLSX 专属阅读页
///
/// 支持：
///   - 网格表格视图（等宽字体 + 冻结首行 + 横竖双向滚动 + 列宽自适应）
///   - 卡片视图（一行数据 = 一张卡片，移动端竖屏最优）
///   - 行详情页（点卡片展开全字段）
///   - 模式切换（网格/卡片）
///   - Sheet 标签切换（横向滚动）
///   - 搜索功能
///   - 列排序（点表头排序）
///   - 单元格长按复制
///   - 样式渲染（背景色、加粗、斜体）
///   - 横屏适配
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';
import '../models/xlsx_data.dart';
import '../services/bookshelf_service.dart';

// ─── 视图模式 ───

enum _XlsxViewMode { grid, card }

class XlsxReaderPage extends StatefulWidget {
  final Book book;

  const XlsxReaderPage({super.key, required this.book});

  @override
  State<XlsxReaderPage> createState() => _XlsxReaderPageState();
}

class _XlsxReaderPageState extends State<XlsxReaderPage> {
  // ─── 状态 ───

  XlsxWorkbook? _workbook;
  bool _isLoading = true;
  String? _loadError;
  int _currentSheetIndex = 0;
  _XlsxViewMode _viewMode = _XlsxViewMode.grid;

  // 排序状态
  int? _sortColumnIndex;
  bool _sortAscending = true;
  List<XlsxRow>? _sortedRows;

  // 搜索状态
  bool _isSearching = false;
  String _searchQuery = '';
  List<_SearchResult> _searchResults = [];

  // 列宽缓存
  List<double>? _columnWidths;

  // 横竖滚控制器
  final _verticalController = ScrollController();
  final _horizontalController = ScrollController();
  final _headerHorizontalController = ScrollController();

  // 主题色
  late Color _backgroundColor;
  late Color _textColor;
  late Color _headerColor;
  late Color _headerBgColor;
  late Color _cardColor;
  late Color _borderColor;

  @override
  void initState() {
    super.initState();
    _loadContent();
  }

  @override
  void dispose() {
    _verticalController.dispose();
    _horizontalController.dispose();
    _headerHorizontalController.dispose();
    super.dispose();
  }

  // ─── 数据加载 ───

  Future<void> _loadContent() async {
    try {
      final service = BookshelfService.instance;
      final workbook = await service.readXlsxContentStructured(widget.book);
      if (mounted) {
        setState(() {
          _workbook = workbook;
          _isLoading = false;
          // 根据数据量选择默认视图模式
          final sheet = _currentSheet;
          if (sheet != null && sheet.maxColumnCount > 6) {
            _viewMode = _XlsxViewMode.card;
          }
        });
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

  // ─── 主题初始化 ───

  void _initTheme(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    _backgroundColor = isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5F5F5);
    _textColor = isDark ? Colors.white70 : Colors.black87;
    _headerColor = isDark ? Colors.white : Colors.black;
    _headerBgColor = isDark ? const Color(0xFF2D2D44) : const Color(0xFFE8EAF6);
    _cardColor = isDark ? const Color(0xFF2D2D44) : Colors.white;
    _borderColor = isDark ? const Color(0xFF3D3D5C) : const Color(0xFFE0E0E0);
  }

  // ─── 当前 Sheet ───

  XlsxSheet? get _currentSheet {
    if (_workbook == null || _currentSheetIndex >= _workbook!.sheets.length) {
      return null;
    }
    return _workbook!.sheets[_currentSheetIndex];
  }

  /// 获取当前显示的行（可能已排序）
  List<XlsxRow> get _displayRows {
    final sheet = _currentSheet;
    if (sheet == null) return [];
    if (_sortedRows != null) return _sortedRows!;
    return sheet.rows;
  }

  // ─── 列宽计算 ───

  List<double> _computeColumnWidths(XlsxSheet sheet) {
    if (_columnWidths != null &&
        _columnWidths!.length == sheet.maxColumnCount) {
      return _columnWidths!;
    }

    const double charWidth = 7.0; // 等宽字体单字符宽度估算
    const double padding = 16.0; // 单元格左右 padding
    const double minColWidth = 50.0;
    const double maxColWidth = 200.0;
    const int scanRows = 50; // 只扫描前 N 行估算

    final rows = sheet.rows;
    final scanCount = rows.length < scanRows ? rows.length : scanRows;

    final maxWidths = List<double>.filled(sheet.maxColumnCount, minColWidth);

    for (int i = 0; i < scanCount; i++) {
      final row = rows[i];
      for (int j = 0; j < row.cells.length && j < sheet.maxColumnCount; j++) {
        final cell = row.cells[j];
        if (cell.hasValue) {
          final w = (cell.value!.length * charWidth + padding)
              .clamp(minColWidth, maxColWidth);
          if (w > maxWidths[j]) maxWidths[j] = w;
        }
      }
    }

    // 如果是表头模式，用表头列字母宽度兜底
    for (int j = 0; j < sheet.maxColumnCount; j++) {
      final headerWidth =
          (columnIndexToLetter(j).length * charWidth + padding)
              .clamp(minColWidth, maxColWidth);
      if (headerWidth > maxWidths[j]) maxWidths[j] = headerWidth;
    }

    _columnWidths = maxWidths;
    return maxWidths;
  }

  // ─── 横滚同步 ───

  void _syncHorizontalScroll(ScrollController source) {
    final target = source == _headerHorizontalController
        ? _horizontalController
        : _headerHorizontalController;
    if (target.hasClients && source.hasClients) {
      final offset = source.offset;
      if ((offset - target.offset).abs() > 1) {
        target.jumpTo(offset.clamp(0, target.position.maxScrollExtent));
      }
    }
  }

  // ─── 构建 ───

  @override
  Widget build(BuildContext context) {
    _initTheme(context);

    if (_isLoading) {
      return Scaffold(
        backgroundColor: _backgroundColor,
        appBar: AppBar(title: Text(widget.book.title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_loadError != null) {
      return Scaffold(
        backgroundColor: _backgroundColor,
        appBar: AppBar(title: Text(widget.book.title)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('加载失败：$_loadError',
                style: TextStyle(color: _textColor)),
          ),
        ),
      );
    }

    if (_workbook == null || _workbook!.sheets.isEmpty) {
      return Scaffold(
        backgroundColor: _backgroundColor,
        appBar: AppBar(title: Text(widget.book.title)),
        body: Center(
          child: Text('此表格无可读数据',
              style: TextStyle(color: _textColor, fontSize: 16)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          _buildSheetTabs(),
          Expanded(child: _buildBody()),
          _buildFooter(),
        ],
      ),
    );
  }

  // ─── AppBar ───

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: _isSearching
          ? _buildSearchField()
          : Text(widget.book.title,
              style: const TextStyle(fontSize: 16)),
      actions: [
        // 搜索
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => setState(() {
            _isSearching = true;
            _searchResults = [];
            _searchQuery = '';
          }),
        ),
        // 模式切换
        IconButton(
          icon: Icon(_viewMode == _XlsxViewMode.grid
              ? Icons.view_agenda
              : Icons.grid_on),
          tooltip: _viewMode == _XlsxViewMode.grid ? '卡片视图' : '网格视图',
          onPressed: () => setState(() {
            _viewMode = _viewMode == _XlsxViewMode.grid
                ? _XlsxViewMode.card
                : _XlsxViewMode.grid;
          }),
        ),
        // 横屏
        IconButton(
          icon: const Icon(Icons.screen_lock_landscape),
          tooltip: '横屏模式',
          onPressed: _toggleOrientation,
        ),
      ],
    );
  }

  // ─── 搜索 ───

  Widget _buildSearchField() {
    return TextField(
      autofocus: true,
      style: TextStyle(color: _textColor, fontSize: 16),
      decoration: InputDecoration(
        hintText: '搜索内容...',
        hintStyle: TextStyle(color: Colors.grey),
        border: InputBorder.none,
      ),
      onChanged: (query) {
        _searchQuery = query;
        _performSearch(query);
      },
    );
  }

  void _performSearch(String query) {
    if (query.isEmpty || _workbook == null) {
      setState(() => _searchResults = []);
      return;
    }
    final lower = query.toLowerCase();
    final results = <_SearchResult>[];
    for (final sheet in _workbook!.sheets) {
      for (final row in sheet.rows) {
        for (final cell in row.cells) {
          if (cell.hasValue &&
              cell.value!.toLowerCase().contains(lower)) {
            results.add(_SearchResult(
              sheetName: sheet.name,
              row: row,
              cell: cell,
            ));
            if (results.length >= 100) break; // 限制结果数
          }
        }
        if (results.length >= 100) break;
      }
    }
    setState(() => _searchResults = results);
  }

  // ─── Sheet 标签 ───

  Widget _buildSheetTabs() {
    if (_workbook == null || _workbook!.sheetNames.length <= 1) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 40,
      color: _headerBgColor,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _workbook!.sheetNames.length,
        itemBuilder: (ctx, i) {
          final name = _workbook!.sheetNames[i];
          final isSelected = i == _currentSheetIndex;
          return GestureDetector(
            onTap: () => _switchSheet(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: isSelected ? Colors.blue : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                name,
                style: TextStyle(
                  color: isSelected ? Colors.blue : _textColor,
                  fontWeight:
                      isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        },
      ),
    );
  }

  void _switchSheet(int index) {
    setState(() {
      _currentSheetIndex = index;
      _columnWidths = null; // 重置列宽
      _sortColumnIndex = null;
      _sortedRows = null;
      _verticalController.jumpTo(0);
      _horizontalController.jumpTo(0);
    });
  }

  // ─── 主体 ───

  Widget _buildBody() {
    if (_isSearching && _searchQuery.isNotEmpty) {
      return _buildSearchResults();
    }

    final sheet = _currentSheet;
    if (sheet == null || sheet.rows.isEmpty) {
      return Center(
        child: Text('当前工作表无数据',
            style: TextStyle(color: _textColor, fontSize: 16)),
      );
    }

    return _viewMode == _XlsxViewMode.grid
        ? _buildGridView(sheet)
        : _buildCardView(sheet);
  }

  // ═══════════════════════════════════════
  //  网格表格视图
  // ═══════════════════════════════════════

  Widget _buildGridView(XlsxSheet sheet) {
    final colWidths = _computeColumnWidths(sheet);
    final totalWidth = 40.0 + colWidths.fold<double>(0, (s, w) => s + w);

    return Column(
      children: [
        // 冻结表头
        _buildGridHeader(sheet, colWidths, totalWidth),
        // 分隔线
        Container(height: 1, color: _borderColor),
        // 数据区域
        Expanded(
          child: _buildGridData(sheet, colWidths, totalWidth),
        ),
      ],
    );
  }

  Widget _buildGridHeader(
      XlsxSheet sheet, List<double> colWidths, double totalWidth) {
    final headerRow = sheet.hasHeader && sheet.rows.isNotEmpty
        ? sheet.rows.first
        : null;
    // 列标题行数据
    final displayCols = sheet.hasHeader && headerRow != null
        ? headerRow.cells
        : List.generate(
            sheet.maxColumnCount,
            (i) => XlsxCell(
              columnLetter: columnIndexToLetter(i),
              columnIndex: i,
              value: columnIndexToLetter(i),
            ));

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification) {
          _syncHorizontalScroll(_headerHorizontalController);
        }
        return false;
      },
      child: SingleChildScrollView(
        controller: _headerHorizontalController,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: _buildGridRowWidget(
            cells: displayCols,
            colWidths: colWidths,
            isHeader: true,
            rowIndex: headerRow?.rowIndex ?? 0,
            showSortIndicator: true,
          ),
        ),
      ),
    );
  }

  Widget _buildGridData(
      XlsxSheet sheet, List<double> colWidths, double totalWidth) {
    final rows = _displayRows;
    final startRow = sheet.hasHeader ? 1 : 0;
    final dataRows = rows.length > startRow
        ? rows.sublist(startRow)
        : rows;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification) {
          _syncHorizontalScroll(_horizontalController);
        }
        return false;
      },
      child: SingleChildScrollView(
        controller: _horizontalController,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: totalWidth,
          child: ListView.builder(
            controller: _verticalController,
            itemCount: dataRows.length,
            itemExtent: 36.0, // 固定行高提升性能
            itemBuilder: (ctx, i) {
              final row = dataRows[i];
              return _buildGridRowWidget(
                cells: row.cells,
                colWidths: colWidths,
                isHeader: false,
                rowIndex: row.rowIndex,
                row: row,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildGridRowWidget({
    required List<XlsxCell> cells,
    required List<double> colWidths,
    required bool isHeader,
    required int rowIndex,
    XlsxRow? row,
    bool showSortIndicator = false,
  }) {
    return Container(
      height: 36,
      color: isHeader ? _headerBgColor : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 行号列
          Container(
            width: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(color: _borderColor, width: 0.5),
              ),
            ),
            child: Text(
              isHeader ? '#' : '$rowIndex',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey,
                fontFamily: 'monospace',
              ),
            ),
          ),
          // 数据列
          for (int i = 0; i < cells.length && i < colWidths.length; i++)
            _buildGridCell(
              cell: cells[i],
              width: colWidths[i],
              isHeader: isHeader,
              showSortIndicator: showSortIndicator && i == _sortColumnIndex,
              row: row,
            ),
        ],
      ),
    );
  }

  Widget _buildGridCell({
    required XlsxCell cell,
    required double width,
    required bool isHeader,
    bool showSortIndicator = false,
    XlsxRow? row,
  }) {
    // 解析背景色
    Color? bgColor;
    if (cell.backgroundColor != null && cell.backgroundColor!.length >= 6) {
      try {
        final hex = cell.backgroundColor!;
        // ARGB 格式，如 "FFFF0000" → 红色
        if (hex.length == 8) {
          final a = int.parse(hex.substring(0, 2), radix: 16) / 255;
          final r = int.parse(hex.substring(2, 4), radix: 16);
          final g = int.parse(hex.substring(4, 6), radix: 16);
          final b = int.parse(hex.substring(6, 8), radix: 16);
          bgColor = Color.fromARGB((a * 255).round(), r, g, b);
        } else if (hex.length == 6) {
          final r = int.parse(hex.substring(0, 2), radix: 16);
          final g = int.parse(hex.substring(2, 4), radix: 16);
          final b = int.parse(hex.substring(4, 6), radix: 16);
          bgColor = Color.fromARGB(255, r, g, b);
        }
      } catch (_) {}
    }

    return GestureDetector(
      onLongPress: () => _onCellLongPress(cell),
      onTap: isHeader ? () => _onHeaderTap(cell.columnIndex) : null,
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: bgColor,
          border: Border(
            right: BorderSide(color: _borderColor, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                cell.value ?? '',
                style: TextStyle(
                  fontFamily: isHeader ? null : 'monospace',
                  fontSize: isHeader ? 12 : 13,
                  fontWeight: isHeader || cell.isBold
                      ? FontWeight.bold
                      : FontWeight.normal,
                  fontStyle: cell.isItalic ? FontStyle.italic : FontStyle.normal,
                  color: isHeader ? _headerColor : _textColor,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                softWrap: false,
              ),
            ),
            if (showSortIndicator)
              Icon(
                _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14,
                color: Colors.blue,
              ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════
  //  卡片视图
  // ═══════════════════════════════════════

  Widget _buildCardView(XlsxSheet sheet) {
    final rows = _displayRows;
    final headerRow = sheet.hasHeader && rows.isNotEmpty ? rows.first : null;
    final startRow = sheet.hasHeader ? 1 : 0;
    final dataRows =
        rows.length > startRow ? rows.sublist(startRow) : rows;

    if (dataRows.isEmpty) {
      return Center(
        child: Text('无数据行',
            style: TextStyle(color: _textColor, fontSize: 16)),
      );
    }

    return ListView.builder(
      controller: _verticalController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: dataRows.length,
      itemBuilder: (ctx, i) {
        return _buildCard(dataRows[i], headerRow);
      },
    );
  }

  Widget _buildCard(XlsxRow row, XlsxRow? headerRow) {
    // 首列值作卡片标题
    final titleCell = row.cells.isNotEmpty ? row.cells.first : null;
    final title = titleCell?.hasValue == true
        ? titleCell!.value!
        : '行 ${row.rowIndex}';

    // 其余列作键值对
    final detailCells = row.cells.length > 1
        ? row.cells.sublist(1)
        : <XlsxCell>[];

    return GestureDetector(
      onTap: () => _openRowDetail(row, headerRow),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: _cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _borderColor, width: 0.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: _textColor,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  Text(
                    '#${row.rowIndex}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
              if (detailCells.isNotEmpty) const Divider(height: 12),
              // 键值对
              for (final cell in detailCells)
                if (cell.hasValue)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 80,
                          child: Text(
                            headerRow != null &&
                                    cell.columnIndex < headerRow.cells.length
                                ? headerRow.cells[cell.columnIndex].value ??
                                    cell.columnLetter
                                : cell.columnLetter,
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            cell.value!,
                            style: TextStyle(
                              fontSize: 13,
                              color: _textColor,
                              fontWeight:
                                  cell.isBold ? FontWeight.bold : FontWeight.normal,
                              fontStyle: cell.isItalic
                                  ? FontStyle.italic
                                  : FontStyle.normal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════
  //  行详情页
  // ═══════════════════════════════════════

  void _openRowDetail(XlsxRow row, XlsxRow? headerRow) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _XlsxRowDetailPage(
          row: row,
          headerRow: headerRow,
          backgroundColor: _backgroundColor,
          textColor: _textColor,
        ),
      ),
    );
  }

  // ═══════════════════════════════════════
  //  搜索结果
  // ═══════════════════════════════════════

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty && _searchQuery.isNotEmpty) {
      return Center(
        child: Text('未找到匹配内容',
            style: TextStyle(color: _textColor, fontSize: 16)),
      );
    }
    if (_searchResults.isEmpty) {
      return Center(
        child: Text('输入关键词搜索',
            style: TextStyle(color: Colors.grey, fontSize: 16)),
      );
    }

    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (ctx, i) {
        final result = _searchResults[i];
        return ListTile(
          title: Text(
            result.cell.value ?? '',
            style: TextStyle(color: _textColor, fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${result.sheetName} · 行 ${result.row.rowIndex} · ${result.cell.columnLetter}',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          onTap: () => _jumpToSearchResult(result),
        );
      },
    );
  }

  void _jumpToSearchResult(_SearchResult result) {
    // 切换到对应 Sheet
    final sheetIndex =
        _workbook!.sheetNames.indexOf(result.sheetName);
    if (sheetIndex >= 0) {
      _switchSheet(sheetIndex);
    }
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchResults = [];
    });
    // TODO: 可扩展为自动滚动到对应行
  }

  // ═══════════════════════════════════════
  //  排序
  // ═══════════════════════════════════════

  void _onHeaderTap(int columnIndex) {
    setState(() {
      if (_sortColumnIndex == columnIndex) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumnIndex = columnIndex;
        _sortAscending = true;
      }
      _applySort();
    });
  }

  void _applySort() {
    final sheet = _currentSheet;
    if (sheet == null || _sortColumnIndex == null) {
      _sortedRows = null;
      return;
    }

    final rows = List<XlsxRow>.from(sheet.rows);
    final headerRow = sheet.hasHeader && rows.isNotEmpty ? rows.first : null;
    final dataStart = headerRow != null ? 1 : 0;

    if (dataStart < rows.length) {
      final header = dataStart > 0 ? [rows.first] : <XlsxRow>[];
      final data = rows.sublist(dataStart);
      data.sort((a, b) {
        final aVal = _sortColumnIndex! < a.cells.length
            ? a.cells[_sortColumnIndex!].value ?? ''
            : '';
        final bVal = _sortColumnIndex! < b.cells.length
            ? b.cells[_sortColumnIndex!].value ?? ''
            : '';
        // 尝试数字比较
        final aNum = double.tryParse(aVal);
        final bNum = double.tryParse(bVal);
        int cmp;
        if (aNum != null && bNum != null) {
          cmp = aNum.compareTo(bNum);
        } else {
          cmp = aVal.toLowerCase().compareTo(bVal.toLowerCase());
        }
        return _sortAscending ? cmp : -cmp;
      });
      _sortedRows = [...header, ...data];
    } else {
      _sortedRows = rows;
    }
  }

  // ═══════════════════════════════════════
  //  单元格长按复制
  // ═══════════════════════════════════════

  void _onCellLongPress(XlsxCell cell) {
    if (!cell.hasValue) return;
    Clipboard.setData(ClipboardData(text: cell.value!));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制: ${cell.value!.length > 30 ? '${cell.value!.substring(0, 30)}...' : cell.value!}'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ═══════════════════════════════════════
  //  横屏
  // ═══════════════════════════════════════

  void _toggleOrientation() {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    if (isLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  // ─── 底部状态栏 ───

  Widget _buildFooter() {
    final sheet = _currentSheet;
    if (sheet == null) return const SizedBox.shrink();

    final totalRows = sheet.rows.where((r) => !r.isEmpty).length;
    final mode = _viewMode == _XlsxViewMode.grid ? '网格' : '卡片';
    final sortInfo = _sortColumnIndex != null
        ? ' · 排序: ${columnIndexToLetter(_sortColumnIndex!)}${_sortAscending ? '↑' : '↓'}'
        : '';

    return Container(
      height: 28,
      color: _headerBgColor,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '$totalRows 行 · ${sheet.maxColumnCount} 列$sortInfo',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          Text(
            '$mode模式',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════
//  行详情页
// ═══════════════════════════════════════

class _XlsxRowDetailPage extends StatelessWidget {
  final XlsxRow row;
  final XlsxRow? headerRow;
  final Color backgroundColor;
  final Color textColor;

  const _XlsxRowDetailPage({
    required this.row,
    this.headerRow,
    required this.backgroundColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text('行 ${row.rowIndex}'),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: row.cells.length,
        itemBuilder: (ctx, i) {
          final cell = row.cells[i];
          final label = headerRow != null &&
                  i < headerRow!.cells.length &&
                  headerRow!.cells[i].hasValue
              ? headerRow!.cells[i].value!
              : cell.columnLetter;

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onLongPress: () {
                    if (cell.hasValue) {
                      Clipboard.setData(ClipboardData(text: cell.value!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制'),
                          duration: Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: backgroundColor,
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      cell.value ?? '',
                      style: TextStyle(
                        fontSize: 15,
                        color: cell.hasValue ? textColor : Colors.grey,
                        fontWeight:
                            cell.isBold ? FontWeight.bold : FontWeight.normal,
                        fontStyle: cell.isItalic
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════
//  搜索结果
// ═══════════════════════════════════════

class _SearchResult {
  final String sheetName;
  final XlsxRow row;
  final XlsxCell cell;

  const _SearchResult({
    required this.sheetName,
    required this.row,
    required this.cell,
  });
}
