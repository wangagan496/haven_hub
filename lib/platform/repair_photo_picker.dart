import 'package:image_picker/image_picker.dart';
import 'avatar_picker.dart';

typedef RepairPhotoPicker = Future<List<PickedAvatar>> Function(int remaining);

Future<List<PickedAvatar>> pickRepairPhotos(int remaining) async {
  final files = await ImagePicker()
      .pickMultiImage(maxWidth: 1600, maxHeight: 1600, imageQuality: 85);
  if (files.length > remaining) {
    throw FormatException('还能添加$remaining张照片，请重新选择');
  }
  final result = <PickedAvatar>[];
  for (final file in files) {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('每张照片需为有效图片且不超过8MB');
    }
    result.add(PickedAvatar(
        bytes: bytes, fileName: file.name.isEmpty ? 'repair.jpg' : file.name));
  }
  return result;
}
