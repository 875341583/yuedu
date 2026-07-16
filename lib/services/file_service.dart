/// 文件服务接口（条件导入：Native用dart:io，Web用空实现）
library;

import 'file_service_stub.dart'
    if (dart.library.io) 'file_service_native.dart'
    as impl;

/// 文件服务：跨平台文件操作
class FileService {
  /// 检查文件是否存在
  static Future<bool> fileExists(String path) => impl.fileExists(path);

  /// 读取文件全部字节数据
  static Future<List<int>> readFileBytes(String path) => impl.readFileBytes(path);

  /// 读取文件指定字节范围
  static Future<List<int>> readFileRange(String path, int start, int length) =>
      impl.readFileRange(path, start, length);

  /// 获取文件大小（字节）
  static Future<int> fileSize(String path) => impl.fileSize(path);

  /// 获取文件名（不含路径）
  static String getFileName(String path) => impl.getFileName(path);
}
