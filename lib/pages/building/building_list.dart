import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controller/build_controller.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/toast.dart';
import '../../widgets/community_picker.dart';
import '../../widgets/section_title.dart';
import '../room/room_list.dart';

typedef BuildingCountGenerator = int Function();

int generateBuildingCount() => Random().nextInt(10) + 2;

class BuildingList extends StatefulWidget {
  const BuildingList({
    this.buildingCountGenerator = generateBuildingCount,
    super.key,
  });

  static const String routeName = AppRoutes.buildingList;

  final BuildingCountGenerator buildingCountGenerator;

  @override
  State<BuildingList> createState() => _BuildingListState();
}

class _BuildingListState extends State<BuildingList> {
  late final BuildController _controller;
  late final List<String> _list;
  bool _isSelecting = false;

  @override
  void initState() {
    super.initState();
    _controller = BuildController.instance();
    final int buildingCount = widget.buildingCountGenerator();
    final String communityName = _controller.buildingInfo.name;
    final String suffix = buildingCount >= 5 ? '栋' : '单元';
    _list = List<String>.generate(
      buildingCount,
      (int index) => '$communityName${index + 1}$suffix',
      growable: false,
    );
  }

  Future<void> _selectBuilding(String building) async {
    if (_isSelecting) return;

    setState(() => _isSelecting = true);
    _controller.updateBuild(building);
    try {
      await PromptAction.showToast('当前选择：${_controller.build}');
      if (!mounted) return;

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
        title: const Text('选择楼栋'),
      ),
      body: GetBuilder<BuildController>(
        init: _controller,
        builder: (BuildController controller) {
          final String communityName = controller.buildingInfo.name;
          final String address = controller.buildingInfo.address;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              CommunityHeader(
                communityName: communityName,
                address: address,
              ),
              const SectionTitle('楼栋信息'),
              Expanded(
                child: PickerListView(
                  items: _list,
                  enabled: !_isSelecting,
                  onSelected: _selectBuilding,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
