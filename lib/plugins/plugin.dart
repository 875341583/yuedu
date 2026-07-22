/// 阅界插件系统 — 插件接口定义
///
/// 设计理念：
/// 由于 Flutter AOT 限制无法真正动态加载代码，阅界插件采用
/// "内置代码模块 + 配置驱动"架构：插件代码随 App 编译，
/// 用户通过插件中心启用/禁用、配置参数、导入配置。
///
/// 插件来源（PluginSource）：
/// - builtin：内置插件（随版本发布）
/// - local：用户从本地导入插件配置 JSON
/// - remote：从 URL 下载插件配置
///
/// 插件类型（PluginType）：
/// - fileManagement：文件管理类（分类、标签、集合）
/// - readingEnhancement：阅读增强类（高亮、翻译、搜索释义）
/// - aiModel：AI 模型类（本地小模型嵌入）
/// - utility：工具类
library;

import 'package:flutter/material.dart';

/// 插件类型
enum PluginType {
  fileManagement('文件管理', Icons.folder_outlined),
  readingEnhancement('阅读增强', Icons.auto_stories),
  pdfReflow('PDF 重排', Icons.replay_outlined),
  aiModel('AI 模型', Icons.psychology),
  utility('工具', Icons.build_outlined);

  final String label;
  final IconData icon;
  const PluginType(this.label, this.icon);
}

/// 插件来源
enum PluginSource {
  builtin('内置'),
  local('本地导入'),
  remote('链接下载');

  final String label;
  const PluginSource(this.label);
}

/// 插件元数据（用于在 UI 展示，不涉及代码加载）
class PluginMetadata {
  final String id;
  final String name;
  final String description;
  final String version;
  final String author;
  final PluginType type;
  final PluginSource source;
  final IconData icon;
  final List<String> tags;

  const PluginMetadata({
    required this.id,
    required this.name,
    required this.description,
    this.version = '1.0.0',
    this.author = '阅界团队',
    required this.type,
    required this.source,
    required this.icon,
    this.tags = const [],
  });
}

/// 阅界插件抽象基类
///
/// 内置插件直接实现此抽象类；外部插件（local/remote）本质是
/// 配置 JSON，由对应的内置插件"宿主"读取配置产生行为差异。
abstract class YueDuPlugin {
  /// 元数据
  PluginMetadata get metadata;

  /// 默认是否启用（首次安装时）
  bool get defaultEnabled => false;

  /// 是否支持在插件中心配置（显示"设置"按钮）
  bool get hasSettings => false;

  /// 生命周期：插件被启用时调用
  Future<void> onLoad();

  /// 生命周期：插件被禁用时调用
  Future<void> onUnload();

  /// 构建设置面板（hasSettings=true 时调用）
  Widget? buildSettingsPanel(BuildContext context) => null;

  /// ── 执行管道（v0.9.0 新增）──────────────────────────────
  /// 插件的核心执行方法，由阅读页调用点触发。
  ///
  /// [context] — 调用方的 BuildContext（可用于弹对话框等）
  /// [params] — 上下文参数，由调用点传入（如当前页文本、PDF文档等）
  ///
  /// 返回插件执行结果（如重排后的文本），失败抛异常。
  /// 默认实现返回未实现，子类按需 override。
  Future<PluginResult> execute(
    BuildContext context, {
    Map<String, dynamic>? params,
  }) async {
    throw UnimplementedError('${metadata.name} 尚未实现 execute()');
  }

  /// 是否提供操作按钮（阅读页浮标栏显示）
  /// 返回 null 表示不显示按钮；返回 Widget 则在浮标栏渲染
  Widget? buildActionButton(BuildContext context) => null;

  /// 便捷访问
  String get id => metadata.id;
  String get name => metadata.name;
}

/// 插件执行结果
class PluginResult {
  /// 结果类型
  final PluginResultType type;

  /// 文本内容（reflow/summary 等场景）
  final String? text;

  /// 附加数据（如分栏检测结果、OCR置信度等）
  final Map<String, dynamic>? extra;

  /// 用户可见的提示消息
  final String? message;

  const PluginResult({
    required this.type,
    this.text,
    this.extra,
    this.message,
  });

  factory PluginResult.text(String t) =>
      PluginResult(type: PluginResultType.reflow, text: t);

  factory PluginResult.message(String m) =>
      PluginResult(type: PluginResultType.info, message: m);

  factory PluginResult.error(String m) =>
      PluginResult(type: PluginResultType.error, message: m);
}

/// 插件结果类型
enum PluginResultType {
  /// 文本重排结果
  reflow,
  /// 信息提示
  info,
  /// 错误
  error,
}
