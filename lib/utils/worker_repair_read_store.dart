import 'package:shared_preferences/shared_preferences.dart';

import '../constant/index.dart';
import '../models/repair.dart';

/// Read markers belong to the assigned worker, API environment and record version.
/// They never change repair data or authentication credentials.
class WorkerRepairReadStore {
  WorkerRepairReadStore(
      {Future<SharedPreferences> Function()? preferencesLoader})
      : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferencesLoader;
  Future<void> _pendingWrite = Future<void>.value();

  static bool needsAttention(RepairRecord record) =>
      record.status == 5 || record.status == 2;

  String _key(RepairRecord record) =>
      'workerRepairRead:v1:${Uri.encodeComponent(GlobalVariable.baseUrl)}:'
      '${Uri.encodeComponent(record.workerId)}:${Uri.encodeComponent(record.id)}';

  String _version(RepairRecord record) => '${record.revision}:${record.status}';

  Future<Set<String>> unreadIds(List<RepairRecord> records) async {
    await _pendingWrite;
    final preferences = await _preferencesLoader();
    return <String>{
      for (final record in records)
        if (needsAttention(record) &&
            (record.workerId.isEmpty ||
                preferences.getString(_key(record)) != _version(record)))
          record.id,
    };
  }

  Future<bool> markViewed(RepairRecord record) {
    if (!needsAttention(record)) return Future<bool>.value(true);
    if (record.workerId.isEmpty || record.id.isEmpty) {
      return Future<bool>.value(false);
    }
    final operation = _pendingWrite.then((_) async {
      final preferences = await _preferencesLoader();
      final previous = preferences.getString(_key(record));
      final revision = int.tryParse(previous?.split(':').first ?? '') ?? -1;
      // A slow older detail response must not replace a newer read marker.
      if (revision > record.revision) return true;
      return preferences.setString(_key(record), _version(record));
    });
    _pendingWrite = operation.then<void>((_) {},
        onError: (Object error, StackTrace stackTrace) {});
    return operation;
  }
}

final workerRepairReadStore = WorkerRepairReadStore();
