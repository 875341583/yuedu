/// 行分割模块：按容器宽度将段落拆分为行
library;

import 'cjk.dart';
import 'font_metrics.dart';
import 'types.dart';

/// 将排版段列表分割为多行
List<List<Segment>> breakLines(List<Segment> segments, TypesetConfig config) {
  if (segments.isEmpty) return [];

  final maxWidth = config.containerWidth;
  final lines = <List<Segment>>[];
  var currentLine = <Segment>[];
  var currentWidth = 0.0;

  var i = 0;
  while (i < segments.length) {
    final seg = segments[i];

    // 换行符：强制结束当前行
    if (seg.kind == SegmentKind.lineBreak) {
      // 先保存当前行（如果有内容）
      if (currentLine.isNotEmpty) {
        lines.add(currentLine);
        currentLine = <Segment>[];
        currentWidth = 0.0;
      }
      // 标记这是一个段落分隔（通过在lines中插入空行）
      // 空行列表用于后续引擎计算段落间距
      lines.add([]); // 空行 = 段落标记
      i++;
      continue;
    }

    // 精确度量：中西文间距用固定 1/4 em，字符用 TextPainter 真实宽度
    final segWidth = seg.kind == SegmentKind.cjkLatinSpacing
        ? config.fontSize * 0.25
        : measureCharWidth(seg.char_, config);

    if (currentWidth + segWidth > maxWidth && currentLine.isNotEmpty) {
      // 超出容器宽度，需要换行
      // 应用避头尾规则
      final breakResult = _applyKinsoku(
        segments.sublist(i),
        currentLine,
        currentWidth,
        config,
      );

      lines.add(breakResult.currentLine);
      currentLine = <Segment>[];
      currentWidth = 0.0;
      i += breakResult.skipCount;
      continue;
    }

    currentWidth += segWidth;
    currentLine.add(seg);
    i++;
  }

  if (currentLine.isNotEmpty) {
    lines.add(currentLine);
  }

  return lines;
}

/// 应用避头尾规则的结果
class _BreakResult {
  final List<Segment> currentLine;
  final int skipCount;

  _BreakResult(this.currentLine, this.skipCount);
}

/// 应用避头尾规则
  _BreakResult _applyKinsoku(
  List<Segment> remaining,
  List<Segment> currentLine,
  double _currentWidth,
  TypesetConfig config,
) {
  // em not needed in kinsoku check currently

  // 检查下一个字符是否为行首禁则
  if (remaining.isNotEmpty && remaining[0].kind == SegmentKind.character) {
    final ch = remaining[0].char_;
    if (!canBeLineHead(ch)) {
      // 行首禁则：将禁则字符附加到上一行
      final newLine = List<Segment>.from(currentLine);
      newLine.add(remaining[0]);
      return _BreakResult(newLine, 1);
    }
  }

  // 检查当前行最后一个字符是否为行尾禁则
  if (currentLine.isNotEmpty) {
    final lastSeg = currentLine.last;
    if (lastSeg.kind == SegmentKind.character && !canBeLineTail(lastSeg.char_)) {
      // 行尾禁则：将最后字符移到下一行
      final newLine = List<Segment>.from(currentLine)..removeLast();
      return _BreakResult(newLine, 0);
    }
  }

  return _BreakResult(currentLine, 0);
}
