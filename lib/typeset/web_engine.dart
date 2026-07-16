/// Web平台引擎实现（不支持dart:ffi）
///
/// 此文件仅在Web平台编译，通过条件导入控制
library;

import 'engine.dart';
import 'types.dart';
import 'typeset_engine_interface.dart';

/// 创建Web平台引擎实例（使用Dart纯实现）
TypesetEngine createNativeEngine() {
  return _WebTypesetEngine();
}

/// Web平台的引擎类型名称
String get nativeEngineName => 'Dart (Web)';

/// Web平台的排版引擎（委托给Dart纯实现）
class _WebTypesetEngine implements TypesetEngine {
  @override
  TypesetResult typeset(String text, TypesetConfig config) {
    return typesetParagraph(text, config);
  }

  @override
  void dispose() {}
}
