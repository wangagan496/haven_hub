import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../api/location.dart';
import '../../controller/build_controller.dart';
import '../../models/building_info.dart';
import '../../models/device_map_location.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/building_recommendations.dart';
import '../../utils/toast.dart';
import '../../widgets/community_picker.dart';
import '../../widgets/section_title.dart';
import '../room/room_list.dart';

class BuildingList extends StatefulWidget {
  const BuildingList({
    super.key,
    this.buildingLookup = searchCommunityBuildings,
    this.deviceLocation,
  });

  final CommunityBuildingLookup buildingLookup;
  final DeviceMapLocation? deviceLocation;

  static const String routeName = AppRoutes.buildingList;

  @override
  State<BuildingList> createState() => _BuildingListState();
}

class _BuildingListState extends State<BuildingList> {
  late final BuildController _controller;
  late final TextEditingController _buildingInput;
  late final BuildingInfo _community;
  final List<TencentBuilding> _buildings = <TencentBuilding>[];
  final Set<String> _seenPoiIds = <String>{};
  bool _isLoading = false;
  bool _hasMore = true;
  bool _reachedLimit = false;
  String? _lookupError;
  int _nextPage = 1;
  bool _isSelecting = false;
  Timer? _positionExpiry;

  @override
  void initState() {
    super.initState();
    _controller = BuildController.instance();
    _buildingInput = TextEditingController(text: _controller.build);
    _community = _controller.buildingInfo;
    final DeviceMapLocation? position = widget.deviceLocation;
    if (position != null &&
        position.unavailableReason(DateTime.now()) == null) {
      _positionExpiry = Timer(
        position.timestamp
                .add(const Duration(minutes: 5))
                .difference(DateTime.now()) +
            const Duration(milliseconds: 1),
        () {
          if (mounted) setState(() {});
        },
      );
    }
    if (_canLookup) unawaited(_loadBuildings());
  }

  bool get _canLookup =>
      _community.hasCommunity &&
      _community.latitude != null &&
      _community.longitude != null;

  bool get _sameCommunity {
    final BuildingInfo current = _controller.buildingInfo;
    return current.name == _community.name &&
        current.address == _community.address &&
        current.communityId == _community.communityId &&
        current.latitude == _community.latitude &&
        current.longitude == _community.longitude;
  }

