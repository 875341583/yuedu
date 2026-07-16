/// 排版引擎统一入口
///
/// 根据运行平台自动路由：
/// - Web平台：使用Dart纯实现引擎（dart:ffi在Web上不可用）
/// - Native平台（Windows/Android/macOS/Linux）：使用Rust FFI引擎
///
/// 使用Dart条件导入（conditional imports）实现平台路由：
/// `native_engine.dart` 导入dart:ffi，仅在Native平台编译
/// `web_engine.dart` 不导入dart:ffi，仅在Web平台编译
///
/// 使用方式：
/// ```dart
/// final engine = TypesetEngineProvider.engine;
/// final result = engine.typeset('你好世界', config);
/// ```
library;

import 'engine.dart';
import 'types.dart';
import 'typeset_engine_interface.dart';

export 'typeset_engine_interface.dart';

// 条件导入：Web平台用web_engine.dart，Native平台用native_engine.dart
import 'native_engine.dart'
    if (dart.library.html) 'web_engine.dart'
    if (dart.library.io) 'native_engine.dart' as platform;

/// Dart纯实现引擎（直接使用Dart排版引擎，无需FFI）
class DartTypesetEngine implements TypesetEngine {
  @override
  TypesetResult typeset(String text, TypesetConfig config) {
    return typesetParagraph(text, config);
  }

  @override
  void dispose() {}
}

/// 引擎提供者：根据平台返回合适的引擎实例
class TypesetEngineProvider {
  static TypesetEngine? _engine;

  /// 获取当前平台的排版引擎
  static TypesetEngine get engine {
    _engine ??= platform.createNativeEngine();
    return _engine!;
  }

  /// 释放引擎资源
  static void dispose() {
    _engine?.dispose();
    _engine = null;
  }

  /// 当前使用的引擎类型名称（用于调试/显示）
  static String get engineName => platform.nativeEngineName;
}
