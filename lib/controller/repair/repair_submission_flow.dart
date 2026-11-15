import '../../models/repair.dart';
import '../../utils/app_exception.dart';
import '../../utils/repair_draft_store.dart';

sealed class RepairSubmissionResult {
  const RepairSubmissionResult();
}

final class RepairSubmissionIgnored extends RepairSubmissionResult {
  const RepairSubmissionIgnored();
}

final class RepairSubmissionCreated extends RepairSubmissionResult {
  const RepairSubmissionCreated(this.value, {required this.draftRemoved});
  // 保留旧接口和测试替身返回非工单编号的兼容行为。
  final Object? value;
  final bool draftRemoved;
}

final class RepairSubmissionNotSent extends RepairSubmissionResult {
  const RepairSubmissionNotSent({required this.conflict});
  final bool conflict;
}

final class RepairSubmissionUnknown extends RepairSubmissionResult {
  const RepairSubmissionUnknown();
}

final class RepairSubmissionStopped extends RepairSubmissionResult {
  const RepairSubmissionStopped({required this.draftSaved});
  final bool draftSaved;
}

final class RepairSubmissionFailed extends RepairSubmissionResult {
  const RepairSubmissionFailed(this.error, {this.uncertain = false});
  final Object error;
  final bool uncertain;
}

/// 一张新建报修表单的提交生命周期，不依赖 Widget、GetX 或全局会话。
///
/// 页面先读取草稿，再提供当前输入快照；校验、时段刷新、确认框和导航留在页面。
/// 本类独占提交回执和操作锁：先保存回执再发送，未知结果只能查询、原样重试或停止。
/// [isOwnerCurrent] 必须同时核对账号和创建本实例时的会话，不能只比较用户 ID。
class RepairSubmissionFlow {
  RepairSubmissionFlow({
    required String ownerKey,
    required bool Function(String) isOwnerCurrent,
    required RepairDraftStore draftStore,
    required Future<Object?> Function(RepairRecord) submitter,
    required Future<String?> Function(String) submissionLoader,
    required Future<String?> Function(String) submissionCloser,
    void Function()? onChanged,
  })  : _ownerKey = ownerKey.trim(),
        _isOwnerCurrent = isOwnerCurrent,
        _store = draftStore,
        _submitter = submitter,
        _submissionLoader = submissionLoader,
        _submissionCloser = submissionCloser,
        _onChanged = onChanged;

  String _ownerKey;
  final bool Function(String) _isOwnerCurrent;
  final RepairDraftStore _store;
  final Future<Object?> Function(RepairRecord) _submitter;
  final Future<String?> Function(String) _submissionLoader;
  final Future<String?> Function(String) _submissionCloser;
  void Function()? _onChanged;
  bool _disposed = false;
  bool _loaded = false;
  bool _busy = false;
  bool _submitted = false;
  bool _resultUnconfirmed = false;
  bool _draftSaveFailed = false;
  bool _draftSaveConflict = false;
  RepairRecord? _pendingSubmission;
  RepairRecord? _record;
  bool? _waitingSchedule;

  String get ownerKey => _ownerKey;
  bool get busy => _busy;
  bool get submitted => _submitted;
  bool get resultUnconfirmed => _resultUnconfirmed;
  bool get draftSaveFailed => _draftSaveFailed;
  bool get draftSaveConflict => _draftSaveConflict;
  RepairRecord? get pendingSubmission =>
      _pendingSubmission == null ? null : _copy(_pendingSubmission!);

  bool get _active =>
      !_disposed && _ownerKey.isNotEmpty && _isOwnerCurrent(_ownerKey);

  /// 身份可以由冷启动资料加载补齐，但不能把已有流程改绑给另一个账号。
  Future<RepairDraft?> loadDraft(String userKey) async {
    final String key = userKey.trim();
    if (_disposed ||
        key.isEmpty ||
        !_isOwnerCurrent(key) ||
        (_ownerKey.isNotEmpty && _ownerKey != key)) {
      throw const SessionChangedException();
    }
    _ownerKey = key;
    final RepairDraft? draft = await _store.load(key);
    if (!_active) throw const SessionChangedException();
    _loaded = true;
    _pendingSubmission =
        draft?.submission == null ? null : _copy(draft!.submission!);
    _resultUnconfirmed =
        (draft?.resultUnconfirmed ?? false) || _pendingSubmission != null;
    if (draft != null) {
      _record = _copy(draft.record);
      _waitingSchedule = draft.waitingSchedule;
    }
    return draft;
  }

