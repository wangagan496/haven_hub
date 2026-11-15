import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven_hub/controller/repair/repair_submission_flow.dart';
import 'package:haven_hub/models/repair.dart';
import 'package:haven_hub/utils/app_exception.dart';
import 'package:haven_hub/utils/repair_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _record = RepairRecord(
  houseId: 'house-a',
  repairItemId: 'item-a',
  mobile: '13800138000',
  description: '原始内容',
  attachment: <String>['photo-a'],
);

class _Store extends RepairDraftStore {
  bool failLoad = false;
  bool failSave = false;
  bool throwSave = false;
  bool failRemove = false;
  bool throwRemove = false;
  Completer<void>? saveGate;
  final saving = Completer<void>();

  @override
  Future<RepairDraft?> load(String userKey) {
    if (failLoad) throw StateError('read unavailable');
    return super.load(userKey);
  }

  @override
  Future<bool> save(String userKey, RepairDraft draft,
      {String? expectedSubmissionId}) async {
    if (!saving.isCompleted) saving.complete();
    await saveGate?.future;
    if (throwSave) throw StateError('storage unavailable');
    if (failSave) return false;
    return super
        .save(userKey, draft, expectedSubmissionId: expectedSubmissionId);
  }

  @override
  Future<bool> remove(String userKey) async {
    if (throwRemove) throw StateError('cleanup unavailable');
    if (failRemove) return false;
    return super.remove(userKey);
  }
}

RepairSubmissionFlow _flow(
  RepairDraftStore store, {
  String owner = 'a',
  bool Function(String)? isOwnerCurrent,
  Future<Object?> Function(RepairRecord)? submitter,
  Future<String?> Function(String)? lookup,
  Future<String?> Function(String)? closer,
  void Function()? onChanged,
}) =>
    RepairSubmissionFlow(
      ownerKey: owner,
      isOwnerCurrent: isOwnerCurrent ?? (key) => key == 'a',
      draftStore: store,
      submitter: submitter ?? (_) async => fail('unexpected create'),
      submissionLoader: lookup ?? (_) async => null,
      submissionCloser: closer ?? (_) async => null,
      onChanged: onChanged,
    );

Future<void> _ready(RepairSubmissionFlow flow) async {
  await flow.loadDraft('a');
  flow.captureDraft(_record, waitingSchedule: true);
}

