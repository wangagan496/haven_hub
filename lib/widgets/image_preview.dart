import 'package:flutter/material.dart';

/// 保持图片比例，支持鼠标滚轮、双指和按钮缩放。
class ImagePreview extends StatefulWidget {
  const ImagePreview({required this.child, super.key});

  final Widget child;

  @override
  State<ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<ImagePreview> {
  final TransformationController _transformation = TransformationController();
  Size _viewport = Size.zero;

  @override
  void dispose() {
    _transformation.dispose();
    super.dispose();
  }

  void _zoom(double factor) {
    final double scale =
        (_transformation.value.getMaxScaleOnAxis() * factor).clamp(1.0, 8.0);
    if (scale == 1) {
      _reset();
      return;
    }
    final Offset center = _viewport.center(Offset.zero);
    final Offset scene = _transformation.toScene(center);
    _transformation.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        center.dx - scene.dx * scale,
        center.dy - scene.dy * scale,
        0,
      );
  }

  void _reset() => _transformation.value = Matrix4.identity();

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            IconTheme(
              data: const IconThemeData(color: Colors.white),
              child: Row(
                children: <Widget>[
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Text('照片预览', style: TextStyle(color: Colors.white)),
                  ),
                  IconButton(
                    tooltip: '缩小',
                    onPressed: () => _zoom(1 / 1.5),
                    icon: const Icon(Icons.zoom_out),
                  ),
                  IconButton(
                    tooltip: '放大',
                    onPressed: () => _zoom(1.5),
                    icon: const Icon(Icons.zoom_in),
                  ),
                  IconButton(
                    tooltip: '适应屏幕',
                    onPressed: _reset,
                    icon: const Icon(Icons.fit_screen),
                  ),
                  IconButton(
                    tooltip: '关闭预览',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  _viewport = constraints.biggest;
                  return GestureDetector(
                    onDoubleTap: () {
                      if (_transformation.value.getMaxScaleOnAxis() > 1) {
                        _reset();
                      } else {
                        _zoom(2);
                      }
                    },
                    child: InteractiveViewer(
                      transformationController: _transformation,
                      minScale: 1,
                      maxScale: 8,
                      child: SizedBox.expand(child: Center(child: widget.child)),
                    ),
                  );
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '滚轮或双指缩放 · 拖动查看 · 双击放大/还原',
                style: TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
