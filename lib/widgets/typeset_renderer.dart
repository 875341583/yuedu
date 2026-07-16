/// 排版渲染组件：使用CustomPaint绘制排版引擎的结果
library;

import 'package:flutter/material.dart';

import '../typeset/types.dart';

class TypesetRendererWidget extends StatelessWidget {
  final TypesetResult result;
  final TypesetConfig config;
  final Color textColor;
  final Color bgColor;

  const TypesetRendererWidget({
    super.key,
    required this.result,
    required this.config,
    this.textColor = Colors.black87,
    this.bgColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: config.containerWidth,
      decoration: BoxDecoration(
        border: Border.all(color: bgColor.withOpacity(0.2)),
        borderRadius: BorderRadius.circular(4),
        color: bgColor,
      ),
      padding: const EdgeInsets.all(16),
      child: CustomPaint(
        size: Size(config.containerWidth - 32, result.totalHeight),
        painter: _TypesetPainter(result: result, config: config, textColor: textColor),
      ),
    );
  }
}

class _TypesetPainter extends CustomPainter {
  final TypesetResult result;
  final TypesetConfig config;
  final Color textColor;

  _TypesetPainter({required this.result, required this.config, required this.textColor});

  @override
  void paint(Canvas canvas, Size size) {
    for (final glyph in result.glyphs) {
      if (glyph.isCjkLatinSpacing) {
        // 中西文间距不绘制（只是位置留白）
        continue;
      }

      // 跳过换行符
      if (glyph.char == '\n') continue;

      // 用TextPainter逐字符精确定位绘制
      final tp = TextPainter(
        text: TextSpan(
          text: glyph.char,
          style: TextStyle(
            fontSize: config.fontSize,
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
    return oldDelegate.result != result || oldDelegate.config != config || oldDelegate.textColor != textColor;
  }
}
