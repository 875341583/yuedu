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

  /// 便捷访问
  String get id => metadata.id;
  String get name => metadata.name;
}
