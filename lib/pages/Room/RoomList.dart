// ignore_for_file: file_names

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controller/build_controller.dart';
import '../House/HouseForm.dart';

typedef RoomDataGenerator = List<String> Function();

List<String> generateMockRoomNumbers() {
  final Random random = Random();
  final int floor = random.nextInt(6) + 1;
  final int roomCount = random.nextInt(5) + 2;

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

  static const String routeName = '/roomlist';

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
    _controller = Get.find<BuildController>();
    _mockData();
  }

  void _mockData() {
    _list = widget.roomDataGenerator();
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
      backgroundColor: const Color(0xFFF8F3F8),
      appBar: AppBar(
        title: const Text('选择房间'),
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
                    const SizedBox(height: 10),
                    Text(
                      controller.build,
                      style: const TextStyle(
                        color: Color(0xFF6552B5),
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text(
                  '房间信息',
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
                    final String room = _list[index];
                    return ListTile(
                      onTap: _isSelecting ? null : () => _selectRoom(room),
                      tileColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      title: Text(
                        room,
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
