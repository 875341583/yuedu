/// 阅界排版引擎 PoC - Dart实现
///
/// 核心职责：
/// - 标点挤压（行首/行尾/连续标点半角化）
/// - 避头尾（行首禁则/行尾禁则）
/// - 中西文间距（中文与西文之间插入1/4 em空隙）
/// - 行分割（按容器宽度将段落拆分为行）
///
/// 输出：每个字符的 x/y 坐标和宽度，供 Flutter TextPainter 逐段渲染。
library;

import 'cjk.dart';
import 'linebreak.dart';
import 'types.dart';

export 'cjk.dart' show isCjk, isCjkPunctuation, isCompressible, Segment, SegmentKind;
export 'linebreak.dart' show breakLines;
export 'types.dart' show TypesetConfig, GlyphInfo, LineInfo, TypesetResult;

/// 简化的字符宽度测量
///
/// PoC阶段使用等价宽度表，MVP阶段替换为精确字体度量
double measureCharWidth(String ch, TypesetConfig config) {
  final em = config.fontSize;
  if (isCjk(ch)) return em; // CJK字符全角
  if (ch.codeUnitAt(0) < 128) return em * 0.5; // ASCII半角
  return em * 0.5; // 其他半角近似
}

/// 排版引擎主入口：对一段纯文本执行排版计算
TypesetResult typesetParagraph(String text, TypesetConfig config) {
  if (text.isEmpty) {
    return const TypesetResult(glyphs: [], lines: [], totalHeight: 0.0);
  }

  final chars = text.split('');
  if (chars.isEmpty) {
    return const TypesetResult(glyphs: [], lines: [], totalHeight: 0.0);
  }

  // 1. 中西文间距处理
  final segments = insertCjkLatinSpacing(chars);

  // 2. 避头尾 + 行分割
  final lines = breakLines(segments, config);

  // 3. 标点挤压 + 计算每个字符的绝对位置
  final glyphs = <GlyphInfo>[];
  final lineInfos = <LineInfo>[];
  var y = 0.0;
  final lineHeight = config.fontSize * config.lineHeightRatio;
  var glyphOffset = 0;

  for (var lineIdx = 0; lineIdx < lines.length; lineIdx++) {
    final line = lines[lineIdx];

    // 空行 = 段落分隔，额外增加半行高的间距
    if (line.isEmpty) {
      y += lineHeight * 0.5; // 段落间距
      continue;
    }

    final squeezed = squeezePunctuation(line);
    var x = 0.0;
    var lineWidth = 0.0;
    var lineGlyphCount = 0;

    for (final seg in squeezed) {
      if (seg.kind == SegmentKind.cjkLatinSpacing) {
        final spacing = config.fontSize * 0.25;
        glyphs.add(GlyphInfo(
          char: ' ',
          x: x,
          y: y,
          width: spacing,
          lineIndex: lineIdx,
          isCjkLatinSpacing: true,
        ));
        x += spacing;
        lineWidth += spacing;
        lineGlyphCount++;
      } else {
        final ch = seg.char_;
        // 如果是挤压后的标点，宽度为半角
        double width;
        bool isSqueezed = false;
        if (isCompressible(ch) && seg.widthEm == 0.5) {
          width = config.fontSize * 0.5;
          isSqueezed = true;
        } else {
          width = measureCharWidth(ch, config);
        }

        glyphs.add(GlyphInfo(
          char: ch,
          x: x,
          y: y,
          width: width,
          lineIndex: lineIdx,
          isSqueezed: isSqueezed,
        ));
        x += width;
        lineWidth += width;
        lineGlyphCount++;
      }
    }

    lineInfos.add(LineInfo(
      startGlyphIndex: glyphOffset,
      glyphCount: lineGlyphCount,
      y: y,
      width: lineWidth,
    ));
    glyphOffset += lineGlyphCount;
    y += lineHeight;
  }

  return TypesetResult(
    glyphs: glyphs,
    lines: lineInfos,
    totalHeight: y,
  );
}
