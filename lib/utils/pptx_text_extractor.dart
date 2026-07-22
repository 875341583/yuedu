/// PPTX 布局感知提取器
///
/// PPTX 是 ZIP 包，每张幻灯片位于 ppt/slides/slideN.xml，结构为：
///   <p:sp> 形状（文本框等）
///     <p:spPr> 形状属性
///       <a:xfrm>
///         <a:off x= y= />    位置（EMU 单位）
///         <a:ext cx= cy= />  尺寸（EMU 单位）
///       </a:xfrm>
///     <p:txBody>
///       <a:p> 段落
///         <a:pPr align="ctr"/> 段落属性
///         <a:r> 文本运行
///           <a:rPr b="1" sz="2400" color="FF0000"/> 运行属性
///           <a:t>实际文本</a:t>
///         </a:r>
///       </a:p>
///     </p:txBody>
///   <p:pic> 图片
///     <p:spPr>
///       <a:xfrm><a:off x= y= /><a:ext cx= cy= /></a:xfrm>
///     </p:spPr>
///     <p:blipFill><a:blip r:embed="rIdN"/></p:blipFill>
///
/// 同时解析 theme1.xml 获取主题颜色，slideLayouts 和 slideMasters 获取背景。
///
/// EMU (English Metric Unit) 换算：914400 EMU = 1 英寸 = 96 px
/// 1 px = 9525 EMU
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart' as archive;
import 'package:flutter/painting.dart' show Color;

// ─── EMU 常量 ──────────────────────────────────────────────
const int _emuPerPx = 9525; // 1px = 9525 EMU (96dpi)
const int _emuPerInch = 914400;

/// 幻灯片尺寸（像素）
class SlideSize {
  final int widthPx;
  final int heightPx;
  const SlideSize(this.widthPx, this.heightPx);

  @override
  String toString() => 'SlideSize(${widthPx}x${heightPx}px)';
}

/// 文本运行样式
class RunStyle {
  final bool bold;
  final bool italic;
  final bool underline;
  final int? fontSize; // pt（null=继承段落默认/主题）
  final Color? color;  // null=继承
  final String? fontName;

  const RunStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.fontSize,
    this.color,
    this.fontName,
  });
}

/// 段落对齐方式
enum ParagraphAlign { left, center, right, justify }

/// 一个文本运行（同样式连续文本）
class TextRun {
  final String text;
  final RunStyle style;
  const TextRun(this.text, this.style);
}

/// 一个段落
class PptxParagraph {
  final List<TextRun> runs;
  final ParagraphAlign align;
  final int? bulletId; // 占位，预留列表支持
  final double? spaceBefore; // pt
  final double? spaceAfter;  // pt
  final double? lineSpacing; // 倍数

  const PptxParagraph({
    this.runs = const [],
    this.align = ParagraphAlign.left,
    this.bulletId,
    this.spaceBefore,
    this.spaceAfter,
    this.lineSpacing,
  });

  /// 该段落纯文本
  String get plainText => runs.map((r) => r.text).join();
}

/// 幻灯片上的一个形状元素
class PptxShape {
  /// 位置和尺寸（像素，基于幻灯片原始大小）
  final double leftPx;
  final double topPx;
  final double widthPx;
  final double heightPx;

  /// 文本段落列表（如果这是文本框）
  final List<PptxParagraph> paragraphs;

  /// 图片字节（如果这是图片元素）
  final Uint8List? imageBytes;

  /// 图片 MIME 类型
  final String? imageMime;

  /// 形状类型
  final ShapeType shapeType;

  /// 背景色（形状自身的填充色）
  final Color? fillColor;

  /// 是否是占位符（标题、正文等）
  final int? placeholderType;

  const PptxShape({
    required this.leftPx,
    required this.topPx,
    required this.widthPx,
    required this.heightPx,
    this.paragraphs = const [],
    this.imageBytes,
    this.imageMime,
    this.shapeType = ShapeType.textBox,
    this.fillColor,
    this.placeholderType,
  });

