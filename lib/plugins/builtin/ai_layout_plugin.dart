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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../plugin.dart';
import '../plugin_manager.dart';

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

  // ── v0.9.0: 执行管道 ──────────────────────────────────

  @override
  Widget? buildActionButton(BuildContext context) {
    // 阅读页浮标栏的"AI 重排"按钮，仅在已配置时显示
    return null; // 由阅读页直接构建按钮，此处暂返回 null
  }

  /// 重排给定文本：调用 AI 将复杂排版转为适合小屏阅读的格式
  @override
  Future<PluginResult> execute(
    BuildContext context, {
    Map<String, dynamic>? params,
  }) async {
    final rawText = params?['text'] as String? ?? '';
    if (rawText.isEmpty) {
      return PluginResult.error('无可重排的文本内容');
    }
    if (!isConfigured) {
      return PluginResult.error('AI API 未配置，请先在插件设置中填写 API 地址、密钥和模型名称');
    }

    final systemPrompt = '''你是一个专业文档排版重构助手。
请将以下文档内容重构为适合手机小屏阅读的格式：
1. 保留所有文字内容，不增删
2. 按语义分段，每段不超过3-4行
3. 标题独占一行，用【】标注
4. 去除多余的空行和换行
5. 如有表格，转为简洁文本列表
6. 如有公式，用纯文本近似表示''';

    try {
      final result = await callApi(
        systemPrompt: systemPrompt,
        userMessage: rawText,
      );
      return PluginResult.text(result);
    } catch (e) {
      return PluginResult.error('AI 重排失败: $e');
    }
  }

  // ─── 用户设置 ──────────────────────────────────────────
  static const _kAiApiUrl = 'yuedu_ai_api_url';
  static const _kAiApiKey = 'yuedu_ai_api_key';
  static const _kAiModel = 'yuedu_ai_model';
  static const _kAiBackend = 'yuedu_ai_backend';

  String _apiUrl = '';
  String _apiKey = '';
  String _model = '';
  AiBackend _backend = AiBackend.custom;

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
      final backendIdx = prefs.getInt(_kAiBackend) ?? 2; // 默认 custom
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

  /// 一键保存所有配置并返回是否成功
  Future<bool> saveAllSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAiApiUrl, _apiUrl);
      await prefs.setString(_kAiApiKey, _apiKey);
      await prefs.setString(_kAiModel, _model);
      await prefs.setInt(_kAiBackend, _backend.index);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ─── API 调用 ──────────────────────────────────────────

  /// 检查 API 配置是否可用
  bool get isConfigured => _apiUrl.isNotEmpty && _apiKey.isNotEmpty && _model.isNotEmpty;

  /// 获取实际请求地址（兼容末尾有无 /chat/completions）
  String get _effectiveApiUrl {
    var url = _apiUrl.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (!url.endsWith('/chat/completions')) {
      // 如果用户只填了基础地址（如 https://api.siliconflow.cn/v1），自动补全
      if (url.endsWith('/v1') || url.endsWith('/v1')) {
        url = '$url/chat/completions';
      } else {
        url = '$url/chat/completions';
      }
    }
    return url;
  }

  /// 调用 AI API 生成文本（OpenAI 兼容格式）
  ///
  /// [systemPrompt] — 系统提示词
  /// [userMessage] — 用户消息内容
  /// [imageBase64] — 可选的图片 base64 编码（视觉模型用）
  /// [imageMediaType] — 图片媒体类型，默认 image/png
  ///
  /// 返回 AI 生成的文本内容，失败时抛出异常
  Future<String> callApi({
    required String systemPrompt,
    required String userMessage,
    String? imageBase64,
    String imageMediaType = 'image/png',
  }) async {
    if (!isConfigured) {
      throw Exception('AI API 未配置：请先在插件设置中填写 API 地址、密钥和模型名称');
    }

    final url = Uri.parse(_effectiveApiUrl);

    // 构建消息列表
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
    ];

    // 用户消息：纯文本 or 文本+图片
    if (imageBase64 != null && imageBase64.isNotEmpty) {
      messages.add({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': userMessage},
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:$imageMediaType;base64,$imageBase64',
            },
          },
        ],
      });
    } else {
      messages.add({'role': 'user', 'content': userMessage});
    }

    final body = jsonEncode({
      'model': _model,
      'messages': messages,
      'temperature': 0.3,
      'max_tokens': 4096,
      'stream': false,
    });

    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiKey',
      },
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception('API 请求失败 (${response.statusCode}): ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('API 返回数据异常：无 choices');
    }

    final message = choices[0]['message'] as Map<String, dynamic>?;
    final content = message?['content'] as String?;
    if (content == null || content.isEmpty) {
      throw Exception('API 返回数据异常：无 content');
    }

    return content;
  }

  /// 简单文本对话（不传图片）
  Future<String> chat(String userMessage, {String? systemPrompt}) async {
    return callApi(
      systemPrompt: systemPrompt ?? '你是一个文档排版重构助手，负责将复杂的文档排版转为适合小屏阅读的格式。',
      userMessage: userMessage,
    );
  }

  /// 测试 API 连通性，返回 (成功?, 错误信息?)
  Future<(bool, String?)> testConnection() async {
    try {
      final result = await callApi(
        systemPrompt: '请简短回复。',
        userMessage: '回复ok',
      );
      return (result.isNotEmpty, null);
    } catch (e) {
      return (false, e.toString());
    }
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

  /// 从 PluginManager 获取已注册的插件实例（单例）
  AiLayoutPlugin get _plugin {
    final p = PluginManager.instance.all.where((p) => p.id == 'pdf_ai_layout').firstOrNull;
    return p as AiLayoutPlugin;
  }

  @override
  void initState() {
    super.initState();
    _urlController.text = _plugin.apiUrl;
    _keyController.text = _plugin.apiKey;
    _modelController.text = _plugin.model;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _saveSettings() async {
    // 先将当前 controller 值写入插件
    await _plugin.setApiUrl(_urlController.text);
    await _plugin.setApiKey(_keyController.text);
    await _plugin.setModel(_modelController.text);
    final ok = await _plugin.saveAllSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '配置已保存' : '保存失败，请重试'),
        duration: const Duration(seconds: 2),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  bool _testingConnection = false;

  Future<void> _testConnection() async {
    setState(() => _testingConnection = true);
    try {
      await _plugin.setApiUrl(_urlController.text);
      await _plugin.setApiKey(_keyController.text);
      await _plugin.setModel(_modelController.text);
      final (ok, error) = await _plugin.testConnection();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '连接成功，AI API 可正常使用' : '连接失败: ${error ?? "未知错误"}'),
          duration: const Duration(seconds: 4),
          backgroundColor: ok ? Colors.green : Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('连接异常: $e'),
          duration: const Duration(seconds: 4),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  /// 一键填入 SiliconFlow 默认配置
  void _fillSiliconFlowDefaults() {
    _urlController.text = 'https://api.siliconflow.cn/v1/chat/completions';
    _keyController.text = 'sk-qoenrtsudajsgmjkkwsqnnqofetrceoetajjsbngikpmahlc';
    _modelController.text = 'deepseek-ai/DeepSeek-V3';
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final plugin = _plugin;
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
        const SizedBox(height: 28),
        // 一键配置 SiliconFlow（v0.8.3 起始终显示，方便随时恢复推荐配置）
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _fillSiliconFlowDefaults,
            icon: const Icon(Icons.bolt, size: 20),
            label: const Text('一键配置 SiliconFlow（DeepSeek-V3）'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.indigo,
              side: const BorderSide(color: Colors.indigo),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 保存配置按钮
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _saveSettings,
            icon: const Icon(Icons.save, size: 20),
            label: const Text('保存配置'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 测试连接按钮
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _testingConnection ? null : _testConnection,
            icon: _testingConnection
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_find, size: 20),
            label: Text(_testingConnection ? '测试中...' : '测试连接'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.teal,
              side: const BorderSide(color: Colors.teal),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    );
  }
}
