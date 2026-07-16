/// Rust排版引擎的FFI绑定
///
/// 在Native平台（Windows/Android）通过dart:ffi调用Rust编译的typeset_engine.dll/.so
/// Web平台不支持dart:ffi，需走Dart纯实现引擎
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'types.dart';

// =========== FFI C结构体定义 ===========

/// FFI版本的GlyphInfo，与Rust侧FFIGlyphInfo一一对应
final class FFIGlyphInfo extends Struct {
  @Uint32()
  external int codePoint;

  @Double()
  external double x;

  @Double()
  external double y;

  @Double()
  external double width;

  @Uint32()
  external int lineIndex;

  @Uint8()
  external int isSqueezed;

  @Uint8()
  external int isCjkLatinSpacing;
}

/// FFI版本的排版结果，与Rust侧FFITypesetResult一一对应
final class FFITypesetResult extends Struct {
  external Pointer<FFIGlyphInfo> glyphsPtr;

  @Uint32()
  external int glyphCount;

  external Pointer<Uint32> lineCountsPtr;

  @Uint32()
  external int lineCount;

  @Double()
  external double totalHeight;
}

// =========== FFI函数签名 ===========

typedef TypesetFFINative = FFITypesetResult Function(
  Pointer<Uint8> textPtr,
  Int32 textLen,
  Double fontSize,
  Double lineHeightRatio,
  Double containerWidth,
);

typedef TypesetFFIDart = FFITypesetResult Function(
  Pointer<Uint8> textPtr,
  int textLen,
  double fontSize,
  double lineHeightRatio,
  double containerWidth,
);

typedef FreeTypesetResultNative = Void Function(FFITypesetResult result);
typedef FreeTypesetResultDart = void Function(FFITypesetResult result);

// =========== Rust排版引擎FFI绑定类 ===========

/// Rust排版引擎的FFI绑定
///
/// 使用方式：
/// ```dart
/// final engine = RustTypesetEngine();
/// final result = engine.typeset('你好世界', config);
/// engine.dispose();
/// ```
class RustTypesetEngine {
  late DynamicLibrary _lib;
  late TypesetFFIDart _typesetFFI;
  late FreeTypesetResultDart _freeTypesetResult;

  bool _initialized = false;

  /// 初始化FFI绑定，加载动态库
  ///
  /// Windows: typeset_engine.dll
  /// Android: libtypeset_engine.so
  /// macOS/iOS: typeset_engine.dylib / libtypeset_engine.a
  void _init() {
    if (_initialized) return;

    final libPath = _getLibraryPath();
    _lib = DynamicLibrary.open(libPath);

    _typesetFFI = _lib.lookupFunction<TypesetFFINative, TypesetFFIDart>(
      'typeset_ffi',
    );

    _freeTypesetResult = _lib.lookupFunction<
        FreeTypesetResultNative,
        FreeTypesetResultDart>('free_typeset_result');

    _initialized = true;
  }

  /// 获取平台对应的动态库路径
  String _getLibraryPath() {
    if (Platform.isWindows) {
      // Windows: 按优先级查找DLL
      // 1. exe同目录（Flutter Windows桌面构建输出位置）
      // 2. 项目根目录（flutter run的工作目录）
      // 3. windows/子目录
      // 4. Rust编译输出目录
      final candidates = [
        'typeset_engine.dll',
        'windows\\typeset_engine.dll',
        'engine\\target\\release\\typeset_engine.dll',
        'engine\\target\\debug\\typeset_engine.dll',
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) {
          return path;
        }
      }
      // 如果都没找到，返回默认名称让系统在PATH中查找
      return 'typeset_engine.dll';
    } else if (Platform.isAndroid) {
      return 'libtypeset_engine.so';
    } else if (Platform.isLinux) {
      return 'libtypeset_engine.so';
    } else if (Platform.isMacOS) {
      return 'typeset_engine.dylib';
    }
    throw UnsupportedError('Platform not supported for FFI');
  }

  /// 对一段文本执行排版计算（通过Rust FFI）
  ///
  /// [text] 输入文本
  /// [config] 排版配置
  /// 返回排版结果
  TypesetResult typeset(String text, TypesetConfig config) {
    _init();

    if (text.isEmpty) {
      return const TypesetResult(glyphs: [], lines: [], totalHeight: 0.0);
    }

    // 将Dart String转为UTF-8字节（Rust侧期望UTF-8）
    final utf8Bytes = utf8.encode(text);
    final textLen = utf8Bytes.length;

    // 使用arena分配器分配临时内存
    return using((arena) {
      // 分配文本内存
      final textPtr = arena<Uint8>(textLen);
      final textPtrBytes = textPtr.asTypedList(textLen);
      textPtrBytes.setAll(0, utf8Bytes);

      // 调用Rust FFI
      final ffiResult = _typesetFFI(
        textPtr,
        textLen,
        config.fontSize,
        config.lineHeightRatio,
        config.containerWidth,
      );

      // 将FFI结果转换为Dart对象
      final result = _convertFFIResult(ffiResult, config);

      // 释放Rust侧分配的内存
      _freeTypesetResult(ffiResult);

      return result;
    });
  }

  /// 将FFITypesetResult转换为Dart的TypesetResult
  TypesetResult _convertFFIResult(
    FFITypesetResult ffiResult,
    TypesetConfig config,
  ) {
    final glyphCount = ffiResult.glyphCount;
    final lineCount = ffiResult.lineCount;

    if (glyphCount == 0) {
      return const TypesetResult(glyphs: [], lines: [], totalHeight: 0.0);
    }

    // 从FFI指针读取glyph数组（结构体指针用数组索引访问）
    final glyphsPtr = ffiResult.glyphsPtr;
    final glyphs = <GlyphInfo>[];

    for (var i = 0; i < glyphCount; i++) {
      final ffiGlyph = glyphsPtr[i];
      glyphs.add(GlyphInfo(
        char: String.fromCharCode(ffiGlyph.codePoint),
        x: ffiGlyph.x,
        y: ffiGlyph.y,
        width: ffiGlyph.width,
        lineIndex: ffiGlyph.lineIndex,
        isSqueezed: ffiGlyph.isSqueezed != 0,
        isCjkLatinSpacing: ffiGlyph.isCjkLatinSpacing != 0,
      ));
    }

    // 从FFI指针读取行段数数组（Uint32指针可用asTypedList）
    final lineCounts = ffiResult.lineCountsPtr.asTypedList(lineCount);
    final lineInfos = <LineInfo>[];
    var glyphOffset = 0;
    final lineHeight = config.fontSize * config.lineHeightRatio;

    for (var i = 0; i < lineCount; i++) {
      lineInfos.add(LineInfo(
        startGlyphIndex: glyphOffset,
        glyphCount: lineCounts[i],
        y: i * lineHeight,
        width: 0, // MVP阶段精确行宽暂不传递
      ));
      glyphOffset += lineCounts[i];
    }

    return TypesetResult(
      glyphs: glyphs,
      lines: lineInfos,
      totalHeight: ffiResult.totalHeight,
    );
  }

  /// 释放资源
  void dispose() {
    // DynamicLibrary不需要手动关闭
    _initialized = false;
  }
}
