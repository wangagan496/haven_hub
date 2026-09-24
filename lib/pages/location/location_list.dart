import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../api/location.dart';
import '../../controller/build_controller.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/location.dart';
import '../../utils/toast.dart';
import '../../widgets/section_title.dart';
import '../building/building_list.dart';

typedef LocationPermissionRequester = Future<PermissionStatus> Function();

const Duration _permissionRequestTimeout = Duration(seconds: 12);

Future<PermissionStatus> requestLocationPermission() async {
  if (!kIsWeb) {
    return Permission.location.request();
  }

  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }

  if (permission == LocationPermission.always ||
      permission == LocationPermission.whileInUse) {
    return PermissionStatus.granted;
  }
  if (permission == LocationPermission.deniedForever) {
    return PermissionStatus.permanentlyDenied;
  }
  return PermissionStatus.denied;
}

class LocationList extends StatefulWidget {
  const LocationList({
    this.permissionRequester = requestLocationPermission,
    this.permissionRequestTimeout = _permissionRequestTimeout,
    this.positionLoader = getLocation,
    this.locationLookup = getTencentLocationInfo,
    this.ipLocationLookup = getTencentIpLocationInfo,
    super.key,
  });

  static const String routeName = AppRoutes.locationList;

  final LocationPermissionRequester permissionRequester;
  final Duration permissionRequestTimeout;
  final PositionLoader positionLoader;
  final LocationLookup locationLookup;
  final IpLocationLookup ipLocationLookup;

  @override
  State<LocationList> createState() => _LocationListState();
}

class _LocationListState extends State<LocationList> {
  late final BuildController _buildController;
  bool _isLoading = false;

  /// 是否已经拿到过一次定位结果。决定刷新时用整屏骨架还是保留页面：
  /// 已经有内容时把搜索框和定位按钮整块换掉，用户会以为页面被重置了。
  bool _hasResolved = false;
  String _currentAddress = '正在获取当前位置';
  String _keyword = '';
  List<NearbyCommunity> _locations = const <NearbyCommunity>[];

  /// 当前应展示的社区列表，与 [_locations] 和 [_keyword] 同步更新。
  ///
  /// 不再放进 build 里惰性计算：那样缓存是否有效取决于「每条改数据的路径都
  /// 记得把它置空」，漏一处就会显示出上一次的过滤结果。
  List<NearbyCommunity> _visibleLocations = const <NearbyCommunity>[];

  @override
  void initState() {
    super.initState();
    _buildController = BuildController.instance();
    unawaited(_getAccess());
  }

