import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/house.dart';
import '../../api/user.dart';
import '../../api/visitor.dart';
import '../../models/house.dart';
import '../../models/visitor.dart';
import '../../platform/visitor_pass_share.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/date_utils.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../utils/validators.dart';
import '../../utils/visitor_share_reminder.dart';
import '../../utils/visitor_submission_store.dart';
import '../../widgets/async_state_view.dart';
import '../../widgets/cached_image.dart';

class VisitorListPage extends StatefulWidget {
  const VisitorListPage({this.loader = getVisitorListApi, super.key});
  static const String routeName = visitorList;
  final VisitorListLoader loader;
  @override
  State<VisitorListPage> createState() => _VisitorListPageState();
}

class _VisitorListPageState extends State<VisitorListPage> {
  List<VisitorRecord> _records = const <VisitorRecord>[];
  bool _loading = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.loader();
      if (mounted) setState(() => _records = result);
    } on Object catch (error) {
      final msg = describeError(error, fallback: '获取访客记录失败，请重试');
      if (mounted) {
        setState(() => _error = msg);
        await AppPrompt.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(String route, [Object? arguments]) async {
    final bool result =
        await Navigator.pushNamed<bool>(context, route, arguments: arguments) ??
            false;
    if (mounted && result) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('访客记录')),
        body: Column(children: <Widget>[
          Expanded(
            child: AsyncStateView(
              isLoading: _loading,
              errorMessage: _error,
              onRetry: _load,
              hasContent: _records.isNotEmpty,
              builder: (_) => RefreshIndicator(
                onRefresh: _load,
                child: _records.isEmpty
                    ? ListView(children: const <Widget>[
                        SizedBox(height: 180),
                        Icon(Icons.people_outline,
                            size: 52, color: AppColors.divider),
                        SizedBox(height: 12),
                        Center(
                            child: Text('暂无访客记录',
                                style:
                                    TextStyle(color: AppColors.textTertiary))),
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: _records.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, index) {
                          final item = _records[index];
                          return Card(
                              child: ListTile(
                                  title: Text(
                                      item.name.isEmpty ? '访客邀请' : item.name),
                                  subtitle: Text(
                                      '${item.houseInfo}\n到访日期：${item.visitDate}'),
                                  isThreeLine: true,
                                  trailing: Text(item.statusText,
                                      style: const TextStyle(
                                          color: AppColors.accent)),
                                  onTap: item.id.isEmpty
                                      ? null
                                      : () => _open(VisitorDetailPage.routeName,
                                          item.id)));
                        },
                      ),
              ),
            ),
          ),
          SafeArea(
              top: false,
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton.icon(
                          onPressed: () => _open(VisitorFormPage.routeName),
                          icon: const Icon(Icons.person_add_alt_1),
                          label: const Text('新增访客邀请'))))),
        ]),
      );
}

Widget _buildVisitorPassPreview(String url) => CachedImage(
      imageUrl: url,
      fit: BoxFit.contain,
      errorWidget:
          const Center(child: Icon(Icons.broken_image_outlined, size: 48)),
    );

class VisitorDetailPage extends StatefulWidget {
  const VisitorDetailPage({
    this.loader = getVisitorDetailApi,
    this.imageLoader = loadVisitorPassImage,
    this.sharer = shareVisitorPassImage,
    this.shareSupported,
    this.previewBuilder = _buildVisitorPassPreview,
    super.key,
  });
  static const String routeName = visitorDetail;
  final VisitorDetailLoader loader;
  final VisitorPassImageLoader imageLoader;
  final VisitorPassSharer sharer;
  final bool? shareSupported;
  final Widget Function(String url) previewBuilder;
  @override
  State<VisitorDetailPage> createState() => _VisitorDetailPageState();
}

