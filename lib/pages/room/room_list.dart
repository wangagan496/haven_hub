import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../controller/build_controller.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/floor.dart';
import '../../utils/toast.dart';
import '../../widgets/community_picker.dart';
import '../../widgets/section_title.dart';
import '../house/house_form.dart';

class RoomList extends StatefulWidget {
  const RoomList({super.key});

  static const String routeName = AppRoutes.roomList;

  @override
  State<RoomList> createState() => _RoomListState();
}

class _RoomListState extends State<RoomList> {
  late final BuildController _controller;
  late final TextEditingController _roomInput;
  late final TextEditingController _floorInput;
  final FocusNode _floorFocus = FocusNode();
  final TextEditingController _prefixInput = TextEditingController();
  final MenuController _roomMenu = MenuController();
  int _roomOptionCount = 20;
  String _lastPrefix = '';
  String? _floorError;
  String? _selectedRoomSuggestion;
  String? _roomSuggestionFloor;
  bool _isSelecting = false;

  @override
  void initState() {
    super.initState();
    _controller = BuildController.instance();
    _roomInput = TextEditingController(text: _controller.room);
    _floorInput = TextEditingController(text: _controller.buildingInfo.floor);
    _floorInput.addListener(_validateFloorInput);
    _floorFocus.addListener(_validateFloorInput);
    _prefixInput.addListener(_updatePrefix);
  }

  String _completeRoom(String value) {
    final String room = value.trim();
    final String prefix = _prefixInput.text.trim().toUpperCase();
    if (room.isEmpty || prefix.isEmpty) return room;
    return room.toUpperCase().startsWith(prefix)
        ? '$prefix${room.substring(prefix.length)}'
        : '$prefix$room';
  }

