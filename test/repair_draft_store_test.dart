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
