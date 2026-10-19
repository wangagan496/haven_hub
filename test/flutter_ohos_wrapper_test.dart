import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final String mode in <String>['debug', 'release']) {
    test('Flutter OH wrapper forwards --$mode to Flutter', () async {
      final Directory fixture =
          await Directory.systemTemp.createTemp('haven-flutter-wrapper-');
      addTearDown(() => fixture.delete(recursive: true));
      final Directory bin = await Directory('${fixture.path}/bin').create();
      await File('${bin.path}/flutter.bat').writeAsString(
        '@echo off\r\necho FLUTTER_ARGS %*\r\nexit /b 0\r\n',
      );
      final File platform = File(
        '${fixture.path}/packages/flutter/lib/src/foundation/platform.dart',
      );
      await platform.parent.create(recursive: true);
      await platform.writeAsString('enum TargetPlatform { ohos, }');
      final File defines = File('${fixture.path}/defines.env');
      await defines.writeAsString('TENCENT_MAP_KEY=wrapper-test-placeholder\n');
      final ProcessResult result = await Process.run('pwsh', <String>[
        '-NoProfile',
        '-File',
        'tool/flutter_ohos.ps1',
        '-FlutterOhosSdk',
        fixture.path,
        '-DartDefinesFile',
        defines.path,
        'build',
        'hap',
        '--$mode',
        '--no-pub',
        '--target-platform=ohos-x64',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final String forwarded = '${result.stdout}'
          .split('\n')
          .singleWhere((String line) => line.startsWith('FLUTTER_ARGS '));
      expect(forwarded, contains('--$mode'));
      expect(forwarded, contains('--target-platform=ohos-x64'));
      expect(forwarded, contains('--no-pub'));
      if (mode == 'release') {
        expect(forwarded, isNot(contains('--debug')));
      }
    }, skip: !Platform.isWindows);
  }
}
