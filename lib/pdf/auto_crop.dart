/// PDF 智能裁白边引擎
///
/// 通过分析 PDF 页面的文本边界（PdfPageTextFragment.bounds）
/// 自动检测并裁除页面四周的白边，让内容充满屏幕。
///
/// 两种裁切模式：
/// - perPage：逐页独立计算裁切区域，每页裁切可能不同
/// - unified：取所有页面裁切区域的并集，统一裁切
///
/// 技术原理：
/// 1. 调用 PdfPage.loadText() 获取文本片段及其边界矩形
/// 2. 合并所有文本片段的边界矩形，得到内容区域的外接矩形
/// 3. 外接矩形 + padding 即为裁切区域
/// 4. 使用 PdfPage.render() 子区域渲染参数仅渲染裁切区域
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// 裁切模式
enum CropMode {
  /// 逐页独立裁切
  perPage,

  /// 统一裁切（所有页取并集）
  unified,

  /// 不裁切
  off,
}

/// 单页裁切结果
///
/// [contentBounds] 使用 PDF 页面坐标系（原点左下角，Y 轴向上），
/// 单位为 points（1/72 英寸）。
class PdfCropRegion {
  final int pageNumber;

  /// PDF 坐标系下内容区域的外接矩形（origin bottom-left, Y up）
  final PdfRect contentBounds;

  /// 裁切区域（= contentBounds + padding），同样是 PDF 坐标系
  final PdfRect cropBounds;

  PdfCropRegion({
    required this.pageNumber,
    required this.contentBounds,
    required this.cropBounds,
  });

  /// 内容区域宽度（points）
  double get contentWidth => contentBounds.width;

  /// 内容区域高度（points）
  double get contentHeight => contentBounds.height;

  /// 裁切后页面宽度（points）
  double get cropWidth => cropBounds.width;

  /// 裁切后页面高度（points）— 注意 PDF 坐标系 top > bottom
  double get cropHeight => cropBounds.height;
}

/// 智能裁白边引擎
class AutoCropEngine {
  AutoCropEngine._();

  /// 计算单页裁切区域
  ///
  /// [page] — PDF 页面对象
  /// [contentPadding] — 内容区域外加的留白（points），默认 8pt
  static Future<PdfCropRegion?> computeForPage(
    PdfPage page, {
    double contentPadding = 8.0,
  }) async {
    try {
      final text = await page.loadText();
      if (text.fragments.isEmpty) return null;

      // 合并所有文本片段的边界矩形
      PdfRect? merged;
      for (final fragment in text.fragments) {
        if (fragment.bounds.isEmpty) continue;
        merged = merged == null
            ? fragment.bounds
            : merged.merge(fragment.bounds);
      }

      if (merged == null || merged.isEmpty) return null;

      // 加 padding，但不超出页面边界
      final padded = merged.inflate(contentPadding, contentPadding);
      final pageW = page.width;
      final pageH = page.height;
      final left = math.max(0.0, padded.left);
      final bottom = math.max(0.0, padded.bottom);
      final right = math.min(pageW, padded.right);
      final top = math.min(pageH, padded.top);

      return PdfCropRegion(
        pageNumber: page.pageNumber,
        contentBounds: merged,
        cropBounds: PdfRect(left, top, right, bottom),
      );
    } catch (_) {
      return null;
    }
  }

  /// 计算整份文档所有页面的裁切区域
  ///
  /// 返回 List，索引 0 对应第 1 页。null 表示该页无法检测内容边界。
  static Future<List<PdfCropRegion?>> computeForDocument(
    PdfDocument doc, {
    double contentPadding = 8.0,
  }) async {
    final results = <PdfCropRegion?>[];
    for (int i = 0; i < doc.pages.length; i++) {
      try {
        final page = doc.pages[i];
        final region = await computeForPage(page, contentPadding: contentPadding);
        results.add(region);
      } catch (_) {
        results.add(null);
      }
    }
    return results;
  }

  /// 从逐页结果中计算统一裁切区域（取所有页内容区域的并集）
  ///
  /// 逻辑：对每页的 contentBounds 取 left 最小、bottom 最小、
  /// right 最大、top 最大，合并成统一矩形。
  static PdfCropRegion? computeUnified(
    List<PdfCropRegion?> perPageRegions, {
    double contentPadding = 8.0,
    double pageWidth = 612.0,
    double pageHeight = 792.0,
  }) {
    PdfRect? unifiedContent;
    for (final region in perPageRegions) {
      if (region == null) continue;
      unifiedContent = unifiedContent == null
          ? region.contentBounds
          : unifiedContent.merge(region.contentBounds);
    }
    if (unifiedContent == null) return null;

    final padded = unifiedContent.inflate(contentPadding, contentPadding);
    final left = math.max(0.0, padded.left);
    final bottom = math.max(0.0, padded.bottom);
    final right = math.min(pageWidth, padded.right);
    final top = math.min(pageHeight, padded.top);

    return PdfCropRegion(
      pageNumber: 0, // 统一模式无特定页码
      contentBounds: unifiedContent,
      cropBounds: PdfRect(left, top, right, bottom),
    );
  }

