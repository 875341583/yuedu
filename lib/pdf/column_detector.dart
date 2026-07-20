/// PDF 分栏检测引擎
///
/// 通过分析 PDF 页面文本片段的水平位置分布，
/// 自动检测页面的分栏结构（单栏/双栏/多栏），
/// 用于分栏重排（将多栏 PDF 重排为单栏便于小屏阅读）。
///
/// 检测原理：
/// 1. 获取页面所有文本片段的 bounds
/// 2. 按垂直位置（Y 轴）分块，每块内的文本行视为同一行组
/// 3. 在每个行组内，分析文本片段的 X 坐标分布
/// 4. 若存在明显的横向间隙（> gapThreshold），则判定为分栏
/// 5. 全局统计分栏模式，确定页面整体分栏数
library;

import 'dart:math' as math;
import 'package:pdfrx/pdfrx.dart';

/// 分栏检测结果
class ColumnDetectionResult {
  final int pageNumber;

  /// 检测到的栏数（1=单栏, 2=双栏, 3+=多栏）
  final int columnCount;

  /// 每一栏的 X 范围（PDF 坐标系，left/right）
  final List<ColumnBounds> columns;

  /// 栏间距（中间间隙的 X 范围）
  final List<ColumnGap> gaps;

  /// 检测置信度（0~1），越高越可靠
  final double confidence;

  ColumnDetectionResult({
    required this.pageNumber,
    required this.columnCount,
    required this.columns,
    required this.gaps,
    required this.confidence,
  });

  /// 是否为多栏页面
  bool get isMultiColumn => columnCount > 1;
}

/// 单栏的边界
class ColumnBounds {
  /// 栏左边界（PDF 坐标系 X 值）
  final double left;

  /// 栏右边界（PDF 坐标系 X 值）
  final double right;

  ColumnBounds({required this.left, required this.right});

  double get width => right - left;
}

/// 栏间距
class ColumnGap {
  final double left;
  final double right;
  final double center;

  ColumnGap({required this.left, required this.right})
      : center = (left + right) / 2;

  double get width => right - left;
}

/// 分栏检测引擎
class ColumnDetector {
  ColumnDetector._();

  /// 检测单页的分栏结构
  ///
  /// [page] — PDF 页面
  /// [gapThreshold] — 栏间最小间隙（points），默认 18pt（约 6.35mm）
  /// [minColumnWidth] — 栏最小宽度（points），默认 80pt，低于此视为噪音
  /// [minConfidenceFragments] — 置信度计算所需的最少片段数
  static Future<ColumnDetectionResult?> detectForPage(
    PdfPage page, {
    double gapThreshold = 18.0,
    double minColumnWidth = 80.0,
    int minConfidenceFragments = 5,
  }) async {
    try {
      final text = await page.loadText();
      if (text.fragments.isEmpty) return null;

      final pageWidth = page.width;
      final fragments = text.fragments.where((f) => f.bounds.isNotEmpty).toList();
      if (fragments.isEmpty) return null;

      // 方法 1：基于全局 X 投影直方图
      // 收集所有片段的左右边界，构建 X 轴密度直方图
      final histogram = _buildXHistogram(fragments, pageWidth, binWidth: 5.0);

      // 找到直方图中的"谷"（低密度区域），即为潜在栏间隙
      final valleys = _findValleys(histogram, gapThreshold: gapThreshold / 5.0);

      if (valleys.isEmpty) {
        // 单栏
        return ColumnDetectionResult(
          pageNumber: page.pageNumber,
          columnCount: 1,
          columns: [ColumnBounds(left: 0, right: pageWidth)],
          gaps: [],
          confidence: _computeConfidence(fragments.length, minConfidenceFragments, 1),
        );
      }

      // 根据谷的位置划分栏
      final columns = _splitColumnsByValleys(valleys, pageWidth, minColumnWidth);

      if (columns.length <= 1) {
        return ColumnDetectionResult(
          pageNumber: page.pageNumber,
          columnCount: 1,
          columns: [ColumnBounds(left: 0, right: pageWidth)],
          gaps: [],
          confidence: _computeConfidence(fragments.length, minConfidenceFragments, 1),
        );
      }

      // 构建间隙列表
      final gaps = <ColumnGap>[];
      for (int i = 0; i < valleys.length; i++) {
        gaps.add(ColumnGap(
          left: valleys[i].left * 5.0,
          right: valleys[i].right * 5.0,
        ));
      }

      return ColumnDetectionResult(
        pageNumber: page.pageNumber,
        columnCount: columns.length,
        columns: columns,
        gaps: gaps,
        confidence: _computeConfidence(fragments.length, minConfidenceFragments, columns.length),
      );
    } catch (_) {
      return null;
    }
  }

  /// 检测整份文档的分栏结构
  static Future<List<ColumnDetectionResult?>> detectForDocument(
    PdfDocument doc, {
    double gapThreshold = 18.0,
    double minColumnWidth = 80.0,
  }) async {
    final results = <ColumnDetectionResult?>[];
    for (int i = 0; i < doc.pages.length; i++) {
      try {
        final result = await detectForPage(
          doc.pages[i],
          gapThreshold: gapThreshold,
          minColumnWidth: minColumnWidth,
        );
        results.add(result);
      } catch (_) {
        results.add(null);
      }
    }
    return results;
  }

