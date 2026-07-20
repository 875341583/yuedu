/// XLSX 文本提取器
///
/// XLSX 是 ZIP 包，关键文件：
///   - xl/sharedStrings.xml  → 全局共享字符串表 <sst><si><t>文本</t></si></sst>
///   - xl/workbook.xml       → sheet 名称与顺序
///   - xl/worksheets/sheetN.xml → 每个 sheet 的单元格数据
///   - xl/styles.xml          → 单元格样式（字体、背景色等）
///
/// v0.5.4 修复：
///   - group(2) → group(1) 修复 RangeError 必崩
///
/// v0.7.0 重构：
///   - 新增 extractStructured() 返回 XlsxWorkbook 结构化数据
///   - 保留 extract() 旧接口向后兼容
///   - 解析单元格坐标 r="A1" 实现空列占位
///   - 解析 styles.xml 样式（背景色、加粗、斜体）
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart' as archive;

import '../models/xlsx_data.dart';

class XlsxTextExtractor {
  /// 旧接口保留，内部调用 extractStructured 后降级为纯文本
  static String extract(List<int> bytes) {
    final workbook = extractStructured(bytes);
    if (workbook.sheets.isEmpty) {
      if (workbook.failureReasons.isNotEmpty) {
        final reasons = workbook.failureReasons.take(3).join('；');
        final more = workbook.failureReasons.length > 3
            ? '；等共 ${workbook.failureReasons.length} 个工作表失败'
            : '';
        return '（表格解析失败：${workbook.failureReasons.length} 个工作表无法读取。'
            '原因：$reasons$more）';
      }
      return '（此表格无可读文本单元格，可能为纯图表或图片型表格）';
    }
    final buffer = StringBuffer();
    for (int i = 0; i < workbook.sheets.length; i++) {
      final sheet = workbook.sheets[i];
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write('=== ${sheet.name} ===\n');
      for (final row in sheet.rows) {
        if (row.isEmpty) continue;
        final line = row.cells
            .where((c) => c.hasValue)
            .map((c) => c.value!)
            .join('\t');
        if (line.isNotEmpty) {
          buffer.write(line);
          buffer.write('\n');
        }
      }
    }
    return buffer.toString();
  }

  /// 新接口：返回结构化数据
  static XlsxWorkbook extractStructured(List<int> bytes) {
    // 文件头检测
    if (bytes.length < 4) {
      throw Exception('文件过小，不是有效的 XLSX 文件');
    }
    if (bytes[0] == 0xD0 &&
        bytes[1] == 0xCF &&
        bytes[2] == 0x11 &&
        bytes[3] == 0xE0) {
      throw Exception(
          '此文件是旧版 .xls 格式（二进制），请在电脑上用 Excel 另存为 .xlsx 格式后再导入');
    }
    if (!(bytes[0] == 0x50 && bytes[1] == 0x4B)) {
      throw Exception('文件格式不正确（不是有效的 .xlsx 压缩包），请确认文件未损坏');
    }

    // 解压 ZIP
    final files = _unzip(bytes);

    if (files.isEmpty) {
      throw Exception('XLSX 解压失败，文件可能已损坏或加密');
    }

    // 1. 解析 sharedStrings
    final sharedStrings = _parseSharedStrings(files['xl/sharedStrings.xml']);

    // 2. 解析 workbook.xml 获取 sheet 名称顺序
    final sheetNames = _parseSheetNames(files['xl/workbook.xml']);

    // 3. 解析 styles.xml
    final styles = _parseStyles(files['xl/styles.xml']);

    // 4. 收集所有 sheetN.xml，按 N 数字升序
    final sheetFiles = <int, Uint8List>{};
    for (final entry in files.entries) {
      final m =
          RegExp(r'^xl/worksheets/sheet(\d+)\.xml$').firstMatch(entry.key);
      if (m != null) {
        final idx = int.parse(m.group(1)!);
        sheetFiles[idx] = entry.value;
      }
    }
    final sortedKeys = sheetFiles.keys.toList()..sort();

    final sheets = <XlsxSheet>[];
    final sheetNameList = <String>[];
    final failureReasons = <String>[];

    for (var i = 0; i < sortedKeys.length; i++) {
      final idx = sortedKeys[i];
      final f = sheetFiles[idx]!;
      final sheetTitle = i < sheetNames.length ? sheetNames[i] : 'Sheet$idx';
      sheetNameList.add(sheetTitle);

      try {
        final xml = utf8.decode(f, allowMalformed: true);
        final sheet = _parseSheetStructured(xml, sheetTitle, sharedStrings, styles);
        sheets.add(sheet);
      } catch (e) {
        failureReasons.add('$sheetTitle: $e');
        // 添加空 sheet 占位
        sheets.add(XlsxSheet(
          name: sheetTitle,
          rows: [],
          maxColumnCount: 0,
          hasHeader: false,
        ));
      }
    }

    return XlsxWorkbook(
      sheets: sheets,
      sheetNames: sheetNameList,
      failureReasons: failureReasons,
    );
  }

