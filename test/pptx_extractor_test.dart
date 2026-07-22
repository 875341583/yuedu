import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart' as archive;
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:yuedu/utils/pptx_text_extractor.dart';

void main() {
  group('PPTX 布局提取器测试', () {
    test('空幻灯片返回 0 个形状', () {
      final pptxBytes = _buildMinimalPptx(slides: [
        _SlideData(xml: '<p:sp><p:nvSpPr/><p:spPr/></p:sp>'),
      ]);
      final result = PptxTextExtractor.extract(pptxBytes);
      expect(result.pageCount, 1);
      expect(result.slides[0].shapes, isEmpty);
      expect(result.slideSize.widthPx, 960);
      expect(result.slideSize.heightPx, 540);
    });

    test('提取文本框位置和文本内容', () {
      final slideXml = '<p:sp>'
          '<p:nvSpPr/>'
          '<p:spPr><a:xfrm>'
          '<a:off x="685800" y="457200"/>'
          '<a:ext cx="5486400" cy="1143000"/>'
          '</a:xfrm></p:spPr>'
          '<p:txBody><a:p><a:r>'
          '<a:rPr lang="zh-CN" sz="4400" b="1"/>'
          '<a:t>Hello World</a:t>'
          '</a:r></a:p></p:txBody>'
          '</p:sp>';

      final pptxBytes = _buildMinimalPptx(slides: [
        _SlideData(xml: slideXml),
      ]);
      final result = PptxTextExtractor.extract(pptxBytes);
      expect(result.pageCount, 1);
      expect(result.slides[0].shapes.length, 1);

      final shape = result.slides[0].shapes[0];
      expect(shape.leftPx, closeTo(72.0, 0.5));
      expect(shape.topPx, closeTo(48.0, 0.5));
      expect(shape.widthPx, closeTo(576.0, 0.5));
      expect(shape.heightPx, closeTo(120.0, 0.5));

      expect(shape.hasText, isTrue);
      expect(shape.paragraphs.length, 1);
      expect(shape.paragraphs[0].runs.length, 1);
      expect(shape.paragraphs[0].runs[0].text, 'Hello World');
      expect(shape.paragraphs[0].runs[0].style.bold, isTrue);
      expect(shape.paragraphs[0].runs[0].style.fontSize, 44);
    });

    test('提取多个文本运行的不同样式', () {
      final slideXml = '<p:sp>'
          '<p:nvSpPr/>'
          '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="9144000"/></a:xfrm></p:spPr>'
          '<p:txBody><a:p>'
          '<a:r><a:rPr sz="2400" b="1"/><a:t>Bold 24</a:t></a:r>'
          '<a:r><a:rPr sz="1800" i="1"/><a:t>Italic 18</a:t></a:r>'
          '<a:r><a:rPr sz="1200" u="sng"/><a:t>Underline 12</a:t></a:r>'
          '</a:p></p:txBody>'
          '</p:sp>';

      final pptxBytes = _buildMinimalPptx(slides: [
        _SlideData(xml: slideXml),
      ]);
      final result = PptxTextExtractor.extract(pptxBytes);
      final runs = result.slides[0].shapes[0].paragraphs[0].runs;

      expect(runs.length, 3);
      expect(runs[0].text, 'Bold 24');
      expect(runs[0].style.bold, isTrue);
      expect(runs[0].style.fontSize, 24);

      expect(runs[1].text, 'Italic 18');
      expect(runs[1].style.italic, isTrue);
      expect(runs[1].style.fontSize, 18);

      expect(runs[2].text, 'Underline 12');
      expect(runs[2].style.underline, isTrue);
      expect(runs[2].style.fontSize, 12);
    });

    test('提取 srgbClr 颜色', () {
      final slideXml = '<p:sp>'
          '<p:nvSpPr/>'
          '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1000000" cy="1000000"/></a:xfrm></p:spPr>'
          '<p:txBody><a:p><a:r>'
          '<a:rPr><a:solidFill><a:srgbClr val="FF0000"/></a:rPr>'
          '<a:t>Red Text</a:t>'
          '</a:r></a:p></p:txBody>'
          '</p:sp>';

      final pptxBytes = _buildMinimalPptx(slides: [
        _SlideData(xml: slideXml),
      ]);
      final result = PptxTextExtractor.extract(pptxBytes);
      final run = result.slides[0].shapes[0].paragraphs[0].runs[0];
      expect(run.style.color, isNotNull);
      expect(run.style.color, const Color(0xFFFF0000));
    });

    test('段落对齐方式解析', () {
      final slideXml = '<p:sp>'
          '<p:nvSpPr/>'
          '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1000000" cy="1000000"/></a:xfrm></p:spPr>'
          '<p:txBody>'
          '<a:p><a:pPr algn="ctr"/><a:r><a:t>Center</a:t></a:r></a:p>'
          '<a:p><a:pPr algn="r"/><a:r><a:t>Right</a:t></a:r></a:p>'
          '<a:p><a:r><a:t>Left</a:t></a:r></a:p>'
          '</p:txBody>'
          '</p:sp>';

      final pptxBytes = _buildMinimalPptx(slides: [
        _SlideData(xml: slideXml),
      ]);
      final result = PptxTextExtractor.extract(pptxBytes);
      final paras = result.slides[0].shapes[0].paragraphs;
      expect(paras.length, 3);
      expect(paras[0].align, ParagraphAlign.center);
      expect(paras[1].align, ParagraphAlign.right);
      expect(paras[2].align, ParagraphAlign.left);
    });

    test('占位符类型识别（标题/正文）', () {
      final slideXml = '<p:sp>'
          '<p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
          '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="1000000" cy="1000000"/></a:xfrm></p:spPr>'
          '<p:txBody><a:p><a:r><a:t>Title</a:t></a:r></a:p></p:txBody>'
          '</p:sp>'
          '<p:sp>'
          '<p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>'
          '<p:spPr><a:xfrm><a:off x="0" y="1000000"/><a:ext cx="1000000" cy="1000000"/></a:xfrm></p:spPr>'
          '<p:txBody><a:p><a:r><a:t>Body</a:t></a:r></a:p></p:txBody>'
          '</p:sp>';

      final pptxBytes = _buildMinimalPptx(slides: [
        _SlideData(xml: slideXml),
      ]);
      final result = PptxTextExtractor.extract(pptxBytes);
      final shapes = result.slides[0].shapes;
      expect(shapes.length, 2);
      expect(shapes[0].placeholderType, 1);
      expect(shapes[1].placeholderType, 2);
    });

    test('多页幻灯片按顺序排列', () {
      final xml1 = '<p:sp><p:nvSpPr/><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm></p:spPr>'
          '<p:txBody><a:p><a:r><a:t>Page1</a:t></a:r></a:p></p:txBody></p:sp>';
      final xml2 = '<p:sp><p:nvSpPr/><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm></p:spPr>'
          '<p:txBody><a:p><a:r><a:t>Page2</a:t></a:r></a:p></p:txBody></p:sp>';
      final xml3 = '<p:sp><p:nvSpPr/><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm></p:spPr>'
          '<p:txBody><a:p><a:r><a:t>Page3</a:t></a:r></a:p></p:txBody></p:sp>';

      final pptxBytes = _buildMinimalPptx(slides: [
        _SlideData(xml: xml1),
        _SlideData(xml: xml2),
        _SlideData(xml: xml3),
      ]);
      final result = PptxTextExtractor.extract(pptxBytes);
      expect(result.pageCount, 3);
      expect(result.pages[0], 'Page1');
      expect(result.pages[1], 'Page2');
      expect(result.pages[2], 'Page3');
    });

    test('XML 实体解码', () {
      final slideXml = '<p:sp>'
          '<p:nvSpPr/>'
          '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm></p:spPr>'
          '<p:txBody><a:p><a:r>'
          '<a:t>A&amp;B &lt;tag&gt; &quot;q&quot; &apos;s&apos;</a:t>'
          '</a:r></a:p></p:txBody>'
          '</p:sp>';

      final pptxBytes = _buildMinimalPptx(slides: [
        _SlideData(xml: slideXml),
      ]);
      final result = PptxTextExtractor.extract(pptxBytes);
      expect(result.pages[0], 'A&B <tag> "q" \'s\'');
    });

    test('图片形状提取', () {
      final pngBytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      ]);

      final slideXml = '<p:pic>'
          '<p:nvPicPr/>'
          '<p:spPr><a:xfrm><a:off x="100000" y="200000"/><a:ext cx="300000" cy="400000"/></a:xfrm></p:spPr>'
          '<p:blipFill><a:blip r:embed="rId2"/></p:blipFill>'
          '</p:pic>';

      final relsXml = '<Relationships xmlns="...">'
          '<Relationship Id="rId2" Type="http://...image" Target="../media/image1.png"/>'
          '</Relationships>';

      final pptxBytes = _buildMinimalPptx(
        slides: [_SlideData(xml: slideXml, rels: relsXml)],
        mediaFiles: {'ppt/media/image1.png': pngBytes},
      );
      final result = PptxTextExtractor.extract(pptxBytes);
      expect(result.slides[0].shapes.length, 1);
      final shape = result.slides[0].shapes[0];
      expect(shape.isImage, isTrue);
      expect(shape.imageBytes, isNotNull);
      expect(shape.leftPx, closeTo(10.5, 0.5));
      expect(shape.topPx, closeTo(21.0, 0.5));
    });

    test('幻灯片背景色提取', () {
      final slideXml = '<p:bg><p:bgPr>'
          '<a:solidFill><a:srgbClr val="1F4E79"/></a:solidFill>'
          '</p:bgPr></p:bg>'
          '<p:sp><p:nvSpPr/><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm></p:spPr></p:sp>';

      final pptxBytes = _buildMinimalPptx(slides: [
        _SlideData(xml: slideXml),
      ]);
      final result = PptxTextExtractor.extract(pptxBytes);
      expect(result.slides[0].backgroundColor, const Color(0xFF1F4E79));
    });

    test('自定义幻灯片尺寸', () {
      final presXml = '<?xml version="1.0" encoding="UTF-8"?>'
          '<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
          'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
          '<p:sldSz cx="9144000" cy="6858000"/>'
          '</p:presentation>';

      final pptxBytes = _buildMinimalPptx(
        slides: [_SlideData(xml: '')],
        presentationXml: presXml,
      );
      final result = PptxTextExtractor.extract(pptxBytes);
      expect(result.slideSize.widthPx, 960);
      expect(result.slideSize.heightPx, 720);
    });

    test('无效 ZIP 抛出异常', () {
      expect(
        () => PptxTextExtractor.extract([0, 1, 2, 3]),
        throwsA(isA<Exception>()),
      );
    });

    test('无幻灯片的 PPTX 抛出异常', () {
      final pptxBytes = _buildMinimalPptx(slides: []);
      expect(
        () => PptxTextExtractor.extract(pptxBytes),
        throwsA(isA<Exception>()),
      );
    });
  });
}