  /// 将 PDF 坐标系的裁切区域转为 PdfPage.render() 的像素参数
  ///
  /// render() 使用设备坐标系（原点左上角，Y 轴向下），
  /// 而 [cropBounds] 使用 PDF 坐标系（原点左下角，Y 轴向上）。
  ///
  /// [scale] — 渲染缩放比（像素/points），如 2.0 表示 144dpi
  static RenderCropParams toRenderParams(
    PdfPage page,
    PdfRect cropBounds,
    double scale,
  ) {
    final pageW = page.width;
    final pageH = page.height;

    // render() 坐标系：原点左上角，Y 向下
    // PDF 坐标系：原点左下角，Y 向上
    // 转换：render_y = (pageH - pdf_top) * scale
    final renderX = (cropBounds.left * scale).round();
    final renderY = ((pageH - cropBounds.top) * scale).round();
    final renderW = (cropBounds.width * scale).round();
    final renderH = (cropBounds.height * scale).round();
    final fullW = (pageW * scale).round();
    final fullH = (pageH * scale).round();

    return RenderCropParams(
      x: renderX,
      y: renderY,
      width: renderW,
      height: renderH,
      fullWidth: fullW,
      fullHeight: fullH,
    );
  }
}

/// PdfPage.render() 的裁切参数
class RenderCropParams {
  final int x;
  final int y;
  final int width;
  final int height;
  final int fullWidth;
  final int fullHeight;

  const RenderCropParams({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.fullWidth,
    required this.fullHeight,
  });
}

/// 裁白边渲染器 — 将裁切后的 PDF 页面渲染为 Flutter Image
///
/// 使用 PdfPage.render() 的子区域参数，仅渲染裁切区域，
/// 然后通过 [ui.Image] → [RawImage] 显示。
/// 支持分辨率自适应和缓存。
class CroppedPageRenderer {
  /// 渲染裁切后的页面图片
  ///
  /// [page] — PDF 页面
  /// [cropBounds] — 裁切区域（PDF 坐标系）
  /// [displayWidth] — 目标显示宽度（像素），用于计算渲染 DPI
  /// [maxDpi] — 最大渲染 DPI，默认 300
  static Future<ui.Image?> renderCroppedPage({
    required PdfPage page,
    required PdfRect cropBounds,
    required double displayWidth,
    double maxDpi = 300,
  }) async {
    // 计算渲染缩放比：让裁切区域宽度 ≈ 显示宽度
    final scale = math.min(displayWidth / cropBounds.width, maxDpi / 72.0);
    final params = AutoCropEngine.toRenderParams(page, cropBounds, scale);

    if (params.width <= 0 || params.height <= 0) return null;

    try {
      final image = await page.render(
        x: params.x,
        y: params.y,
        width: params.width,
        height: params.height,
        fullWidth: params.fullWidth.toDouble(),
        fullHeight: params.fullHeight.toDouble(),
        backgroundColor: Colors.white,
      );
      if (image == null) return null;

      final uiImage = await image.createImage();
      image.dispose();
      return uiImage;
    } catch (_) {
      return null;
    }
  }
}

/// 裁白边页面视图 — 替代 PdfPageView 的自定义 Widget
///
/// 当裁白边启用时，使用此组件替代 PdfPageView，
/// 仅渲染裁切区域并显示。
class CroppedPageView extends StatefulWidget {
  final PdfDocument document;
  final int pageNumber;
  final PdfRect cropBounds;
  final Color backgroundColor;
  final double maxDpi;

  const CroppedPageView({
    required this.document,
    required this.pageNumber,
    required this.cropBounds,
    this.backgroundColor = const Color(0xFF3A3A3A),
    this.maxDpi = 300,
    super.key,
  });

  @override
  State<CroppedPageView> createState() => _CroppedPageViewState();
}

class _CroppedPageViewState extends State<CroppedPageView> {
  ui.Image? _image;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _renderPage();
  }

  @override
  void didUpdateWidget(CroppedPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document ||
        oldWidget.pageNumber != widget.pageNumber ||
        oldWidget.cropBounds != widget.cropBounds) {
      _image?.dispose();
      _image = null;
      _renderPage();
    }
  }

  Future<void> _renderPage() async {
    if (_loading) return;
    _loading = true;
    _error = null;

    try {
      final page = widget.document.pages[widget.pageNumber - 1];

      // 使用 LayoutBuilder 尚未构建，先用屏幕宽度估算
      final displayWidth = MediaQuery.of(context).size.width * 2.0; // 2x 缩放
      final image = await CroppedPageRenderer.renderCroppedPage(
        page: page,
        cropBounds: widget.cropBounds,
        displayWidth: displayWidth,
        maxDpi: widget.maxDpi,
      );

      if (!mounted) {
        image?.dispose();
        return;
      }
      setState(() {
        _image = image;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.backgroundColor;

    if (_loading) {
      return Container(
        color: bg,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_error != null || _image == null) {
      return Container(
        color: bg,
        child: Center(
          child: Text(_error ?? '渲染失败', style: const TextStyle(color: Colors.white54)),
        ),
      );
    }

    // 按裁切区域宽高比显示
    final cropW = widget.cropBounds.width;
    final cropH = widget.cropBounds.height;
    final aspect = cropW / cropH;

    return Container(
      color: bg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 计算适配尺寸：让裁切内容尽量填满宽度
          double w, h;
          if (constraints.maxWidth / constraints.maxHeight > aspect) {
            // 屏幕更宽，以高度为准
            h = constraints.maxHeight;
            w = h * aspect;
          } else {
            // 屏幕更高，以宽度为准
            w = constraints.maxWidth;
            h = w / aspect;
          }

          return Center(
            child: SizedBox(
              width: w,
              height: h,
              child: RawImage(
                image: _image,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              ),
            ),
          );
        },
      ),
    );
  }
}