  /// 只接收所属账号的输入；换号后保存仍使用最后一次原账号快照。
  void captureDraft(RepairRecord record, {required bool waitingSchedule}) {
    if (!_active || !_loaded || _submitted) return;
    _record = _copy(record);
    _waitingSchedule = waitingSchedule;
  }

  Future<bool> saveDraft() => _saveDraft();

  Future<bool> _saveDraft({String? expectedSubmissionId}) async {
    final RepairRecord? record = _record;
    if (_disposed || !_loaded || _submitted || record == null) return false;
    final RepairDraft draft = RepairDraft(
      record: _copy(record),
      waitingSchedule: _waitingSchedule,
      submission: pendingSubmission,
      resultUnconfirmed: _resultUnconfirmed,
    );
    try {
      final bool saved = await _store.save(_ownerKey, draft,
          expectedSubmissionId: expectedSubmissionId);
      if (_active) {
        _draftSaveFailed = !saved;
        _draftSaveConflict = false;
        _notify();
      }
      return saved;
    } on RepairDraftConflictException {
      RepairDraft? existing;
      try {
        existing = await _store.load(_ownerKey);
      } on Object {
        // 读取失败也不能放行新请求，保留冲突供用户重试处理。
      }
      if (_active) {
        _draftSaveFailed = true;
        _draftSaveConflict = true;
        if (existing?.submission != null) {
          _pendingSubmission = _copy(existing!.submission!);
          _resultUnconfirmed = true;
        }
        _notify();
      }
      return false;
    } on Object {
      if (_active) {
        _draftSaveFailed = true;
        _draftSaveConflict = false;
        _notify();
      }
      return false;
    }
  }

  Future<bool> discardCorruptedDraft() async {
    if (!_active || _busy || _submitted) return false;
    final bool removed = await _store.discardCorrupted(_ownerKey);
    if (!_active || !removed) return false;
    _loaded = true;
    _pendingSubmission = null;
    _resultUnconfirmed = false;
    _draftSaveFailed = false;
    _draftSaveConflict = false;
    return true;
  }

  Future<RepairSubmissionResult> submit({
    Future<bool> Function()? confirmLegacySubmission,
  }) =>
      _run(() async {
        if (_pendingSubmission != null) {
          return const RepairSubmissionUnknown();
        }
        final RepairRecord? record = _record;
        if (record == null) return const RepairSubmissionIgnored();
        final bool wasUnconfirmed = _resultUnconfirmed;
        if (wasUnconfirmed) {
          if (confirmLegacySubmission == null ||
              !await confirmLegacySubmission() ||
              !_active) {
            return const RepairSubmissionIgnored();
          }
        }
        final RepairRecord pending = RepairDraft.prepareSubmission(record);
        _pendingSubmission = pending;
        _resultUnconfirmed = true;
        final bool saved = await _saveDraft();
        if (!_active) return const RepairSubmissionIgnored();
        if (!saved) {
          // 冲突后的读取也可能失败：本次新回执未落盘，不能暴露为可重试的旧提交。
          // 只有确实读取到另一条持久化回执时，才保留它供结果恢复。
          if (!_draftSaveConflict ||
              _pendingSubmission?.submissionId == pending.submissionId) {
            _pendingSubmission = null;
            _resultUnconfirmed = wasUnconfirmed;
          }
          return RepairSubmissionNotSent(conflict: _draftSaveConflict);
        }
        try {
          final Object? created = await _submitter(_copy(pending));
          if (!_active) return const RepairSubmissionIgnored();
          return await _finish(created);
        } on Object catch (error) {
          if (!_active) return const RepairSubmissionIgnored();
          // 保留原页面对已发请求的分类，包括历史无回执的未知状态。
          final bool uncertain = error is! BusinessException &&
              (error is! NetworkException ||
                  error.isTimeout ||
                  error is SessionChangedException ||
                  const <int?>{null, 408}.contains(error.statusCode) ||
                  (error.statusCode != null && error.statusCode! >= 500));
          _resultUnconfirmed = wasUnconfirmed || uncertain;
          if (!_resultUnconfirmed) _pendingSubmission = null;
          await _saveDraft(
              expectedSubmissionId:
                  _resultUnconfirmed ? null : pending.submissionId);
          if (!_active) return const RepairSubmissionIgnored();
          return RepairSubmissionFailed(error, uncertain: uncertain);
        }
      });

