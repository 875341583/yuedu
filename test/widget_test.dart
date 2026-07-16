import 'package:flutter_test/flutter_test.dart';
import 'package:yuedu/typeset/engine.dart';
import 'package:yuedu/typeset/cjk.dart';

void main() {
  group('CJK判断', () {
    test('识别CJK字符', () {
      expect(isCjk('你'), isTrue);
      expect(isCjk('，'), isTrue);
      expect(isCjk('A'), isFalse);
    });

    test('识别CJK标点', () {
      expect(isCjkPunctuation('，'), isTrue);
      expect(isCjkPunctuation('你'), isFalse);
    });
  });

  group('排版引擎', () {
    test('空文本返回空结果', () {
      final config = TypesetConfig();
      final result = typesetParagraph('', config);
      expect(result.glyphs, isEmpty);
      expect(result.lines, isEmpty);
    });

    test('纯ASCII文本排版', () {
      final config = TypesetConfig(containerWidth: 1000.0);
      final result = typesetParagraph('Hello', config);
      expect(result.glyphs.length, 5);
    });

    test('CJK文本不换行', () {
      final config = TypesetConfig(containerWidth: 1000.0);
      final result = typesetParagraph('你好世界', config);
      expect(result.glyphs.length, 4);
      expect(result.lines.length, 1);
    });

    test('中西文间距验证', () {
      final config = TypesetConfig(containerWidth: 1000.0);
      final result = typesetParagraph('读abc书', config);
      // 应有中西文间距glyph
      expect(result.glyphs.any((g) => g.isCjkLatinSpacing), isTrue);
    });

    test('极窄容器强制换行', () {
      final config = TypesetConfig(
        containerWidth: 50.0,
        fontSize: 16.0,
        lineHeightRatio: 1.5,
      );
      final result = typesetParagraph('你好世界测试排版', config);
      expect(result.lines.length, greaterThan(1));
    });

    test('标点挤压验证', () {
      final config = TypesetConfig(
        containerWidth: 50.0,
        fontSize: 16.0,
        lineHeightRatio: 1.5,
      );
      final result = typesetParagraph('你好，世界！测试。', config);
      // 应有被挤压的标点
      expect(result.glyphs.any((g) => g.isSqueezed), isTrue);
    });
  });

  group('避头尾规则', () {
    test('逗号不应出现在行首', () {
      final config = TypesetConfig(
        containerWidth: 40.0,
        fontSize: 16.0,
        lineHeightRatio: 1.5,
      );
      final result = typesetParagraph('你好，世界测试排版好', config);
      // 检查每行的第一个非间距字符不是逗号
      for (final line in result.lines) {
        final lineGlyphs = result.glyphs
            .skip(line.startGlyphIndex)
            .take(line.glyphCount)
            .where((g) => !g.isCjkLatinSpacing)
            .toList();
        if (lineGlyphs.isNotEmpty) {
          expect(canBeLineHead(lineGlyphs.first.char), isTrue,
              reason: '行首不应是禁则字符: ${lineGlyphs.first.char}');
        }
      }
    });
  });
}
