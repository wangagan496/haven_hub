import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/repair.dart';
import 'submission_id.dart';

class RepairDraftConflictException implements Exception {
  const RepairDraftConflictException();
}

class RepairDraftCorruptedException extends FormatException {
  const RepairDraftCorruptedException() : super('本机报修草稿已损坏，可能包含未确认的提交回执');
}

/// 当前账号的一份待提交草稿。未确认状态只记录本地事实，不推断服务端结果。
class RepairDraft {
  const RepairDraft(
      {required this.record,
      this.resultUnconfirmed = false,
      this.waitingSchedule,
      this.submission});

  final RepairRecord record;
  final bool resultUnconfirmed;
  final bool? waitingSchedule;

  /// 发出请求前持久化的内容快照；编辑表单不会改变待确认提交。
  final RepairRecord? submission;

  static RepairRecord prepareSubmission(RepairRecord record) {
    return RepairRecord.fromJson(<String, dynamic>{
      ...record.toJson(),
      'submissionId': newSubmissionId()
    });
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'record': <String, dynamic>{
          ...record.toJson(),
          'appointment': record.appointment
        },
        'waitingSchedule': waitingSchedule,
        'legacyExpectedTime': record.slot.isEmpty ? record.expectedTime : '',
        'resultUnconfirmed': resultUnconfirmed,
        if (submission != null) 'submission': submission!.toJson(),
      };
}

class RepairDraftStore {
  RepairDraftStore({Future<SharedPreferences> Function()? preferencesLoader})
      : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferencesLoader;
  Future<void> _pendingWrite = Future<void>.value();
  static final _writesByPreferences = Expando<Future<void>>();

  // 当前只保留一份新建报修草稿；不使用 token、手机号或匿名共享键。
  String _key(String userKey) =>
      'repairDraft:v1:${Uri.encodeComponent(userKey)}:new';

  Future<RepairDraft?> load(String userKey) async {
    if (userKey.trim().isEmpty) return null;
    await _pendingWrite;
    final SharedPreferences preferences = await _preferencesLoader();
    await _writesByPreferences[preferences];
    final String? raw = preferences.getString(_key(userKey));
    if (raw == null) return null;
    return _decode(raw);
  }

  RepairDraft _decode(String raw) {
    try {
      final Object? body = jsonDecode(raw);
      if (body is! Map<String, dynamic>) {
        throw const FormatException('本机草稿格式不正确');
      }
      final Object? record = body['record'];
      if (record is! Map<String, dynamic>) {
        throw const FormatException('本机草稿缺少内容');
      }
      RepairRecord? submission;
      if (body.containsKey('submission')) {
        final Object? saved = body['submission'];
        if (saved is! Map<String, dynamic> ||
            !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
                .hasMatch(saved['submissionId']?.toString() ?? '')) {
          throw StateError('本机提交回执损坏，不能安全重新提交');
        }
        submission = RepairRecord.fromJson(saved);
      }
      return RepairDraft(
        submission: submission,
        record: RepairRecord.fromJson(<String, dynamic>{
          ...record,
          if ((record['expectedTime']?.toString() ?? '').isEmpty)
            'expectedTime': body['legacyExpectedTime'] ?? '',
        }),
        resultUnconfirmed:
            body['resultUnconfirmed'] == true || submission != null,
        waitingSchedule: body['waitingSchedule'] is bool
            ? body['waitingSchedule'] as bool
            : null,
      );
    } on RepairDraftCorruptedException {
      rethrow;
    } on Object {
      // 损坏不等于不存在：其中可能有已经发送的回执，不能生成新标识重发。
      throw const RepairDraftCorruptedException();
    }
  }

  Future<bool> save(String userKey, RepairDraft draft,
      {String? expectedSubmissionId}) {
    if (userKey.trim().isEmpty) return Future<bool>.value(false);
    // 先编码快照，排队期间不再读取页面里的可变输入。
    final String raw = jsonEncode(draft.toJson());
    return _write((preferences) async {
      final String? existingRaw = preferences.getString(_key(userKey));
      if (existingRaw != null) {
        final RepairDraft existing = _decode(existingRaw);
        final String? existingId = existing.submission?.submissionId;
        final String? replacementId = draft.submission?.submissionId;
        if (existingId != null &&
            existing.resultUnconfirmed &&
            (replacementId != existingId ||
                jsonEncode(existing.submission!.toJson()) !=
                    jsonEncode(draft.submission?.toJson())) &&
            expectedSubmissionId != existingId) {
          throw const RepairDraftConflictException();
        }
      }
      return preferences.setString(_key(userKey), raw);
    });
  }

  Future<bool> remove(String userKey) {
    if (userKey.trim().isEmpty) return Future<bool>.value(false);
    return _write((preferences) async {
      return preferences.remove(_key(userKey));
    });
  }

  /// 只清除当前账号已经确认损坏的记录；有效草稿和其他账号的数据不受影响。
  Future<bool> discardCorrupted(String userKey) {
    if (userKey.trim().isEmpty) return Future<bool>.value(false);
    return _write((preferences) async {
      final String? raw = preferences.getString(_key(userKey));
      if (raw == null) return false;
      try {
        _decode(raw);
        return false;
      } on RepairDraftCorruptedException {
        return preferences.remove(_key(userKey));
      }
    });
  }

  // 提交成功的删除必须排在尚未完成的保存之后，避免草稿被迟到的保存恢复。
  Future<bool> _write(Future<bool> Function(SharedPreferences) action) {
    final Future<bool> operation = _pendingWrite.then((_) async {
      final preferences = await _preferencesLoader();
      final previous =
          _writesByPreferences[preferences] ?? Future<void>.value();
      final write = previous.then((_) => action(preferences));
      _writesByPreferences[preferences] = write.then<void>((_) {},
          onError: (Object error, StackTrace stack) {});
      return write;
    });
    _pendingWrite = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }
}

final RepairDraftStore repairDraftStore = RepairDraftStore();
