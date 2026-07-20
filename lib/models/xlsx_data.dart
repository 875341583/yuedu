/// XLSX 结构化数据模型
///
/// XlsxTextExtractor.extractStructured() 返回 XlsxWorkbook，
/// 包含所有 Sheet 的行列结构化数据，供 XlsxReaderPage 渲染。
library;

/// 整个工作簿
class XlsxWorkbook {
  final List<XlsxSheet> sheets;
  final List<String> sheetNames; // 与 sheets 等长，用于 Tab 标签
  final List<String> failureReasons; // 解析失败的 sheet 原因

  const XlsxWorkbook({
    required this.sheets,
    required this.sheetNames,
    this.failureReasons = const [],
  });

  bool get isEmpty => sheets.every((s) => s.rows.every((r) => r.isEmpty));
}

/// 单个 Sheet
class XlsxSheet {
  final String name;
  final List<XlsxRow> rows;
  final int maxColumnCount; // 该 sheet 中最大列数，用于列宽计算
  final bool hasHeader; // 首行是否为表头（启发式判断）

  const XlsxSheet({
    required this.name,
    required this.rows,
    required this.maxColumnCount,
    this.hasHeader = false,
  });
}

/// 一行数据
class XlsxRow {
  final int rowIndex; // 原始行号（1-based）
  final List<XlsxCell> cells;
  final bool isEmpty; // 所有单元格是否为空

  const XlsxRow({
    required this.rowIndex,
    required this.cells,
    this.isEmpty = false,
  });
}

/// 单个单元格
class XlsxCell {
  final String? value; // null = 空单元格
  final String columnLetter; // 列字母（A, B, C, ...）
  final int columnIndex; // 列序号（0-based）
  // v0.7.0 样式字段
  final String? backgroundColor; // 十六进制色值，如 "FFFF0000"（ARGB）
  final bool isBold;
  final bool isItalic;

  const XlsxCell({
    this.value,
    required this.columnLetter,
    required this.columnIndex,
    this.backgroundColor,
    this.isBold = false,
    this.isItalic = false,
  });

  /// 便捷：是否有非空值
  bool get hasValue => value != null && value!.isNotEmpty;
}

/// 工具函数

/// 列序号 → 列字母（0→A, 1→B, 25→Z, 26→AA, 27→AB）
String columnIndexToLetter(int index) {
  final result = StringBuffer();
  var i = index;
  while (i >= 0) {
    result.write(String.fromCharCode(65 + (i % 26)));
    i = i ~/ 26 - 1;
  }
  return result.toString().split('').reversed.join();
}

/// 列字母 → 列序号（A→0, B→1, Z→25, AA→26）
int columnLetterToIndex(String letter) {
  var index = 0;
  for (var i = 0; i < letter.length; i++) {
    index = index * 26 + (letter.codeUnitAt(i) - 65 + 1);
  }
  return index - 1;
}

/// 首行是否像表头（启发式判断）
bool guessHasHeader(XlsxRow firstRow) {
  if (firstRow.isEmpty || firstRow.cells.isEmpty) return false;
  final values = firstRow.cells
      .where((c) => c.hasValue)
      .map((c) => c.value!)
      .toList();
  if (values.isEmpty) return false;
  // 全是字符串（不可解析为数字）且平均长度不太长
  final allString = values.every((v) => double.tryParse(v) == null);
  final avgLen = values.fold<int>(0, (s, v) => s + v.length) / values.length;
  return allString && avgLen < 30;
}