// ─── 测试辅助：构建最小 PPTX ZIP ──────────────────────────

class _SlideData {
  final String xml;
  final String? rels;
  _SlideData({required this.xml, this.rels});
}

List<int> _buildMinimalPptx({
  required List<_SlideData> slides,
  String? presentationXml,
  Map<String, Uint8List> mediaFiles = const {},
}) {
  final arch = archive.Archive();

  // 构建 content types overrides
  final overrides = <String>[];
  for (var i = 0; i < slides.length; i++) {
    overrides.add('<Override PartName="/ppt/slides/slide${i + 1}.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>');
  }

  final contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="png" ContentType="image/png"/>'
      '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
      '${overrides.join()}'
      '</Types>';
  arch.addFile(archive.ArchiveFile(
      '[Content_Types].xml', contentTypes.length, utf8.encode(contentTypes)));

  // _rels/.rels
  final rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>'
      '</Relationships>';
  arch.addFile(archive.ArchiveFile(
      '_rels/.rels', rootRels.length, utf8.encode(rootRels)));

  // ppt/presentation.xml
  final sldIds = <String>[];
  for (var i = 0; i < slides.length; i++) {
    sldIds.add('<p:sldId id="${i + 1}" r:id="rId${i + 1}"/>');
  }
  final presXml = presentationXml ??
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
      '<p:sldSz cx="9144000" cy="5143500"/>'
      '<p:sldIdLst>${sldIds.join()}</p:sldIdLst>'
      '</p:presentation>';
  arch.addFile(archive.ArchiveFile(
      'ppt/presentation.xml', presXml.length, utf8.encode(presXml)));

  // ppt/_rels/presentation.xml.rels
  final relEntries = <String>[];
  for (var i = 0; i < slides.length; i++) {
    relEntries.add('<Relationship Id="rId${i + 1}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
        'Target="slides/slide${i + 1}.xml"/>');
  }
  final presRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '${relEntries.join()}'
      '</Relationships>';
  arch.addFile(archive.ArchiveFile('ppt/_rels/presentation.xml.rels',
      presRels.length, utf8.encode(presRels)));

  // ppt/slides/slideN.xml
  for (var i = 0; i < slides.length; i++) {
    final slideContent = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
        '<p:cSld><p:spTree>${slides[i].xml}</p:spTree></p:cSld>'
        '</p:sld>';
    arch.addFile(archive.ArchiveFile('ppt/slides/slide${i + 1}.xml',
        slideContent.length, utf8.encode(slideContent)));

    if (slides[i].rels != null) {
      final relsPath = 'ppt/slides/_rels/slide${i + 1}.xml.rels';
      arch.addFile(archive.ArchiveFile(
          relsPath, slides[i].rels!.length, utf8.encode(slides[i].rels!)));
    }
  }

  // 媒体文件
  for (final entry in mediaFiles.entries) {
    arch.addFile(
        archive.ArchiveFile(entry.key, entry.value.length, entry.value));
  }

  return archive.ZipEncoder().encode(arch)!;
}