Future<RepairRecord> _seed(RepairDraftStore store) async {
  final pending = RepairDraft.prepareSubmission(_record);
  await store.save(
      'a',
      RepairDraft(
        record: _record,
        waitingSchedule: true,
        submission: pending,
        resultUnconfirmed: true,
      ));
  return pending;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final throws in <bool>[false, true]) {
    test('unsaved receipt never sends a request (throws=$throws)', () async {
      final store = _Store()
        ..failSave = !throws
        ..throwSave = throws;
      final flow = _flow(store);
      await _ready(flow);
      final result = await flow.submit();
      expect(result, isA<RepairSubmissionNotSent>());
      expect(flow.draftSaveFailed, isTrue);
      expect(flow.pendingSubmission, isNull);
      expect(flow.resultUnconfirmed, isFalse);
      expect(flow.busy, isFalse);
      expect(await store.load('a'), isNull);
    });
  }

  test('save completes before send and the operation excludes double submit',
      () async {
    final store = _Store()..saveGate = Completer<void>();
    int requests = 0;
    final flow = _flow(store, submitter: (record) async {
      requests++;
      final draft = (await store.load('a'))!;
      expect(draft.submission!.toJson(), record.toJson());
      expect(draft.resultUnconfirmed, isTrue);
      return 'order-a';
    });
    await _ready(flow);
    final first = flow.submit();
    await store.saving.future;
    expect(requests, 0);
    expect(flow.busy, isTrue);
    expect(await flow.submit(), isA<RepairSubmissionIgnored>());
    store.saveGate!.complete();
    final result = await first as RepairSubmissionCreated;
    expect(result.value, 'order-a');
    expect(result.draftRemoved, isTrue);
    expect(requests, 1);
    expect(flow.submitted, isTrue);
    expect(await store.load('a'), isNull);
    expect(await flow.submit(), isA<RepairSubmissionIgnored>());
  });

  final errors = <({Object error, bool uncertain})>[
    (error: const BusinessException('rejected', code: 40001), uncertain: false),
    (
      error: const NetworkException('bad request', statusCode: 400),
      uncertain: false
    ),
    (
      error: const NetworkException('unauthorized', statusCode: 401),
      uncertain: false
    ),
    (
      error: const NetworkException('conflict', statusCode: 409),
      uncertain: false
    ),
    (
      error: const NetworkException('timeout', isTimeout: true),
      uncertain: true
    ),
    (
      error: const NetworkException('request timeout', statusCode: 408),
      uncertain: true
    ),
    (
      error: const NetworkException('server error', statusCode: 500),
      uncertain: true
    ),
    (error: const NetworkException('offline'), uncertain: true),
    (error: const SessionChangedException(), uncertain: true),
    (error: const FormatException('unreadable response'), uncertain: true),
  ];
  for (final example in errors) {
    test('send outcome preserves uncertainty for ${example.error}', () async {
      final store = _Store();
      final flow = _flow(store, submitter: (_) async => throw example.error);
      await _ready(flow);
      final result = await flow.submit() as RepairSubmissionFailed;
      expect(result.error, same(example.error));
      expect(result.uncertain, example.uncertain);
      expect(flow.resultUnconfirmed, example.uncertain);
      final draft = (await store.load('a'))!;
      expect(draft.record.description, _record.description);
      expect(draft.resultUnconfirmed, example.uncertain);
      expect(draft.submission, example.uncertain ? isNotNull : isNull);
      expect(flow.busy, isFalse);
    });
  }

  test('legacy uncertainty requires consent and survives a definite rejection',
      () async {
    final store = _Store();
    await store.save(
        'a', const RepairDraft(record: _record, resultUnconfirmed: true));
    int requests = 0;
    final flow = _flow(store, submitter: (_) async {
      requests++;
      throw const BusinessException('rejected');
    });
    await _ready(flow);
    expect(await flow.submit(), isA<RepairSubmissionIgnored>());
    expect(await flow.submit(confirmLegacySubmission: () async => false),
        isA<RepairSubmissionIgnored>());
    expect(requests, 0);
    expect(await flow.submit(confirmLegacySubmission: () async => true),
        isA<RepairSubmissionFailed>());
    expect(requests, 1);
    expect((await store.load('a'))!.resultUnconfirmed, isTrue);
  });

  test('input edits and returned snapshots cannot change the original retry',
      () async {
    final store = _Store();
    final pending = await _seed(store);
    final sent = <RepairRecord>[];
    final flow = _flow(store, submitter: (record) async {
      sent.add(record);
      throw const NetworkException('lost response', isTimeout: true);
    });
    await _ready(flow);
    final photos = <String>['new-photo'];
    flow.captureDraft(RepairRecord(description: '新输入', attachment: photos),
        waitingSchedule: true);
    photos.add('mutated-after-capture');
    flow.pendingSubmission!.attachment[0] = 'changed-returned-snapshot';
    await flow.saveDraft();
    expect(await flow.resolve(), isA<RepairSubmissionUnknown>());
    expect(await flow.submit(), isA<RepairSubmissionUnknown>());
    expect(await flow.resolve(confirmRetry: () async => false),
        isA<RepairSubmissionIgnored>());
    expect(sent, isEmpty);
    await flow.resolve(confirmRetry: () async => true);
    expect(sent.single.toJson(), pending.toJson());
    sent.single.attachment[0] = 'changed-request-copy';
    expect(flow.pendingSubmission!.toJson(), pending.toJson());
    final draft = (await store.load('a'))!;
    expect(draft.record.description, '新输入');
    expect(draft.record.attachment, <String>['new-photo']);
    expect(draft.submission!.toJson(), pending.toJson());
  });

  test('successful lookup opens the existing order without retry confirmation',
      () async {
    final store = _Store();
    final pending = await _seed(store);
    final flow = _flow(store, lookup: (id) async {
      expect(id, pending.submissionId);
      return 'existing-order';
    });
    await _ready(flow);
    final result = await flow.resolve(
            confirmRetry: () async => fail('confirmation is unnecessary'))
        as RepairSubmissionCreated;
    expect(result.value, 'existing-order');
    expect(flow.submitted, isTrue);
    expect(await store.load('a'), isNull);
  });

  test('corrupt draft blocks sending until explicitly discarded', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('repairDraft:v1:a:new', '{broken');
    final flow = _flow(_Store());
    await expectLater(
        flow.loadDraft('a'), throwsA(isA<RepairDraftCorruptedException>()));
    flow.captureDraft(_record, waitingSchedule: true);
    expect(await flow.submit(), isA<RepairSubmissionIgnored>());
    expect(await flow.saveDraft(), isFalse);
    expect(preferences.getString('repairDraft:v1:a:new'), '{broken');
    expect(await flow.discardCorruptedDraft(), isTrue);
    flow.captureDraft(_record, waitingSchedule: true);
    expect(await flow.saveDraft(), isTrue);
    expect((await _Store().load('a'))!.record.description, '原始内容');
  });

  test(
      'a second form adopts the durable receipt and never sends another create',
      () async {
    final store = _Store();
    final firstResponse = Completer<Object?>();
    final firstSent = Completer<void>();
    final first = _flow(store, submitter: (_) {
      firstSent.complete();
      return firstResponse.future;
    });
    final second = _flow(RepairDraftStore());
    await _ready(first);
    await _ready(second);
    final sending = first.submit();
    await firstSent.future;
    final pending = (await store.load('a'))!.submission!;
    final result = await second.submit() as RepairSubmissionNotSent;
    expect(result.conflict, isTrue);
    expect(second.pendingSubmission!.toJson(), pending.toJson());
    expect(second.resultUnconfirmed, isTrue);
    expect((await store.load('a'))!.submission!.toJson(), pending.toJson());
    firstResponse.completeError(const NetworkException('lost response'));
    await sending;
  });

  test('unreadable conflicting receipt cannot retry an unpersisted attempt',
      () async {
    final store = _Store();
    final flow = _flow(store);
    await _ready(flow);
    final existing = await _seed(RepairDraftStore());
    store.failLoad = true;
    final result = await flow.submit() as RepairSubmissionNotSent;
    expect(result.conflict, isTrue);
    expect(flow.pendingSubmission, isNull);
    expect(await flow.resolve(confirmRetry: () async => true),
        isA<RepairSubmissionIgnored>());
    expect((await RepairDraftStore().load('a'))!.submission!.toJson(),
        existing.toJson());
    store.failLoad = false;
    expect(await flow.submit(), isA<RepairSubmissionNotSent>());
    expect(flow.pendingSubmission!.toJson(), existing.toJson());
  });

  test(
      'switching accounts during receipt save sends nothing and preserves owners',
      () async {
    final store = _Store();
    await store.save(
        'b', const RepairDraft(record: RepairRecord(description: 'B')));
    store.saveGate = Completer<void>();
    String owner = 'a';
    final flow = _flow(store, isOwnerCurrent: (key) => key == owner);
    await _ready(flow);
    final sending = flow.submit();
    expect(flow.busy, isTrue);
    owner = 'b';
    flow.captureDraft(const RepairRecord(description: 'B的新输入'),
        waitingSchedule: false);
    store.saveGate!.complete();
    expect(await sending, isA<RepairSubmissionIgnored>());
    expect((await store.load('a'))!.submission!.description, '原始内容');
    expect((await store.load('b'))!.record.description, 'B');
    await expectLater(
        flow.loadDraft('b'), throwsA(isA<SessionChangedException>()));
  });

  for (final action in <String>['submit', 'resolve', 'stop']) {
    test('same account with a new session ignores late $action response',
        () async {
      final store = _Store();
      if (action != 'submit') await _seed(store);
      final response = Completer<String?>();
      final started = Completer<void>();
      int session = 1;
      Future<String?> request() {
        started.complete();
        return response.future;
      }

      final flow = _flow(store,
          isOwnerCurrent: (key) => key == 'a' && session == 1,
          submitter: (_) => request(),
          lookup: (_) => request(),
          closer: (_) => request());
      await _ready(flow);
      final operation = switch (action) {
        'submit' => flow.submit(),
        'resolve' => flow.resolve(),
        _ => flow.stop(confirm: () async => true),
      };
      await started.future;
      session = 2;
      response.complete('late-order');
      expect(await operation, isA<RepairSubmissionIgnored>());
      expect(flow.submitted, isFalse);
      expect((await store.load('a'))!.submission, isNotNull);
    });
  }

  test('pending confirmation holds the lock and account change cancels retry',
      () async {
    final store = _Store();
    await _seed(store);
    bool current = true;
    final decision = Completer<bool>();
    final asking = Completer<void>();
    final flow = _flow(store, isOwnerCurrent: (_) => current);
    await _ready(flow);
    final resolving = flow.resolve(confirmRetry: () {
      asking.complete();
      return decision.future;
    });
    await asking.future;
    expect(flow.busy, isTrue);
    expect(await flow.stop(confirm: () async => fail('must be excluded')),
        isA<RepairSubmissionIgnored>());
    current = false;
    decision.complete(true);
    expect(await resolving, isA<RepairSubmissionIgnored>());
    expect((await store.load('a'))!.submission, isNotNull);
  });

  for (final failResponse in <bool>[false, true]) {
    test(
        'disposing preserves receipt and ignores late completion (error=$failResponse)',
        () async {
      final store = _Store();
      final response = Completer<Object?>();
      final sent = Completer<void>();
      int notifications = 0;
      final flow = _flow(store,
          onChanged: () => notifications++,
          submitter: (_) {
            sent.complete();
            return response.future;
          });
      await _ready(flow);
      final operation = flow.submit();
      await sent.future;
      final saving = flow.saveDraft();
      flow.dispose();
      final before = notifications;
      if (failResponse) {
        response.completeError(
            const NetworkException('late timeout', isTimeout: true));
      } else {
        response.complete('late-order');
      }
      expect(await operation, isA<RepairSubmissionIgnored>());
      expect(await saving, isTrue);
      expect(notifications, before);
      expect((await RepairDraftStore().load('a'))!.submission, isNotNull);
      expect(await flow.submit(), isA<RepairSubmissionIgnored>());
    });
  }

  for (final throws in <bool>[false, true]) {
    test('cleanup failure cannot turn success into a retry (throws=$throws)',
        () async {
      final store = _Store()
        ..failRemove = !throws
        ..throwRemove = throws;
      final flow = _flow(store, submitter: (_) async => null);
      await _ready(flow);
      final result = await flow.submit() as RepairSubmissionCreated;
      expect(result.value, isNull);
      expect(result.draftRemoved, isFalse);
      expect(flow.submitted, isTrue);
      expect(await flow.submit(), isA<RepairSubmissionIgnored>());
      expect(await flow.saveDraft(), isFalse);
      expect((await store.load('a'))!.submission, isNotNull);
    });
  }

  test(
      'stop clears only after server fencing and keeps latest editable content',
      () async {
    final store = _Store();
    final pending = await _seed(store);
    final response = Completer<String?>();
    final closing = Completer<void>();
    final flow = _flow(store, closer: (id) {
      expect(id, pending.submissionId);
      closing.complete();
      return response.future;
    });
    await _ready(flow);
    flow.captureDraft(const RepairRecord(description: '修改后的内容'),
        waitingSchedule: false);
    expect(await flow.stop(confirm: () async => false),
        isA<RepairSubmissionIgnored>());
    expect(closing.isCompleted, isFalse);
    final operation = flow.stop(confirm: () async => true);
    await closing.future;
    expect((await store.load('a'))!.submission, isNotNull);
    response.complete(null);
    final result = await operation as RepairSubmissionStopped;
    expect(result.draftSaved, isTrue);
    final draft = (await store.load('a'))!;
    expect(draft.submission, isNull);
    expect(draft.resultUnconfirmed, isFalse);
    expect(draft.record.description, '修改后的内容');
    expect(draft.waitingSchedule, isFalse);
  });

  test('failed stop preserves receipt and existing order wins over stop',
      () async {
    final store = _Store();
    final pending = await _seed(store);
    bool failClose = true;
    final flow = _flow(store, closer: (_) async {
      if (failClose) throw const NetworkException('unknown stop');
      return 'already-created';
    });
    await _ready(flow);
    expect(await flow.stop(confirm: () async => true),
        isA<RepairSubmissionFailed>());
    expect((await store.load('a'))!.submission!.submissionId,
        pending.submissionId);
    failClose = false;
    final result =
        await flow.stop(confirm: () async => true) as RepairSubmissionCreated;
    expect(result.value, 'already-created');
    expect(await store.load('a'), isNull);
  });

  test('server closed receipt clears locally and reports a failed local save',
      () async {
    final store = _Store();
    await _seed(store);
    final flow = _flow(store, lookup: (_) async {
      throw const BusinessException('closed', code: 40903);
    });
    await _ready(flow);
    store.failSave = true;
    final result = await flow.resolve() as RepairSubmissionStopped;
    expect(result.draftSaved, isFalse);
    expect(flow.pendingSubmission, isNull);
    expect((await store.load('a'))!.submission, isNotNull);
    store.failSave = false;
    // 磁盘旧回执未清理时，下次新提交也不能越过保存冲突直接发出。
    final retry = await flow.submit() as RepairSubmissionNotSent;
    expect(retry.conflict, isTrue);
  });

  test('empty identity cannot load or send and a later identity can bind once',
      () async {
    final flow = _flow(_Store(), owner: '');
    await expectLater(
        flow.loadDraft(''), throwsA(isA<SessionChangedException>()));
    flow.captureDraft(_record, waitingSchedule: true);
    expect(await flow.submit(), isA<RepairSubmissionIgnored>());
    await _ready(flow);
    expect(flow.ownerKey, 'a');
    expect(await flow.saveDraft(), isTrue);
  });
}