class _VisitorDetailPageState extends State<VisitorDetailPage>
    with WidgetsBindingObserver {
  final GlobalKey _shareButtonKey = GlobalKey();
  int _visibilityRevision = 0;
  String _id = '';
  VisitorRecord? _record;
  late final VisitorPassImageCache _imageCache =
      identical(widget.imageLoader, loadVisitorPassImage) &&
              identical(widget.sharer, shareVisitorPassImage)
          ? visitorPassImageCache
          : VisitorPassImageCache();
  bool _loading = false;
  bool _sharing = false;
  bool _sharePanelOpened = false;
  VisitorShareReminder? _shareReminder;
  final int _shareSession = tokenManager.sessionId;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_sharing && !_sharePanelOpened) _shareReminder?.interrupt();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _visibilityRevision++;
      if (_sharing && !_sharePanelOpened) _shareReminder?.interrupt();
      return;
    }
  }

  bool get _canPresentShare {
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        tokenManager.sessionId == _shareSession &&
        (state == null || state == AppLifecycleState.resumed) &&
        (ModalRoute.of(context)?.isCurrent ?? false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sharing &&
        !_sharePanelOpened &&
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      _visibilityRevision++;
      _shareReminder?.interrupt();
    }
    if (_id.isEmpty) {
      _id = ModalRoute.of(context)?.settings.arguments?.toString().trim() ?? '';
      if (_id.isEmpty) {
        _error = '访客参数不正确';
      } else {
        unawaited(_load());
      }
    }
  }

  Future<void> _load() async {
    if (_loading || _id.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.loader(_id);
      if (mounted) {
        setState(() {
          _record = result;
          if (!result.canShare) _imageCache.clear();
        });
      }
    } on Object catch (error) {
      final msg = describeError(error, fallback: '获取访客详情失败，请重试');
      if (mounted) {
        setState(() => _error = msg);
        await AppPrompt.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _share() async {
    if (_sharing || !_canPresentShare) return;
    final VisitorRecord? record = _record;
    if (record == null || !record.canShare) {
      await AppPrompt.showWarning('当前访客通行码不可分享');
      return;
    }
    setState(() => _sharing = true);
    _sharePanelOpened = false;
    final reminder = _shareReminder = VisitorShareReminder();
    final int visibilityRevision = _visibilityRevision;
    try {
      final current = record;
      final cacheKey = jsonEncode(
          [_shareSession, current.id, current.url, current.encryptedData]);
      final Uint8List bytes = await _imageCache.load(cacheKey, current.url,
          loader: widget.imageLoader,
          fileExists: identical(widget.sharer, shareVisitorPassImage)
              ? hasCachedVisitorPassImage
              : (_) async => true);
      if (!mounted ||
          !_canPresentShare ||
          visibilityRevision != _visibilityRevision) {
        reminder.interrupt();
        return;
      }
      final verified = await widget.loader(_id);
      if (!mounted ||
          !_canPresentShare ||
          visibilityRevision != _visibilityRevision) {
        reminder.interrupt();
        return;
      }
      setState(() => _record = verified);
      if (!verified.canShare ||
          verified.url != current.url ||
          verified.encryptedData != current.encryptedData) {
        _imageCache.clear();
        await AppPrompt.showWarning('通行码已更新或失效，请重新分享');
        return;
      }
      final RenderObject? render =
          _shareButtonKey.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) {
        reminder.interrupt();
        return;
      }
      final Offset position = render.localToGlobal(Offset.zero);
      final double ratio = MediaQuery.devicePixelRatioOf(context);
      final Rect anchor = Rect.fromLTWH(
          position.dx * ratio,
          position.dy * ratio,
          render.size.width * ratio,
          render.size.height * ratio);
      // From this point the native bridge owns the system panel. Losing focus is
      // expected and must not be reported as an interrupted preparation.
      _sharePanelOpened = true;
      await widget.sharer(bytes, anchor: anchor, cacheKey: cacheKey);
      // A closed panel does not prove that the recipient received the image.
    } on Object catch (error) {
      if (error is VisitorShareInterruptedException ||
          (!_sharePanelOpened &&
              (!_canPresentShare ||
                  visibilityRevision != _visibilityRevision))) {
        reminder.interrupt();
        return;
      }
      if (!_canPresentShare) return;
      await AppPrompt.showException(error, fallback: '通行码分享失败，请重试');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final VisitorRecord? item = _record;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('访客邀请详情')),
      bottomNavigationBar: item == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: _shareButtonKey,
                        onPressed: !_sharing &&
                                item.canShare &&
                                (widget.shareSupported ??
                                    supportsVisitorPassShare)
                            ? _share
                            : null,
                        icon: _sharing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.share_outlined),
                        label: Text(_sharing ? '正在分享…' : '分享通行码'),
                      ),
                    ),
                    if (!item.canShare ||
                        !(widget.shareSupported ??
                            supportsVisitorPassShare)) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(!item.canShare ? '暂无可分享的有效通行码' : '请在鸿蒙设备上分享通行码',
                          textAlign: TextAlign.center),
                    ],
                  ],
                ),
              ),
            ),
      body: AsyncStateView(
        isLoading: _loading,
        errorMessage: _error,
        onRetry: _load,
        hasContent: item != null,
        builder: (_) => item == null
            ? const SizedBox.shrink()
            : ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                _Info('到访房屋', item.houseInfo),
                                _Info('状态', item.statusText),
                                if (item.validTime > 0)
                                  _Info('有效时长', '${item.validTime}分钟'),
                                if (item.url.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 16),
                                  const Center(child: Text('访客通行码')),
                                  const SizedBox(height: 12),
                                  Center(
                                      child: SizedBox(
                                          width: 220,
                                          height: 220,
                                          child:
                                              widget.previewBuilder(item.url)))
                                ]
                              ])))
                ],
              ),
      ),
    );
  }
}

