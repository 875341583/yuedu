/// Native平台引擎实现（Windows/Android/macOS/Linux）
///
/// 通过dart:ffi调用Rust编译的typeset_engine动态库
/// Rust引擎已完成换行符支持，可正式启用
library;

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

  @override
  TypesetResult typeset(String text, TypesetConfig config) {
    return _engine.typeset(text, config);
  }

  @override
  void dispose() {
    _engine.dispose();
  }
}
