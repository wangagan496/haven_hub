import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart' as image_picker;

enum AvatarSource {
  camera,
  gallery,
}

class PickedAvatar {
  const PickedAvatar({
    required this.bytes,
    required this.fileName,
  });

  final Uint8List bytes;
  final String fileName;
}

typedef AvatarPicker = Future<PickedAvatar?> Function(AvatarSource source);

bool get supportsAvatarCamera {
  if (kIsWeb) {
    return false;
  }
  return !const <TargetPlatform>{
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  }.contains(defaultTargetPlatform);
}

Future<PickedAvatar?> pickAvatar(AvatarSource source) async {
  final image_picker.XFile? file = await image_picker.ImagePicker().pickImage(
    source: switch (source) {
      AvatarSource.camera => image_picker.ImageSource.camera,
      AvatarSource.gallery => image_picker.ImageSource.gallery,
    },
    maxWidth: 1600,
    maxHeight: 1600,
    imageQuality: 85,
  );
  if (file == null) {
    return null;
  }

  // XFile 字节读取同时支持 Web Blob、鸿蒙和其他原生平台，
  // 网络层不需要依赖各平台含义不同的临时文件路径。
  final Uint8List bytes = await file.readAsBytes();
  if (bytes.isEmpty) {
    throw const FormatException('所选图片内容为空');
  }

  final String fileName = file.name.trim();
  return PickedAvatar(
    bytes: bytes,
    fileName: fileName.isEmpty ? 'avatar.jpg' : fileName,
  );
}