  bool get isImage => shapeType == ShapeType.image;
  bool get hasText => paragraphs.isNotEmpty;
}

/// 形状类型
enum ShapeType {
  textBox,
  image,
  placeholder,
  autoShape,
}

/// 单张幻灯片
class PptxSlide {
  final int index; // 1-based
  final List<PptxShape> shapes;
  final Color? backgroundColor;

  const PptxSlide({
    required this.index,
    this.shapes = const [],
    this.backgroundColor,
  });

  bool get isEmpty => shapes.every((s) => !s.hasText && !s.isImage);
}

/// 解析后的全部幻灯片
class PptxSlides {
  /// 每张幻灯片（按页码顺序）
  final List<PptxSlide> slides;

  /// 幻灯片尺寸（像素）
  final SlideSize slideSize;

  /// 每页纯文本（兼容旧接口）
  final List<String> pages;

  PptxSlides(this.slides, this.slideSize, this.pages);

  int get pageCount => slides.length;
}

// ─── 主提取器 ──────────────────────────────────────────────

class PptxTextExtractor {
  /// 从 pptx 字节流提取每页布局信息
  static PptxSlides extract(List<int> bytes) {
    final archive.Archive zip;
    try {
      zip = archive.ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw Exception('无效的 PPTX 文件：解压失败 ($e)');
    }

    // 收集所有文件路径
    final allFiles = <String, archive.ArchiveFile>{};
    for (final f in zip) {
      allFiles[f.name] = f;
    }

    // 1. 获取幻灯片尺寸
    final slideSize = _getSlideSize(allFiles);

    // 2. 解析主题颜色
    final themeColors = _parseThemeColors(allFiles);

    // 3. 解析各幻灯片
    final slideFiles = <int, String>{};
    for (final name in allFiles.keys) {
      final m = RegExp(r'^ppt/slides/slide(\d+)\.xml$').firstMatch(name);
      if (m != null) {
        final idx = int.parse(m.group(1)!);
        slideFiles[idx] = name;
      }
    }
    if (slideFiles.isEmpty) {
      throw Exception('PPTX 文件未找到幻灯片（ppt/slides/slideN.xml）');
    }
    final sortedKeys = slideFiles.keys.toList()..sort();

    final slides = <PptxSlide>[];
    final pages = <String>[];
    for (final idx in sortedKeys) {
      final xml = _decodeFile(allFiles[slideFiles[idx]!]!);

      // 解析该幻灯片的关
      final relsName = 'ppt/slides/_rels/slide$idx.xml.rels';
      final relsXml = allFiles.containsKey(relsName)
          ? _decodeFile(allFiles[relsName]!)
          : '';

      final slideData = _parseSlideXml(
        xml: xml,
        relsXml: relsXml,
        allFiles: allFiles,
        themeColors: themeColors,
      );

      slides.add(PptxSlide(
        index: idx,
        shapes: slideData.$1,
        backgroundColor: slideData.$2,
      ));
      pages.add(_slideToText(slideData.$1));
    }
    return PptxSlides(slides, slideSize, pages);
  }

  // ─── 幻灯片尺寸 ─────────────────────────────────────────

  static SlideSize _getSlideSize(Map<String, archive.ArchiveFile> files) {
    // 从 presentation.xml 获取 sldSz
    final presFile = files['ppt/presentation.xml'];
    if (presFile != null) {
      final xml = _decodeFile(presFile);
      final m = RegExp(r'<p:sldSz[^>]*cx="(\d+)"[^>]*cy="(\d+)"').firstMatch(xml);
      if (m != null) {
        final cx = int.parse(m.group(1)!);
        final cy = int.parse(m.group(2)!);
        return SlideSize(
          (cx / _emuPerPx).round(),
          (cy / _emuPerPx).round(),
        );
      }
    }
    // 默认 16:9 (960x540)
    return const SlideSize(960, 540);
  }

  // ─── 主题颜色 ───────────────────────────────────────────

