/// OFD 文本提取器
///
/// OFD（Open Fixed-layout Document，GB/T 33190）是中国版 PDF 的国标格式，
/// 本身为 ZIP 包，内部结构示例：
///   OFD.xml                → 根文档，定位 Doc_N
///   Doc_0/Document.xml     → 文档结构，含 <Pages> 顺序
///   Doc_0/Pages/Page_0/Content.xml
///   Doc_0/Pages/Page_0/PageContent.xml
///   每页 Content.xml 含 <TextObject><TextCode>文本</TextCode></TextObject>
///
/// 本提取器解包后扫描所有 .xml 文件，按多种策略提取文本：
/// 1. 优先提取 <TextCode> 标签内容
/// 2. 补充提取 <TextObject> 内的其他文本
/// 3. 最终 fallback：提取所有 XML 标签外的纯文本
library;

import 'dart:convert';
import 'package:archive/archive.dart';

class OfdTextExtractor {
  static String extract(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw Exception('无效的 OFD 文件：解压失败 ($e)');
    }

    // 收集所有疑似页面内容 XML
    final pageEntries = <_OfdPage>[];
    for (final f in archive) {
      final name = f.name;
      if (name.toLowerCase().endsWith('.xml')) {
        String xml;
        try {
          xml = _decodeFile(f);
        } catch (_) {
          continue;
        }
        // 检查是否含页面内容标记
        if (xml.contains('TextObject') ||
            xml.contains('TextCode') ||
            xml.contains('Page') ||
            xml.contains('Content')) {
          final text = _extractPageText(xml);
          pageEntries.add(_OfdPage(name, text));
        }
      }
    }

    if (pageEntries.isEmpty) {
      // 终极 fallback：遍历所有文件提取可读文本
      final fallback = StringBuffer();
      for (final f in archive) {
        if (!f.name.toLowerCase().endsWith('.xml')) continue;
        try {
          final xml = _decodeFile(f);
          final text = _extractAllReadableText(xml);
          if (text.isNotEmpty) {
            if (fallback.isNotEmpty) fallback.write('\n\n');
            fallback.write(text);
          }
        } catch (_) {}
      }
      final s = fallback.toString();
      if (s.isEmpty) {
        throw Exception(
            'OFD 文件无可读文本。可能原因：1)文件为扫描件(纯图片无文字层)；2)OFD使用了特殊字形编码；3)文件格式异常');
      }
      return s;
    }

    // 按路径中 Page_N 的 N 排序
    pageEntries.sort((a, b) {
      final an = _pageIndexOf(a.name);
      final bn = _pageIndexOf(b.name);
      if (an != bn) return an.compareTo(bn);
      return a.name.compareTo(b.name);
    });

    final buffer = StringBuffer();
    for (var i = 0; i < pageEntries.length; i++) {
      final text = pageEntries[i].text;
      if (text.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write('--- 第 ${i + 1} 页 ---\n');
      buffer.write(text);
    }
    if (buffer.isEmpty) {
      throw Exception(
          'OFD 文件无可读文本。可能原因：1)文件为扫描件(纯图片无文字层)；2)OFD使用了特殊字形编码；3)文件格式异常');
    }
    return buffer.toString();
  }

  /// 解析单个页面 XML 中的文字
  /// 策略1: <TextCode ...>文字</TextCode>
  /// 策略2: <TextObject> 内非子标签的文本
  /// 策略3: 所有 XML 标签外的中文/可读文本
  static String _extractPageText(String xml) {
    final buffer = StringBuffer();

    // 策略1: 标准 <TextCode> 标签
    final tcRE = RegExp(r'<TextCode\b[^>]*>([^<]*)</TextCode>', dotAll: true);
    for (final m in tcRE.allMatches(xml)) {
      final raw = m.group(1) ?? '';
      final cleaned = _cleanOfdText(raw);
      if (cleaned.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(cleaned);
      }
    }

    // 如果策略1已有文本，直接返回（避免重复提取）
    if (buffer.isNotEmpty) return buffer.toString();

    // 策略2: <TextObject> 内的非标签文本（有些OFD不使用TextCode子标签）
    final toRE = RegExp(r'<TextObject\b[^>]*>(.*?)</TextObject>', dotAll: true);
    for (final m in toRE.allMatches(xml)) {
      final inner = m.group(1) ?? '';
      // 去掉子标签，只留文本
      final textOnly = inner.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      final cleaned = _cleanOfdText(textOnly);
      if (cleaned.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(cleaned);
      }
    }

    if (buffer.isNotEmpty) return buffer.toString();

    // 策略3: 提取XML中所有标签外的可读文本
    return _extractAllReadableText(xml);
  }

  /// 提取 XML 中所有标签外的可读文本（终极 fallback）
  static String _extractAllReadableText(String xml) {
    // 去掉所有 XML 标签，只留文本内容
    final textOnly = xml.replaceAll(RegExp(r'<[^>]+>'), ' ');
    // 按空白分割，过滤掉纯符号/纯数字/空串
    final parts = textOnly
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty && _hasReadableChars(s))
        .toList();
    if (parts.isEmpty) return '';
    return parts.join(' ').trim();
  }

  /// 判断字符串是否含有可读字符（中文/字母/数字）
  static bool _hasReadableChars(String s) {
    for (final code in s.runes) {
      // CJK 统一汉字范围
      if (code >= 0x4E00 && code <= 0x9FFF) return true;
      // CJK 扩展A
      if (code >= 0x3400 && code <= 0x4DBF) return true;
      // 基本拉丁字母
      if (code >= 0x41 && code <= 0x5A) return true; // A-Z
      if (code >= 0x61 && code <= 0x7A) return true; // a-z
      // 数字
      if (code >= 0x30 && code <= 0x39) return true;
    }
    return false;
  }

  /// 清理 OFD TextCode 内的绘图指令噪声
  static String _cleanOfdText(String s) {
    final buf = StringBuffer();
    for (final code in s.runes) {
      // 跳过控制字符（除制表/换行）
      if (code < 0x20 && code != 9 && code != 10) continue;
      buf.writeCharCode(code);
    }
    return buf.toString().trim();
  }

  /// 从路径提取 Page_N 中的 N（用于排序）
  static int _pageIndexOf(String path) {
    final m = RegExp(r'Page_(?:(\d+)|\d+_Page_(\d+))').firstMatch(path);
    if (m != null) {
      final v = m.group(1) ?? m.group(2);
      if (v != null) return int.tryParse(v) ?? 0;
    }
    final m2 = RegExp(r'/Page[_/](\d+)').firstMatch(path);
    if (m2 != null) return int.tryParse(m2.group(1)!) ?? 0;
    return 0;
  }

  static String _decodeFile(ArchiveFile file) {
    final data = file.content as dynamic;
    if (data is String) return data;
    if (data is List) {
      final bytes = List<int>.from(data);
      return utf8.decode(bytes, allowMalformed: true);
    }
    return data.toString();
  }
}

class _OfdPage {
  final String name;
  final String text;
  _OfdPage(this.name, this.text);
}
