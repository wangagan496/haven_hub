import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/worker.dart';
import '../../models/repair.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../utils/worker_repair_read_store.dart';
import '../../widgets/repair_photos.dart';
import '../../widgets/repair_progress.dart';

class WorkerPage extends StatefulWidget {
  const WorkerPage({
    this.recordsLoader = getWorkerRepairsApi,
    this.recordLoader = getWorkerRepairApi,
    this.readStore,
    this.tokens,
    super.key,
  });
  final Future<List<RepairRecord>> Function() recordsLoader;
  final Future<RepairRecord> Function(String id) recordLoader;
  final WorkerRepairReadStore? readStore;
  final TokenManager? tokens;
  @override
  State<WorkerPage> createState() => _WorkerPageState();
}

class _WorkerPageState extends State<WorkerPage> {
  List<RepairRecord> _records = <RepairRecord>[];
  Set<String> _unreadIds = <String>{};
  WorkerRepairReadStore get _readStore =>
      widget.readStore ?? workerRepairReadStore;
  TokenManager get _tokens => widget.tokens ?? tokenManager;
  int _status = 5;
  bool _loading = false;
  bool _loggingOut = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    final session = _tokens.sessionId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await widget.recordsLoader();
      if (!mounted || session != _tokens.sessionId) return;
      final unreadIds = await _readStore.unreadIds(records);
      if (!mounted || session != _tokens.sessionId) return;
      setState(() {
        _records = records;
        _unreadIds = unreadIds;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _records = <RepairRecord>[];
          _error = describeError(error, fallback: '工单加载失败，请重试');
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    try {
      final removed = await _tokens.deleteToken();
      if (!removed) {
        // 与 TabsPage 一致：磁盘清理失败也要立即作废内存会话，避免继续带旧凭证请求。
        _tokens.invalidateLocalSession();
        if (mounted) await PromptAction.showError('本地登录信息清除失败，请重试');
        return;
      }
      if (!mounted) return;
      await Navigator.pushNamedAndRemoveUntil<void>(
          context, AppRoutes.login, (_) => false);
    } on Object catch (error) {
      if (mounted) {
        await PromptAction.showError(
            describeError(error, fallback: '退出登录失败，请重试'));
      }
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = _records.where((r) => r.status == _status).toList();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
          title: const Text('维修工作台'),
          automaticallyImplyLeading: false,
          actions: <Widget>[
            IconButton(
                tooltip: '刷新工单',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh)),
            TextButton(
                onPressed: _loggingOut ? null : _logout,
                child: const Text('退出登录')),
          ]),
      body: Column(children: <Widget>[
        Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 12, children: <Widget>[
              for (final entry
                  in const <int, String>{5: '待接单', 2: '处理中', 3: '已完成'}.entries)
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    ChoiceChip(
                        showCheckmark: false,
                        label: Text(entry.value),
                        selected: _status == entry.key,
                        onSelected: (_) => setState(() => _status = entry.key)),
                    if (entry.key != 3 &&
                        _records.any((r) =>
                            r.status == entry.key && _unreadIds.contains(r.id)))
                      Positioned(
                        top: 2,
                        right: -4,
                        child: _UnreadDot(
                          key: ValueKey('worker-status-dot-${entry.key}'),
                          label: '${entry.value}有未查看工单',
                        ),
                      ),
                  ],
                ),
            ])),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: <Widget>[
                Text(_error!),
                TextButton(onPressed: _load, child: const Text('重试'))
              ])),
        Expanded(
            child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: <Widget>[
                      if (!_loading && _error == null && records.isEmpty)
                        const Padding(
                            padding: EdgeInsets.all(48),
                            child: Center(child: Text('当前没有此状态的工单'))),
                      for (final record in records)
                        ListTile(
                          key: ValueKey(record.id),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          title: Text(
                            record.description.isEmpty
                                ? record.repairItemName
                                : record.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                                '${record.repairItemName} · ${record.statusText}\n${record.houseInfo}\n预约：${record.appointment}'),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (_unreadIds.contains(record.id)) ...[
                                _UnreadDot(
                                  key: ValueKey(
                                      'worker-record-dot-${record.id}'),
                                  label: '未查看工单',
                                ),
                                const SizedBox(width: 8),
                              ],
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () async {
                            final session = _tokens.sessionId;
                            await Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => WorkerDetailPage(
                                          id: record.id,
                                          recordLoader: widget.recordLoader,
                                          readStore: _readStore,
                                        )));
                            if (mounted && session == _tokens.sessionId) {
                              await _load();
                            }
                          },
                        ),
                    ]))),
      ]),
    );
  }
}

class _UnreadDot extends StatelessWidget {
  const _UnreadDot({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Semantics(
          label: label,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: const Color(0xFFFF3B30),
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.surface, width: 2),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x33FF3B30),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      );
}

