import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 带缓存的网络图片组件。
///
/// 封装 [CachedNetworkImage]，提供统一的加载、错误处理和占位符样式。
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
    Widget image = CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit,
      placeholder: (BuildContext context, String url) {
        return placeholder ??
            _buildDefaultPlaceholder(context);
      },
      errorWidget: (BuildContext context, String url, Object error) {
        return errorWidget ??
            _buildDefaultErrorWidget(context);
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
        fit: BoxFit.cover,
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
