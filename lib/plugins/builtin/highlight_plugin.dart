/// 内置插件：阅读高亮与笔记
///
/// 功能：
/// 1. 长按阅读页文字选取区段，弹出工具栏：5色高亮 + 添加笔记 + 复制 + 取消
/// 2. 已高亮的区段在阅读页用半透明色背景渲染
/// 3. 目录面板新增"高亮"Tab，查看本书所有高亮与笔记，点击跳转
/// 4. 高亮与笔记持久化到 SharedPreferences，跨重启保留
///
/// 插件只负责：初始化 HighlightService、提供设置面板
/// 渲染与手势逻辑在 ReaderPage 内部，依据 PluginManager.isEnabled('highlight') 决定是否启用
library;

import 'package:flutter/material.dart';

import '../plugin.dart';
import '../../models/highlight.dart';
import '../../services/highlight_service.dart';

class HighlightPlugin extends YueDuPlugin {
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'highlight',
        name: '阅读高亮与笔记',
        description: '长按阅读页文字选取区段，可添加 5 色高亮或笔记。已高亮的文字在阅读页与目录面板中查看，点击跳转回原文位置。',
        version: '1.0.0',
        type: PluginType.readingEnhancement,
        source: PluginSource.builtin,
        icon: Icons.border_color_outlined,
        tags: ['高亮', '笔记', '标注'],
      );

  @override
  bool get defaultEnabled => true;

  @override
  bool get hasSettings => true;

  @override
  Future<void> onLoad() async {
    await HighlightService.instance.loadFromStorage();
  }

  @override
  Future<void> onUnload() async {
    // 禁用时保留数据，仅停止功能展示
  }

  @override
  Widget buildSettingsPanel(BuildContext context) {
    return const _HighlightSettingsPanel();
  }
}

class _HighlightSettingsPanel extends StatefulWidget {
  const _HighlightSettingsPanel();

  @override
  State<_HighlightSettingsPanel> createState() =>
      _HighlightSettingsPanelState();
}

class _HighlightSettingsPanelState extends State<_HighlightSettingsPanel> {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        Text(
          '阅读高亮与笔记插件',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 8),
        Text(
          '在阅读页长按文字可选取区段，弹出工具栏：\n'
          '• 高亮（黄/绿/蓝/红/紫 5 色）\n'
          '• 添加笔记（输入文字后保存）\n'
          '• 复制选中文本\n'
          '• 取消选择\n\n'
          '已高亮的区段在阅读页用对应颜色的半透明背景渲染。\n'
          '点击目录面板的"高亮"Tab 可查看本书所有高亮，点击跳转回原文位置。',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        SizedBox(height: 20),
        Divider(),
        SizedBox(height: 16),
        Text('颜色预设', style: TextStyle(fontWeight: FontWeight.w600)),
        SizedBox(height: 8),
        _ColorPalette(),
        SizedBox(height: 24),
        Text('后续规划', style: TextStyle(fontWeight: FontWeight.w600)),
        SizedBox(height: 8),
        Text(
          '• 高亮区段导出（Markdown / 纯文本）\n'
          '• 高亮跨设备同步（商业版功能）\n'
          '• 高亮检索（按颜色/笔记内容过滤）\n'
          '• 笔记 Markdown 富文本编辑',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
      ],
    );
  }
}

class _ColorPalette extends StatelessWidget {
  const _ColorPalette();

  @override
  Widget build(BuildContext context) {
    final colorNames = ['黄', '绿', '蓝', '红', '紫'];
    return Row(
      children: List.generate(5, (i) {
        return Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Column(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Color(HighlightColors.indexToArgb(i)).withOpacity(0.5),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black12),
                ),
              ),
              const SizedBox(height: 4),
              Text(colorNames[i],
                  style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ],
          ),
        );
      }),
    );
  }
}
