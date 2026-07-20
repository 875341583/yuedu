/// 内置插件：PDF 文本重排
///
/// 将 PDF 多栏文本重排为单栏，方便小屏阅读。
/// 基于 Dart 移植的 k2pdfopt 核心算法（纯 Dart 轻量处理），
/// 仅调用 Dart 端文本分析 + 分栏检测，不依赖 FFI/ONNX。
///
/// 功能：
/// 1. 检测 PDF 页面的分栏结构（调用 ColumnDetector）
/// 2. 按阅读顺序（左栏→右栏，从上到下）重排文本
/// 3. 将重排后的文本以可滚动单栏方式展示
/// 4. 支持用户自定义重排参数（字体大小、行距等）
///
/// 插件运行时：仅 API 调用 + Dart 轻量处理
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugin.dart';
import '../../pdf/pdf_engines.dart';

class TextReflowPlugin extends YueDuPlugin {
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'pdf_text_reflow',
        name: 'PDF 文本重排',
        description: '将 PDF 多栏文本智能重排为单栏，方便小屏阅读。支持自定义字体大小和行距。',
        version: '1.0.0',
        type: PluginType.pdfReflow,
        source: PluginSource.builtin,
        icon: Icons.replay_outlined,
        tags: ['PDF', '重排', '分栏', '小屏'],
      );

  @override
  bool get defaultEnabled => false;

  @override
  bool get hasSettings => true;

  @override
  Future<void> onLoad() async {
    // 加载用户偏好设置
    await _loadSettings();
  }

  @override
  Future<void> onUnload() async {
    // 禁用时保留数据
  }

  @override
  Widget buildSettingsPanel(BuildContext context) {
    return const _TextReflowSettingsPanel();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _fontSize = prefs.getDouble(_kReflowFontSize) ?? 16.0;
      _lineHeight = prefs.getDouble(_kReflowLineHeight) ?? 1.6;
    } catch (_) {}
  }

  // ─── 用户设置 ──────────────────────────────────────────
  static const _kReflowFontSize = 'yuedu_reflow_font_size';
  static const _kReflowLineHeight = 'yuedu_reflow_line_height';

  double _fontSize = 16.0;
  double _lineHeight = 1.6;

  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;

  Future<void> setFontSize(double size) async {
    _fontSize = size;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kReflowFontSize, size);
    } catch (_) {}
  }

  Future<void> setLineHeight(double height) async {
    _lineHeight = height;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kReflowLineHeight, height);
    } catch (_) {}
  }
}

class _TextReflowSettingsPanel extends StatefulWidget {
  const _TextReflowSettingsPanel();

  @override
  State<_TextReflowSettingsPanel> createState() =>
      _TextReflowSettingsPanelState();
}

class _TextReflowSettingsPanelState extends State<_TextReflowSettingsPanel> {
  @override
  Widget build(BuildContext context) {
    final plugin = TextReflowPlugin();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'PDF 文本重排插件',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          '将 PDF 多栏文本智能重排为单栏，方便小屏阅读。\n\n'
          '工作原理：\n'
          '1. 分析 PDF 页面文本位置分布\n'
          '2. 自动检测分栏结构（单栏/双栏/多栏）\n'
          '3. 按阅读顺序（左栏→右栏，从上到下）重排\n'
          '4. 以可滚动单栏方式展示重排后的文本\n\n'
          '适用场景：学术论文、报纸排版、杂志文章等多栏 PDF。',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 16),
        const Text('重排参数', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        // 字体大小
        Row(
          children: [
            const Text('字体大小', style: TextStyle(fontSize: 14)),
            const Spacer(),
            Text('${plugin.fontSize.round()}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
        Slider(
          value: plugin.fontSize,
          min: 12.0,
          max: 28.0,
          divisions: 16,
          label: '${plugin.fontSize.round()}',
          onChanged: (v) async {
            await plugin.setFontSize(v);
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        // 行距
        Row(
          children: [
            const Text('行距倍数', style: TextStyle(fontSize: 14)),
            const Spacer(),
            Text('${plugin.lineHeight.toStringAsFixed(1)}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
        Slider(
          value: plugin.lineHeight,
          min: 1.0,
          max: 2.5,
          divisions: 15,
          label: plugin.lineHeight.toStringAsFixed(1),
          onChanged: (v) async {
            await plugin.setLineHeight(v);
            setState(() {});
          },
        ),
        const SizedBox(height: 24),
        const Text('后续规划', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text(
          '• 段落识别与合并\n'
          '• 公式/图表保留原位\n'
          '• 自定义重排模板\n'
          '• 重排结果导出',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
      ],
    );
  }
}
