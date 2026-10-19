import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../api/location.dart';
import '../../controller/build_controller.dart';
import '../../models/device_map_location.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/location.dart';
import '../../utils/toast.dart';
import '../../widgets/section_title.dart';
import '../building/building_list.dart';
import 'community_search.dart';

typedef LocationPermissionRequester = Future<PermissionStatus> Function();

const Duration _permissionRequestTimeout = Duration(seconds: 12);
const Duration _positionRequestTimeout = Duration(seconds: 50);
const Duration _lookupRequestTimeout = Duration(seconds: 20);

Future<PermissionStatus> checkLocationPermission() async {
  if (!kIsWeb) {
    return Permission.location.status;
  }

  final LocationPermission permission = await Geolocator.checkPermission();

  if (permission == LocationPermission.always ||
      permission == LocationPermission.whileInUse) {
    return PermissionStatus.granted;
  }
  if (permission == LocationPermission.deniedForever) {
    return PermissionStatus.permanentlyDenied;
  }
  return PermissionStatus.denied;
}

Future<bool> openLocationPermissionSettings() async {
  if (kIsWeb) return false;
  return openAppSettings();
}

Future<bool> openSystemLocationSettings() async {
  if (kIsWeb) return false;
  return Geolocator.openLocationSettings();
}

class LocationList extends StatefulWidget {
  const LocationList({
    this.permissionRequester = checkLocationPermission,
    this.permissionRequestTimeout = _permissionRequestTimeout,
    this.settingsOpener = openLocationPermissionSettings,
    this.locationSettingsOpener = openSystemLocationSettings,
    this.communitySearch = searchCommunitiesByName,
    this.positionLoader,
    this.locationLookup = getTencentLocationInfo,
    this.ipLocationLookup = getTencentIpLocationInfo,
    super.key,
  });

  static const String routeName = AppRoutes.locationList;

  final LocationPermissionRequester permissionRequester;
  final Duration permissionRequestTimeout;
  final Future<bool> Function() settingsOpener;
  final Future<bool> Function() locationSettingsOpener;
  final CommunitySearch communitySearch;
  final PositionLoader? positionLoader;
  final LocationLookup locationLookup;
  final IpLocationLookup ipLocationLookup;

  @override
  State<LocationList> createState() => _LocationListState();
}

