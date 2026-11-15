import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/visitor.dart';
import 'submission_id.dart';

/// 每个已确认账号保留一份不可变的待确认邀请；不以Token或手机号作键。
class VisitorSubmissionStore {
  VisitorSubmissionStore(
      {Future<SharedPreferences> Function()? preferencesLoader})
      : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;
  final Future<SharedPreferences> Function() _preferencesLoader;
  Future<void> _pendingWrite = Future<void>.value();
  String _key(String owner) =>
      'visitorSubmission:v1:${Uri.encodeComponent(owner)}:new';

  static VisitorRecord prepare(VisitorRecord record) =>
      VisitorRecord.fromJson(<String, dynamic>{
        ...record.toJson(),
        'houseInfo': record.houseInfo,
        'submissionId': newSubmissionId()
      });

  VisitorRecord _decode(String raw) {
    try {
      final dynamic json = jsonDecode(raw);
      if (json is! Map<String, dynamic> ||
          json['version'] != 1 ||
          json['request'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final request = json['request'] as Map<String, dynamic>;
      for (final field in <String>[
        'submissionId',
        'houseId',
        'name',
        'mobile',
        'visitDate'
      ]) {
        if (request[field] is! String ||
            (request[field] as String).trim().isEmpty) {
          throw const FormatException();
        }
      }
      if (request['gender'] is! int ||
          (request['gender'] != 0 && request['gender'] != 1)) {
        throw const FormatException();
      }
      final record = VisitorRecord.fromJson(request);
      final date = DateTime.tryParse(record.visitDate);
      if (!isSubmissionId(record.submissionId) ||
          record.name.length > 100 ||
          !RegExp(r'^1[3-9]\d{9}$').hasMatch(record.mobile) ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(record.visitDate) ||
          date == null ||
          date.toIso8601String().substring(0, 10) != record.visitDate) {
        throw const FormatException();
      }
      return record;
    } on FormatException {
      throw const FormatException('本机访客提交回执损坏，不能安全重新提交，请保留数据并联系维护人员');
    }
  }

  Future<VisitorRecord?> load(String owner) async {
    if (owner.trim().isEmpty) throw const FormatException('账号信息未就绪');
    await _pendingWrite;
    final preferences = await _preferencesLoader();
    final raw = preferences.getString(_key(owner));
    return raw == null ? null : _decode(raw);
  }

  Future<bool> save(String owner, VisitorRecord record) {
    if (owner.trim().isEmpty) return Future.value(false);
    final raw = jsonEncode(<String, dynamic>{
      'version': 1,
      'request': <String, dynamic>{
        ...record.toJson(),
        'houseInfo': record.houseInfo
      }
    });
    _decode(raw);
    return _write(() async {
      final preferences = await _preferencesLoader();
      final existing = preferences.getString(_key(owner));
      // 旧页面不能覆盖另一份尚未确认的提交，也不能覆盖损坏回执。
      if (existing != null) {
        final saved = _decode(existing);
        if (jsonEncode(saved.toJson()) != jsonEncode(record.toJson())) {
          return false;
        }
      }
      return preferences.setString(_key(owner), raw);
    });
  }

  Future<bool> remove(String owner, String submissionId) {
    if (owner.trim().isEmpty || !isSubmissionId(submissionId)) {
      return Future.value(false);
    }
    return _write(() async {
      final preferences = await _preferencesLoader();
      final raw = preferences.getString(_key(owner));
      if (raw == null) return true;
      if (_decode(raw).submissionId != submissionId) return false;
      return preferences.remove(_key(owner));
    });
  }

  Future<bool> _write(Future<bool> Function() action) {
    final operation = _pendingWrite.then((_) => action());
    _pendingWrite = operation.then<void>((_) {},
        onError: (Object error, StackTrace stack) {});
    return operation;
  }
}

final visitorSubmissionStore = VisitorSubmissionStore();
