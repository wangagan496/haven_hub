import 'dart:async';
import 'dart:convert';

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

  test(
      'interleaved form stores cannot replace a different pending submission receipt',
      () async {
    final firstForm = RepairDraftStore();
    final secondForm = RepairDraftStore();
    final pending = RepairDraft.prepareSubmission(const RepairRecord(
        houseId: 'house-a', repairItemId: 'item-a', description: '已发出的报修'));
    expect(
        await firstForm.save(
            'user-a',
            RepairDraft(
                record: pending, submission: pending, resultUnconfirmed: true)),
        isTrue);

    await expectLater(
      secondForm.save(
          'user-a',
          const RepairDraft(
              record:
                  RepairRecord(houseId: 'house-b', description: '另一份表单内容'))),
      throwsA(isA<RepairDraftConflictException>()),
    );
    final restored = await RepairDraftStore().load('user-a');
    expect(restored!.submission!.submissionId, pending.submissionId);
    expect(restored.submission!.description, '已发出的报修');

    expect(
        await secondForm.save(
            'user-a',
            RepairDraft(
                record: const RepairRecord(
                    houseId: 'house-a', description: '更新普通草稿'),
                submission: pending,
                resultUnconfirmed: true)),
        isTrue);
    expect((await firstForm.load('user-a'))!.submission!.submissionId,
        pending.submissionId);
  });

  test(
      'concurrent form saves serialize the pending receipt check with the write',
      () async {
    final first = RepairDraftStore();
    final second = RepairDraftStore();
    final sent =
        RepairDraft.prepareSubmission(const RepairRecord(description: 'sent'));
    final other =
        RepairDraft.prepareSubmission(const RepairRecord(description: 'other'));
    Future<String?> save(RepairDraftStore store, RepairRecord record) async {
      try {
        await store.save(
            'user-a',
            RepairDraft(
                record: record, submission: record, resultUnconfirmed: true));
        return record.submissionId;
      } on RepairDraftConflictException {
        return null;
      }
    }

    final results = await Future.wait([save(first, sent), save(second, other)]);
    expect(results.whereType<String>(), hasLength(1));
    expect((await second.load('user-a'))!.submission!.submissionId,
        results.whereType<String>().single);
  });

  test(
      'phase3 draft preserves slot urgency waiting choice and legacy timestamp',
      () async {
    final store = RepairDraftStore();
    await store.save(
        'user-a',
        const RepairDraft(
            record: RepairRecord(slot: '2030-10-20#10', urgentRequest: true),
            waitingSchedule: false));
    final selected = (await store.load('user-a'))!;
    expect(selected.record.slot, '2030-10-20#10');
    expect(selected.record.urgentRequest, isTrue);
    expect(selected.waitingSchedule, isFalse);
    await store.save(
        'user-a',
        const RepairDraft(
            record: RepairRecord(urgentRequest: true, asap: true),
            waitingSchedule: true));
    final waiting = (await store.load('user-a'))!;
    expect(waiting.record.asap, isTrue);
    expect(waiting.waitingSchedule, isTrue);
    expect(waiting.record.slot, isEmpty);
    await store.save(
        'user-a',
        const RepairDraft(
            record: RepairRecord(expectedTime: '2030-10-20T18:00:00+08:00')));
    expect((await store.load('user-a'))!.record.expectedTime,
        '2030-10-20T18:00:00+08:00');
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

  test(
      'corrupted local draft fails closed instead of discarding a possible receipt',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'repairDraft:v1:user-a:new': '{invalid json',
    });
    await expectLater(RepairDraftStore().load('user-a'), throwsFormatException);
    expect(
        (await SharedPreferences.getInstance())
            .getString('repairDraft:v1:user-a:new'),
        '{invalid json');
  });

  test(
      'corrupted local draft can be explicitly discarded before saving a new draft',
      () async {
    const String key = 'repairDraft:v1:user-a:new';
    SharedPreferences.setMockInitialValues(
        <String, Object>{key: '{invalid json'});
    final RepairDraftStore store = RepairDraftStore();
    await expectLater(
        store.load('user-a'), throwsA(isA<RepairDraftCorruptedException>()));
    expect(await store.discardCorrupted('user-a'), isTrue);
    expect(await store.load('user-a'), isNull);
    expect(await store.save('user-a', draft), isTrue);
    expect((await store.load('user-a'))!.record.description, 'leak');
  });

  test('discardCorrupted preserves a valid draft and other accounts', () async {
    final RepairDraftStore store = RepairDraftStore();
    await store.save('user-a', draft);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'repairDraft:v1:user-a:new': jsonEncode(draft.toJson()),
      'repairDraft:v1:user-b:new': '{invalid json',
    });
    expect(await store.discardCorrupted('user-a'), isFalse);
    expect(await store.load('user-a'), isNotNull);
    expect(await store.discardCorrupted('user-b'), isTrue);
    expect(await store.load('user-b'), isNull);
  });
}
