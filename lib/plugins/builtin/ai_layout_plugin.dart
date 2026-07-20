/// 内置插件：AI 排版重构
///
/// 使用 AI 模型对 PDF 内容进行智能排版重构，
/// 将复杂排版（学术论文、杂志等）重排为适合小屏阅读的格式。
///
/// 功能：
/// 1. 调用 AI API 将 PDF 页面内容重构为语义化文本
/// 2. 支持用户自己的 API Token（OpenAI / 自部署模型）
/// 3. 支持本地模型（通过 Ollama / LM Studio 等）
/// 4. 保留原始文档的语义结构（标题/段落/列表/公式）
///
/// 插件运行时：仅 API 调用 + Dart 轻量处理
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugin.dart';

class AiLayoutPlugin extends YueDuPlugin {
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'pdf_ai_layout',
        name: 'AI 排版重构',
        description: '使用 AI 模型智能重构 PDF 排版，将复杂排版转为适合小屏阅读的格式。需配置 AI API。',
        version: '1.0.0',
        type: PluginType.pdfReflow,
        source: PluginSource.builtin,
        icon: Icons.auto_awesome_outlined,
        tags: ['PDF', 'AI', '排版', '重排'],
      );

  @override
  bool get defaultEnabled => false;

  @override
  bool get hasSettings => true;

  @override
  Future<void> onLoad() async {
    await _loadSettings();
  }

  @override
  Future<void> onUnload() async {}

  @override
  Widget buildSettingsPanel(BuildContext context) {
    return const _AiLayoutSettingsPanel();
  }

  // ─── 用户设置 ──────────────────────────────────────────
  static const _kAiApiUrl = 'yuedu_ai_api_url';
  static const _kAiApiKey = 'yuedu_ai_api_key';
  static const _kAiModel = 'yuedu_ai_model';
  static const _kAiBackend = 'yuedu_ai_backend';

  String _apiUrl = '';
  String _apiKey = '';
  String _model = '';
  AiBackend _backend = AiBackend.openai;

  String get apiUrl => _apiUrl;
  String get apiKey => _apiKey;
  String get model => _model;
  AiBackend get backend => _backend;

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _apiUrl = prefs.getString(_kAiApiUrl) ?? '';
      _apiKey = prefs.getString(_kAiApiKey) ?? '';
      _model = prefs.getString(_kAiModel) ?? '';
      final backendIdx = prefs.getInt(_kAiBackend) ?? 0;
      _backend = AiBackend.values[backendIdx.clamp(0, AiBackend.values.length - 1)];
    } catch (_) {}
  }

  Future<void> setApiUrl(String url) async {
    _apiUrl = url;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAiApiUrl, url);
    } catch (_) {}
  }

  Future<void> setApiKey(String key) async {
    _apiKey = key;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAiApiKey, key);
    } catch (_) {}
  }

  Future<void> setModel(String m) async {
    _model = m;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAiModel, m);
    } catch (_) {}
  }

  Future<void> setBackend(AiBackend b) async {
    _backend = b;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kAiBackend, b.index);
    } catch (_) {}
  }
}

/// AI 后端选择
enum AiBackend {
  /// OpenAI API（GPT-4V 等）
  openai('OpenAI API'),

  /// 本地模型（Ollama / LM Studio）
  localModel('本地模型'),

  /// 自定义 API 端点（兼容 OpenAI 格式）
  custom('自定义端点');

  final String label;
  const AiBackend(this.label);
}

class _AiLayoutSettingsPanel extends StatefulWidget {
  const _AiLayoutSettingsPanel();

  @override
  State<_AiLayoutSettingsPanel> createState() =>
      _AiLayoutSettingsPanelState();
}

class _AiLayoutSettingsPanelState extends State<_AiLayoutSettingsPanel> {
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();
  final _modelController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final plugin = AiLayoutPlugin();
    _urlController.text = plugin.apiUrl;
    _keyController.text = plugin.apiKey;
    _modelController.text = plugin.model;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plugin = AiLayoutPlugin();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'AI 排版重构插件',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          '使用 AI 视觉模型智能重构 PDF 排版。\n\n'
          '工作原理：\n'
          '1. 将 PDF 页面转为图片发送给 AI\n'
          '2. AI 识别文档结构（标题/段落/列表/公式/图表）\n'
          '3. 生成语义化 Markdown 文本\n'
          '4. 以可滚动格式展示重构后的内容\n\n'
          '支持后端：\n'
          '• OpenAI GPT-4V 等（需 API Key）\n'
          '• 本地模型（Ollama / LM Studio）\n'
          '• 自定义 OpenAI 兼容端点',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 16),
        // AI 后端选择
        const Text('AI 后端', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ...AiBackend.values.map((b) => RadioListTile<AiBackend>(
              title: Text(b.label),
              value: b,
              groupValue: plugin.backend,
              onChanged: (v) async {
                if (v != null) {
                  await plugin.setBackend(v);
                  setState(() {});
                }
              },
            )),
        const SizedBox(height: 8),
        // API URL
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            labelText: 'API 地址',
            hintText: 'https://api.openai.com/v1',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) async => await plugin.setApiUrl(v),
        ),
        const SizedBox(height: 12),
        // API Key
        TextField(
          controller: _keyController,
          decoration: const InputDecoration(
            labelText: 'API 密钥',
            hintText: 'sk-...',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
          onChanged: (v) async => await plugin.setApiKey(v),
        ),
        const SizedBox(height: 12),
        // Model
        TextField(
          controller: _modelController,
          decoration: const InputDecoration(
            labelText: '模型名称',
            hintText: 'gpt-4o / qwen-vl / ollama:llava',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) async => await plugin.setModel(v),
        ),
      ],
    );
  }
}
