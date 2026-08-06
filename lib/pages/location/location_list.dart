import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../api/location.dart';
import '../../theme/app_colors.dart';
import '../../controller/build_controller.dart';
import '../../utils/app_exception.dart';
import '../../utils/location.dart';
import '../../utils/toast.dart';
import '../../widgets/section_title.dart';
import '../building/building_list.dart';

typedef LocationPermissionRequester = Future<PermissionStatus> Function();

Future<PermissionStatus> requestLocationPermission() {
  return Permission.location.request();
}

class LocationList extends StatefulWidget {
  const LocationList({
    this.permissionRequester = requestLocationPermission,
    this.positionLoader = getLocation,
    this.locationLookup = getTencentLocationInfo,
    this.ipLocationLookup = getTencentIpLocationInfo,
    super.key,
  });

  static const String routeName = '/locationlist';

  final LocationPermissionRequester permissionRequester;
  final PositionLoader positionLoader;
  final LocationLookup locationLookup;
  final IpLocationLookup ipLocationLookup;

  @override
  State<LocationList> createState() => _LocationListState();
}

class _LocationListState extends State<LocationList> {
  late final BuildController _buildController;
  bool _isLoading = false;
  String _currentAddress = '正在获取当前位置';
  String _keyword = '';
  List<NearbyCommunity> _locations = const <NearbyCommunity>[];
  List<NearbyCommunity>? _filteredLocations;

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
      final PermissionStatus status = await widget.permissionRequester();
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

  Future<void> _loadCurrentLocation() async {
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

  Future<void> _loadIpLocation(String warningMessage) async {
    final LocationLookupResult result = await widget.ipLocationLookup();
    if (!mounted) return;

    await PromptAction.showWarning(warningMessage);
    if (!mounted) return;

    _applyLookupResult(result);
  }

  void _applyLookupResult(LocationLookupResult result) {
    setState(() {
      _currentAddress = result.isIpBased
          ? '${result.address}（IP 定位，精度仅到城市级）'
          : result.address;
      _locations = result.communities;
      _filteredLocations = null; // 清空缓存，因为列表已更新
    });
  }

  void _onSearchChanged(String value) {
    setState(() {
      _keyword = value;
      _filteredLocations = null; // 清空缓存，强制重新过滤
    });
  }

  List<NearbyCommunity> _getFilteredLocations() {
    // 使用缓存的过滤结果，避免每次 build 都重新计算
    if (_filteredLocations != null) {
      return _filteredLocations!;
    }

    final String keyword = _keyword.trim().toLowerCase();
    final List<NearbyCommunity> filtered = keyword.isEmpty
        ? _locations
        : _locations.where((NearbyCommunity item) {
            return item.name.toLowerCase().contains(keyword) ||
                item.address.toLowerCase().contains(keyword);
          }).toList(growable: false);

    _filteredLocations = filtered;
    return filtered;
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
    final List<NearbyCommunity> locations = _getFilteredLocations();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('选择社区'),
      ),
      body: SafeArea(
        top: false,
        child: _isLoading
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
                          onPressed: _getAccess,
                          icon: const Icon(Icons.my_location_rounded, size: 20),
                          label: const Text('重新定位'),
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
                        ? Center(
                            child: const Text(
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
