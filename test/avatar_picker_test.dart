import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/platform/avatar_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('plugins.flutter.io/image_picker');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final String code in <String>[
    'camera_access_denied',
    'camera_unavailable',
    'camera_capture_failed',
  ]) {
    test('$code gives an actionable error rather than a successful cancel',
        () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: code);
      });
      await expectLater(
        pickAvatar(AvatarSource.camera),
        throwsA(isA<FormatException>().having(
          (FormatException error) => error.message,
          'message',
          contains('相册'),
        )),
      );
    });
  }

  test('unknown platform errors remain errors', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unexpected');
    });
    await expectLater(pickAvatar(AvatarSource.camera),
        throwsA(isA<PlatformException>()));
  });

  test('gallery cancellation returns null and preserves selection options',
      () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'pickImage');
      final Map<Object?, Object?> arguments =
          call.arguments as Map<Object?, Object?>;
      expect(arguments['source'], 1);
      expect(arguments['maxWidth'], 1600);
      expect(arguments['maxHeight'], 1600);
      expect(arguments['imageQuality'], 85);
      return null;
    });
    expect(await pickAvatar(AvatarSource.gallery), isNull);
  });
}