class WorkerDetailPage extends StatefulWidget {
  const WorkerDetailPage({
    required this.id,
    this.recordLoader = getWorkerRepairApi,
    this.processor = processWorkerRepairApi,
    this.readStore,
    super.key,
  });
  final String id;
  final WorkerRepairReadStore? readStore;
  final Future<RepairRecord> Function(String id) recordLoader;
  final Future<RepairRecord> Function(RepairRecord record,
      {required bool complete, String result}) processor;
  @override
  State<WorkerDetailPage> createState() => _WorkerDetailPageState();
}

class _WorkerDetailPageState extends State<WorkerDetailPage> {
  RepairRecord? _record;
  final _result = TextEditingController();
  final _resultFocus = FocusNode();
  String? _resultError;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  void _rememberDisplayed(RepairRecord record, int session) {
    if (!WorkerRepairReadStore.needsAttention(record) ||
        record.workerId.isEmpty) {
      return;
    }
    // Opening a route is not enough: only mark a successfully rendered detail.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          session != tokenManager.sessionId ||
          !identical(_record, record) ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      unawaited(_saveViewed(record, session));
    });
  }

  Future<void> _saveViewed(RepairRecord record, int session) async {
    bool saved;
    try {
      saved =
          await (widget.readStore ?? workerRepairReadStore).markViewed(record);
    } on Object {
      saved = false;
    }
    if (!saved && mounted && session == tokenManager.sessionId) {
      await PromptAction.showWarning('查看记录保存失败，下次可能再次提醒');
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _result.dispose();
    _resultFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _saving) return;
    final session = tokenManager.sessionId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final record = await widget.recordLoader(widget.id);
      if (mounted && session == tokenManager.sessionId) {
        setState(() => _record = record);
        _rememberDisplayed(record, session);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _record = null;
          _error = describeError(error, fallback: '工单加载失败');
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _process() async {
    final record = _record;
    if (_saving || _loading || record == null) return;
    if (record.status == 2 && _result.text.trim().isEmpty) {
      setState(() => _resultError = '请填写处理结果后再完成维修');
      _resultFocus.requestFocus();
      await PromptAction.showWarning('请填写处理结果后再完成维修');
      return;
    }
    final session = tokenManager.sessionId;
    setState(() => _saving = true);
    try {
      final updated = await widget.processor(record,
          complete: record.status == 2, result: _result.text.trim());
      if (!mounted || session != tokenManager.sessionId) return;
      setState(() => _record = updated);
      _rememberDisplayed(updated, session);
      await PromptAction.showSuccess(updated.status == 3 ? '维修已完成' : '接单成功');
    } on Object catch (error) {
      if (mounted) {
        await PromptAction.showError(
            describeError(error, fallback: '操作失败，请刷新后重试'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('维修工单'), actions: <Widget>[
        IconButton(
            tooltip: '刷新工单',
            onPressed: _loading || _saving ? null : _load,
            icon: const Icon(Icons.refresh))
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : record == null
              ? Center(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                      Text(_error ?? '工单不存在'),
                      TextButton(onPressed: _load, child: const Text('重试'))
                    ]))
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 792),
                      child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: <Widget>[
                            RepairProgress(record: record),
                            const SizedBox(height: 12),
                            Text(record.repairItemName,
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 16),
                            SelectableText(
                                '房屋：${record.houseInfo}\n预约：${record.appointment}\n住户联系电话：${record.mobile}'),
                            const SizedBox(height: 16),
                            Text(record.description.isEmpty
                                ? '住户未填写补充描述'
                                : record.description),
                            const SizedBox(height: 20),
                            if (record.attachment.isNotEmpty)
                              RepairPhotos(urls: record.attachment),
                            if (record.status == 2)
                              Padding(
                                  padding: const EdgeInsets.only(top: 24),
                                  child: TextField(
                                      controller: _result,
                                      focusNode: _resultFocus,
                                      enabled: !_saving,
                                      onChanged: (_) {
                                        if (_resultError != null) {
                                          setState(() => _resultError = null);
                                        }
                                      },
                                      maxLength: 1000,
                                      maxLines: 3,
                                      decoration: InputDecoration(
                                          labelText: '处理结果（必填）',
                                          hintText: '请说明故障原因、处理措施和维修结果',
                                          alignLabelWithHint: true,
                                          border: const OutlineInputBorder(),
                                          errorText: _resultError))),
                          ]))),
      bottomNavigationBar:
          record != null && (record.status == 5 || record.status == 2)
              ? SafeArea(
                  child: Align(
                      heightFactor: 1,
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 792),
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                      onPressed:
                                          _saving || _loading ? null : _process,
                                      child: Text(_saving
                                          ? '正在提交…'
                                          : record.status == 5
                                              ? '接单'
                                              : '完成维修')))))))
              : null,
    );
  }
}
