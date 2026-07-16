/// 字符宽度精确测量模块
///
/// 使用 Flutter TextPainter 进行字符级宽度测量，替代等宽近似估算。
/// 测量结果以 (字符码点, 字号, 字体) 为键进行缓存，避免重复 layout。
///
/// 核心原则：排版引擎的宽度计算必须与渲染器 (TextPainter) 的实际渲染宽度一致，
/// 否则字符位置会与绘制位置偏移，导致重叠或间隙不均。
library;

import 'package:flutter/painting.dart';

import 'types.dart';

/// 字符宽度缓存表
/// key 格式: "codePoint|fontSize|fontFamily"
final Map<String, double> _charWidthCache = {};

/// 清除字符宽度缓存（字号或字体变更时调用）
void clearCharWidthCache() {
  _charWidthCache.clear();
}

/// 使用 TextPainter 精确测量单个字符的渲染宽度
///
/// [ch] 要测量的字符
/// [config] 排版配置（提供字号和字体信息）
/// 返回字符的像素宽度
double measureCharWidth(String ch, TypesetConfig config) {
  if (ch.isEmpty || ch == '\n') return 0.0;

  final code = ch.codeUnitAt(0);
  final cacheKey = '$code|${config.fontSize}|${config.fontFamily ?? ''}';

  final cached = _charWidthCache[cacheKey];
  if (cached != null) return cached;

  final tp = TextPainter(
    text: TextSpan(
      text: ch,
      style: TextStyle(
        fontSize: config.fontSize,
        fontFamily: config.fontFamily,
      ),
    ),
    textDirection: TextDirection.ltr,
  );
  tp.layout();
  final width = tp.width;
  tp.dispose();

  _charWidthCache[cacheKey] = width;
  return width;
}
