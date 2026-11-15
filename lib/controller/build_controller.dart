import 'package:get/get.dart' show Get, GetxController, Inst;

import '../models/building_info.dart';
import '../models/house.dart';
import '../utils/submission_id.dart';
import '../utils/token_manager.dart';

/// 一次选房的内存草稿；未提交的表单资料只属于这次流程。
enum HouseSelectionStep { community, building, room, owner }

class HouseSelectionDraft {
  HouseSelectionDraft(this.id);
  final String id;
  HouseSelectionStep step = HouseSelectionStep.community;
  BuildingInfo selection = const BuildingInfo();
  House form = const House();
  String buildingInput = '';
  String roomInput = '';
  String floorInput = '';
  String roomPrefix = '';
}

/// 同一账号可保留多次选房；页面用固定草稿编号读写，避免互相覆盖。
class BuildController extends GetxController {
  static BuildController instance() {
    if (Get.isRegistered<BuildController>()) return Get.find<BuildController>();
    return Get.put(BuildController());
  }

  final Map<String, HouseSelectionDraft> _drafts =
      <String, HouseSelectionDraft>{};
  int _session = tokenManager.sessionId;
  String? _currentId;

  @override
  void onInit() {
    super.onInit();
    tokenManager.sessionChanges.addListener(_sessionChanged);
  }

  @override
  void onClose() {
    tokenManager.sessionChanges.removeListener(_sessionChanged);
    super.onClose();
  }

  void _sessionChanged() {
    if (_session == tokenManager.sessionId) return;
    _session = tokenManager.sessionId;
    _drafts.clear();
    _currentId = null;
    update();
  }

  List<HouseSelectionDraft> get drafts {
    _sessionChanged();
    return List<HouseSelectionDraft>.unmodifiable(_drafts.values);
  }

  String get currentDraftId {
    _sessionChanged();
    return _currentId ?? startDraft(notify: false);
  }

  String startDraft({bool notify = true}) {
    _sessionChanged();
    // 回执可跨应用重开保留，草稿编号也不能在重开后复用。
    final id = newSubmissionId();
    _drafts[id] = HouseSelectionDraft(id);
    _currentId = id;
    if (notify) update();
    return id;
  }

  HouseSelectionDraft? draftFor(String id) {
    _sessionChanged();
    return _drafts[id];
  }

  /// 重开后从当前账号的已持久化回执恢复原草稿；不覆盖仍存在的编辑内容。
  void restoreSubmissionDraft(String id, House house) {
    _sessionChanged();
    if (_drafts.containsKey(id)) return;
    _drafts[id] = HouseSelectionDraft(id)
      ..step = HouseSelectionStep.owner
      ..selection = BuildingInfo(name: house.point, building: house.building,
          room: house.room, floor: house.floor)
      ..form = house.copyWith(id: '');
    update();
  }

  bool activateDraft(String id) {
    if (draftFor(id) == null) return false;
    _currentId = id;
    update();
    return true;
  }

  void resumeAt(String id, HouseSelectionStep step) {
    final draft = draftFor(id);
    if (draft != null) draft.step = step;
  }

  BuildingInfo selectionFor(String id) =>
      draftFor(id)?.selection ?? const BuildingInfo();
  BuildingInfo get buildingInfo {
    _sessionChanged();
    return _drafts[_currentId]?.selection ?? const BuildingInfo();
  }

  String get build => buildingInfo.building;
  String get room => buildingInfo.room;

  HouseSelectionDraft? _target(String? draftId) =>
      draftFor(draftId ?? currentDraftId);

  House houseFor(String id) {
    final draft = draftFor(id);
    if (draft == null) return const House();
    final selection = draft.selection;
    return draft.form.copyWith(
        point: selection.name,
        building: selection.building,
        room: selection.room,
        floor: selection.floor);
  }

  void saveForm(String id, House form) {
    final draft = draftFor(id);
    if (draft != null) draft.form = form.copyWith(id: '');
  }

  /// 换小区只清空这一份草稿的下级选择。
  void selectCommunity(Map<String, dynamic> community, {String? draftId}) {
    final draft = _target(draftId);
    if (draft == null) return;
    draft
      ..step = HouseSelectionStep.building
      ..selection = BuildingInfo.fromJson(community)
          .copyWith(building: '', room: '', floor: '')
      ..buildingInput = ''
      ..roomInput = ''
      ..floorInput = ''
      ..roomPrefix = '';
    update();
  }

  void selectBuilding(String building, {String? draftId}) {
    final draft = _target(draftId);
    if (draft == null) return;
    draft
      ..step = HouseSelectionStep.room
      ..selection = draft.selection
          .copyWith(building: building.trim(), room: '', floor: '')
      ..buildingInput = building
      ..roomInput = ''
      ..floorInput = ''
      ..roomPrefix = '';
    update();
  }

  void selectRoom(String room, {String? floor, String? draftId}) {
    final draft = _target(draftId);
    if (draft == null) return;
    draft
      ..step = HouseSelectionStep.owner
      ..selection = draft.selection.copyWith(room: room.trim(), floor: floor)
      ..roomInput = room
      ..floorInput = draft.selection.floor;
    update();
  }

  void discardDraft(String id) {
    _sessionChanged();
    _drafts.remove(id);
    if (_currentId == id) _currentId = null;
    update();
  }

  /// 完成或放弃当前流程时，只清理该流程。
  void clearSelection({String? draftId}) {
    final id = draftId ?? _currentId;
    if (id != null) discardDraft(id);
  }
}
