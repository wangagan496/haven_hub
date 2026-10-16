import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/utils/worker_repair_read_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  const first =
      RepairRecord(id: 'repair', workerId: 'worker-a', status: 5, revision: 1);

  test('read state survives a new store and remains isolated by worker',
      () async {
    expect(await WorkerRepairReadStore().markViewed(first), isTrue);
    final restored = WorkerRepairReadStore();
    expect(await restored.unreadIds([first]), isEmpty);
    const other = RepairRecord(
        id: 'repair', workerId: 'worker-b', status: 5, revision: 1);
    expect(await restored.unreadIds([other]), {'repair'});
    expect(await restored.markViewed(other), isTrue);
    expect(await restored.unreadIds([first, other]), isEmpty);
  });

  test('new versions are unread; stale responses cannot undo a newer view',
      () async {
    final store = WorkerRepairReadStore();
    await store.markViewed(first);
    const updated = RepairRecord(
        id: 'repair', workerId: 'worker-a', status: 2, revision: 2);
    expect(await store.unreadIds([updated]), {'repair'});
    await store.markViewed(updated);
    await store.markViewed(first);
    expect(await store.unreadIds([updated]), isEmpty);
  });

  test('completed and cancelled records never need a dot', () async {
    final store = WorkerRepairReadStore();
    expect(
        await store.unreadIds([
          for (final status in [0, 1, 3, 4, -1])
            RepairRecord(
                id: 'repair-$status', workerId: 'worker-a', status: status),
        ]),
        isEmpty);
  });

  test('missing worker identity cannot create a shared read marker', () async {
    final store = WorkerRepairReadStore();
    const record = RepairRecord(id: 'repair', status: 5);
    expect(await store.markViewed(record), isFalse);
    expect(await store.unreadIds([record]), {'repair'});
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('API parsing retains the stable assigned worker identifier', () {
    expect(
        RepairRecord.fromJson({'workerId': 'worker-a'}).workerId, 'worker-a');
  });
}