  /// 查询为空只代表未知；只有用户明确同意才按原回执、原内容重试。
  Future<RepairSubmissionResult> resolve({
    Future<bool> Function()? confirmRetry,
  }) =>
      _run(() async {
        final RepairRecord? pending = _pendingSubmission;
        if (pending == null) return const RepairSubmissionIgnored();
        try {
          final String? id = await _submissionLoader(pending.submissionId);
          if (!_active) return const RepairSubmissionIgnored();
          if (id != null) return await _finish(id);
          if (confirmRetry == null) return const RepairSubmissionUnknown();
          if (!await confirmRetry() || !_active) {
            return const RepairSubmissionIgnored();
          }
          final Object? created = await _submitter(_copy(pending));
          if (!_active) return const RepairSubmissionIgnored();
          return await _finish(created);
        } on Object catch (error) {
          if (!_active) return const RepairSubmissionIgnored();
          if (error is BusinessException && error.code == 40903) {
            return _clearSubmission();
          }
          return RepairSubmissionFailed(error);
        }
      });

  /// 服务端封住旧回执后才清除；已创建的工单直接返回，不取消它。
  Future<RepairSubmissionResult> stop({
    required Future<bool> Function() confirm,
  }) =>
      _run(() async {
        final RepairRecord? pending = _pendingSubmission;
        if (pending == null) return const RepairSubmissionIgnored();
        try {
          if (!await confirm() || !_active) {
            return const RepairSubmissionIgnored();
          }
          final String? id = await _submissionCloser(pending.submissionId);
          if (!_active) return const RepairSubmissionIgnored();
          return id != null ? await _finish(id) : await _clearSubmission();
        } on Object catch (error) {
          if (!_active) return const RepairSubmissionIgnored();
          return RepairSubmissionFailed(error);
        }
      });

  Future<RepairSubmissionResult> _clearSubmission() async {
    final String? previousId = _pendingSubmission?.submissionId;
    _pendingSubmission = null;
    _resultUnconfirmed = false;
    final bool saved = await _saveDraft(expectedSubmissionId: previousId);
    if (!_active) return const RepairSubmissionIgnored();
    return RepairSubmissionStopped(draftSaved: saved);
  }

  Future<RepairSubmissionResult> _finish(Object? created) async {
    // 先标记成功，清理失败或页面关闭都不能重新放行提交。
    _submitted = true;
    bool removed = false;
    try {
      removed = await _store.remove(_ownerKey);
    } on Object {
      // 清理失败通过结果交给页面提示，不把已经成功的提交改成失败。
    }
    if (!_active) return const RepairSubmissionIgnored();
    return RepairSubmissionCreated(created, draftRemoved: removed);
  }

  Future<RepairSubmissionResult> _run(
      Future<RepairSubmissionResult> Function() operation) async {
    if (!_active || !_loaded || _busy || _submitted) {
      return const RepairSubmissionIgnored();
    }
    _busy = true;
    _notify();
    try {
      return await operation();
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _notify() {
    // 换号后仍通知操作锁已释放，页面才能停止加载动画；业务结果仍由 _active 拦截。
    if (!_disposed) _onChanged?.call();
  }

  /// 停止消费迟到结果和通知；不会删除持久化回执，也不会取消服务端请求。
  void dispose() {
    _disposed = true;
    _onChanged = null;
  }

  static RepairRecord _copy(RepairRecord record) =>
      RepairRecord.fromJson(<String, dynamic>{
        ...record.toJson(),
        'appointment': record.appointment,
        'expectedTime': record.expectedTime,
      });
}
