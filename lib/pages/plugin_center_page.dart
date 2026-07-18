/// 插件中心页面
///
/// 展示所有已注册插件，支持：
/// - 启用/禁用插件
/// - 进入插件设置面板
/// - 本地导入插件配置（预留）
/// - 从 URL 下载插件配置（预留）
library;

import 'package:flutter/material.dart';

import '../plugins/plugin.dart';
import '../plugins/plugin_manager.dart';

class PluginCenterPage extends StatefulWidget {
  const PluginCenterPage({super.key});

  @override
  State<PluginCenterPage> createState() => _PluginCenterPageState();
}

class _PluginCenterPageState extends State<PluginCenterPage> {
  final _manager = PluginManager.instance;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _manager.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plugins = _manager.all;
    // 按类型分组
    final byType = <PluginType, List<YueDuPlugin>>{};
    for (final p in plugins) {
      byType.putIfAbsent(p.metadata.type, () => []).add(p);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('插件中心'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: '本地导入配置',
            onPressed: _importLocalConfig,
          ),
          IconButton(
            icon: const Icon(Icons.cloud_download_outlined),
            tooltip: '从链接下载',
            onPressed: _downloadFromUrl,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 顶部说明卡片
          _buildIntroCard(),
          const SizedBox(height: 16),
          // 按类型展示
          for (final type in PluginType.values)
            if (byType.containsKey(type)) ...[
              _buildTypeHeader(type),
              const SizedBox(height: 8),
              for (final p in byType[type]!)
                _buildPluginCard(p),
              const SizedBox(height: 16),
            ],
          // 未来插件预告
          _buildFuturePluginsCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildIntroCard() {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.extension,
                color: Theme.of(context).colorScheme.primary, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('阅界插件系统',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    '启用插件增强阅读体验。支持本地导入和链接下载扩展能力。',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeHeader(PluginType type) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8),
      child: Row(
        children: [
          Icon(type.icon, size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Text(type.label,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildPluginCard(YueDuPlugin plugin) {
    final enabled = _manager.isEnabled(plugin.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (enabled ? Colors.indigo : Colors.grey).withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            plugin.metadata.icon,
            color: enabled ? Colors.indigo : Colors.grey,
          ),
        ),
        title: Row(
          children: [
            Text(plugin.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                plugin.metadata.source.label,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              ),
            ),
            const SizedBox(width: 6),
            Text('v${plugin.metadata.version}',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(plugin.metadata.description,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (plugin.hasSettings && enabled)
              IconButton(
                icon: const Icon(Icons.settings_outlined, size: 20),
                tooltip: '设置',
                onPressed: () => _openSettings(plugin),
              ),
            Switch(
              value: enabled,
              onChanged: (v) => _manager.toggle(plugin.id),
            ),
          ],
        ),
      ),
    );
  }

  void _openSettings(YueDuPlugin plugin) {
    final panel = plugin.buildSettingsPanel(context);
    if (panel == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('${plugin.name} 设置')),
          body: panel,
        ),
      ),
    );
  }

  Widget _buildFuturePluginsCard() {
    return Card(
      elevation: 0,
      color: Colors.grey.shade100,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.upcoming, color: Colors.grey.shade600, size: 20),
                const SizedBox(width: 8),
                const Text('规划中的插件',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 12),
            _futureItem(Icons.translate, '翻译插件',
                '选中文本翻译为目标语言（接入在线翻译 API 或本地词典）'),
            _futureItem(Icons.search, '搜索释义插件',
                '选词搜索词典释义，支持本地词典和在线百科'),
            _futureItem(Icons.psychology, '本地 AI 小模型',
                '嵌入轻量推理模型，为总结、问答、推荐等提供核心能力'),
          ],
        ),
      ),
    );
  }

  Widget _futureItem(IconData icon, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade500),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13)),
                Text(desc,
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importLocalConfig() async {
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => const _ConfigInputDialog(
        title: '本地导入插件配置',
        hint: '粘贴插件配置 JSON',
      ),
    );
    if (input == null || input.trim().isEmpty) return;
    final ok = await _manager.importLocalConfig(input.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '配置已导入（待宿主插件支持后生效）' : '导入失败'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _downloadFromUrl() async {
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => const _ConfigInputDialog(
        title: '从链接下载插件',
        hint: '输入插件配置 URL',
      ),
    );
    if (url == null || url.trim().isEmpty) return;
    final ok = await _manager.downloadFromUrl(url.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已记录下载链接（完整下载功能下个版本支持）' : '下载失败'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// 配置输入对话框（本地导入/URL下载共用）
class _ConfigInputDialog extends StatefulWidget {
  final String title;
  final String hint;

  const _ConfigInputDialog({required this.title, required this.hint});

  @override
  State<_ConfigInputDialog> createState() => _ConfigInputDialogState();
}

class _ConfigInputDialogState extends State<_ConfigInputDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _controller,
          maxLines: 6,
          decoration: InputDecoration(
            hintText: widget.hint,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
