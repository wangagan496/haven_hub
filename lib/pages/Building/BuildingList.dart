// ignore_for_file: file_names

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controller/build_controller.dart';
import '../../utils/toast.dart';
import '../Room/RoomList.dart';

typedef BuildingCountGenerator = int Function();

int generateBuildingCount() => Random().nextInt(10) + 2;

class BuildingList extends StatefulWidget {
  const BuildingList({
    this.buildingCountGenerator = generateBuildingCount,
    super.key,
  });

  static const String routeName = '/buildinglist';

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
    _controller = Get.find<BuildController>();
    final int buildingCount = widget.buildingCountGenerator();
    final String communityName =
        _controller.buildingInfo['name']?.toString().trim() ?? '';
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
      backgroundColor: const Color(0xFFF8F3F8),
      appBar: AppBar(
        title: const Text('选择楼栋'),
        centerTitle: true,
        backgroundColor: const Color(0xFFF8F3F8),
        surfaceTintColor: Colors.transparent,
      ),
      body: GetBuilder<BuildController>(
        init: _controller,
        builder: (BuildController controller) {
          final String communityName =
              controller.buildingInfo['name']?.toString().trim() ?? '';
          final String address =
              controller.buildingInfo['address']?.toString().trim() ?? '';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      communityName,
                      style: const TextStyle(
                        color: Color(0xFF262626),
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (address.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(
                        address,
                        style: const TextStyle(
                          color: Color(0xFF888888),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text(
                  '楼栋信息',
                  style: TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 14,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: _list.length,
                  separatorBuilder: (_, __) => const Divider(
                    height: 1,
                    indent: 16,
                  ),
                  itemBuilder: (BuildContext context, int index) {
                    final String building = _list[index];
                    return ListTile(
                      onTap:
                          _isSelecting ? null : () => _selectBuilding(building),
                      tileColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      title: Text(
                        building,
                        style: const TextStyle(
                          color: Color(0xFF262626),
                          fontSize: 16,
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
          );
        },
      ),
    );
  }
}
