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
/// 本提取器解包后扫描所有 .xml 文件，将含 <TextObject|TextCode|TextCode 后续指令>
/// 的页面按文件名顺序排列，提取所有 TextCode 内可见文本。
/// OFD 的 TextCode 可能含 X/Y 坐标属性及绘图指令（如 "G\n" 字形），这里采用宽松策略：
/// - 优先取 <TextCode X=".." Y="..">实际文字</TextCode> 形式
/// - 输出每页一段文本
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
    // OFD 页面文件名常见：Pages/Page_N/Content.xml 或 Page_N/PageContent.xml
    // 我们直接遍历所有 .xml 中包含 <TextObject 或 <TextCode 的文件
    final pageEntries = <_OfdPage>[];
    for (final f in archive) {
      final name = f.name;
      if (!name.toLowerCase().endsWith('.xml')) continue;
      String xml;
      try {
        xml = _decodeFile(f);
      } catch (_) {
        continue;
      }
      if (!xml.contains('TextObject') && !xml.contains('TextCode')) continue;
      final text = _extractPageText(xml);
      pageEntries.add(_OfdPage(name, text));
    }

    if (pageEntries.isEmpty) {
      // 退化：直接拼接所有 xml 中的 <TextCode> 内容
      final fallback = StringBuffer();
      for (final f in archive) {
        if (!f.name.toLowerCase().endsWith('.xml')) continue;
        try {
          final xml = _decodeFile(f);
          final text = _extractPageText(xml);
          if (text.isNotEmpty) {
            if (fallback.isNotEmpty) fallback.write('\n\n');
            fallback.write(text);
          }
        } catch (_) {}
      }
      final s = fallback.toString();
      if (s.isEmpty) throw Exception('OFD 文件无可读文本');
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
    if (buffer.isEmpty) throw Exception('OFD 文件无可读文本');
    return buffer.toString();
  }

  /// 解析单个页面 Content.xml 中的文字
  static String _extractPageText(String xml) {
    final buffer = StringBuffer();
    // <TextCode ...>文字</TextCode>
    final tcRE = RegExp(r'<TextCode\b[^>]*>([^<]*)</TextCode>');
    for (final m in tcRE.allMatches(xml)) {
      final raw = m.group(1) ?? '';
      // OFD TextCode 内容可能含字形编码（"G..." 指令），这里启发式过滤：
      // 仅保留正常可见字符（可见 ASCII 与常见中文）
      final cleaned = _cleanOfdText(raw);
      if (cleaned.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(cleaned);
      }
    }
    return buffer.toString();
  }

  /// 清理 OFD TextCode 内的绘图指令噪声
  /// OFD 中字形可能以 'G' 后跟 base64 编码出现，与正常文字混在 TextCode 中较罕见。
  /// 这里保留所有人类可读字符（去掉控制字符），不做激进替换以保证真实文字不丢。
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
    // 退化：尝试匹配 _Page_ 后数字
    final m2 = RegExp(r'/Page[_/](\d+)').firstMatch(path);
    if (m2 != null) return int.tryParse(m2.group(1)!) ?? 0;
    return 0;
  }

  static String _decodeFile(ArchiveFile file) {
    final data = file.content as dynamic;
    if (data is String) return data;
    if (data is List) {
      final bytes = List<int>.from(data);
      // ofd 内 XML 强制 UTF-8，必须用 utf8.decode 正确解析多字节中文
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
