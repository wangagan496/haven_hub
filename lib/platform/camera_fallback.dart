import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

const _nativeCamera = MethodChannel('haven_hub/native_camera');

/// Keeps the system picker as the default; the native bridge is app-local.
Future<XFile?> pickImageWithCameraFallback({
  required ImageSource source,
  double? maxWidth,
  double? maxHeight,
  int? imageQuality,
}) async {
  try {
    return await ImagePicker().pickImage(
      source: source,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      imageQuality: imageQuality,
    );
  } on PlatformException catch (error) {
    if (source != ImageSource.camera || error.code != 'camera_unavailable') {
      rethrow;
    }
    try {
      final path = await _nativeCamera.invokeMethod<String>('capture', {
        'imageQuality': imageQuality ?? 90,
      });
      if (path == null) return null;
      if (path.isEmpty) {
        throw PlatformException(code: 'camera_capture_failed');
      }
      return XFile(path);
    } on MissingPluginException {
      throw error;
    }
  }
}
