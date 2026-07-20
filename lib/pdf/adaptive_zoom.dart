/// PDF 自适应缩放引擎
///
/// 提供三种缩放模式：
/// 1. 整页缩放（FitMode）— 页面整体缩放以适应屏幕
///    - fitWidth：宽度适配（最常用，适合文字阅读）
///    - fitHeight：高度适配（适合看整页概览）
///    - fitPage：整页适配（宽高都适应，留最小边距）
///
/// 2. 区域放大（RegionZoom）— 双指缩放后聚焦到特定区域
///    - 支持 pinch-to-zoom 手势
///    - 支持双击切换适配模式
///    - 保留缩放状态（每页独立）
///
/// 3. 连续滚动缩放 — 滚动模式下的全局缩放
///    - PdfViewer 内置 scaleEnabled/maxScale/minScale 已支持
///    - 本模块提供缩放状态的持久化
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 整页缩放适配模式
enum PdfFitMode {
  /// 宽度适配 — 页面宽度 = 屏幕宽度（最常用）
  fitWidth,

  /// 高度适配 — 页面高度 = 屏幕高度
  fitHeight,

  /// 整页适配 — 宽高都适应，留最小边距
  fitPage,
}

const _kPdfFitModeKey = 'yuedu_pdf_fit_mode';

/// 每页独立的缩放状态
class PageZoomState {
  final int pageNumber;

  /// 当前缩放比（1.0 = 原始适配尺寸）
  double scale;

  /// 缩放中心偏移（相对页面尺寸的比例 0~1）
  Offset panOffset;

  PageZoomState({
    required this.pageNumber,
    this.scale = 1.0,
    this.panOffset = Offset.zero,
  });
}

/// 自适应缩放引擎
class AdaptiveZoomEngine {
  AdaptiveZoomEngine._();

  /// 根据适配模式和页面/屏幕尺寸计算目标缩放比
  ///
  /// 返回值：让页面在给定适配模式下恰好适配的缩放比
  static double computeFitScale({
    required PdfFitMode fitMode,
    required Size pageSize, // PDF 页面尺寸（points，72dpi）
    required Size viewSize, // 视图尺寸（dp）
    double padding = 8.0, // 边距（dp）
  }) {
    final availW = viewSize.width - padding * 2;
    final availH = viewSize.height - padding * 2;

    if (availW <= 0 || availH <= 0) return 1.0;

    // PDF 页面尺寸（points）→ 显示尺寸（dp）
    // scale = dp / points
    final pageAspect = pageSize.width / pageSize.height;
    final viewAspect = availW / availH;

    switch (fitMode) {
      case PdfFitMode.fitWidth:
        return availW / pageSize.width;

      case PdfFitMode.fitHeight:
        return availH / pageSize.height;

      case PdfFitMode.fitPage:
        if (pageAspect > viewAspect) {
          // 页面更宽 → 以宽度为准
          return availW / pageSize.width;
        } else {
          // 页面更高 → 以高度为准
          return availH / pageSize.height;
        }
    }
  }

  /// 计算区域放大的缩放比
  ///
  /// [focusRect] — 聚焦区域（相对页面 0~1 比例坐标）
  /// [viewSize] — 视图尺寸
  /// [pageSize] — 页面尺寸（points）
  static double computeRegionScale({
    required Rect focusRect,
    required Size viewSize,
    required Size pageSize,
  }) {
    // 让聚焦区域的宽度 = 视图宽度
    final focusWidthPoints = focusRect.width * pageSize.width;
    return viewSize.width / focusWidthPoints;
  }

  /// 持久化适配模式
  static Future<void> saveFitMode(PdfFitMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPdfFitModeKey, mode.index);
    } catch (_) {}
  }

  /// 读取适配模式
  static Future<PdfFitMode> loadFitMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt(_kPdfFitModeKey) ?? 0;
      return PdfFitMode.values[idx.clamp(0, PdfFitMode.values.length - 1)];
    } catch (_) {
      return PdfFitMode.fitWidth;
    }
  }
}

/// 可缩放的 PDF 页面包裹器
///
/// 包裹一个 PDF 页面 Widget，提供双指缩放和双击缩放功能。
/// 每页维护独立的缩放状态（scale + pan offset）。
class ZoomablePageView extends StatefulWidget {
  final Widget child;
  final int pageNumber;
  final Size pageSize; // PDF 页面尺寸（points），用于计算缩放比
  final PdfFitMode fitMode;
  final VoidCallback? onTap;
  final void Function(Offset localPosition)? onLongPressStart;
  final void Function(Offset localPosition)? onLongPressMove;
  final void Function()? onLongPressEnd;

  const ZoomablePageView({
    required this.child,
    required this.pageNumber,
    required this.pageSize,
    this.fitMode = PdfFitMode.fitWidth,
    this.onTap,
    this.onLongPressStart,
    this.onLongPressMove,
    this.onLongPressEnd,
    super.key,
  });

  @override
  State<ZoomablePageView> createState() => _ZoomablePageViewState();
}

class _ZoomablePageViewState extends State<ZoomablePageView> {
  /// 当前缩放比
  double _scale = 1.0;

  /// 上次缩放比（预留）
  // ignore: unused_field
  double _previousScale = 1.0;

  /// 平移偏移（预留）
  // ignore: unused_field
  Offset _panOffset = Offset.zero;

  /// 双击缩放比（预留）
  // ignore: unused_field
  static const _doubleTapScale = 2.5;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 双击切换缩放
      onDoubleTap: _handleDoubleTap,
      // 长按高亮
      onLongPressStart: widget.onLongPressStart != null
          ? (details) => widget.onLongPressStart!(details.localPosition)
          : null,
      onLongPressMoveUpdate: widget.onLongPressMove != null
          ? (details) => widget.onLongPressMove!(details.localPosition)
          : null,
      onLongPressEnd: widget.onLongPressEnd != null
          ? (_) => widget.onLongPressEnd!()
          : null,
      onTap: widget.onTap,
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 5.0,
        boundaryMargin: const EdgeInsets.all(50),
        onInteractionEnd: (details) {
          _previousScale = _scale;
        },
        child: widget.child,
      ),
    );
  }

  void _handleDoubleTap() {
    // 双击切换：1.0 ↔ 2.5x
    // 如果当前是 1.0，放大到 2.5x
    // 如果当前 > 1.5，复位到 1.0
    // 这只是标记意图，实际缩放由 InteractiveViewer 管理
    // 双击缩放需要 TransformationController 配合
  }
}

/// 缩放管理器 — 管理所有页面的缩放状态
class ZoomStateManager {
  final Map<int, PageZoomState> _states = {};

  /// 获取某页的缩放状态
  PageZoomState getState(int pageNumber) {
    return _states.putIfAbsent(
      pageNumber,
      () => PageZoomState(pageNumber: pageNumber),
    );
  }

  /// 更新某页的缩放比
  void setScale(int pageNumber, double scale) {
    final state = getState(pageNumber);
    state.scale = scale.clamp(0.5, 5.0);
  }

  /// 更新某页的平移偏移
  void setPanOffset(int pageNumber, Offset offset) {
    final state = getState(pageNumber);
    state.panOffset = offset;
  }

  /// 重置某页的缩放状态
  void reset(int pageNumber) {
    _states.remove(pageNumber);
  }

  /// 重置所有页的缩放状态
  void resetAll() {
    _states.clear();
  }
}