  // ─── 解压 ZIP ───

  static Map<String, Uint8List> _unzip(List<int> bytes) {
    final files = <String, Uint8List>{};
    var archiveOk = false;
    String? archiveError;
    try {
      final arc = archive.ZipDecoder().decodeBytes(bytes);
      archiveOk = true;
      for (final f in arc) {
        try {
          final data = f.content as dynamic;
          if (data is String) {
            files[f.name] = Uint8List.fromList(utf8.encode(data));
          } else if (data is List) {
            files[f.name] = Uint8List.fromList(List<int>.from(data));
          }
        } catch (e) {
          archiveError ??= '$e';
        }
      }
    } catch (e) {
      archiveError = '$e';
    }

    if (!archiveOk || files.isEmpty || !files.containsKey('xl/workbook.xml')) {
      try {
        final manualFiles = _ManualZip.parse(bytes);
        for (final entry in manualFiles.entries) {
          files.putIfAbsent(entry.key, () => entry.value);
        }
      } catch (_) {
        // 手写解析器也失败
      }
    }
    return files;
  }

  // ─── 解析 sharedStrings ───

  static List<String> _parseSharedStrings(Uint8List? ssBytes) {
    if (ssBytes == null) return [];
    try {
      final xml = utf8.decode(ssBytes, allowMalformed: true);
      final siRE = RegExp(r'<si[\s>](.*?)</si>', dotAll: true);
      final tRE = RegExp(r'<t(?:\s[^>]*)?>([^<]*)</t>');
      final result = <String>[];
      for (final siMatch in siRE.allMatches(xml)) {
        final siContent = siMatch.group(1) ?? '';
        final buf = StringBuffer();
        for (final tMatch in tRE.allMatches(siContent)) {
          buf.write(tMatch.group(1));
        }
        result.add(_decodeXmlEntities(buf.toString()));
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  // ─── 解析 workbook.xml sheet 名称 ───

  static List<String> _parseSheetNames(Uint8List? wbBytes) {
    if (wbBytes == null) return [];
    try {
      final wbXml = utf8.decode(wbBytes, allowMalformed: true);
      final nameRE = RegExp(r'<sheet\s[^>]*?name="([^"]+)"');
      return nameRE
          .allMatches(wbXml)
          .map((m) => _decodeXmlEntities(m.group(1)!))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ─── 解析 styles.xml ───

  /// 样式索引 → 样式信息
  static _XlsxStyles _parseStyles(Uint8List? stylesBytes) {
    if (stylesBytes == null) return _XlsxStyles.empty();
    try {
      final xml = utf8.decode(stylesBytes, allowMalformed: true);

      // 解析字体
      final fonts = <_XlsxFont>[];
      final fontRE =
          RegExp(r'<font[^>]*>(.*?)</font>', dotAll: true);
      for (final fontMatch in fontRE.allMatches(xml)) {
        final content = fontMatch.group(1) ?? '';
        final isBold = content.contains('<b/>') || content.contains('<b ');
        final isItalic =
            content.contains('<i/>') || content.contains('<i ');
        // 解析颜色：<color rgb="FF000000"/> 或 <color theme="0"/>
        String? color;
        final colorMatch =
            RegExp(r'<color\s+rgb="([A-Fa-f0-9]+)"').firstMatch(content);
        if (colorMatch != null) {
          color = colorMatch.group(1);
        }
        fonts.add(_XlsxFont(isBold: isBold, isItalic: isItalic, color: color));
      }

      // 解析填充背景色
      final fills = <String?>[];
      final fillRE =
          RegExp(r'<fill[^>]*>(.*?)</fill>', dotAll: true);
      for (final fillMatch in fillRE.allMatches(xml)) {
        final content = fillMatch.group(1) ?? '';
        // 背景色：<bgColor rgb="FFFF0000"/> 或 <patternFill><bgColor .../>
        String? bgColor;
        final bgMatch =
            RegExp(r'<bgColor\s+rgb="([A-Fa-f0-9]+)"').firstMatch(content);
        if (bgMatch != null) {
          bgColor = bgMatch.group(1);
        }
        fills.add(bgColor);
      }

      // 解析单元格格式 xf：关联 fontId + fillId
      final cellXfs = <_XlsxXf>[];
      // 处理属性顺序不同的情况
      final xfRE2 =
          RegExp(r'<xf\s+([^>]+)>');
      for (final xfMatch in xfRE2.allMatches(xml)) {
        final attrs = xfMatch.group(1) ?? '';
        final numFmtIdMatch = RegExp(r'numFmtId="(\d+)"').firstMatch(attrs);
        final fontIdMatch = RegExp(r'fontId="(\d+)"').firstMatch(attrs);
        final fillIdMatch = RegExp(r'fillId="(\d+)"').firstMatch(attrs);
        cellXfs.add(_XlsxXf(
          numFmtId: numFmtIdMatch != null
              ? int.tryParse(numFmtIdMatch.group(1)!) ?? 0
              : 0,
          fontId:
              fontIdMatch != null ? int.tryParse(fontIdMatch.group(1)!) ?? 0 : 0,
          fillId:
              fillIdMatch != null ? int.tryParse(fillIdMatch.group(1)!) ?? 0 : 0,
        ));
      }

      return _XlsxStyles(fonts: fonts, fills: fills, cellXfs: cellXfs);
    } catch (_) {
      return _XlsxStyles.empty();
    }
  }

  // ─── 结构化 Sheet 解析 ───

  static XlsxSheet _parseSheetStructured(
    String xml,
    String sheetName,
    List<String> sharedStrings,
    _XlsxStyles styles,
  ) {
    final rowRE = RegExp(r'<row\s[^>]*>(.*?)</row>', dotAll: true);
    final cellRE = RegExp(r'<c\s+([^>]*)>(.*?)</c>', dotAll: true);
    final vRE = RegExp(r'<v>([^<]*)</v>');
    final isRE = RegExp(r'<is>(.*?)</is>', dotAll: true);
    final tInlineRE = RegExp(r'<t(?:\s[^>]*)?>([^<]*)</t>');

    final rows = <XlsxRow>[];
    var maxColCount = 0;

    for (final rowMatch in rowRE.allMatches(xml)) {
      final rowContent = rowMatch.group(1) ?? '';

      // 提取行号
      final rowAttrs = RegExp(r'<row\s+([^>]*)>').firstMatch(xml.substring(rowMatch.start, rowMatch.start + 100));
      final rowAttrStr = rowAttrs?.group(1) ?? '';
      final rowNumMatch = RegExp(r'r="(\d+)"').firstMatch(rowAttrStr);
      final rowNum = rowNumMatch != null
          ? int.tryParse(rowNumMatch.group(1)!) ?? 0
          : rows.length + 1;

      // 用 Map 收集单元格（key = 列序号），确保空列占位
      final cellMap = <int, XlsxCell>{};

      for (final cellMatch in cellRE.allMatches(rowContent)) {
        final attrs = cellMatch.group(1) ?? '';
        final cellContent = cellMatch.group(2) ?? '';

        // 解析坐标 r="A1"
        final rMatch = RegExp(r'r="([A-Z]+)(\d+)"').firstMatch(attrs);
        final columnLetter = rMatch?.group(1) ?? '';
        final columnIndex = columnLetter.isNotEmpty
            ? columnLetterToIndex(columnLetter)
            : cellMap.length;

        // 解析样式索引 s="3"
        final sMatch = RegExp(r's="(\d+)"').firstMatch(attrs);
        final styleIndex = sMatch != null ? int.tryParse(sMatch.group(1)!) : null;

        // 解析单元格类型和值
        String? value;
        final tAttrMatch = RegExp(r't="([^"]+)"').firstMatch(attrs);
        final tAttr = tAttrMatch?.group(1);

        if (tAttr == 's') {
          final vMatch = vRE.firstMatch(cellContent);
          if (vMatch != null) {
            final v = vMatch.group(1);
            final idx = v == null ? -1 : (int.tryParse(v) ?? -1);
            if (idx >= 0 && idx < sharedStrings.length) {
              value = sharedStrings[idx];
            }
          }
        } else if (tAttr == 'inlineStr') {
          final isMatch = isRE.firstMatch(cellContent);
          if (isMatch != null) {
            final isContent = isMatch.group(1) ?? '';
            final buf = StringBuffer();
            for (final tMatch in tInlineRE.allMatches(isContent)) {
              buf.write(tMatch.group(1) ?? '');
            }
            value = _decodeXmlEntities(buf.toString());
          }
        } else {
          final vMatch = vRE.firstMatch(cellContent);
          if (vMatch != null) {
            value = vMatch.group(1);
          }
        }

        if (value != null) {
          value = _decodeXmlEntities(value);
        }

        // 查找样式
        String? bgColor;
        bool bold = false;
        bool italic = false;
        if (styleIndex != null && styleIndex < styles.cellXfs.length) {
          final xf = styles.cellXfs[styleIndex];
          if (xf.fontId < styles.fonts.length) {
            final font = styles.fonts[xf.fontId];
            bold = font.isBold;
            italic = font.isItalic;
          }
          if (xf.fillId < styles.fills.length) {
            bgColor = styles.fills[xf.fillId];
          }
        }

        cellMap[columnIndex] = XlsxCell(
          value: value,
          columnLetter: columnLetter.isNotEmpty
              ? columnLetter
              : columnIndexToLetter(columnIndex),
          columnIndex: columnIndex,
          backgroundColor: bgColor,
          isBold: bold,
          isItalic: italic,
        );
      }

      if (cellMap.isNotEmpty) {
        maxColCount = maxColCount > cellMap.length ? maxColCount : cellMap.length;

        // 填充空列占位
        final sortedKeys = cellMap.keys.toList()..sort();
        final maxKey = sortedKeys.last;
        maxColCount = maxColCount > (maxKey + 1) ? maxColCount : maxKey + 1;

        final cells = <XlsxCell>[];
        for (int col = 0; col < maxColCount; col++) {
          if (cellMap.containsKey(col)) {
            cells.add(cellMap[col]!);
          } else {
            cells.add(XlsxCell(
              columnLetter: columnIndexToLetter(col),
              columnIndex: col,
            ));
          }
        }

        final isEmpty = cells.every((c) => !c.hasValue);
        rows.add(XlsxRow(
          rowIndex: rowNum,
          cells: cells,
          isEmpty: isEmpty,
        ));
      }
    }

    // 二次扫描确保所有行列数一致
    if (rows.isNotEmpty) {
      // 重新计算 maxColumnCount（取所有行中最大列索引+1）
      for (final row in rows) {
        if (row.cells.isNotEmpty) {
          final lastCol = row.cells.last.columnIndex + 1;
          if (lastCol > maxColCount) maxColCount = lastCol;
        }
      }
      // 补齐所有行到 maxColCount
      final normalizedRows = <XlsxRow>[];
      for (final row in rows) {
        if (row.cells.length < maxColCount) {
          final paddedCells = List<XlsxCell>.from(row.cells);
          for (int col = paddedCells.length; col < maxColCount; col++) {
            paddedCells.add(XlsxCell(
              columnLetter: columnIndexToLetter(col),
              columnIndex: col,
            ));
          }
          normalizedRows.add(XlsxRow(
            rowIndex: row.rowIndex,
            cells: paddedCells,
            isEmpty: row.isEmpty,
          ));
        } else {
          normalizedRows.add(row);
        }
      }
      rows.clear();
      rows.addAll(normalizedRows);
    }

    final hasHeader = rows.isNotEmpty ? guessHasHeader(rows.first) : false;

    return XlsxSheet(
      name: sheetName,
      rows: rows,
      maxColumnCount: maxColCount,
      hasHeader: hasHeader,
    );
  }

  // ─── XML 实体解码 ───

  static String _decodeXmlEntities(String s) {
    try {
      return s
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .replaceAllMapped(
            RegExp(r'&#(\d+);'),
            (m) => String.fromCharCodes([int.parse(m.group(1)!)]),
          )
          .replaceAllMapped(
            RegExp(r'&#x([0-9a-fA-F]+);'),
            (m) => String.fromCharCodes([int.parse(m.group(1)!, radix: 16)]),
          );
    } catch (_) {
      return s;
    }
  }
}

// ─── 样式内部数据结构 ───

class _XlsxFont {
  final bool isBold;
  final bool isItalic;
  final String? color; // 字体颜色
  const _XlsxFont({this.isBold = false, this.isItalic = false, this.color});
}

class _XlsxXf {
  final int numFmtId;
  final int fontId;
  final int fillId;
  const _XlsxXf(
      {required this.numFmtId, required this.fontId, required this.fillId});
}

class _XlsxStyles {
  final List<_XlsxFont> fonts;
  final List<String?> fills; // 背景色
  final List<_XlsxXf> cellXfs;

  const _XlsxStyles(
      {required this.fonts, required this.fills, required this.cellXfs});

  static _XlsxStyles empty() =>
      const _XlsxStyles(fonts: [], fills: [], cellXfs: []);
}

// ─── 手写 ZIP 解析器（不依赖 archive 包） ───

class _ManualZip {
  static Map<String, Uint8List> parse(List<int> bytes) {
    final result = <String, Uint8List>{};
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    var pos = 0;
    while (pos + 4 <= data.length) {
      if (data[pos] != 0x50 ||
          data[pos + 1] != 0x4B ||
          data[pos + 2] != 0x03 ||
          data[pos + 3] != 0x04) {
        break;
      }
      if (pos + 30 > data.length) break;

      final compressionMethod = _readUint16(data, pos + 8);
      final compressedSize = _readUint32(data, pos + 18);
      // uncompressedSize 在 data descriptor 模式下不可靠，由 actualCompressedSize 推算
      _readUint32(data, pos + 22);
      final fileNameLength = _readUint16(data, pos + 26);
      final extraFieldLength = _readUint16(data, pos + 28);

      final dataStart = pos + 30 + fileNameLength + extraFieldLength;
      if (dataStart > data.length) break;

      final fileNameBytes = data.sublist(pos + 30, pos + 30 + fileNameLength);
      final fileName = utf8.decode(fileNameBytes, allowMalformed: true);

      final actualCompressedSize = compressedSize > 0
          ? compressedSize
          : _findNextLocalHeader(data, dataStart) - dataStart;
      if (actualCompressedSize <= 0 ||
          dataStart + actualCompressedSize > data.length) {
        break;
      }

      final compressedData =
          data.sublist(dataStart, dataStart + actualCompressedSize);
      Uint8List? fileData;
      try {
        if (compressionMethod == 0) {
          fileData = compressedData;
        } else if (compressionMethod == 8) {
          final decoded =
              ZLibDecoder(raw: true).convert(compressedData.toList());
          fileData = Uint8List.fromList(decoded);
        }
      } catch (_) {
        // 解压失败跳过
      }

      if (fileData != null && fileName.isNotEmpty && !fileName.endsWith('/')) {
        result[fileName] = fileData;
      }

      pos = dataStart + actualCompressedSize;
    }
    return result;
  }

  static int _readUint16(Uint8List data, int offset) {
    if (offset + 2 > data.length) return 0;
    return data[offset] | (data[offset + 1] << 8);
  }

  static int _readUint32(Uint8List data, int offset) {
    if (offset + 4 > data.length) return 0;
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  static int _findNextLocalHeader(Uint8List data, int from) {
    for (var i = from; i + 4 <= data.length; i++) {
      if (data[i] == 0x50 &&
          data[i + 1] == 0x4B &&
          data[i + 2] == 0x03 &&
          data[i + 3] == 0x04) {
        return i;
      }
      if (data[i] == 0x50 &&
          data[i + 1] == 0x4B &&
          data[i + 2] == 0x01 &&
          data[i + 3] == 0x02) {
        return i;
      }
    }
    return data.length;
  }
}