  Future<void> _getAccess() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);
    try {
      // GPS 反查可返回区、街道等完整行政区划；IP 定位只作为兜底，
      // 因其通常只能稳定到城市级别。
      late final PermissionStatus status;
      try {
        status = await widget.permissionRequester().timeout(
              widget.permissionRequestTimeout,
            );
      } on Object {
        if (!mounted) return;
        await _loadIpLocation(
          '无法获取定位权限，已切换为 IP 定位，仅供城市级参考',
        );
        return;
      }
      if (!mounted) return;

      if (status.isGranted) {
        await _loadCurrentLocation();
      } else if (status.isPermanentlyDenied) {
        await _loadIpLocation(
          '定位权限已被永久拒绝，已切换为 IP 定位，仅供城市级参考',
        );
      } else {
        await _loadIpLocation(
          '未获得定位权限，已切换为 IP 定位，仅供城市级参考',
        );
      }
    } on Object catch (error) {
      if (!mounted) return;
      final String msg = describeError(
        error,
        fallback: '获取当前位置失败，请重试',
        onOtherError: (Object error) => switch (error) {
          LocationServiceDisabledException() => '请先开启系统定位服务',
          TimeoutException() => '定位超时，请移动到开阔位置后重试',
          _ => null,
        },
      );
      await PromptAction.showError(msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 主动切换到设备 GPS 定位。
  ///
  /// 页面默认已优先使用 GPS；此按钮可在用户移动或修改模拟器坐标后
  /// 主动刷新设备位置。
  Future<void> _getGpsAccess() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);
    try {
      final PermissionStatus status =
          await widget.permissionRequester().timeout(
                widget.permissionRequestTimeout,
              );
      if (!mounted) return;

      if (status.isGranted) {
        await _loadCurrentLocation(allowIpFallback: false);
      } else if (status.isPermanentlyDenied) {
        // 永久拒绝后系统不再弹权限框，只能去设置里改。这里主动给一条路，
        // 否则用户点多少次「GPS定位」都只是同一个报错。
        await _promptOpenSettings(
          '定位权限已被永久拒绝，需要在小区的系统设置中开启精确位置权限。',
        );
      } else {
        throw const FormatException('未获得 GPS 定位权限，请允许使用精确位置');
      }
    } on Object catch (error) {
      if (!mounted) return;
      final String msg = describeError(
        error,
        fallback: '获取 GPS 定位失败，请重试',
        onOtherError: (Object error) => switch (error) {
          LocationServiceDisabledException() => '请先开启系统定位服务',
          TimeoutException() => 'GPS 定位超时，请移动到开阔位置后重试',
          _ => null,
        },
      );
      await PromptAction.showError(msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _getIpAccess() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);
    try {
      await _loadIpLocation();
      if (!mounted) return;
      await PromptAction.showWarning(
        'IP 定位显示的是网络出口位置，可能与实际所在区不同，仅供参考',
      );
    } on Object catch (error) {
      if (!mounted) return;
      final String msg = describeError(
        error,
        fallback: 'IP 定位失败，请重试',
      );
      await PromptAction.showError(msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadCurrentLocation({bool allowIpFallback = true}) async {
    LocationLookupResult? result;
    try {
      final Position position = await widget.positionLoader();
      if (!mounted) return;

      setState(() {
        _currentAddress = '${position.latitude.toStringAsFixed(6)}, '
            '${position.longitude.toStringAsFixed(6)}';
      });

      result = await widget.locationLookup(
        position.latitude,
        position.longitude,
        isMocked: position.isMocked,
      );
    } on Object catch (locationError, locationStackTrace) {
      if (!mounted) return;
      if (!allowIpFallback) {
        Error.throwWithStackTrace(locationError, locationStackTrace);
      }
      try {
        result = await widget.ipLocationLookup();
      } on Object {
        Error.throwWithStackTrace(locationError, locationStackTrace);
      }
      if (!mounted) return;
      await PromptAction.showWarning('GPS 定位不可用，已切换为 IP 定位，仅供城市级参考');
    }
    if (!mounted) return;

    final LocationLookupResult lookupResult = result;
    _applyLookupResult(lookupResult);
  }

  Future<void> _loadIpLocation([String warningMessage = '']) async {
    final LocationLookupResult result = await widget.ipLocationLookup();
    if (!mounted) return;

    if (warningMessage.isNotEmpty) {
      await PromptAction.showWarning(warningMessage);
    }
    if (!mounted) return;

    _applyLookupResult(result);
  }

  void _applyLookupResult(LocationLookupResult result) {
    setState(() {
      _currentAddress = result.isIpBased
          ? '${result.address}（IP 网络出口位置，仅供参考）'
          : result.address;
      _locations = result.communities;
      _visibleLocations = _filterCommunities(_locations, _keyword);
      _hasResolved = true;
    });
  }

  void _onSearchChanged(String value) {
    setState(() {
      _keyword = value;
      _visibleLocations = _filterCommunities(_locations, value);
    });
  }

  static List<NearbyCommunity> _filterCommunities(
    List<NearbyCommunity> source,
    String keyword,
  ) {
    final String needle = keyword.trim().toLowerCase();
    if (needle.isEmpty) {
      return source;
    }
    return source
        .where((NearbyCommunity item) =>
            item.name.toLowerCase().contains(needle) ||
            item.address.toLowerCase().contains(needle))
        .toList(growable: false);
  }

  /// 权限被永久拒绝后，唯一的恢复路径是系统设置。
  Future<void> _promptOpenSettings(String message) async {
    final bool? openSettings = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: const Text('需要定位权限'),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('暂不'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('前往设置'),
          ),
        ],
      ),
    );
    if (openSettings ?? false) {
      await openAppSettings();
    }
  }

  Future<void> _selectCommunity(NearbyCommunity community) async {
    _buildController.updateBuildingInfo(<String, String>{
      'name': community.name,
      'address': community.address,
    });
    await Navigator.pushNamed<void>(
      context,
      BuildingList.routeName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<NearbyCommunity> locations = _visibleLocations;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('选择社区'),
      ),
      body: SafeArea(
        top: false,
        // 只有首次进入才铺整屏骨架。已经有地址或列表后再刷新，页面结构保持
        // 不动，搜索框和两个定位按钮始终可点。
        child: _isLoading && !_hasResolved
            ? const _LocationSkeleton(key: Key('location-skeleton'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SectionTitle('当前地址'),
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _currentAddress,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textBody,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('gps-location-button'),
                          onPressed: _getGpsAccess,
                          icon: const Icon(Icons.gps_fixed_rounded, size: 20),
                          label: const Text('GPS定位'),
                        ),
                        TextButton.icon(
                          key: const Key('ip-location-button'),
                          onPressed: _getIpAccess,
                          icon: const Icon(Icons.public_rounded, size: 20),
                          label: const Text('IP定位'),
                        ),
                      ],
                    ),
                  ),
                  const SectionTitle('附近社区'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: TextField(
                      onChanged: _onSearchChanged,
                      decoration: InputDecoration(
                        hintText: '请输入社区名称或地址',
                        prefixIcon: const Icon(Icons.search_rounded),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: locations.isEmpty
                        ? const Center(
                            child: Text(
                              '附近暂无社区信息',
                              style: TextStyle(color: AppColors.textTertiary),
                            ),
                          )
                        : ListView.separated(
                            itemCount: locations.length,
                            separatorBuilder: (_, __) => const Divider(
                              height: 1,
                              indent: 16,
                            ),
                            itemBuilder: (BuildContext context, int index) {
                              final NearbyCommunity item = locations[index];
                              return ListTile(
                                onTap: () => _selectCommunity(item),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                tileColor: Colors.white,
                                title: Text(
                                  item.name,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                subtitle: item.address.isEmpty
                                    ? null
                                    : Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Text(
                                          item.address,
                                          style: const TextStyle(
                                            color: AppColors.textSecondary,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                trailing: const Icon(
                                  Icons.chevron_right_rounded,
                                  color: AppColors.divider,
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _LocationSkeleton extends StatelessWidget {
  const _LocationSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '正在获取当前位置和附近社区',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SectionTitle('当前地址'),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: const Row(
                children: <Widget>[
                  Expanded(child: _SkeletonBlock(height: 18)),
                  SizedBox(width: 28),
                  _SkeletonBlock(width: 76, height: 18),
                ],
              ),
            ),
            const SectionTitle('附近社区'),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: _SkeletonBlock(height: 48, borderRadius: 6),
            ),
            Expanded(
              child: ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 5,
                separatorBuilder: (_, __) => const Divider(
                  height: 1,
                  indent: 16,
                ),
                itemBuilder: (BuildContext context, int index) {
                  return const ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _SkeletonBlock(width: 132, height: 18),
                          SizedBox(height: 10),
                          _SkeletonBlock(width: 220, height: 13),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  const _SkeletonBlock({
    required this.height,
    this.width,
    this.borderRadius = 4,
  });

  final double? width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE8E3E8),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}
