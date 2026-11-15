import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/pages/house/house_form.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel =
      MethodChannel('plugins.flutter.io/image_picker');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('house photo camera unavailable error suggests choosing a gallery image',
      () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'camera_unavailable');
    });

    await expectLater(
      pickHousePhoto(ImageSource.camera),
      throwsA(isA<FormatException>().having(
        (FormatException error) => error.message,
        'message',
        '当前设备无法使用系统相机，请从相册选择图片',
      )),
    );
  });

  test('unknown house photo picker errors remain available to callers',
      () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unexpected');
    });

    await expectLater(
      pickHousePhoto(ImageSource.camera),
      throwsA(isA<PlatformException>()),
    );
  });
}
