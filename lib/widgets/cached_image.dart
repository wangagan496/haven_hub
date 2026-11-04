import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../utils/request_dio.dart';
import '../utils/token_manager.dart';

/// 带缓存的网络图片组件。
///
/// 本服务受保护图片仅驻留内存，换号、退出或页面销毁时清理。
/// 公开图片在鸿蒙使用 Flutter 内存缓存，其他平台沿用磁盘缓存。
/// 统一加载、错误处理和占位符样式。
class CachedImage extends StatelessWidget {
  /// 创建带缓存的网络图片。
  const CachedImage({
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
    this.borderRadius,
    super.key,
  });

  /// 图片 URL。
  final String imageUrl;

  /// 图片宽度。
  final double? width;

  /// 图片高度。
  final double? height;

  /// 图片填充方式。
  final BoxFit fit;

  /// 自定义占位符。
  final Widget? placeholder;

  /// 自定义错误组件。
  final Widget? errorWidget;

  /// 圆角半径。
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    // 当前 path_provider 依赖没有 OHOS 实现。磁盘缓存初始化会失败，
    // 并使 flutter_cache_manager 的加载 Future 一直不结束。
    // NetworkImage 使用 Flutter 内存缓存，无需新增原生插件或权限。
    Widget image = RequestDio.isServiceMedia(imageUrl)
        ? _ProtectedImage(imageUrl: imageUrl, width: width, height: height, fit: fit,
            placeholder: placeholder ?? _buildDefaultPlaceholder(context),
            errorWidget: errorWidget ?? _buildDefaultErrorWidget(context))
        : !kIsWeb && defaultTargetPlatform == TargetPlatform.ohos
        ? Image.network(
            imageUrl,
            width: width,
            height: height,
            fit: fit,
            cacheWidth: width?.toInt(),
            cacheHeight: height?.toInt(),
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) return child;
              return placeholder ?? _buildDefaultPlaceholder(context);
            },
            errorBuilder: (context, error, stackTrace) =>
                errorWidget ?? _buildDefaultErrorWidget(context),
          )
        : CachedNetworkImage(
            imageUrl: imageUrl,
            width: width,
            height: height,
            fit: fit,
            placeholder: (BuildContext context, String url) {
              return placeholder ?? _buildDefaultPlaceholder(context);
            },
            errorWidget: (BuildContext context, String url, Object error) {
              return errorWidget ?? _buildDefaultErrorWidget(context);
            },
            // 配置缓存策略
            cacheKey: imageUrl,
            maxWidthDiskCache: 1000,
            maxHeightDiskCache: 1000,
            // 内存缓存配置（使用默认值）
            memCacheWidth: width?.toInt(),
            memCacheHeight: height?.toInt(),
          );

    if (borderRadius != null) {
      image = ClipRRect(
        borderRadius: borderRadius!,
        child: image,
      );
    }

    return image;
  }

  /// 构建默认占位符。
  Widget _buildDefaultPlaceholder(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[200],
      child: const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
        ),
      ),
    );
  }

  /// 构建默认错误组件。
  Widget _buildDefaultErrorWidget(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Colors.grey[200],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 48,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 8),
          Text(
            '图片加载失败',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Private bytes live only while this view is active, and are removed on account changes.
class _ProtectedImage extends StatefulWidget {
  const _ProtectedImage({required this.imageUrl, required this.width,
    required this.height, required this.fit, required this.placeholder, required this.errorWidget});
  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget placeholder;
  final Widget errorWidget;
  @override
  State<_ProtectedImage> createState() => _ProtectedImageState();
}

class _ProtectedImageState extends State<_ProtectedImage> with WidgetsBindingObserver {
  CancelToken? _cancel;
  MemoryImage? _image;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    tokenManager.sessionChanges.addListener(_reload);
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void didUpdateWidget(covariant _ProtectedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageUrl != oldWidget.imageUrl) _reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  void _reload() {
    final generation = ++_generation;
    _cancel?.cancel();
    final previous = _image;
    if (previous != null) unawaited(previous.evict());
    final cancel = _cancel = CancelToken();
    setState(() { _image = null; _failed = false; });
    unawaited(() async {
      try {
        final bytes = await requestDio.getMedia(widget.imageUrl, cancelToken: cancel);
        if (!mounted || generation != _generation) return;
        setState(() => _image = MemoryImage(bytes));
      } on Object {
        if (!mounted || generation != _generation) return;
        setState(() => _failed = true);
      }
    }());
  }

  @override
  void dispose() {
    _generation++;
    _cancel?.cancel();
    tokenManager.sessionChanges.removeListener(_reload);
    WidgetsBinding.instance.removeObserver(this);
    final image = _image;
    if (image != null) unawaited(image.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (_failed) return widget.errorWidget;
    if (image == null) return widget.placeholder;
    return Image(image: image, width: widget.width, height: widget.height,
        fit: widget.fit,
        errorBuilder: (_, error, stack) => widget.errorWidget);
  }
}

/// 圆形头像图片组件。
class CachedAvatar extends StatelessWidget {
  /// 创建圆形头像。
  const CachedAvatar({
    required this.imageUrl,
    this.size = 48,
    this.backgroundColor,
    super.key,
  });

  /// 头像图片 URL。
  final String imageUrl;

  /// 头像尺寸（宽高相等）。
  final double size;

  /// 背景颜色（当图片未加载时显示）。
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: CachedImage(
        imageUrl: imageUrl,
        width: size,
        height: size,
        placeholder: _buildAvatarPlaceholder(context),
        errorWidget: _buildAvatarError(context),
      ),
    );
  }

  Widget _buildAvatarPlaceholder(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: backgroundColor ?? Colors.grey[300],
      child: Center(
        child: SizedBox(
          width: size * 0.4,
          height: size * 0.4,
          child: const CircularProgressIndicator(
            strokeWidth: 2,
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarError(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: backgroundColor ?? Colors.grey[300],
      child: Icon(
        Icons.person,
        size: size * 0.6,
        color: Colors.white,
      ),
    );
  }
}