  static Map<String, Color> _parseThemeColors(
      Map<String, archive.ArchiveFile> files) {
    final colors = <String, Color>{};
    final themeFile = files['ppt/theme/theme1.xml'];
    if (themeFile == null) return colors;

    final xml = _decodeFile(themeFile);

    // <a:clrScheme name="..."> 内有 dk1, lt1, dk2, lt2, accent1-6, hlink, folHlink
    // 内容是 <a:sysClr val="windowText" lastClr="000000"/> 或 <a:srgbClr val="4472C4"/>
    final clrSchemeRE = RegExp(
      r'<a:(dk1|lt1|dk2|lt2|accent1|accent2|accent3|accent4|accent5|accent6|hlink|folHlink)>(.*?)</a:\1>',
      dotAll: true,
    );
    for (final m in clrSchemeRE.allMatches(xml)) {
      final name = m.group(1)!;
      final inner = m.group(2)!;
      Color? c;
      final srgb = RegExp(r'<a:srgbClr val="([0-9A-Fa-f]{6})"').firstMatch(inner);
      if (srgb != null) {
        final hex = srgb.group(1)!;
        c = Color(int.parse('FF$hex', radix: 16));
      } else {
        final sysClr = RegExp(r'<a:sysClr val="(\w+)" lastClr="([0-9A-Fa-f]{6})"')
            .firstMatch(inner);
        if (sysClr != null) {
          final hex = sysClr.group(2)!;
          c = Color(int.parse('FF$hex', radix: 16));
        }
      }
      if (c != null) colors[name] = c;
    }

    // dk1/lt1 在 XLSX/pptx 中实际映射有 swap，但 PPTX 中 dk1=windowText(黑)、lt1=window(白)
    // 我们按值取用即可
    return colors;
  }

  // ─── 解析单张幻灯片 XML ─────────────────────────────────

  /// 返回 (shapes, backgroundColor)
  static (List<PptxShape>, Color?) _parseSlideXml({
    required String xml,
    required String relsXml,
    required Map<String, archive.ArchiveFile> allFiles,
    required Map<String, Color> themeColors,
  }) {
    final shapes = <PptxShape>[];
    Color? bgColor;

    // 解析关系 ID → 媒体文件路径
    final relMap = _parseRels(relsXml);

    // 幻灯片背景
    final bgRE = RegExp(r'<p:bg[^>]*>(.*?)</p:bg>', dotAll: true);
    final bgMatch = bgRE.firstMatch(xml);
    if (bgMatch != null) {
      final bgInner = bgMatch.group(1)!;
      final srgb =
          RegExp(r'<a:srgbClr val="([0-9A-Fa-f]{6})"').firstMatch(bgInner);
      if (srgb != null) {
        bgColor = Color(int.parse('FF${srgb.group(1)}', radix: 16));
      }
    }

    // 匹配所有 <p:sp> 和 <p:pic> 元素
    // 我们用基于标签提取的方式，不依赖 XML 解析器

    // ── 文本框/形状 <p:sp>──
    _extractShapes(xml, shapes, relMap, allFiles, themeColors);

    // ── 图片 <p:pic> ──
    _ExtractPics(xml, shapes, relMap, allFiles);

    return (shapes, bgColor);
  }

  // ─── 提取所有 <p:sp> 形状 ────────────────────────────────

  static void _extractShapes(
    String xml,
    List<PptxShape> shapes,
    Map<String, String> relMap,
    Map<String, archive.ArchiveFile> allFiles,
    Map<String, Color> themeColors,
  ) {
    // 按 <p:sp 开头，</p:sp> 结尾分割
    final spRE = RegExp(r'<p:sp[\s>](.*?)</p:sp>', dotAll: true);
    for (final m in spRE.allMatches(xml)) {
      final spXml = m.group(1)!;
      final data = _parseShapeElement(spXml, relMap, allFiles, themeColors);
      if (data != null) shapes.add(data);
    }
  }

