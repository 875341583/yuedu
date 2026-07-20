/// 阅界插件系统 — 插件管理器
///
/// 职责：
/// - 注册内置插件
/// - 持久化启用状态（SharedPreferences）
/// - 提供 enable / disable / isEnabled 接口
/// - 预留本地导入和 URL 下载（写入配置，由对应宿主插件读取）
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin.dart';
import 'builtin/file_category_plugin.dart';
import 'builtin/highlight_plugin.dart';
import 'builtin/text_reflow_plugin.dart';
import 'builtin/ocr_reflow_plugin.dart';
import 'builtin/ai_layout_plugin.dart';

/// 启用状态变化通知回调
typedef PluginStateCallback = void Function(String pluginId, bool enabled);

class PluginManager extends ChangeNotifier {
  PluginManager._();
  static final PluginManager instance = PluginManager._();

  static const _kEnabledKey = 'yuedu_enabled_plugins';
  static const _kDisabledExplicitKey = 'yuedu_disabled_explicit';
  static const _kLocalConfigKey = 'yuedu_local_plugin_configs';
  static const _kRemoteConfigKey = 'yuedu_remote_plugin_configs';

  /// 所有已注册插件（按注册顺序）
  final List<YueDuPlugin> _all = [];

  /// 当前启用的插件 id 集合
  final Set<String> _enabled = {};

  /// 本地导入的插件配置（JSON 字符串列表）
  final List<String> _localConfigs = [];

  /// 远程下载的插件配置（JSON 字符串列表）
  final List<String> _remoteConfigs = [];

  /// 是否已初始化
  bool _initialized = false;

  List<YueDuPlugin> get all => List.unmodifiable(_all);

  List<YueDuPlugin> get enabled =>
      _all.where((p) => _enabled.contains(p.id)).toList();

  bool isEnabled(String id) => _enabled.contains(id);

  bool get isInitialized => _initialized;

  /// 初始化：注册内置插件 + 读取持久化状态 + 加载已启用插件
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // 注册内置插件
    _register(FileCategoryPlugin());
    _register(HighlightPlugin());
    _register(TextReflowPlugin());
    _register(OcrReflowPlugin());
    _register(AiLayoutPlugin());

    // 读取持久化
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_kEnabledKey) ?? <String>[];
      // 只恢复仍存在的插件 id
      _enabled.addAll(saved.where((id) =>
          _all.any((p) => p.id == id)));
      // 升级迁移：对 defaultEnabled=true 的插件，若用户未显式禁用过则补启用
      // （老用户升级到引入新插件的版本时，saved 非空但不含新插件 id，需补启用）
      final explicitlyDisabled = <String>{};
      try {
        final disabledRaw = prefs.getStringList(_kDisabledExplicitKey) ?? <String>[];
        explicitlyDisabled.addAll(disabledRaw.where((id) => _all.any((p) => p.id == id)));
      } catch (_) {}
      for (final p in _all) {
        if (p.defaultEnabled && !_enabled.contains(p.id) && !explicitlyDisabled.contains(p.id)) {
          _enabled.add(p.id);
        }
      }
      _localConfigs.addAll(prefs.getStringList(_kLocalConfigKey) ?? <String>[]);
      _remoteConfigs.addAll(prefs.getStringList(_kRemoteConfigKey) ?? <String>[]);
    } catch (_) {}

    // 加载已启用插件
    for (final p in _all) {
      if (_enabled.contains(p.id)) {
        try {
          await p.onLoad();
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  void _register(YueDuPlugin plugin) {
    if (_all.any((p) => p.id == plugin.id)) return;
    _all.add(plugin);
  }

  /// 启用插件
  Future<bool> enable(String id) async {
    final p = _all.where((p) => p.id == id).firstOrNull;
    if (p == null) return false;
    if (_enabled.contains(id)) return true;
    try {
      await p.onLoad();
      _enabled.add(id);
      // 清除显式禁用标记
      try {
        final prefs = await SharedPreferences.getInstance();
        final list = prefs.getStringList(_kDisabledExplicitKey) ?? <String>[];
        if (list.contains(id)) {
          list.remove(id);
          await prefs.setStringList(_kDisabledExplicitKey, list);
        }
      } catch (_) {}
      await _persist();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 禁用插件
  Future<bool> disable(String id) async {
    final p = _all.where((p) => p.id == id).firstOrNull;
    if (p == null) return false;
    if (!_enabled.contains(id)) return true;
    try {
      await p.onUnload();
      _enabled.remove(id);
      // 记录显式禁用，供升级迁移逻辑参考（避免升级时自动补启用）
      if (p.defaultEnabled) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final list = prefs.getStringList(_kDisabledExplicitKey) ?? <String>[];
          if (!list.contains(id)) {
            list.add(id);
            await prefs.setStringList(_kDisabledExplicitKey, list);
          }
        } catch (_) {}
      }
      await _persist();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 切换启用状态
  Future<bool> toggle(String id) {
    return _enabled.contains(id) ? disable(id) : enable(id);
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kEnabledKey, _enabled.toList());
      await prefs.setStringList(_kLocalConfigKey, _localConfigs);
      await prefs.setStringList(_kRemoteConfigKey, _remoteConfigs);
    } catch (_) {}
  }

  /// ── 本地导入（预留） ───────────────────────────────────
  /// 当前实现：将插件配置 JSON 保存到本地配置列表，
  /// 由对应的内置宿主插件读取并应用。真正"代码级"插件需要
  /// Flutter 动态化能力，后续版本探索。
  Future<bool> importLocalConfig(String jsonConfig) async {
    try {
      _localConfigs.add(jsonConfig);
      await _persist();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// ── 链接下载（预留） ───────────────────────────────────
  /// 从 URL 下载插件配置 JSON，保存到远程配置列表。
  Future<bool> downloadFromUrl(String url) async {
    try {
      // TODO: 实际 HTTP 下载（需要网络权限和 http 包）
      // 当前仅记录 URL，后续版本实现完整下载
      _remoteConfigs.add('{"url":"$url","downloadedAt":"${DateTime.now().toIso8601String()}"}');
      await _persist();
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  List<String> get localConfigs => List.unmodifiable(_localConfigs);
  List<String> get remoteConfigs => List.unmodifiable(_remoteConfigs);
}
