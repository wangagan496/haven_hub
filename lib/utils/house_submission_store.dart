import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/house.dart';
import 'submission_id.dart';
import 'validators.dart';

class HouseSubmission {
  const HouseSubmission({required this.house, required this.draftId});
  final House house;
  final String draftId;
  String get id => house.submissionId;

  /// 仅清理原草稿中仍与提交快照相同的资料，保留后来修改过的草稿。
  bool matches(House current) =>
      jsonEncode(House.fromJson(current.copyWith(submissionId: '').toJson())
          .toJson()) ==
      jsonEncode(house.copyWith(submissionId: '').toJson());

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'draftId': draftId,
        'request': house.toJson(),
      };
}

/// 每个已确认账号只允许一份结果待确认的房屋创建；普通选房草稿仍可有多份。
class HouseSubmissionStore {
  HouseSubmissionStore(
      {Future<SharedPreferences> Function()? preferencesLoader})
      : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;
  final Future<SharedPreferences> Function() _preferencesLoader;
  Future<void> _pendingWrite = Future<void>.value();
  String _key(String owner) =>
      'houseSubmission:v1:${Uri.encodeComponent(owner)}:new';

  static HouseSubmission prepare(House house, {required String draftId}) {
    if (house.id.isNotEmpty) throw const FormatException('编辑房屋不能生成创建回执');
    return HouseSubmission(
      house: House.fromJson(
          house.copyWith(submissionId: newSubmissionId()).toJson()),
      draftId: draftId,
    );
  }

  HouseSubmission _decode(String raw) {
    try {
      final dynamic json = jsonDecode(raw);
      if (json is! Map<String, dynamic> ||
          json['version'] != 1 ||
          json['draftId'] is! String ||
          !isSubmissionId(json['draftId'] as String) ||
          json['request'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final request = json['request'] as Map<String, dynamic>;
      for (final field in <String>[
        'submissionId',
        'point',
        'building',
        'room',
        'name',
        'mobile',
        'idcardFrontUrl',
        'idcardBackUrl'
      ]) {
        if (request[field] is! String ||
            (request[field] as String).trim().isEmpty) {
          throw const FormatException();
        }
      }
      if (request.containsKey('id') ||
          request.containsKey('revision') ||
          (request.containsKey('floor') && request['floor'] is! String) ||
          request['gender'] is! int ||
          (request['gender'] != 0 && request['gender'] != 1)) {
        throw const FormatException();
      }
      final house = House.fromJson(request);
      if (!isSubmissionId(house.submissionId) ||
          <String>[house.point, house.building, house.room]
              .any((value) => value.length > 100) ||
          !Validators.ownerNamePattern.hasMatch(house.name) ||
          !RegExp(r'^1[3-9]\d{9}$').hasMatch(house.mobile) ||
          !RegExp(r'^(?:[1-9]\d{0,3}|B[1-9]\d?)?$').hasMatch(house.floor)) {
        throw const FormatException();
      }
      for (final url in <String>[house.idcardFrontUrl, house.idcardBackUrl]) {
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !<String>['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty) {
          throw const FormatException();
        }
      }
      return HouseSubmission(house: house, draftId: json['draftId'] as String);
    } on FormatException {
      throw const FormatException('本机房屋提交回执损坏，不能安全重新提交，请保留数据并联系维护人员');
    }
  }

  Future<HouseSubmission?> load(String owner) async {
    if (owner.trim().isEmpty) throw const FormatException('账号信息未就绪');
    await _pendingWrite;
    final prefs = await _preferencesLoader();
    final raw = prefs.getString(_key(owner));
    return raw == null ? null : _decode(raw);
  }

  Future<bool> save(String owner, HouseSubmission submission) {
    if (owner.trim().isEmpty) return Future.value(false);
    final raw = jsonEncode(submission.toJson());
    _decode(raw);
    return _write(() async {
      final prefs = await _preferencesLoader();
      final existing = prefs.getString(_key(owner));
      if (existing != null && jsonEncode(_decode(existing).toJson()) != raw) {
        return false;
      }
      return prefs.setString(_key(owner), raw);
    });
  }

  Future<bool> remove(String owner, String id) {
    if (owner.trim().isEmpty || !isSubmissionId(id)) return Future.value(false);
    return _write(() async {
      final prefs = await _preferencesLoader();
      final raw = prefs.getString(_key(owner));
      if (raw == null) return true;
      if (_decode(raw).id != id) return false;
      return prefs.remove(_key(owner));
    });
  }

  Future<bool> _write(Future<bool> Function() action) {
    final operation = _pendingWrite.then((_) => action());
    _pendingWrite = operation.then<void>((_) {},
        onError: (Object error, StackTrace stack) {});
    return operation;
  }
}

final houseSubmissionStore = HouseSubmissionStore();