  static PptxShape? _parseShapeElement(
    String spXml,
    Map<String, String> relMap,
    Map<String, archive.ArchiveFile> allFiles,
    Map<String, Color> themeColors,
  ) {
    // 位置和尺寸
    final (off, ext) = _parseXfrm(spXml);
    if (off == null || ext == null) return null;

    final leftPx = off.$1 / _emuPerPx;
    final topPx = off.$2 / _emuPerPx;
    final widthPx = ext.$1 / _emuPerPx;
    final heightPx = ext.$2 / _emuPerPx;

    // 形状类型：占位符 or 普通文本框
    int? phType;
    final phRE = RegExp(r'<p:ph[^>]*type="(\w+)"');
    final phMatch = phRE.firstMatch(spXml);
    if (phMatch != null) {
      final t = phMatch.group(1)!;
      phType = _placeholderTypeFromString(t);
    }

    // 填充色
    Color? fillColor = _parseFill(spXml, themeColors);

    // 解析文本
    final paragraphs = _parseTxBody(spXml, themeColors);

    return PptxShape(
      leftPx: leftPx,
      topPx: topPx,
      widthPx: widthPx,
      heightPx: heightPx,
      paragraphs: paragraphs,
      shapeType: phType != null ? ShapeType.placeholder : ShapeType.textBox,
      fillColor: fillColor,
      placeholderType: phType,
    );
  }

  // ─── 提取所有 <p:pic> 图片 ────────────────────────────────

  static void _ExtractPics(
    String xml,
    List<PptxShape> shapes,
    Map<String, String> relMap,
    Map<String, archive.ArchiveFile> allFiles,
  ) {
    final picRE = RegExp(r'<p:pic[\s>](.*?)</p:pic>', dotAll: true);
    for (final m in picRE.allMatches(xml)) {
      final picXml = m.group(1)!;

      final (off, ext) = _parseXfrm(picXml);
      if (off == null || ext == null) continue;

      final leftPx = off.$1 / _emuPerPx;
      final topPx = off.$2 / _emuPerPx;
      final widthPx = ext.$1 / _emuPerPx;
      final heightPx = ext.$2 / _emuPerPx;

      // 提取 r:embed 引用
      final blipRE = RegExp(r'<a:blip[^>]*r:embed="([^"]+)"');
      final blipMatch = blipRE.firstMatch(picXml);
      if (blipMatch == null) continue;
      final rid = blipMatch.group(1)!;
      final mediaPath = relMap[rid];
      if (mediaPath == null) continue;

      final imgData = _readMediaFile(allFiles, mediaPath);
      if (imgData == null) continue;

      shapes.add(PptxShape(
        leftPx: leftPx,
        topPx: topPx,
        widthPx: widthPx,
        heightPx: heightPx,
        imageBytes: imgData,
        imageMime: _mimeFromPath(mediaPath),
        shapeType: ShapeType.image,
      ));
    }
  }

  // ─── 解析 <a:xfrm> 位置与尺寸 ─────────────────────────────

  static ((int, int)?, (int, int)?) _parseXfrm(String xml) {
    final xfrmRE = RegExp(r'<a:xfrm[^>]*>(.*?)</a:xfrm>', dotAll: true);
    final m = xfrmRE.firstMatch(xml);
    if (m == null) return (null, null);
    final inner = m.group(1)!;

    int? offX, offY, extCx, extCy;
    final offRE = RegExp(r'<a:off\s+x="(-?\d+)"\s+y="(-?\d+)"');
    final offMatch = offRE.firstMatch(inner);
    if (offMatch != null) {
      offX = int.parse(offMatch.group(1)!);
      offY = int.parse(offMatch.group(2)!);
    }

    final extRE = RegExp(r'<a:ext\s+cx="(\d+)"\s+cy="(\d+)"');
    final extMatch = extRE.firstMatch(inner);
    if (extMatch != null) {
      extCx = int.parse(extMatch.group(1)!);
      extCy = int.parse(extMatch.group(2)!);
    }

    if (offX == null || offY == null) return (null, null);
    if (extCx == null || extCy == null) return ((offX, offY), null);
    return ((offX, offY), (extCx, extCy));
  }

