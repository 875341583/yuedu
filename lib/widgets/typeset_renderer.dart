/// 排版渲染组件：使用CustomPaint绘制排版引擎的结果
///
/// 支持高亮段渲染：调用方计算好每个高亮区段在 glyphs 列表中的起止索引区间，
/// 传给 [TypesetRendererWidget.highlights]，painter 会先在底层画背景矩形再绘字。
library;

import 'package:flutter/material.dart';

import '../typeset/types.dart';

/// 一个高亮区段：[startGlyphIndex, endGlyphIndex) 闭开区间
class HighlightSpan {
  final int startGlyphIndex;
  final int endGlyphIndex;
  final Color color;

  const HighlightSpan({
    required this.startGlyphIndex,
    required this.endGlyphIndex,
    required this.color,
  });

  bool hits(int glyphIndex) =>
      glyphIndex >= startGlyphIndex && glyphIndex < endGlyphIndex;
}

/// 一个临时选区（手指长按拖动选取过程中显示的半透明块）
class SelectionSpan {
  final int startGlyphIndex;
  final int endGlyphIndex;
  final Color color;

  const SelectionSpan({
    required this.startGlyphIndex,
    required this.endGlyphIndex,
    required this.color,
  });

  bool hits(int glyphIndex) =>
      glyphIndex >= startGlyphIndex && glyphIndex < endGlyphIndex;
}

class TypesetRendererWidget extends StatelessWidget {
  final TypesetResult result;
  final TypesetConfig config;
  final Color textColor;
  final Color bgColor;

  /// 当前页的高亮段（持久化高亮，已渲染图层底色）
  final List<HighlightSpan> highlights;

  /// 当前选区（手势进行中临时显示，颜色半透明）
  final SelectionSpan? selection;

  const TypesetRendererWidget({
    super.key,
    required this.result,
    required this.config,
    this.textColor = Colors.black87,
    this.bgColor = Colors.white,
    this.highlights = const [],
    this.selection,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: config.containerWidth,
      color: bgColor,
      child: CustomPaint(
        size: Size(config.containerWidth, result.totalHeight),
        painter: _TypesetPainter(
          result: result,
          config: config,
          textColor: textColor,
          highlights: highlights,
          selection: selection,
        ),
      ),
    );
  }
}

class _TypesetPainter extends CustomPainter {
  final TypesetResult result;
  final TypesetConfig config;
  final Color textColor;
  final List<HighlightSpan> highlights;
  final SelectionSpan? selection;

  _TypesetPainter({
    required this.result,
    required this.config,
    required this.textColor,
    required this.highlights,
    required this.selection,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── 1. 先画高亮背景层（按行合并glyph x范围画Rect） ──
    // 行高约 fontSize * lineHeightRatio
    final lineH = config.fontSize * config.lineHeightRatio;
    final glyphs = result.glyphs;

    void paintSpan(int startIdx, int endIdx, Color color, double opacity) {
      if (startIdx >= endIdx || startIdx < 0 || endIdx > glyphs.length) return;
      // 按行聚合画矩形：同 lineHeight 的连续 glyph 合为一个 Rect
      int i = startIdx;
      while (i < endIdx && i < glyphs.length) {
        final g = glyphs[i];
        if (g.isCjkLatinSpacing || g.char == '\n') {
          i++;
          continue;
        }
        // 行基线 y（glyph.y 是基线，矩形顶部约 y - fontSize * 0.85）
        final top = g.y - config.fontSize * 0.85;
        double left = g.x;
        double right = g.x + g.width;
        int j = i + 1;
        // 同行往后聚合
        while (j < endIdx && j < glyphs.length) {
          final g2 = glyphs[j];
          if (g2.isCjkLatinSpacing || g2.char == '\n') {
            j++;
            continue;
          }
          final top2 = g2.y - config.fontSize * 0.85;
          if ((top2 - top).abs() > 0.5) break; // 不同行
          right = g2.x + g2.width;
          j++;
        }
        final rect = Rect.fromLTRB(left, top, right, top + lineH);
        final paint = Paint()..color = color.withOpacity(opacity);
        canvas.drawRect(rect, paint);
        i = j;
      }
    }

    // 持久化高亮（opacity 0.35）
    for (final h in highlights) {
      paintSpan(h.startGlyphIndex, h.endGlyphIndex, h.color, 0.35);
    }

    // 临时选区（opacity 0.25，蓝灰）
    if (selection != null) {
      final s = selection!;
      final start = s.startGlyphIndex < s.endGlyphIndex
          ? s.startGlyphIndex
          : s.endGlyphIndex;
      final end = s.startGlyphIndex < s.endGlyphIndex
          ? s.endGlyphIndex
          : s.startGlyphIndex;
      paintSpan(start, end, s.color, 0.25);
    }

    // ── 2. 再画文字层 ──
    for (final glyph in glyphs) {
      if (glyph.isCjkLatinSpacing) {
        continue;
      }
      if (glyph.char == '\n') continue;

      final tp = TextPainter(
        text: TextSpan(
          text: glyph.char,
          style: TextStyle(
            fontSize: config.fontSize,
            fontFamily: config.fontFamily,
            color: glyph.isSqueezed ? textColor.withOpacity(0.6) : textColor,
            height: config.lineHeightRatio,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, Offset(glyph.x, glyph.y));
    }
  }

  @override
  bool shouldRepaint(covariant _TypesetPainter oldDelegate) {
    return oldDelegate.result != result ||
        oldDelegate.config != config ||
        oldDelegate.textColor != textColor ||
        _listDiffers(oldDelegate.highlights, highlights) ||
        oldDelegate.selection != selection;
  }

  bool _listDiffers(List<HighlightSpan> a, List<HighlightSpan> b) {
    if (a.length != b.length) return true;
    for (int i = 0; i < a.length; i++) {
      if (a[i].startGlyphIndex != b[i].startGlyphIndex ||
          a[i].endGlyphIndex != b[i].endGlyphIndex ||
          a[i].color != b[i].color) {
        return true;
      }
    }
    return false;
  }
}