class VisitorFormPage extends StatefulWidget {
  const VisitorFormPage(
      {this.houseLoader = getHouseListApi,
      this.submitter = submitVisitorApi,
      this.userInfoLoader = getUserInfoApi,
      this.submissionLoader = getVisitorSubmissionApi,
      this.submissionCloser = closeVisitorSubmissionApi,
      this.submissionStore,
      super.key});
  static const String routeName = visitorForm;
  final HouseListLoader houseLoader;
  final SubmitVisitorLoader submitter;
  final UserInfoLoader userInfoLoader;
  final Future<VisitorSubmissionResult> Function(String) submissionLoader;
  final Future<VisitorSubmissionResult> Function(String) submissionCloser;
  final VisitorSubmissionStore? submissionStore;
  @override
  State<VisitorFormPage> createState() => _VisitorFormPageState();
}

class _VisitorFormPageState extends State<VisitorFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _mobile = TextEditingController();
  List<House> _houses = const <House>[];
  String? _houseId;
  DateTime? _date;
  int _gender = 1;
  bool _loading = false;
  bool _submitting = false;
  final int _session = tokenManager.sessionId;
  bool get _active => mounted && tokenManager.sessionId == _session;
  VisitorSubmissionStore get _store =>
      widget.submissionStore ?? visitorSubmissionStore;
  String _owner = '';
  bool _storageReady = false;
  bool _receiptResolved = false;
  VisitorRecord? _pending;
  String? _pendingMessage;
  String? _error;
  String? _nameServerError;
  String? _rejectedName;
  @override
  void initState() {
    super.initState();
    unawaited(_loadHouses());
  }

  @override
  void dispose() {
    _name.dispose();
    _mobile.dispose();
    super.dispose();
  }

  Future<void> _loadHouses() async {
    if (_loading || _submitting || !_active) return;
    setState(() {
      _loading = true;
      _error = null;
      _storageReady = false;
    });
    try {
      final user = await widget.userInfoLoader();
      if (!_active) return;
      if (user.id.trim().isEmpty) {
        throw const FormatException('账号信息缺少用户 ID，请重新加载');
      }
      _owner = user.id.trim();
      final pending = await _store.load(_owner);
      if (!_active) return;
      setState(() {
        _pending = pending;
        _storageReady = true;
        if (pending != null) {
          _houseId = pending.houseId;
          _name.text = pending.name;
          _mobile.text = pending.mobile;
          _gender = pending.gender;
          _date = DateTime.parse(pending.visitDate);
        }
      });
      final result = await widget.houseLoader();
      if (_active) setState(() => _houses = result);
    } on Object catch (error) {
      final msg = describeError(error, fallback: '加载邀请表单失败，请重试');
      if (_active) {
        setState(() => _error = msg);
        await AppPrompt.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate() async {
    if (_submitting || _pending != null || !_active) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastDate = today.add(const Duration(days: 365));
    final selected = _date ?? today;
    final date = await showDatePicker(
        context: context,
        initialDate: selected.isBefore(today)
            ? today
            : selected.isAfter(lastDate)
                ? lastDate
                : selected,
        firstDate: today,
        lastDate: lastDate);
    if (date != null && _active) setState(() => _date = date);
  }

  Future<void> _submit() async {
    if (_submitting ||
        _loading ||
        !_storageReady ||
        _pending != null ||
        !_active) {
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_date == null) {
      await AppPrompt.showWarning('请选择到访日期');
      return;
    }
    setState(() => _submitting = true);
    try {
      final pending = VisitorSubmissionStore.prepare(VisitorRecord(
          houseId: _houseId!,
          houseInfo:
              _houses.firstWhere((house) => house.id == _houseId).fullName,
          name: _name.text.trim(),
          gender: _gender,
          mobile: _mobile.text.trim(),
          visitDate: formatDate(_date!)));
      final saved = await _store.save(_owner, pending);
      if (!_active) return;
      if (!saved) {
        setState(() {
          _storageReady = false;
          _error = '提交回执未能保存，本次尚未发送，请重新加载';
        });
        return;
      }
      setState(() {
        _pending = pending;
        _pendingMessage = null;
      });
      await widget.submitter(pending);
      if (!_active) return;
      await _finishCreated();
    } on Object catch (error) {
      if (!_active) return;
      if (_pending != null && isDefiniteRequestRejection(error)) {
        final pending = _pending!;
        bool removed = false;
        try {
          removed = await _store.remove(_owner, pending.submissionId);
        } on Object {
          // Keep the receipt until persistence confirms that it was removed.
        }
        if (!_active) return;
        if (!removed) {
          setState(() => _pendingMessage = '请求已明确失败，但本机回执尚未清理；请再次查看提交结果');
          await AppPrompt.showWarning(_pendingMessage!);
          return;
        }
        setState(() {
          _pending = null;
          _pendingMessage = null;
          _receiptResolved = false;
          if (error is BusinessException && error.code == 40002 &&
              _name.text.trim() == pending.name) {
            _nameServerError = error.message;
            _rejectedName = pending.name;
          }
        });
        if (error is BusinessException && error.code == 40002 &&
            _name.text.trim() == pending.name) {
          return;
        }
        await AppPrompt.showException(error, fallback: '创建访客邀请失败，请重试');
        return;
      }
      if (_pending == null) {
        setState(() {
          _storageReady = false;
          _error = describeError(error, fallback: '提交回执保存失败，本次尚未发送，请重新加载');
        });
      }
      await AppPrompt.showException(error, fallback: '创建访客邀请失败，请重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<bool> _clearPending() async {
    final pending = _pending;
    if (pending == null || !_active) return false;
    final removed = await _store.remove(_owner, pending.submissionId);
    if (!_active) return false;
    if (!removed) throw const FormatException('本机提交回执尚未清理，请保留页面并再次查看提交结果');
    setState(() {
      _pending = null;
      _pendingMessage = null;
      _receiptResolved = false;
    });
    return true;
  }

  Future<void> _finishCreated() async {
    if (!_active) return;
    setState(() {
      _receiptResolved = true;
      _pendingMessage = '邀请已创建，本机回执尚未清理；清理失败时请再次查看提交结果';
    });
    if (!await _clearPending() || !_active) return;
    await AppPrompt.showSuccess('访客邀请已创建');
    if (mounted && _active) Navigator.pop(context, true);
  }

  Future<void> _handleResult(VisitorSubmissionResult result) async {
    if (!_active) return;
    switch (result.state) {
      case VisitorSubmissionState.created:
        await _finishCreated();
      case VisitorSubmissionState.closed:
        setState(() {
          _receiptResolved = true;
          _pendingMessage = '本次提交已停止，本机回执尚未清理；清理失败时请再次查看提交结果';
        });
        await _clearPending();
      case VisitorSubmissionState.unknown:
        setState(() => _pendingMessage = '暂未查到结果，原请求可能仍在处理；可按原内容重试或停止本次提交。');
    }
  }

  Future<void> _recoverSubmission(
      {bool retry = false, bool close = false}) async {
    final pending = _pending;
    if (_submitting || pending == null || !_active) return;
    setState(() => _submitting = true);
    try {
      if (retry || close) {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                  title: Text(close ? '停止本次提交' : '按原内容重试'),
                  content: Text(close
                      ? '若邀请已创建，将找回原邀请；否则停止旧请求，确认停止后才能修改内容。此操作不会取消已创建的邀请。'
                      : '将使用已保存的原内容与同一提交回执重试，不会创建第二份邀请。'),
                  actions: <Widget>[
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('先不操作')),
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: Text(close ? '确认停止' : '确认重试')),
                  ],
                ));
        if (!_active || confirmed != true) return;
      }
      if (retry) {
        await widget.submitter(pending);
        if (_active) await _finishCreated();
      } else {
        final result = await (close
            ? widget.submissionCloser
            : widget.submissionLoader)(pending.submissionId);
        if (_active) await _handleResult(result);
      }
    } on Object catch (error) {
      if (_active) {
        await AppPrompt.showException(error, fallback: '尚未确认提交结果，请保留回执后重试');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _buildPending(VisitorRecord pending) => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text('已保存一份待确认的访客提交，确认结果前不能创建另一份邀请。'),
          const SizedBox(height: 12),
          _Info(
              '到访房屋', pending.houseInfo.isEmpty ? '已保存的房屋' : pending.houseInfo),
          _Info('访客姓名', pending.name),
          _Info('访客手机号', pending.mobile),
          _Info('到访日期', pending.visitDate),
          if (_pendingMessage != null) Text(_pendingMessage!),
          if (_submitting) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: _submitting ? null : _recoverSubmission,
              child: const Text('查看提交结果')),
          OutlinedButton(
              onPressed: _submitting || _receiptResolved
                  ? null
                  : () => _recoverSubmission(retry: true),
              child: const Text('按原内容重试')),
          TextButton(
              onPressed:
                  _submitting ? null : () => _recoverSubmission(close: true),
              child: const Text('停止本次提交')),
        ],
      );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: tokenManager.sessionChanges,
        builder: (context, session, _) => session == _session
            ? _buildFormPage()
            : Scaffold(
                appBar: AppBar(title: const Text('新增访客邀请')),
                body: const Center(child: Text('登录账号已变化，请退出后重新打开'))),
      );

  Widget _buildFormPage() => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('新增访客邀请')),
      body: _pending != null
          ? _buildPending(_pending!)
          : AsyncStateView(
              isLoading: _loading,
              errorMessage: _error,
              onRetry: _loadHouses,
              hasContent: _storageReady && _houses.isNotEmpty,
              builder: (_) => Form(
                  key: _formKey,
                  child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: <Widget>[
                        DropdownButtonFormField<String>(
                            initialValue:
                                _houses.any((house) => house.id == _houseId)
                                    ? _houseId
                                    : null,
                            decoration:
                                const InputDecoration(labelText: '到访房屋'),
                            validator: (v) => v == null ? '请选择到访房屋' : null,
                            items: _houses
                                .map((house) => DropdownMenuItem(
                                    value: house.id,
                                    child: Text(house.fullName)))
                                .toList(),
                            onChanged: _submitting
                                ? null
                                : (value) => setState(() => _houseId = value)),
                        const SizedBox(height: 14),
                        TextFormField(
                            controller: _name,
                            enabled: !_submitting,
                            maxLength: 100,
                            onChanged: (_) {
                              if (_nameServerError != null) {
                                setState(() {
                                  _nameServerError = null;
                                  _rejectedName = null;
                                });
                              }
                            },
                            decoration:
                                const InputDecoration(labelText: '访客姓名'),
                            autovalidateMode: _nameServerError != null
                                ? AutovalidateMode.always
                                : AutovalidateMode.onUserInteraction,
                            validator: (value) => value?.trim() == _rejectedName
                                ? _nameServerError
                                : Validators.required('请输入访客姓名').validate(value)),
                        const SizedBox(height: 14),
                        DropdownButtonFormField<int>(
                            initialValue: _gender,
                            decoration:
                                const InputDecoration(labelText: '访客性别'),
                            items: const <DropdownMenuItem<int>>[
                              DropdownMenuItem(value: 1, child: Text('男')),
                              DropdownMenuItem(value: 0, child: Text('女'))
                            ],
                            onChanged: _submitting
                                ? null
                                : (value) =>
                                    setState(() => _gender = value ?? 1)),
                        const SizedBox(height: 14),
                        TextFormField(
                            controller: _mobile,
                            enabled: !_submitting,
                            keyboardType: TextInputType.phone,
                            decoration:
                                const InputDecoration(labelText: '访客手机号'),
                            validator: Validators.required('请输入访客手机号')
                                .chain(Validators.mobile())
                                .validate),
                        const SizedBox(height: 14),
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                                _date == null ? '请选择到访日期' : formatDate(_date!)),
                            trailing: const Icon(Icons.calendar_today_outlined),
                            onTap: _submitting ? null : _pickDate),
                        const SizedBox(height: 28),
                        FilledButton(
                            onPressed:
                                _submitting || !_storageReady ? null : _submit,
                            child: _submitting
                                ? const CircularProgressIndicator()
                                : const Text('创建邀请'))
                      ]))));
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: <Widget>[
        SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(color: AppColors.textTertiary))),
        Expanded(child: Text(value.isEmpty ? '暂无' : value))
      ]));
}
