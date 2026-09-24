// Local platform fixture. No login, account initialization or backend writes.
// Run with tool/flutter_ohos.ps1 run -t tool/platform_smoke.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:geolocator/geolocator.dart';
import 'package:haven_hub/api/location.dart';
import 'package:haven_hub/constant/index.dart';
import 'package:haven_hub/models/visitor.dart';
import 'package:haven_hub/pages/location/location_list.dart';
import 'package:haven_hub/pages/visitor/visitor_pages.dart';
import 'package:haven_hub/platform/avatar_picker.dart';
import 'package:haven_hub/theme/app_theme.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/toast.dart';
import 'package:permission_handler/permission_handler.dart';

import 'visitor_share_smoke.dart' show createSmokeImage;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(
    navigatorKey: GlobalVariable.navigatorKey,
    theme: buildAppTheme(),
    locale: const Locale('zh'),
    supportedLocales: const <Locale>[Locale('zh')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const _PlatformSmoke(),
  ));
}

class _PlatformSmoke extends StatefulWidget {
  const _PlatformSmoke();

  @override
  State<_PlatformSmoke> createState() => _PlatformSmokeState();
}

class _PlatformSmokeState extends State<_PlatformSmoke> {
  bool _busy = false;
  String _result = '未执行；图片仅留内存，不上传，不显示定位坐标。';

  Future<void> _checkPermissions() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final PermissionStatus camera = await Permission.camera.status;
      final PermissionStatus microphone = await Permission.microphone.status;
      final PermissionStatus location = await Permission.location.status;
      final bool locationService = await Geolocator.isLocationServiceEnabled();
      if (!mounted) return;
      setState(() => _result = 'camera=${camera.name}\n'
          'microphone=${microphone.name}\nlocation=${location.name}\n'
          'locationService=$locationService');
    } on Object catch (error) {
      if (!mounted) return;
      await PromptAction.showError(describeError(error, fallback: '读取权限失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(AvatarSource source) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final PickedAvatar? image = await pickAvatar(source);
      if (!mounted) return;
      setState(() => _result = image == null
          ? '图片选择已取消；未上传'
          : '读取图片成功：${image.bytes.length} bytes；未上传');
    } on Object catch (error) {
      if (!mounted) return;
      final String message = describeError(error, fallback: '图片选择失败');
      setState(() => _result = error is PlatformException
          ? '平台返回 ${error.code}: ${error.message}'
          : message);
      await PromptAction.showError(message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLocation() async {
    if (_busy) return;
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => LocationList(
        locationLookup: (double latitude, double longitude,
                {required bool isMocked}) async =>
            const LocationLookupResult(
          address: '设备定位已收到（不显示坐标）',
          communities: <NearbyCommunity>[],
        ),
        ipLocationLookup: () async => const LocationLookupResult(
          address: '本地 IP 兜底测试数据',
          communities: <NearbyCommunity>[],
          isIpBased: true,
        ),
      ),
    ));
  }

  Future<void> _openShare() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await createSmokeImage();
      if (!mounted) return;
      await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
        settings: const RouteSettings(arguments: 'local-platform-smoke'),
        builder: (_) => VisitorDetailPage(
          loader: (_) async => const VisitorRecord(
            id: 'local-platform-smoke',
            houseInfo: '本地测试数据 · 无通行权限',
            status: 1,
            url: 'https://example.invalid/local-test.png',
            validTime: 30,
          ),
          imageLoader: (_) async => bytes,
          previewBuilder: (_) => Image.memory(bytes, fit: BoxFit.contain),
        ),
      ));
    } on Object catch (error) {
      if (!mounted) return;
      await PromptAction.showError(describeError(error, fallback: '准备测试图片失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('本地平台验证')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          const Text('不登录、不修改业务数据、不上传图片。'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _checkPermissions,
            child: const Text('读取权限状态'),
          ),
          FilledButton(
            onPressed: _busy ? null : _openLocation,
            child: const Text('定位页面：真实权限、本地结果'),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _pick(AvatarSource.camera),
            child: const Text('拍照：不上传'),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _pick(AvatarSource.gallery),
            child: const Text('相册：不上传'),
          ),
          FilledButton(
            onPressed: _busy ? null : _openShare,
            child: const Text('系统分享：本地测试图'),
          ),
          const SizedBox(height: 16),
          SelectableText(_result),
        ],
      ),
    );
  }
}
