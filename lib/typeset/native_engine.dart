/// Native平台引擎实现（Windows/Android/macOS/Linux）
///
/// 通过dart:ffi调用Rust编译的typeset_engine动态库
/// Rust引擎已完成换行符支持，可正式启用
library;

import 'dart:io';

import 'font_metrics.dart';
import 'rust_ffi.dart';
import 'types.dart';
import 'typeset_engine_interface.dart';

/// 创建Native平台引擎实例（使用Rust FFI）
TypesetEngine createNativeEngine() {
  return _RustEngineWrapper();
}

/// Native平台的引擎类型名称
String get nativeEngineName => 'Rust FFI';

/// Rust FFI引擎的TypesetEngine适配器
class _RustEngineWrapper implements TypesetEngine {
  final RustTypesetEngine _engine = RustTypesetEngine();
  bool _fontLoaded = false;

  _RustEngineWrapper() {
    _tryLoadFont();
  }

  /// 尝试加载系统字体，使 Rust 引擎获得精确度量能力
  void _tryLoadFont() {
    final candidates = _getFontCandidates();
    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) {
        final ok = _engine.setFontPath(path);
        if (ok) {
          _fontLoaded = true;
          break;
        }
      }
    }
  }

  /// 获取当前平台的字体文件候选列表（按优先级排序）
  List<String> _getFontCandidates() {
    if (Platform.isWindows) {
      return [
        r'C:\Windows\Fonts\msyh.ttc',      // Microsoft YaHei
        r'C:\Windows\Fonts\msyh.ttf',      // Microsoft YaHei (standalone)
        r'C:\Windows\Fonts\simhei.ttf',    // SimHei
        r'C:\Windows\Fonts\simsun.ttc',    // SimSun
      ];
    } else if (Platform.isAndroid) {
      return [
        '/system/fonts/NotoSansCJK-Regular.ttc',
        '/system/fonts/DroidSansFallback.ttf',
        '/system/fonts/Roboto-Regular.ttf',
      ];
    } else if (Platform.isLinux) {
      return [
        '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
        '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
        '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
        '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
      ];
    } else if (Platform.isMacOS) {
      return [
        '/System/Library/Fonts/PingFang.ttc',
        '/Library/Fonts/Arial Unicode.ttf',
      ];
    }
    return [];
  }

  @override
  TypesetResult typeset(String text, TypesetConfig config) {
    // 使用 TextPainter 预测量所有唯一字符的宽度，传给 Rust 引擎
    // 确保引擎度量值与渲染器完全一致
    _syncCharWidths(text, config);
    return _engine.typeset(text, config);
  }

  /// 提取文本中的唯一字符，用 TextPainter 测量宽度，传给 Rust 引擎
  void _syncCharWidths(String text, TypesetConfig config) {
    final uniqueChars = <int>{};
    for (final ch in text.runes) {
      if (ch != 10 && ch != 13) { // 跳过换行符
        uniqueChars.add(ch);
      }
    }

    if (uniqueChars.isEmpty) return;

    final widthTable = <int, double>{};
    for (final codePoint in uniqueChars) {
      final ch = String.fromCharCode(codePoint);
      widthTable[codePoint] = measureCharWidth(ch, config);
    }

    _engine.setCharWidths(widthTable);
  }

  @override
  void dispose() {
    _engine.dispose();
  }
}
