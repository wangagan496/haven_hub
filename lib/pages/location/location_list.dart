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
const Duration _positionRequestTimeout = Duration(seconds: 50);
const Duration _lookupRequestTimeout = Duration(seconds: 20);

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
    this.positionLoader,
    this.locationLookup = getTencentLocationInfo,
    this.ipLocationLookup = getTencentIpLocationInfo,
    super.key,
  });

  static const String routeName = AppRoutes.locationList;

  final LocationPermissionRequester permissionRequester;
  final Duration permissionRequestTimeout;
  final PositionLoader? positionLoader;
  final LocationLookup locationLookup;
  final IpLocationLookup ipLocationLookup;

  @override
  State<LocationList> createState() => _LocationListState();
}

class _LocationListState extends State<LocationList> {
  late final BuildController _buildController;
  bool _isLoading = false;
  int _requestId = 0;
  String? _errorMessage;
  String _loadingStage = '正在等待定位权限，请留意浏览器的权限提示';

  /// 是否已经拿到过一次定位结果。决定刷新时用整屏骨架还是保留页面：
  /// 已经有内容时保留搜索框和社区列表，避免刷新时页面闪烁。
  bool _hasResolved = false;
  String _currentAddress = '正在获取当前位置';
  List<NearbyCommunity> _locations = const <NearbyCommunity>[];

  @override
  void initState() {
    super.initState();
    _buildController = BuildController.instance();
    unawaited(_getAccess());
  }

  bool _isCurrent(int requestId) => mounted && requestId == _requestId;

