import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  const RepairDraft draft = RepairDraft(
    record: RepairRecord(
        houseId: 'house-a',
        repairItemId: 'item-a',
        mobile: '13800138000',
        appointment: '2026-10-09',
        description: 'leak'),
    resultUnconfirmed: true,
  );

  test('draft and unconfirmed result survive a new store instance', () async {
    expect(await RepairDraftStore().save('user-a', draft), isTrue);
    final RepairDraft restored = (await RepairDraftStore().load('user-a'))!;
    expect(restored.record.toJson(), draft.record.toJson());
    expect(restored.resultUnconfirmed, isTrue);
    expect(restored.record.appointment, draft.record.appointment);
  });

  test('phase3 draft preserves slot urgency waiting choice and legacy timestamp', () async {
    final store = RepairDraftStore();
    await store.save('user-a', const RepairDraft(record: RepairRecord(slot:'2030-10-20#10',urgentRequest:true),waitingSchedule:false));
    final selected = (await store.load('user-a'))!;
    expect(selected.record.slot,'2030-10-20#10'); expect(selected.record.urgentRequest,isTrue); expect(selected.waitingSchedule,isFalse);
    await store.save('user-a', const RepairDraft(record: RepairRecord(urgentRequest:true,asap:true),waitingSchedule:true));
    final waiting = (await store.load('user-a'))!;
    expect(waiting.record.asap,isTrue); expect(waiting.waitingSchedule,isTrue); expect(waiting.record.slot,isEmpty);
    await store.save('user-a',const RepairDraft(record:RepairRecord(expectedTime:'2030-10-20T18:00:00+08:00')));
    expect((await store.load('user-a'))!.record.expectedTime,'2030-10-20T18:00:00+08:00');
  });

  test('accounts cannot read or delete each other drafts', () async {
    final RepairDraftStore store = RepairDraftStore();
    await store.save('user-a', draft);
    expect(await store.load('user-b'), isNull);
    await store.save(
        'user-b',
        const RepairDraft(
          record: RepairRecord(description: 'account-b'),
        ));
    await store.remove('user-b');
    expect((await store.load('user-a'))!.record.description, 'leak');
    expect(await store.load('user-b'), isNull);
  });

  test('missing user identity never uses shared anonymous storage', () async {
    final RepairDraftStore store = RepairDraftStore();
    expect(await store.save('', draft), isFalse);
    expect(await store.save('  ', draft), isFalse);
    expect(await store.load(''), isNull);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('successful cleanup cannot be undone by a pending draft save', () async {
    final Completer<SharedPreferences> preferences =
        Completer<SharedPreferences>();
    final RepairDraftStore store =
        RepairDraftStore(preferencesLoader: () => preferences.future);
    final Future<bool> saved = store.save('user-a', draft);
    final Future<bool> removed = store.remove('user-a');
    preferences.complete(await SharedPreferences.getInstance());
    expect(await saved, isTrue);
    expect(await removed, isTrue);
    expect(await store.load('user-a'), isNull);
  });

  test('corrupted local draft does not prevent opening the form', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'repairDraft:v1:user-a:new': '{invalid json',
    });
    expect(await RepairDraftStore().load('user-a'), isNull);
  });
}