  void _updatePrefix() {
    if (!mounted) return;
    final String prefix = _prefixInput.text.trim().toUpperCase();
    if (prefix == _lastPrefix) return;
    final bool wasSuggestion = _roomInput.text == _selectedRoomSuggestion;
    String room = _roomInput.text;
    if (_lastPrefix.isNotEmpty && room.toUpperCase().startsWith(_lastPrefix)) {
      room = room.substring(_lastPrefix.length);
    }
    _lastPrefix = prefix;
    final String updated = _completeRoom(room);
    _roomInput.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: updated.length));
    if (wasSuggestion) _selectedRoomSuggestion = updated;
    setState(() {});
  }

  List<DropdownMenuEntry<String>> _filterRooms(
      List<DropdownMenuEntry<String>> entries, String query) {
    final String room = _completeRoom(query);
    final List<DropdownMenuEntry<String>> matches = entries
        .where(
          (DropdownMenuEntry<String> entry) =>
              entry.enabled &&
              entry.value.toLowerCase().contains(room.toLowerCase()),
        )
        .toList();
    if (room.isNotEmpty &&
        room.length <= 100 &&
        !matches
            .any((DropdownMenuEntry<String> entry) => entry.value == room)) {
      matches.add(DropdownMenuEntry(
          value: room, label: room, labelWidget: Text('使用房号 $room')));
    }
    return matches.isNotEmpty
        ? matches
        : const <DropdownMenuEntry<String>>[
            DropdownMenuEntry(value: '', label: '请输入实际房号', enabled: false),
          ];
  }

  void _validateFloorInput() {
    if (!mounted) return;
    if (_selectedRoomSuggestion != null &&
        normalizeFloor(_floorInput.text) != _roomSuggestionFloor) {
      if (_roomInput.text == _selectedRoomSuggestion) _roomInput.clear();
      _selectedRoomSuggestion = null;
      _roomSuggestionFloor = null;
    }
    setState(() => _floorError = validateFloor(_floorInput.text));
  }

  List<DropdownMenuEntry<String>> _roomSuggestions() {
    final String floor = normalizeFloor(_floorInput.text);
    if (validateFloor(floor) != null) {
      return const <DropdownMenuEntry<String>>[
        DropdownMenuEntry(value: '', label: '请先修正楼层，或直接填写房号', enabled: false),
      ];
    }
    // 仅生成填写参考，不代表该楼栋的真实房间清单。
    return <DropdownMenuEntry<String>>[
      for (int room = 1; room <= _roomOptionCount; room++)
        DropdownMenuEntry(
          value:
              '${_prefixInput.text.toUpperCase()}$floor${room.toString().padLeft(2, '0')}',
          label:
              '${_prefixInput.text.toUpperCase()}$floor${room.toString().padLeft(2, '0')}',
        ),
    ];
  }

  @override
  void dispose() {
    _roomInput.dispose();
    _floorInput
      ..removeListener(_validateFloorInput)
      ..dispose();
    _floorFocus
      ..removeListener(_validateFloorInput)
      ..dispose();
    _prefixInput
      ..removeListener(_updatePrefix)
      ..dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (_isSelecting) return;
    if (!_controller.buildingInfo.hasCommunity ||
        !_controller.buildingInfo.hasBuilding) {
      await PromptAction.showWarning('请先返回选择小区并填写楼栋');
      return;
    }
    final String room = _completeRoom(_roomInput.text);
    _validateFloorInput();
    if (_floorError != null) {
      _floorFocus.requestFocus();
      return;
    }
    if (room.isEmpty || room.length > 100) {
      await PromptAction.showWarning('请填写房号，最多100个字符');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _isSelecting = true);
    _controller.updateRoom(room, floor: normalizeFloor(_floorInput.text));
    try {
      await Navigator.pushNamed<void>(
        context,
        HouseForm.routeName,
        arguments: const HouseFormArguments(mode: HouseFormMode.create),
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
        title: const Text('填写房号'),
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
                selectedBuilding: controller.build,
              ),
              const SectionTitle('房间信息'),
              ManualHouseInput(
                controller: _roomInput,
                notice: '可下拉选择或直接填写房号，选项仅供填写参考，请以实际门牌为准。',
                label: '房号',
                hint: '例如：1602、B-302',
                inputField: DropdownMenu<String>(
                  key: const Key('room-number-input'),
                  controller: _roomInput,
                  menuController: _roomMenu,
                  expandedInsets: EdgeInsets.zero,
                  menuHeight: 240,
                  requestFocusOnTap: true,
                  enableFilter: true,
                  filterCallback: _filterRooms,
                  label: const Text('房号'),
                  hintText: '搜索、下拉选择或直接填写',
                  inputFormatters: <TextInputFormatter>[
                    LengthLimitingTextInputFormatter(100)
                  ],
                  enabled: !_isSelecting &&
                      controller.buildingInfo.hasCommunity &&
                      controller.buildingInfo.hasBuilding,
                  inputDecorationTheme:
                      const InputDecorationTheme(border: OutlineInputBorder()),
                  dropdownMenuEntries: _roomSuggestions(),
                  onSelected: (String? room) {
                    _selectedRoomSuggestion = _roomSuggestions().any(
                            (DropdownMenuEntry<String> entry) =>
                                entry.enabled && entry.value == room)
                        ? room
                        : null;
                    _roomSuggestionFloor = normalizeFloor(_floorInput.text);
                  },
                ),
                additionalField: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    DropdownMenu<String>(
                      key: const Key('floor-dropdown'),
                      controller: _floorInput,
                      focusNode: _floorFocus,
                      expandedInsets: EdgeInsets.zero,
                      menuHeight: 280,
                      requestFocusOnTap: true,
                      enableFilter: true,
                      label: const Text('楼层（选填）'),
                      hintText: '选择或输入楼层，例如33、100、B1',
                      errorText: _floorError,
                      enabled: !_isSelecting &&
                          controller.buildingInfo.hasCommunity &&
                          controller.buildingInfo.hasBuilding,
                      inputDecorationTheme: const InputDecorationTheme(
                        border: OutlineInputBorder(),
                      ),
                      dropdownMenuEntries: <DropdownMenuEntry<String>>[
                        for (int floor = 1; floor <= 99; floor++)
                          DropdownMenuEntry(value: '$floor', label: '$floor层'),
                      ],
                    ),
                    const SizedBox(height: 16),
                    DropdownMenu<String>(
                      key: const Key('room-prefix-input'),
                      controller: _prefixInput,
                      expandedInsets: EdgeInsets.zero,
                      menuHeight: 220,
                      requestFocusOnTap: true,
                      enableFilter: true,
                      label: const Text('房号字母前缀（选填）'),
                      hintText: '例如 A、B、AA；留空不加前缀',
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
                        LengthLimitingTextInputFormatter(10),
                      ],
                      enabled: !_isSelecting &&
                          controller.buildingInfo.hasCommunity &&
                          controller.buildingInfo.hasBuilding,
                      inputDecorationTheme: const InputDecorationTheme(
                          border: OutlineInputBorder()),
                      dropdownMenuEntries: <DropdownMenuEntry<String>>[
                        const DropdownMenuEntry(
                            value: '', label: '', labelWidget: Text('无前缀')),
                        for (int code = 65; code <= 90; code++)
                          DropdownMenuEntry(
                              value: String.fromCharCode(code),
                              label: String.fromCharCode(code)),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const Key('more-room-options'),
                        onPressed: !_isSelecting &&
                                _floorError == null &&
                                controller.buildingInfo.hasCommunity &&
                                controller.buildingInfo.hasBuilding &&
                                _roomOptionCount < 100
                            ? () {
                                setState(() => _roomOptionCount += 20);
                                _roomMenu.open();
                              }
                            : null,
                        child: Text(_roomOptionCount < 100
                            ? '显示更多参考房号（已有 $_roomOptionCount 个）'
                            : '已显示100个参考房号，其他房号可直接填写'),
                      ),
                    ),
                  ],
                ),
                canContinue: _floorError == null,
                buttonLabel: '下一步，填写业主信息',
                enabled: !_isSelecting &&
                    controller.buildingInfo.hasCommunity &&
                    controller.buildingInfo.hasBuilding,
                onContinue: _continue,
              ),
              if (!controller.buildingInfo.hasCommunity ||
                  !controller.buildingInfo.hasBuilding)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('请先返回选择小区并填写楼栋'),
                ),
            ],
          );
        },
      ),
    );
  }
}