  int _beginRequest() {
    final int requestId = ++_requestId;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _loadingStage = '正在等待定位权限，请留意浏览器的权限提示';
    });
    return requestId;
  }

  void _showFailure(String message) {
    setState(() {
      _errorMessage = message;
      if (!_hasResolved) _currentAddress = '定位失败，请重试';
    });
  }

  Future<void> _retryLookup() async {
    if (_isLoading) return;
    await _getAccess();
  }

  Future<void> _getAccess() async {
    if (_isLoading) return;

    final int requestId = _beginRequest();
    try {
      // GPS 反查可返回区、街道等完整行政区划；权限不足时自动使用 IP 兜底。
      late final PermissionStatus status;
      try {
        status = await widget.permissionRequester().timeout(
              widget.permissionRequestTimeout,
            );
      } on Object {
        if (!_isCurrent(requestId)) return;
        await _loadIpLocation(requestId);
        return;
      }
      if (!_isCurrent(requestId)) return;

      if (status.isGranted) {
        await _loadCurrentLocation(requestId);
      } else {
        await _loadIpLocation(requestId);
      }
    } on Object catch (error) {
      if (!_isCurrent(requestId)) return;
      final String msg = describeError(
        error,
        fallback: '获取当前位置失败，请重试',
        onOtherError: (Object error) => switch (error) {
          LocationServiceDisabledException() => '请先开启系统定位服务',
          TimeoutException() => '定位或社区查询超时，请重试',
          _ => null,
        },
      );
      _showFailure(msg);
      await PromptAction.showError(msg);
    } finally {
      if (_isCurrent(requestId)) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadCurrentLocation(int requestId) async {
    LocationLookupResult? result;
    Position? devicePosition;
    try {
      setState(() => _loadingStage = '正在获取当前位置');
      final Position position =
          await (widget.positionLoader?.call() ?? getLocation())
              .timeout(_positionRequestTimeout);
      if (!_isCurrent(requestId)) return;

      devicePosition = position;
      setState(() {
        _loadingStage = '已获取设备位置，正在查询地址和附近社区';
      });

      result = await widget
          .locationLookup(
            position.latitude,
            position.longitude,
            isMocked: position.isMocked,
          )
          .timeout(_lookupRequestTimeout);
    } on Object catch (locationError, locationStackTrace) {
      if (!_isCurrent(requestId)) return;
      if (devicePosition != null) {
        final String reason = '附近社区查询失败：${describeError(
          locationError,
          fallback: '地址或附近社区查询异常',
          onOtherError: (Object error) =>
              error is TimeoutException ? '查询超时' : null,
        )}';
        Error.throwWithStackTrace(FormatException(reason), locationStackTrace);
      }
      await _loadIpLocation(requestId);
      return;
    }
    if (!_isCurrent(requestId)) return;

    final LocationLookupResult lookupResult = result;
    _applyLookupResult(lookupResult);
  }

  Future<void> _loadIpLocation(int requestId) async {
    setState(() => _loadingStage = '正在查询位置和附近社区');
    final LocationLookupResult result =
        await widget.ipLocationLookup().timeout(_lookupRequestTimeout);
    if (!_isCurrent(requestId)) return;

    _applyLookupResult(result);
  }

  void _applyLookupResult(LocationLookupResult result) {
    setState(() {
      _currentAddress = result.address;
      _locations = result.communities;
      _hasResolved = true;
    });
  }

  static List<DropdownMenuEntry<NearbyCommunity?>> _filterCommunities(
    List<DropdownMenuEntry<NearbyCommunity?>> source,
    String keyword,
  ) {
    final String needle = keyword.trim().toLowerCase();
    if (needle.isEmpty) {
      return source;
    }
    final matches = source
        .where((DropdownMenuEntry<NearbyCommunity?> entry) =>
            entry.value != null &&
            (entry.value!.name.toLowerCase().contains(needle) ||
                entry.value!.address.toLowerCase().contains(needle)))
        .toList(growable: false);
    return matches.isEmpty
        ? const <DropdownMenuEntry<NearbyCommunity?>>[
            DropdownMenuEntry(value: null, label: '没有匹配的小区', enabled: false),
          ]
        : matches;
  }

  Future<void> _selectCommunity(NearbyCommunity community) async {
    _buildController.updateBuildingInfo(<String, dynamic>{
      'name': community.name,
      'address': community.address,
      'communityId': community.id,
      'latitude': community.latitude,
      'longitude': community.longitude,
    });
    await Navigator.pushNamed<void>(
      context,
      BuildingList.routeName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<NearbyCommunity> locations = _locations;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('选择社区'),
      ),
      body: SafeArea(
        top: false,
        // 首次加载显示进度；刷新时保留已有结果。
        child: _isLoading && !_hasResolved
            ? Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: <Widget>[
                      Expanded(child: Text(_loadingStage)),
                    ]),
                  ),
                  const Expanded(
                      child: _LocationSkeleton(key: Key('location-skeleton'))),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_isLoading || _errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_isLoading ? _loadingStage : _errorMessage!),
                    ),
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
                        if (_errorMessage != null)
                          IconButton(
                            key: const Key('location-retry-button'),
                            tooltip: '重新查询',
                            onPressed: _retryLookup,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                      ],
                    ),
                  ),
                  const SectionTitle('附近社区'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: DropdownMenu<NearbyCommunity?>(
                      key: const Key('community-dropdown'),
                      enabled: !_isLoading && locations.isNotEmpty,
                      expandedInsets: EdgeInsets.zero,
                      menuHeight: 320,
                      requestFocusOnTap: true,
                      enableFilter: true,
                      filterCallback: _filterCommunities,
                      hintText: '搜索或下拉选择小区',
                      leadingIcon: const Icon(Icons.search_rounded),
                      menuStyle: const MenuStyle(
                        backgroundColor: WidgetStatePropertyAll(Colors.white),
                        surfaceTintColor:
                            WidgetStatePropertyAll(Colors.transparent),
                      ),
                      onSelected: (NearbyCommunity? community) {
                        if (community != null) {
                          unawaited(_selectCommunity(community));
                        }
                      },
                      dropdownMenuEntries: locations
                          .map((NearbyCommunity item) =>
                              DropdownMenuEntry<NearbyCommunity?>(
                                value: item,
                                label: item.name,
                                labelWidget: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(item.name),
                                      if (item.address.isNotEmpty)
                                        Text(
                                          item.address,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ))
                          .toList(growable: false),
                      inputDecorationTheme: InputDecorationTheme(
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
                            child: Text(
                              _errorMessage != null
                                  ? '社区加载失败，请重新查询'
                                  : '附近暂无社区信息',
                              style: const TextStyle(
                                  color: AppColors.textTertiary),
                            ),
                          )
                        : const SizedBox.shrink(),
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