class _LocationListState extends State<LocationList>
    with WidgetsBindingObserver {
  late final BuildController _buildController;
  bool _isLoading = false;
  int _requestId = 0;
  String? _errorMessage;
  String _loadingStage = '正在获取当前位置';
  bool _needsAuthorization = true;
  bool _openingSettings = false;
  bool _waitingForSettings = false;
  bool _leftForSettings = false;
  bool _serviceDisabled = false;
  bool _isIpBased = false;
  bool _openingSearch = false;
  String? _fallbackReason;
  String _city = '';
  DeviceMapLocation? _deviceLocation;

  /// 是否已经拿到过一次定位结果。决定刷新时用整屏骨架还是保留页面：
  /// 已经有内容时保留搜索框和社区列表，避免刷新时页面闪烁。
  bool _hasResolved = false;
  String _currentAddress = '正在获取当前位置';
  List<NearbyCommunity> _locations = const <NearbyCommunity>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _buildController = BuildController.instance();
    unawaited(_getAccess());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_waitingForSettings) return;
    if (state != AppLifecycleState.resumed) {
      _leftForSettings = true;
      return;
    }
    if (!_leftForSettings) return;
    _waitingForSettings = false;
    _leftForSettings = false;
    // 设置返回后旧的权限/IP 请求可能仍在等待，作废它再查询新权限。
    _requestId++;
    _isLoading = false;
    unawaited(_getAccess());
  }

  Future<void> _openSettings({bool systemLocation = false}) async {
    if (_openingSettings) return;
    setState(() => _openingSettings = true);
    _waitingForSettings = true;
    _leftForSettings = false;
    try {
      final bool opened = await (systemLocation
              ? widget.locationSettingsOpener()
              : widget.settingsOpener())
          .timeout(
        const Duration(seconds: 5),
      );
      if (!mounted) return;
      if (!opened) {
        _waitingForSettings = false;
        await PromptAction.showWarning(kIsWeb
            ? '请在浏览器的网站设置中允许定位，然后刷新页面'
            : systemLocation
                ? '无法打开设置，请在系统设置中开启定位服务'
                : '无法打开设置，请在系统设置中为本应用开启定位权限');
      }
    } on Object {
      if (!mounted) return;
      _waitingForSettings = false;
      await PromptAction.showError(
          systemLocation ? '无法打开设置，请在系统设置中开启定位服务' : '无法打开设置，请在系统设置中为本应用开启定位权限');
    } finally {
      if (mounted) setState(() => _openingSettings = false);
    }
  }

  Widget _buildAuthorizationPrompt() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          const Expanded(child: Text('如未授权，请到设置授权')),
          TextButton(
            key: const Key('location-settings-button'),
            onPressed: _openingSettings ? null : _openSettings,
            child: const Text('去授权'),
          ),
        ],
      ),
    );
  }

  bool _isCurrent(int requestId) => mounted && requestId == _requestId;

  Widget _buildLocationNotice() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_fallbackReason != null)
            Text(_fallbackReason!, key: const Key('location-fallback-reason')),
          if (_isIpBased)
            const Text('当前为网络粗略定位，可能偏离实际位置。请核对地址，或按城市搜索小区。',
                key: Key('location-approximate-notice')),
          if (_serviceDisabled)
            TextButton(
              key: const Key('location-service-settings-button'),
              onPressed: _openingSettings
                  ? null
                  : () => _openSettings(systemLocation: true),
              child: const Text('开启系统定位'),
            ),
        ],
      ),
    );
  }

  Future<void> _openCommunitySearch() async {
    if (_openingSearch) return;
    _openingSearch = true;
    try {
      final NearbyCommunity? community = await Navigator.push<NearbyCommunity>(
        context,
        MaterialPageRoute<NearbyCommunity>(
            builder: (_) => CommunitySearchPage(
                  search: widget.communitySearch,
                  initialCity: _city,
                )),
      );
      if (!mounted || community == null) return;
      await _selectCommunity(community);
    } finally {
      _openingSearch = false;
    }
  }

  int _beginRequest() {
    final int requestId = ++_requestId;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _fallbackReason = null;
      _serviceDisabled = false;
      _loadingStage = '正在获取当前位置';
      _deviceLocation = null;
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
        setState(() {
          _needsAuthorization = true;
          _fallbackReason = '无法确认定位权限，请到设置检查';
        });
        await _loadIpLocation(requestId);
        return;
      }
      if (!_isCurrent(requestId)) return;
      setState(() => _needsAuthorization = !status.isGranted);

      if (status.isGranted) {
        await _loadCurrentLocation(requestId);
      } else {
        setState(() => _fallbackReason = '未获得定位权限，无法获取设备位置');
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
      if (locationError is PermissionDeniedException) {
        setState(() => _needsAuthorization = true);
      }
      if (devicePosition != null) {
        final String reason = '附近社区查询失败：${describeError(
          locationError,
          fallback: '地址或附近社区查询异常',
          onOtherError: (Object error) =>
              error is TimeoutException ? '查询超时' : null,
        )}';
        Error.throwWithStackTrace(FormatException(reason), locationStackTrace);
      }
      setState(() {
        _serviceDisabled = locationError is LocationServiceDisabledException;
        _fallbackReason = switch (locationError) {
          LocationServiceDisabledException() => '系统定位服务未开启',
          PermissionDeniedException() => '设备定位权限被拒绝',
          PositionAcquisitionTimeout() => locationError.message ?? '设备定位等待超时',
          TimeoutException() => '设备定位等待超时',
          PositionUpdateException() => '浏览器或系统无法提供位置',
          _ => '设备定位失败，请检查系统定位设置后重试',
        };
      });
      await _loadIpLocation(requestId);
      return;
    }
    if (!_isCurrent(requestId)) return;

    final LocationLookupResult lookupResult = result;
    _applyLookupResult(lookupResult);
    final Position position = devicePosition;
    if (!lookupResult.isIpBased &&
        position.timestamp != null &&
        validMapCoordinate(
            lookupResult.mapLatitude, lookupResult.mapLongitude)) {
      _deviceLocation = DeviceMapLocation(
        latitude: lookupResult.mapLatitude!,
        longitude: lookupResult.mapLongitude!,
        accuracy: position.accuracy,
        timestamp: position.timestamp!,
      );
    }
  }

  Future<void> _loadIpLocation(int requestId) async {
    setState(() => _loadingStage = '正在查询网络粗略位置');
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
      _isIpBased = result.isIpBased;
      _city = result.city;
      if (!result.isIpBased) {
        _fallbackReason = null;
        _serviceDisabled = false;
      }
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
      arguments: _deviceLocation,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<NearbyCommunity> locations = _locations;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('选择社区'),
        actions: <Widget>[
          TextButton(
            key: const Key('community-search-button'),
            onPressed: _openCommunitySearch,
            child: const Text('搜索小区'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        // 首次加载显示进度；刷新时保留已有结果。
        child: _isLoading && !_hasResolved
            ? Column(
                children: <Widget>[
                  if (_needsAuthorization) _buildAuthorizationPrompt(),
                  if (_fallbackReason != null || _isIpBased)
                    _buildLocationNotice(),
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
            : ListView(
                children: <Widget>[
                  if (_needsAuthorization) _buildAuthorizationPrompt(),
                  if (_fallbackReason != null || _isIpBased)
                    _buildLocationNotice(),
                  if (_isLoading || _errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_isLoading ? _loadingStage : _errorMessage!),
                    ),
                  SectionTitle(_isIpBased ? '大致位置（网络估算）' : '当前地址'),
                  if (_errorMessage != null && _hasResolved)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('本次定位未更新，以下保留上次结果'),
                    ),
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
                        IconButton(
                          key: const Key('location-retry-button'),
                          tooltip: '重新定位',
                          onPressed: _isLoading ? null : _retryLookup,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                  ),
                  SectionTitle(_isIpBased ? '估算位置周边小区（请核对）' : '附近社区'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _openCommunitySearch,
                        icon: const Icon(Icons.travel_explore),
                        label: const Text('找不到？按城市搜索小区'),
                      ),
                    ),
                  ),
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
                      hintText: '筛选或下拉选择已加载的小区',
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
                  Padding(
                    padding: const EdgeInsets.all(16),
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
