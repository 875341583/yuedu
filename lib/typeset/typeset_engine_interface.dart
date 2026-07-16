/// 排版引擎接口定义
///
/// 独立文件，避免条件导入时的循环依赖
library;

import 'types.dart';

/// 引擎接口
abstract class TypesetEngine {
  /// 对一段文本执行排版计算
  TypesetResult typeset(String text, TypesetConfig config);

  /// 释放资源
  void dispose();
}
