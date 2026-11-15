import 'package:flutter/services.dart';

/// Converts known camera picker failures into actionable user-facing errors.
/// Unknown platform failures remain available to the caller unchanged.
FormatException? imagePickerCameraError(PlatformException error) {
  return switch (error.code) {
    'camera_access_denied' => const FormatException('未获得相机权限，请允许后重试或从相册选择图片'),
    'camera_unavailable' => const FormatException('当前设备无法使用系统相机，请从相册选择图片'),
    'camera_capture_failed' ||
    'camera_permission_error' =>
      const FormatException('相机无法启动，请重试或从相册选择图片'),
    _ => null,
  };
}
