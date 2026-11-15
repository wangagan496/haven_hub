import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/platform/camera_fallback.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  const native = MethodChannel('haven_hub/native_camera');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger
      ..setMockMethodCallHandler(picker, null)
      ..setMockMethodCallHandler(native, null);
  });

  test('unavailable system camera uses native capture and forwards quality', () async {
    messenger
      ..setMockMethodCallHandler(picker, (_) async => throw PlatformException(code: 'camera_unavailable'))
      ..setMockMethodCallHandler(native, (call) async {
      expect(call.method, 'capture');
      expect(call.arguments, {'imageQuality': 85});
      return '/cache/native-camera/photo.jpg';
    });
    final result = await pickImageWithCameraFallback(source: ImageSource.camera, imageQuality: 85);
    expect(result?.path, '/cache/native-camera/photo.jpg');
  });

  test('native cancellation remains cancellation', () async {
    messenger
      ..setMockMethodCallHandler(picker, (_) async => throw PlatformException(code: 'camera_unavailable'))
      ..setMockMethodCallHandler(native, (_) async => null);
    expect(await pickImageWithCameraFallback(source: ImageSource.camera), isNull);
  });

  test('missing native bridge preserves unavailable error', () async {
    messenger.setMockMethodCallHandler(picker, (_) async => throw PlatformException(code: 'camera_unavailable'));
    await expectLater(pickImageWithCameraFallback(source: ImageSource.camera),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'camera_unavailable')));
  });

  for (final code in ['camera_access_denied', 'unexpected']) {
    test('$code does not activate fallback', () async {
      messenger
        ..setMockMethodCallHandler(picker, (_) async => throw PlatformException(code: code))
        ..setMockMethodCallHandler(native, (_) async => fail('Unexpected fallback'));
      await expectLater(pickImageWithCameraFallback(source: ImageSource.camera),
          throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)));
    });
  }

  test('gallery failure does not activate fallback', () async {
    messenger
      ..setMockMethodCallHandler(picker, (_) async => throw PlatformException(code: 'camera_unavailable'))
      ..setMockMethodCallHandler(native, (_) async => fail('Unexpected fallback'));
    await expectLater(pickImageWithCameraFallback(source: ImageSource.gallery), throwsA(isA<PlatformException>()));
  });

  test('successful system picker does not activate fallback', () async {
    messenger
      ..setMockMethodCallHandler(picker, (_) async => '/cache/system.jpg')
      ..setMockMethodCallHandler(native, (_) async => fail('Unexpected fallback'));
    expect((await pickImageWithCameraFallback(source: ImageSource.camera))?.path, '/cache/system.jpg');
  });
}