  // ─── 解析 <p:txBody> 文本段落 ─────────────────────────────

  static List<PptxParagraph> _parseTxBody(
    String xml,
    Map<String, Color> themeColors,
  ) {
    final paragraphs = <PptxParagraph>[];

    // 提取 txBody
    final txBodyRE = RegExp(r'<p:txBody[^>]*>(.*?)</p:txBody>', dotAll: true);
    final txMatch = txBodyRE.firstMatch(xml);
    if (txMatch == null) return paragraphs;
    final txBody = txMatch.group(1)!;

    // 按 <a:p> 分割
    final pRE = RegExp(r'<a:p[\s>](.*?)</a:p>', dotAll: true);
    for (final pMatch in pRE.allMatches(txBody)) {
      final pXml = pMatch.group(1)!;

      // 段落属性 <a:pPr>
      ParagraphAlign align = ParagraphAlign.left;
      double? spaceBefore, spaceAfter, lineSpacing;
      final pPrMatch = RegExp(r'<a:pPr[^>]*>').firstMatch(pXml);
      if (pPrMatch != null) {
        final pPrTag = pPrMatch.group(0)!;
        final algnMatch = RegExp(r'algn="(ctr|l|r|just)"').firstMatch(pPrTag);
        if (algnMatch != null) {
          switch (algnMatch.group(1)) {
            case 'ctr':
              align = ParagraphAlign.center;
            case 'r':
              align = ParagraphAlign.right;
            case 'just':
              align = ParagraphAlign.justify;
            default:
              align = ParagraphAlign.left;
          }
        }
        // lnSpc / spcBef / spcAft
        final lnSpcMatch = RegExp(r'<a:lnSpc><a:spcPct val="(\d+)"').firstMatch(pXml);
        if (lnSpcMatch != null) {
          lineSpacing = int.parse(lnSpcMatch.group(1)!) / 100000.0;
        }
        final spcBefMatch = RegExp(r'<a:spcBef><a:spcPts val="(\d+)"').firstMatch(pXml);
        if (spcBefMatch != null) {
          spaceBefore = int.parse(spcBefMatch.group(1)!) / 100.0;
        }
        final spcAftMatch = RegExp(r'<a:spcAft><a:spcPts val="(\d+)"').firstMatch(pXml);
        if (spcAftMatch != null) {
          spaceAfter = int.parse(spcAftMatch.group(1)!) / 100.0;
        }
      }

      // 文本运行 <a:r>
      final runs = <TextRun>[];
      final rRE = RegExp(r'<a:r[\s>](.*?)</a:r>', dotAll: true);
      for (final rMatch in rRE.allMatches(pXml)) {
        final rXml = rMatch.group(1)!;
        // 运行属性 <a:rPr>
        final style = _parseRunProps(rXml, themeColors);
        // 文本 <a:t>
        final tRE = RegExp(r'<a:t(?:\s[^>]*)?>([^<]*)</a:t>');
        final tMatch = tRE.firstMatch(rXml);
        if (tMatch != null) {
          final text = _decodeXmlEntities(tMatch.group(1) ?? '');
          if (text.isNotEmpty) runs.add(TextRun(text, style));
        }
      }

      // <a:br/> 换行
      if (pXml.contains('<a:br')) {
        runs.add(const TextRun('\n', RunStyle()));
      }

      if (runs.isNotEmpty) {
        paragraphs.add(PptxParagraph(
          runs: runs,
          align: align,
          spaceBefore: spaceBefore,
          spaceAfter: spaceAfter,
          lineSpacing: lineSpacing,
        ));
      }
    }

    return paragraphs;
  }

  // ─── 解析 <a:rPr> 运行属性 ────────────────────────────────