  /// 构建 X 轴密度直方图
  ///
  /// 将页面水平方向分为若干 bin，统计每个 bin 内文本覆盖的行数
  static List<int> _buildXHistogram(
    List<PdfPageTextFragment> fragments,
    double pageWidth,
    {double binWidth = 5.0}
  ) {
    final binCount = (pageWidth / binWidth).ceil();
    final histogram = List<int>.filled(binCount, 0);

    for (final fragment in fragments) {
      final bounds = fragment.bounds;
      final startBin = (bounds.left / binWidth).floor().clamp(0, binCount - 1);
      final endBin = (bounds.right / binWidth).floor().clamp(0, binCount - 1);
      for (int b = startBin; b <= endBin && b < binCount; b++) {
        histogram[b]++;
      }
    }
    return histogram;
  }

  /// 在直方图中找到"谷"（连续低密度区域）
  ///
  /// [gapThreshold] — 谷的最小宽度（bin 数）
  static List<_Valley> _findValleys(List<int> histogram, {required double gapThreshold}) {
    final valleys = <_Valley>[];
    final maxDensity = histogram.reduce(math.max);

    if (maxDensity == 0) return valleys;

    // 低密度阈值：低于最大密度的 15%
    final lowThreshold = (maxDensity * 0.15).ceil();

    int? valleyStart;
    for (int i = 0; i < histogram.length; i++) {
      if (histogram[i] <= lowThreshold) {
        valleyStart ??= i;
      } else {
        if (valleyStart != null) {
          final width = i - valleyStart;
          if (width >= gapThreshold) {
            valleys.add(_Valley(valleyStart, i));
          }
          valleyStart = null;
        }
      }
    }
    // 处理末尾的谷
    if (valleyStart != null) {
      final width = histogram.length - valleyStart;
      if (width >= gapThreshold) {
        valleys.add(_Valley(valleyStart, histogram.length));
      }
    }

    return valleys;
  }

  /// 根据谷的位置划分栏
  static List<ColumnBounds> _splitColumnsByValleys(
    List<_Valley> valleys,
    double pageWidth,
    double minColumnWidth,
  ) {
    final columns = <ColumnBounds>[];
    double currentLeft = 0.0;

    for (final valley in valleys) {
      final valleyLeft = valley.left * 5.0; // 转回 points
      final valleyRight = valley.right * 5.0;

      // 谷左侧的栏
      final colRight = valleyLeft;
      if (colRight - currentLeft >= minColumnWidth) {
        columns.add(ColumnBounds(left: currentLeft, right: colRight));
      }
      currentLeft = valleyRight;
    }

    // 最后一栏
    if (pageWidth - currentLeft >= minColumnWidth) {
      columns.add(ColumnBounds(left: currentLeft, right: pageWidth));
    }

    return columns;
  }

  /// 计算检测置信度
  static double _computeConfidence(
    int fragmentCount,
    int minFragments,
    int columnCount,
  ) {
    // 片段数太少 → 低置信度
    final fragmentConf = fragmentCount >= minFragments ? 1.0 : fragmentCount / minFragments;
    // 栏数越多需要更多证据
    final columnConf = columnCount <= 1
        ? 1.0
        : math.max(0.0, 1.0 - (columnCount - 1) * 0.1);
    return (fragmentConf * columnConf).clamp(0.0, 1.0);
  }
}

/// 直方图中的"谷"（低密度区域）
class _Valley {
  final int left; // 起始 bin 索引
  final int right; // 结束 bin 索引（不含）

  const _Valley(this.left, this.right);
}

/// 分栏重排器 — 将多栏页面的文本按栏提取并重排为单栏
///
/// 输入：分栏检测结果 + 原始文本片段
/// 输出：按栏序（左栏→右栏）从上到下排列的文本块列表
class ColumnReflower {
  ColumnReflower._();

  /// 将多栏页面的文本按栏重排
  ///
  /// 返回按阅读顺序（左栏从上到下，然后右栏从上到下）排列的文本片段
  static List<ReflowedBlock> reflow(
    PdfPageText text,
    ColumnDetectionResult columnResult,
  ) {
    if (!columnResult.isMultiColumn) {
      // 单栏，按原始顺序
      return text.fragments
          .where((f) => f.bounds.isNotEmpty)
          .map((f) => ReflowedBlock(
                text: f.text,
                bounds: f.bounds,
                columnIndex: 0,
              ))
          .toList();
    }

    final blocks = <ReflowedBlock>[];

    // 按栏处理：每栏内的片段按 Y 坐标排序（PDF 坐标系 top 从大到小 = 从上到下）
    for (int ci = 0; ci < columnResult.columns.length; ci++) {
      final column = columnResult.columns[ci];
      final columnFragments = text.fragments
          .where((f) =>
              f.bounds.isNotEmpty &&
              f.bounds.left >= column.left &&
              f.bounds.right <= column.right)
          .toList();

      // 按 Y 坐标排序：PDF 坐标系 top 值大 = 位置靠上
      columnFragments.sort((a, b) => b.bounds.top.compareTo(a.bounds.top));

      for (final fragment in columnFragments) {
        blocks.add(ReflowedBlock(
          text: fragment.text,
          bounds: fragment.bounds,
          columnIndex: ci,
        ));
      }
    }

    return blocks;
  }
}

/// 重排后的文本块
class ReflowedBlock {
  final String text;
  final PdfRect bounds;
  final int columnIndex;

  const ReflowedBlock({
    required this.text,
    required this.bounds,
    required this.columnIndex,
  });
}
