/// 文件服务 - Native平台实现（dart:io）
library;

import 'dart:io';

Future<bool> fileExists(String path) async {
  return await File(path).exists();
}

Future<List<int>> readFileBytes(String path) async {
  return await File(path).readAsBytes();
}

/// 读取文件指定字节范围
Future<List<int>> readFileRange(String path, int start, int length) async {
  final file = File(path);
  final raf = await file.open();
  try {
    await raf.setPosition(start);
    final bytes = await raf.read(length);
    return bytes;
  } finally {
    await raf.close();
  }
}

/// 获取文件大小（字节）
Future<int> fileSize(String path) async {
  final stat = await File(path).stat();
  return stat.size;
}

String getFileName(String path) {
  return path.split(Platform.pathSeparator).last;
}
