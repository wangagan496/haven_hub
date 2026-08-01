// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../api/location.dart';
import '../../utils/app_exception.dart';
import '../../utils/location.dart';
import '../../utils/toast.dart';

typedef LocationPermissionRequester = Future<PermissionStatus> Function();

Future<PermissionStatus> requestLocationPermission() {
  return Permission.location.request();
}

class LocationList extends StatefulWidget {
  const LocationList({
    this.permissionRequester = requestLocationPermission,
    this.positionLoader = getLocation,
    this.locationLookup = getTencentLocationInfo,
    super.key,
  });

  static const String routeName = '/locationlist';

  final LocationPermissionRequester permissionRequester;
  final PositionLoader positionLoader;
  final LocationLookup locationLookup;

  @override
  State<LocationList> createState() => _LocationListState();
}

class _LocationListState extends State<LocationList> {
  bool _isLoading = false;
  String _currentAddress = '正在获取当前位置';
  String _keyword = '';
  List<NearbyCommunity> _locations = const <NearbyCommunity>[];

  @override
  void initState() {
    super.initState();
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
        setState(() => _currentAddress = '定位权限已被永久拒绝');
        await PromptAction.showWarning('请在系统设置中开启定位权限');
      } else {
        setState(() => _currentAddress = '未获得定位权限');
        await PromptAction.showWarning('需要定位权限才能获取附近社区');
      }
    } on Object catch (error) {
      final String msg = switch (error) {
        BusinessException() => error.message,
        NetworkException() => error.message,
        FormatException() => error.message,
        LocationServiceDisabledException() => '请先开启系统定位服务',
        TimeoutException() => '定位超时，请移动到开阔位置后重试',
        _ => '获取当前位置失败，请重试',
      };
      await PromptAction.showError(msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadCurrentLocation() async {
    final Position position = await widget.positionLoader();
    if (!mounted) return;

    setState(() {
      _currentAddress = '${position.latitude.toStringAsFixed(6)}, '
          '${position.longitude.toStringAsFixed(6)}';
    });

    final LocationLookupResult result = await widget.locationLookup(
      position.latitude,
      position.longitude,
      isMocked: position.isMocked,
    );
    if (!mounted) return;

    setState(() {
      _currentAddress = result.address;
      _locations = result.communities;
    });
  }

  @override
  Widget build(BuildContext context) {
    final String keyword = _keyword.trim().toLowerCase();
    final List<NearbyCommunity> locations = _locations.where((item) {
      if (keyword.isEmpty) return true;
      return item.name.toLowerCase().contains(keyword) ||
          item.address.toLowerCase().contains(keyword);
    }).toList(growable: false);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F3F8),
      appBar: AppBar(
        title: const Text('选择社区'),
        centerTitle: true,
        backgroundColor: const Color(0xFFF8F3F8),
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _SectionTitle('当前地址'),
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
                        color: Color(0xFF333333),
                        fontSize: 15,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _isLoading ? null : _getAccess,
                    icon: _isLoading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location_rounded, size: 20),
                    label: const Text('重新定位'),
                  ),
                ],
              ),
            ),
            const _SectionTitle('附近社区'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                onChanged: (String value) {
                  setState(() => _keyword = value);
                },
                decoration: InputDecoration(
                  hintText: '请输入社区名称或地址',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
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
                      child: Text(
                        _isLoading ? '正在获取附近社区' : '附近暂无社区信息',
                        style: const TextStyle(color: Color(0xFF777777)),
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
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          tileColor: Colors.white,
                          title: Text(
                            item.name,
                            style: const TextStyle(
                              color: Color(0xFF262626),
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
                                      color: Color(0xFF888888),
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                          trailing: const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFFAAAAAA),
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF888888),
          fontSize: 14,
        ),
      ),
    );
  }
}