  Future<void> _loadBuildings() async {
    if (_isLoading || !_hasMore || !_canLookup || !_sameCommunity) return;
    setState(() {
      _isLoading = true;
      _lookupError = null;
    });
    try {
      final TencentBuildingPage result =
          await widget.buildingLookup(_community, _nextPage);
      if (!mounted || !_sameCommunity) return;
      setState(() {
        final bool hasNewPois =
            result.poiIds.any((String id) => !_seenPoiIds.contains(id));
        final Set<String> buildingIds =
            _buildings.map((TencentBuilding item) => item.id).toSet();
        final Set<String> buildingLabels = _buildings
            .map((TencentBuilding item) => item.label.trim().toLowerCase())
            .toSet();
        _buildings.addAll(result.buildings.where((TencentBuilding item) =>
            buildingIds.add(item.id) &&
            buildingLabels.add(item.label.trim().toLowerCase())));
        _seenPoiIds.addAll(result.poiIds);
        // 腾讯超过可翻页范围时可能重复末页，不能无限加载。
        _hasMore = result.hasMore && hasNewPois;
        _reachedLimit = result.reachedLimit;
        _nextPage++;
      });
    } on Object catch (error) {
      if (!mounted || !_sameCommunity) return;
      setState(() {
        _lookupError = describeError(error, fallback: '楼栋查询失败，请重试');
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<DropdownMenuEntry<String>> _filterBuildings(
    List<DropdownMenuEntry<String>> entries,
    String keyword,
  ) {
    final String needle = keyword.trim().toLowerCase();
    final Set<String> matchingLabels = _buildings
        .where((TencentBuilding building) =>
            needle.isEmpty ||
            building.label.toLowerCase().contains(needle) ||
            building.name.toLowerCase().contains(needle) ||
            building.address.toLowerCase().contains(needle))
        .map((TencentBuilding building) => building.label)
        .toSet();
    final List<DropdownMenuEntry<String>> matches = entries
        .where(
          (DropdownMenuEntry<String> entry) =>
              entry.enabled && matchingLabels.contains(entry.value),
        )
        .toList(growable: false);
    return matches.isNotEmpty
        ? matches
        : <DropdownMenuEntry<String>>[
            DropdownMenuEntry(
              value: '',
              label: _isLoading ? '正在查询楼栋，可直接填写' : '没有匹配的楼栋，可直接填写',
              enabled: false,
            ),
          ];
  }

  Widget _lookupStatus() {
    if (!_sameCommunity) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('所选小区已变更，请返回重新进入楼栋页面。'),
      );
    }
    if (!_canLookup) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('所选小区缺少地图坐标，可返回重新选择，或直接手动填写。'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                LinearProgressIndicator(),
                SizedBox(height: 8),
                Text('正在查询地图楼栋，可先手动填写'),
              ],
            ),
          )
        else if (_lookupError != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                Text('楼栋查询失败：$_lookupError'),
                TextButton(
                    onPressed: _loadBuildings, child: const Text('重试查询')),
              ],
            ),
          )
        else ...<Widget>[
          if (_buildings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('已加载 ${_buildings.length} 个楼栋及单元'),
            ),
          if (_buildings.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_hasMore
                  ? '本页未找到匹配楼栋，可以继续查询或手动填写。'
                  : '本次查询未找到匹配楼栋，请手动填写。这不代表小区没有楼栋。'),
            ),
          if (_hasMore)
            TextButton(onPressed: _loadBuildings, child: const Text('加载更多地图结果'))
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(_reachedLimit
                  ? '已达到本次查询上限，未找到的楼栋或单元可直接填写。'
                  : '没有更多结果了，未找到的楼栋或单元可直接填写。'),
            ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _positionExpiry?.cancel();
    _buildingInput.dispose();
    super.dispose();
  }

  Widget _nearbyRecommendations() {
    if (!_sameCommunity || !_canLookup) return const SizedBox.shrink();
    final DeviceMapLocation? position = widget.deviceLocation;
    final String? reason = position == null
        ? '暂无可用的设备位置，仍可下拉选择或手动填写楼栋'
        : position.unavailableReason(DateTime.now());
    final List<NearbyBuilding> nearby =
        recommendBuildings(_buildings, position, now: DateTime.now());
    if (reason != null || nearby.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(reason ??
            (_isLoading
                ? '正在查找当前位置附近的楼栋'
                : '已加载的地图结果中，没有可按当前位置推荐的楼栋，可下拉选择或手动填写')),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('附近楼栋推荐', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                  '定位误差约 ${position!.accuracy.ceil()} 米。以下为地图标记距离，请核对楼号；最近的不一定是你住的楼。'),
              for (final NearbyBuilding candidate in nearby)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                          '${candidate.building.name} · 约 ${candidate.distance.ceil()} 米'),
                      if (candidate.building.address.isNotEmpty)
                        Text(candidate.building.address,
                            style: Theme.of(context).textTheme.bodySmall),
                      OutlinedButton(
                        key: ValueKey<String>(
                            'confirm-building-${candidate.building.id}'),
                        onPressed: _isSelecting
                            ? null
                            : () => _confirmNearby(candidate.building),
                        child: Text('确认 ${candidate.building.label}，下一步'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmNearby(TencentBuilding building) async {
    if (_isSelecting || !_sameCommunity) return;
    final bool stillAvailable = recommendBuildings(
            _buildings, widget.deviceLocation,
            now: DateTime.now())
        .any((NearbyBuilding item) => item.building.id == building.id);
    if (!stillAvailable) {
      setState(() {});
      await PromptAction.showWarning('定位推荐已失效，请重新核对楼栋');
      return;
    }
    _buildingInput.text = building.label;
    await _continue();
  }

  Future<void> _continue() async {
    if (_isSelecting) return;
    if (!_sameCommunity) return;
    if (!_controller.buildingInfo.hasCommunity) {
      await PromptAction.showWarning('请先返回选择小区');
      return;
    }
    final String building = _buildingInput.text.trim();
    if (building.isEmpty || building.length > 100) {
      await PromptAction.showWarning('请填写楼栋信息，最多100个字符');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _isSelecting = true);
    // 返回重填时，只有楼栋变更才清空之前的房号。
    if (building != _controller.build) _controller.updateBuild(building);
    try {
      await Navigator.pushNamed<void>(
        context,
        RoomList.routeName,
      );
    } finally {
      if (mounted) setState(() => _isSelecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('选择或填写楼栋'),
      ),
      body: GetBuilder<BuildController>(
        init: _controller,
        builder: (BuildController controller) {
          final String communityName = controller.buildingInfo.name;
          final String address = controller.buildingInfo.address;

          return ListView(
            children: <Widget>[
              CommunityHeader(
                communityName: communityName,
                address: address,
              ),
              const SectionTitle('楼栋信息'),
              _nearbyRecommendations(),
              if (controller.buildingInfo.hasCommunity) _lookupStatus(),
              ManualHouseInput(
                controller: _buildingInput,
                notice: '可下拉选择或输入搜索，也可直接填写楼栋和单元。',
                label: '楼栋及单元',
                hint: '例如：12栋2单元、A座；无单元可不填',
                inputField: DropdownMenu<String>(
                  key: const Key('building-dropdown'),
                  controller: _buildingInput,
                  enabled: !_isSelecting &&
                      _sameCommunity &&
                      controller.buildingInfo.hasCommunity,
                  expandedInsets: EdgeInsets.zero,
                  menuHeight: 320,
                  requestFocusOnTap: true,
                  enableFilter: true,
                  filterCallback: _filterBuildings,
                  inputFormatters: <TextInputFormatter>[
                    LengthLimitingTextInputFormatter(100)
                  ],
                  label: const Text('楼栋及单元'),
                  hintText: '搜索、下拉选择或直接填写',
                  inputDecorationTheme:
                      const InputDecorationTheme(border: OutlineInputBorder()),
                  menuStyle: const MenuStyle(
                    backgroundColor: WidgetStatePropertyAll(Colors.white),
                    surfaceTintColor:
                        WidgetStatePropertyAll(Colors.transparent),
                  ),
                  dropdownMenuEntries: <DropdownMenuEntry<String>>[
                    for (final TencentBuilding item in _buildings)
                      DropdownMenuEntry(
                        value: item.label,
                        label: item.label,
                        labelWidget: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(item.name),
                              if (item.address.isNotEmpty)
                                Text(item.address,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                      ),
                    if (_buildings.isEmpty)
                      DropdownMenuEntry(
                          value: '',
                          enabled: false,
                          label: _isLoading ? '正在查询楼栋，可直接填写' : '暂无楼栋选项，可直接填写'),
                  ],
                ),
                buttonLabel: '下一步，填写房号',
                enabled: !_isSelecting &&
                    _sameCommunity &&
                    controller.buildingInfo.hasCommunity,
                onContinue: _continue,
              ),
              if (!controller.buildingInfo.hasCommunity)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('请先返回选择小区'),
                ),
            ],
          );
        },
      ),
    );
  }
}