  static RunStyle _parseRunProps(
    String rXml,
    Map<String, Color> themeColors,
  ) {
    bool bold = false, italic = false, underline = false;
    int? fontSize;
    Color? color;
    String? fontName;

    final rPrRE = RegExp(r'<a:rPr([^>]*)/>|<a:rPr([^>]*)>');
    final m = rPrRE.firstMatch(rXml);
    if (m != null) {
      final attrs = (m.group(1) ?? m.group(2) ?? '');

      final bMatch = RegExp(r'\sb="(\d)"').firstMatch(attrs);
      if (bMatch != null) bold = bMatch.group(1) == '1';

      final iMatch = RegExp(r'\si="(\d)"').firstMatch(attrs);
      if (iMatch != null) italic = iMatch.group(1) == '1';

      final uMatch = RegExp(r'\su="(\w*)"').firstMatch(attrs);
      if (uMatch != null) underline = uMatch.group(1)!.isNotEmpty && uMatch.group(1) != 'none';

      final szMatch = RegExp(r'\ssz="(\d+)"').firstMatch(attrs);
      if (szMatch != null) {
        fontSize = int.parse(szMatch.group(1)!) ~/ 100; // PPTX sz 是 1/100 pt
      }

      // 字体
      final latinRE = RegExp(r'<a:latin typeface="([^"]+)"');
      final latinMatch = latinRE.firstMatch(rXml);
      if (latinMatch != null) fontName = latinMatch.group(1);
    }

    // 颜色：可能来自 <a:solidFill><a:srgbClr> 或 <a:solidFill><a:schemeClr>
    final solidFillRE =
        RegExp(r'<a:solidFill>(.*?)</a:solidFill>', dotAll: true);
    final sfMatch = solidFillRE.firstMatch(rXml);
    if (sfMatch != null) {
      final sfInner = sfMatch.group(1)!;
      color = _parseColorElement(sfInner, themeColors);
    }

    // 也检查 <a:rPr> 内直接 <a:srgbClr>（某些 PPTX 会这样写）
    if (color == null) {
      final srgbDirect =
          RegExp(r'<a:srgbClr val="([0-9A-Fa-f]{6})"').firstMatch(rXml);
      if (srgbDirect != null) {
        color = Color(int.parse('FF${srgbDirect.group(1)}', radix: 16));
      }
    }

    return RunStyle(
      bold: bold,
      italic: italic,
      underline: underline,
      fontSize: fontSize,
      color: color,
      fontName: fontName,
    );
  }

  // ─── 颜色解析 ───────────────────────────────────────────

  static Color? _parseColorElement(
    String inner,
    Map<String, Color> themeColors,
  ) {
    // srgbClr
    final srgb = RegExp(r'<a:srgbClr val="([0-9A-Fa-f]{6})"').firstMatch(inner);
    if (srgb != null) {
      return Color(int.parse('FF${srgb.group(1)}', radix: 16));
    }
    // schemeClr → 查主题颜色表
    final scheme = RegExp(r'<a:schemeClr val="(\w+)"').firstMatch(inner);
    if (scheme != null) {
      final name = scheme.group(1)!;
      // 映射 OOXML schemeClr name → theme name
      final mapped = _mapSchemeColor(name);
      if (mapped != null && themeColors.containsKey(mapped)) {
        return themeColors[mapped];
      }
    }
    return null;
  }

  static String? _mapSchemeColor(String schemeClr) {
    switch (schemeClr) {
      case 'dk1':
      case 'tx1':
        return 'dk1';
      case 'lt1':
      case 'bg1':
        return 'lt1';
      case 'dk2':
      case 'tx2':
        return 'dk2';
      case 'lt2':
      case 'bg2':
        return 'lt2';
      case 'accent1':
        return 'accent1';
      case 'accent2':
        return 'accent2';
      case 'accent3':
        return 'accent3';
      case 'accent4':
        return 'accent4';
      case 'accent5':
        return 'accent5';
      case 'accent6':
        return 'accent6';
      case 'hlink':
        return 'hlink';
      case 'folHlink':
        return 'folHlink';
      default:
        return null;
    }
  }

