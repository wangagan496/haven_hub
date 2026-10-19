import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/repair.dart';

/// 当前账号的一份待提交草稿。未确认状态只记录本地事实，不推断服务端结果。
class RepairDraft {
  const RepairDraft({required this.record, this.resultUnconfirmed = false, this.waitingSchedule});

  final RepairRecord record;
  final bool resultUnconfirmed;
  final bool? waitingSchedule;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'record': <String, dynamic>{...record.toJson(), 'appointment': record.appointment},
        'waitingSchedule': waitingSchedule,
        'legacyExpectedTime': record.slot.isEmpty ? record.expectedTime : '',
        'resultUnconfirmed': resultUnconfirmed,
      };
}

class RepairDraftStore {
  RepairDraftStore({Future<SharedPreferences> Function()? preferencesLoader})
      : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferencesLoader;
  Future<void> _pendingWrite = Future<void>.value();

  // 当前只保留一份新建报修草稿；不使用 token、手机号或匿名共享键。
  String _key(String userKey) =>
      'repairDraft:v1:${Uri.encodeComponent(userKey)}:new';

  Future<RepairDraft?> load(String userKey) async {
    if (userKey.trim().isEmpty) return null;
    await _pendingWrite;
    final SharedPreferences preferences = await _preferencesLoader();
    final String? raw = preferences.getString(_key(userKey));
    if (raw == null) return null;
    try {
      final Object? body = jsonDecode(raw);
      if (body is! Map<String, dynamic>) return null;
      final Object? record = body['record'];
      if (record is! Map<String, dynamic>) return null;
      return RepairDraft(
        record: RepairRecord.fromJson(<String, dynamic>{...record,
          if ((record['expectedTime']?.toString() ?? '').isEmpty) 'expectedTime': body['legacyExpectedTime'] ?? '',
        }),
        resultUnconfirmed: body['resultUnconfirmed'] == true,
        waitingSchedule: body['waitingSchedule'] is bool ? body['waitingSchedule'] as bool : null,
      );
    } on FormatException {
      return null;
    }
  }

  Future<bool> save(String userKey, RepairDraft draft) {
    if (userKey.trim().isEmpty) return Future<bool>.value(false);
    // 先编码快照，排队期间不再读取页面里的可变输入。
    final String raw = jsonEncode(draft.toJson());
    return _write(() async {
      final SharedPreferences preferences = await _preferencesLoader();
      return preferences.setString(_key(userKey), raw);
    });
  }

  Future<bool> remove(String userKey) {
    if (userKey.trim().isEmpty) return Future<bool>.value(false);
    return _write(() async {
      final SharedPreferences preferences = await _preferencesLoader();
      return preferences.remove(_key(userKey));
    });
  }

  // 提交成功的删除必须排在尚未完成的保存之后，避免草稿被迟到的保存恢复。
  Future<bool> _write(Future<bool> Function() action) {
    final Future<bool> operation = _pendingWrite.then((_) => action());
    _pendingWrite = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }
}

final RepairDraftStore repairDraftStore = RepairDraftStore();
