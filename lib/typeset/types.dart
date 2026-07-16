/// 排版引擎公共类型定义
library;

/// 排版配置
class TypesetConfig {
  /// 字号（逻辑像素，也是em单位的基准）
  final double fontSize;

  /// 行高倍率
  final double lineHeightRatio;

  /// 容器宽度（逻辑像素）
  final double containerWidth;

  const TypesetConfig({
    this.fontSize = 16.0,
    this.lineHeightRatio = 1.6,
    this.containerWidth = 360.0,
  });
}

/// 单个字符的位置信息
class GlyphInfo {
  /// 字符
  final String char;

  /// x 坐标
  final double x;

  /// y 坐标
  final double y;

  /// 字符宽度
  final double width;

  /// 所在行索引
  final int lineIndex;

  /// 是否为标点挤压后的字符
  final bool isSqueezed;

  /// 是否为中西文间距
  final bool isCjkLatinSpacing;

  const GlyphInfo({
    required this.char,
    required this.x,
    required this.y,
    required this.width,
    required this.lineIndex,
    this.isSqueezed = false,
    this.isCjkLatinSpacing = false,
  });

  @override
  String toString() =>
      'GlyphInfo(char: $char, x: $x, y: $y, w: $width, line: $lineIndex${isSqueezed ? ' [squeeze]' : ''}${isCjkLatinSpacing ? ' [cjk-lat]' : ''})';
}

/// 行信息
class LineInfo {
  /// 行内起始 glyph 索引
  final int startGlyphIndex;

  /// 行内 glyph 数量
  final int glyphCount;

  /// 行的 y 坐标
  final double y;

  /// 行宽（含标点挤压）
  final double width;

  const LineInfo({
    required this.startGlyphIndex,
    required this.glyphCount,
    required this.y,
    required this.width,
  });
}

/// 排版结果
class TypesetResult {
  /// 每个字符的位置信息
  final List<GlyphInfo> glyphs;

  /// 每行的信息
  final List<LineInfo> lines;

  /// 总高度
  final double totalHeight;

  const TypesetResult({
    required this.glyphs,
    required this.lines,
    required this.totalHeight,
  });
}