  // ─── 形状填充解析 ───────────────────────────────────────

  static Color? _parseFill(
    String spXml,
    Map<String, Color> themeColors,
  ) {
    // 在 spPr 内找 solidFill
    final spPrRE = RegExp(r'<p:spPr[^>]*>(.*?)</p:spPr>', dotAll: true);
    final m = spPrRE.firstMatch(spXml);
    if (m == null) return null;
    final spPr = m.group(1)!;

    final solidFillRE =
        RegExp(r'<a:solidFill>(.*?)</a:solidFill>', dotAll: true);
    final sfMatch = solidFillRE.firstMatch(spPr);
    if (sfMatch != null) {
      return _parseColorElement(sfMatch.group(1)!, themeColors);
    }
    return null;
  }

  // ─── 关系文件解析 ────────────────────────────────────────

  static Map<String, String> _parseRels(String relsXml) {
    final relMap = <String, String>{};
    if (relsXml.isEmpty) return relMap;

    final relRE = RegExp(
      r'<Relationship\s+Id="([^"]+)"\s+Type="[^"]*"\s+Target="([^"]+)"',
    );
    for (final m in relRE.allMatches(relsXml)) {
      final id = m.group(1)!;
      var target = m.group(2)!;
      // media 目标通常 ../media/imageN.ext
      target = target.replaceAll('../', '');
      relMap[id] = target;
    }
    return relMap;
  }

  // ─── 读取媒体文件 ────────────────────────────────────────

  static Uint8List? _readMediaFile(
    Map<String, archive.ArchiveFile> allFiles,
    String mediaPath,
  ) {
    // 尝试 ppt/ 前缀拼
    final candidates = <String>[
      'ppt/$mediaPath',
      mediaPath,
      'ppt/slides/$mediaPath',
    ];
    for (final path in candidates) {
      if (allFiles.containsKey(path)) {
        final data = _decodeFileBytes(allFiles[path]!);
        if (data != null) return data;
      }
    }
    return null;
  }

  static String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/png';
  }

  // ─── 占位符类型 ─────────────────────────────────────────

  static int _placeholderTypeFromString(String t) {
    switch (t) {
      case 'title':
        return 1;
      case 'body':
        return 2;
      case 'ctrTitle':
        return 3;
      case 'subTitle':
        return 4;
      case 'dt':
        return 5;
      case 'ftr':
        return 6;
      case 'sldNum':
        return 7;
      default:
        return 99;
    }
  }

  // ─── 形状列表 → 纯文本（兼容旧接口）────────────────────

  static String _slideToText(List<PptxShape> shapes) {
    final buffer = StringBuffer();
    for (final shape in shapes) {
      if (shape.hasText) {
        for (final para in shape.paragraphs) {
          final text = para.plainText;
          if (text.isNotEmpty) {
            if (buffer.isNotEmpty) buffer.write('\n');
            buffer.write(text);
          }
        }
      }
    }
    return buffer.toString();
  }

  // ─── 工具方法 ────────────────────────────────────────────

  static String _decodeFile(archive.ArchiveFile file) {
    final data = file.content as dynamic;
    if (data is String) return data;
    if (data is List) {
      final bytes = List<int>.from(data);
      return utf8.decode(bytes, allowMalformed: true);
    }
    return data.toString();
  }

  static Uint8List? _decodeFileBytes(archive.ArchiveFile file) {
    final data = file.content as dynamic;
    if (data is List) {
      return Uint8List.fromList(List<int>.from(data));
    }
    if (data is Uint8List) return data;
    if (data is String) return Uint8List.fromList(utf8.encode(data));
    return null;
  }

  static String _decodeXmlEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (m) => String.fromCharCodes([int.parse(m.group(1)!)]),
        )
        .replaceAllMapped(
          RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCodes([int.parse(m.group(1)!, radix: 16)]),
        );
  }
}
