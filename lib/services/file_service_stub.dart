/// 文件服务 - Web平台空实现
library;

Future<bool> fileExists(String path) async => false;

Future<List<int>> readFileBytes(String path) async => [];

/// Web平台不支持按字节范围读取文件
Future<List<int>> readFileRange(String path, int start, int length) async => [];

/// Web平台不支持获取文件大小
Future<int> fileSize(String path) async => 0;

String getFileName(String path) => path.split('/').last;
