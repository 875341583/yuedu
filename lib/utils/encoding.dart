/// 文本编码检测与解码工具
library;

import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;
import 'package:gbk_codec/gbk_codec.dart';

/// 智能解码TXT文件bytes（在Isolate中执行，不阻塞UI）
/// 优先级: UTF-8 BOM > UTF-16 BOM > UTF-8 > GBK > UTF-8(allowMalformed)
/// 使用Flutter compute()：Native平台走Isolate，Web平台同步执行（但O(n)分块解码仍很快）
Future<String> decodeTextBytesAsync(List<int> bytes) async {
  if (bytes.isEmpty) return '';
  return compute(_decodeTextBytesSync, bytes);
}

/// 同步解码（供Isolate内部调用）
String _decodeTextBytesSync(List<int> bytes) {
  if (bytes.isEmpty) return '';

  // 检查UTF-8 BOM (EF BB BF)
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }

  // 检查UTF-16 LE BOM (FF FE)
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16Le(bytes.sublist(2));
  }

  // 检查UTF-16 BE BOM (FE FF)
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16Be(bytes.sublist(2));
  }

  // 尝试UTF-8严格解码
  try {
    return utf8.decode(bytes);
  } catch (_) {}

  // UTF-8失败，尝试GBK解码（分块优化，避免O(n²)）
  try {
    return _decodeGbkChunked(bytes);
  } catch (_) {}

  // 最终回退: UTF-8 允许错误
  return utf8.decode(bytes, allowMalformed: true);
}

/// 分块GBK解码
/// 原版gbk_bytes.decode()内部用ret+=char是O(n²)，15MB会卡死
/// 改为每8KB调一次decoder，结果写入StringBuffer（O(n)）
///
/// 改进：块末尾边界检测改为前向扫描，找到最后一个完整字符的边界。
/// 旧方案只检查最后1字节是否在0x81-0xFE范围，但该范围同时包含首字节和尾字节，
/// 无法区分，导致尾字节被误判为首字节而错误回退，引发级联乱码。
/// 新方案从块起点前向扫描，精确追踪每个字符的起止位置。
String _decodeGbkChunked(List<int> bytes) {
  const chunkSize = 8192;
  final buf = StringBuffer();
  int pos = 0;

  while (pos < bytes.length) {
    var end = pos + chunkSize;
    if (end > bytes.length) end = bytes.length;

    // 从pos前向扫描，找到end之前最后一个完整字符的边界
    // 确保不会在GBK双字节字符中间截断
    if (end < bytes.length) {
      int scanPos = pos;
      int lastBoundary = pos;
      while (scanPos < end) {
        final b = bytes[scanPos];
        if (b <= 0x7F) {
          // ASCII单字节字符
          scanPos++;
          lastBoundary = scanPos;
        } else if (b >= 0x81 && b <= 0xFE) {
          // GBK双字节首字节，需要配对尾字节
          if (scanPos + 1 < end) {
            scanPos += 2;
            lastBoundary = scanPos;
          } else {
            // 首字节恰在块末尾，无法配对，在此截断
            break;
          }
        } else {
          // 无效字节(0x80, 0xFF)，当作单字节跳过
          scanPos++;
          lastBoundary = scanPos;
        }
      }
      end = lastBoundary;
    }

    if (end > pos) {
      final chunk = bytes.sublist(pos, end);
      try {
        buf.write(gbk_bytes.decoder.convert(chunk));
      } catch (_) {
        // 单块解码失败，用UTF-8容错解码避免整窗口回退
        buf.write(utf8.decode(chunk, allowMalformed: true));
      }
    }

    if (end <= pos) {
      pos++; // 避免死循环
    } else {
      pos = end;
    }
  }

  return buf.toString();
}

/// 同步版本（兼容旧调用，不建议用于大文件）
String decodeTextBytes(List<int> bytes) => _decodeTextBytesSync(bytes);

/// UTF-16 Little Endian 解码
String _decodeUtf16Le(List<int> bytes) {
  final codeUnits = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(codeUnits);
}

/// UTF-16 Big Endian 解码
String _decodeUtf16Be(List<int> bytes) {
  final codeUnits = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(codeUnits);
}
