import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controller/build_controller.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/deterministic_sample.dart';
import '../../widgets/community_picker.dart';
import '../../widgets/section_title.dart';
import '../house/house_form.dart';

typedef RoomDataGenerator = List<String> Function(String buildingName);

/// 按楼栋名推导楼层与房间号，同一楼栋每次进入都得到同一个列表。
List<String> generateMockRoomNumbers(String buildingName) {
  final DeterministicSample sample = DeterministicSample(buildingName);
  final int floor = sample.nextInt(6) + 1;
  final int roomCount = sample.nextInt(5) + 2;

  return List<String>.generate(
    roomCount,
    (int index) => '$floor${(index + 1).toString().padLeft(2, '0')}',
    growable: false,
  );
}

class RoomList extends StatefulWidget {
  const RoomList({
    this.roomDataGenerator = generateMockRoomNumbers,
    super.key,
  });

  static const String routeName = AppRoutes.roomList;

  final RoomDataGenerator roomDataGenerator;

  @override
  State<RoomList> createState() => _RoomListState();
}

class _RoomListState extends State<RoomList> {
  late final BuildController _controller;
  List<String> _list = <String>[];
  bool _isSelecting = false;

  @override
  void initState() {
    super.initState();
    _controller = BuildController.instance();
    _mockData();
  }

  void _mockData() {
    _list = widget.roomDataGenerator(_controller.build);
  }

  Future<void> _selectRoom(String room) async {
    if (_isSelecting) return;

    setState(() => _isSelecting = true);
    _controller.updateRoom(room);
    try {
      await Navigator.pushNamed<void>(
        context,
        HouseForm.routeName,
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
        title: const Text('选择房间'),
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
                selectedBuilding: controller.build,
              ),
              const SectionTitle('房间信息'),
              Expanded(
                child: PickerListView(
                  items: _list,
                  enabled: !_isSelecting,
                  onSelected: _selectRoom,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
