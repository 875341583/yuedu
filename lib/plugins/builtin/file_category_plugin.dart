/// 内置插件：文件分类
///
/// 功能：
/// 1. 按文件格式自动分组（TXT/EPUB/PDF/MOBI/DOCX/PPTX/XLSX/OFD）
/// 2. 自定义标签（用户给书打标签，按标签筛选书籍）
///
/// 启用后，书架页顶部出现"分类视图"切换按钮，点击进入分类视图。
/// 分类视图两种模式：
/// - 按格式分组：显示每种格式的书籍数量和列表
/// - 按标签分组：显示所有标签，点击标签筛选书籍
library;

import 'package:flutter/material.dart';

import '../plugin.dart';
import '../../services/tag_service.dart';

class FileCategoryPlugin extends YueDuPlugin {
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'file_category',
        name: '文件分类',
        description: '按格式自动分组显示书架，支持自定义标签管理书籍。启用后书架顶部出现分类视图入口。',
        version: '1.0.0',
        type: PluginType.fileManagement,
        source: PluginSource.builtin,
        icon: Icons.category_outlined,
        tags: ['分类', '标签', '整理'],
      );

  @override
  bool get defaultEnabled => true;

  @override
  bool get hasSettings => true;

  @override
  Future<void> onLoad() async {
    // 初始化标签服务
    await TagService.instance.init();
  }

  @override
  Future<void> onUnload() async {
    // 插件禁用时不清除数据，仅停止提供功能
  }

  @override
  Widget buildSettingsPanel(BuildContext context) {
    return const _FileCategorySettingsPanel();
  }
}

class _FileCategorySettingsPanel extends StatefulWidget {
  const _FileCategorySettingsPanel();

  @override
  State<_FileCategorySettingsPanel> createState() =>
      _FileCategorySettingsPanelState();
}

class _FileCategorySettingsPanelState
    extends State<_FileCategorySettingsPanel> {
  @override
  Widget build(BuildContext context) {
    final tags = TagService.instance.allTags;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '文件分类插件',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          '此插件在书架页提供按格式分组和自定义标签功能。\n插件已默认启用，无需额外配置。',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 20),
        Text('已有标签 (${tags.length})',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (tags.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('暂无标签，在书架页长按书籍可添加标签',
                style: TextStyle(color: Colors.grey)),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: tags.map((t) {
              return Chip(
                label: Text(t),
                onDeleted: () {
                  // 标签管理：这里只展示，删除由书籍详情操作
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text('请在书架页长按书籍移除标签 "$t"'),
                        duration: const Duration(seconds: 2)),
                  );
                },
              );
            }).toList(),
          ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 16),
        const Text('后续规划',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text(
          '• 自定义分类规则（按书名/作者/文件大小自动归类）\n'
          '• 集合/书单功能（手动创建书籍集合）\n'
          '• 智能推荐分类（基于阅读历史）',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
      ],
    );
  }
}
