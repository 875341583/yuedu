/// 内置插件：PDF OCR 重排
///
/// 对扫描版 PDF 进行 OCR 识别后重排为可读文本。
/// 采用 API 调用架构（用户配置自己的 OCR API 端点），
/// 支持文字、表格、公式的全量 OCR。
///
/// 功能：
/// 1. 调用 OCR API 将扫描版 PDF 页面转为文本
/// 2. 支持多种 OCR 后端（Tesseract 本地 / 云端 API）
/// 3. 表格识别与结构化输出
/// 4. 数学公式识别（LaTeX 输出）
///
/// 插件运行时：仅 API 调用 + Dart 轻量处理
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugin.dart';

class OcrReflowPlugin extends YueDuPlugin {
  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'pdf_ocr_reflow',
        name: 'PDF OCR 重排',
        description: '对扫描版 PDF 进行 OCR 文字识别后重排。支持文字、表格、公式，需配置 OCR API 端点。',
        version: '1.0.0',
        type: PluginType.pdfReflow,
        source: PluginSource.builtin,
        icon: Icons.document_scanner_outlined,
        tags: ['PDF', 'OCR', '扫描版', '重排'],
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
    return const _OcrReflowSettingsPanel();
  }

  // ─── 用户设置 ──────────────────────────────────────────
  static const _kOcrApiUrl = 'yuedu_ocr_api_url';
  static const _kOcrApiKey = 'yuedu_ocr_api_key';
  static const _kOcrBackend = 'yuedu_ocr_backend';

  String _apiUrl = '';
  String _apiKey = '';
  OcrBackend _backend = OcrBackend.tesseractLocal;

  String get apiUrl => _apiUrl;
  String get apiKey => _apiKey;
  OcrBackend get backend => _backend;

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _apiUrl = prefs.getString(_kOcrApiUrl) ?? '';
      _apiKey = prefs.getString(_kOcrApiKey) ?? '';
      final backendIdx = prefs.getInt(_kOcrBackend) ?? 0;
      _backend = OcrBackend.values[backendIdx.clamp(0, OcrBackend.values.length - 1)];
    } catch (_) {}
  }

  Future<void> setApiUrl(String url) async {
    _apiUrl = url;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kOcrApiUrl, url);
    } catch (_) {}
  }

  Future<void> setApiKey(String key) async {
    _apiKey = key;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kOcrApiKey, key);
    } catch (_) {}
  }

  Future<void> setBackend(OcrBackend b) async {
    _backend = b;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kOcrBackend, b.index);
    } catch (_) {}
  }
}

/// OCR 后端选择
enum OcrBackend {
  /// Tesseract 本地（需安装 Tesseract）
  tesseractLocal('Tesseract 本地'),

  /// 云端 OCR API（如百度/腾讯/阿里 OCR）
  cloudApi('云端 API'),

  /// 自定义 API 端点
  custom('自定义端点');

  final String label;
  const OcrBackend(this.label);
}

class _OcrReflowSettingsPanel extends StatefulWidget {
  const _OcrReflowSettingsPanel();

  @override
  State<_OcrReflowSettingsPanel> createState() =>
      _OcrReflowSettingsPanelState();
}

class _OcrReflowSettingsPanelState extends State<_OcrReflowSettingsPanel> {
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final plugin = OcrReflowPlugin();
    _urlController.text = plugin.apiUrl;
    _keyController.text = plugin.apiKey;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plugin = OcrReflowPlugin();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'PDF OCR 重排插件',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          '对扫描版 PDF 进行 OCR 文字识别后重排为可读文本。\n\n'
          '支持的识别内容：\n'
          '• 普通文字（中英文混合）\n'
          '• 表格（结构化输出）\n'
          '• 数学公式（LaTeX 输出）\n\n'
          '需要配置 OCR API 端点，支持本地 Tesseract 或云端 OCR 服务。',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 16),
        // OCR 后端选择
        const Text('OCR 后端', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ...OcrBackend.values.map((b) => RadioListTile<OcrBackend>(
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
            hintText: 'https://api.example.com/ocr',
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
            hintText: '留空则不使用认证',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
          onChanged: (v) async => await plugin.setApiKey(v),
        ),
      ],
    );
  }
}
