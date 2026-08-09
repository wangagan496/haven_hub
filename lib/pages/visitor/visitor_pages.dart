import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/house.dart';
import '../../api/visitor.dart';
import '../../models/house.dart';
import '../../models/visitor.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/date_utils.dart';
import '../../utils/toast.dart';
import '../../utils/validators.dart';
import '../../widgets/async_state_view.dart';
import '../../widgets/cached_image.dart';

class VisitorListPage extends StatefulWidget {
  const VisitorListPage({this.loader = getVisitorListApi, super.key});
  static const String routeName = AppRoutes.visitorList;
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
        await PromptAction.showError(msg);
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

class VisitorDetailPage extends StatefulWidget {
  const VisitorDetailPage({this.loader = getVisitorDetailApi, super.key});
  static const String routeName = AppRoutes.visitorDetail;
  final VisitorDetailLoader loader;
  @override
  State<VisitorDetailPage> createState() => _VisitorDetailPageState();
}

class _VisitorDetailPageState extends State<VisitorDetailPage> {
  String _id = '';
  VisitorRecord? _record;
  bool _loading = false;
  String? _error;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
      if (mounted) setState(() => _record = result);
    } on Object catch (error) {
      final msg = describeError(error, fallback: '获取访客详情失败，请重试');
      if (mounted) {
        setState(() => _error = msg);
        await PromptAction.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final VisitorRecord? item = _record;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('访客邀请详情')),
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
                                          child: CachedImage(
                                              imageUrl: item.url,
                                              fit: BoxFit.contain,
                                              errorWidget: const Center(
                                                  child: Icon(
                                                      Icons
                                                          .broken_image_outlined,
                                                      size: 48)))))
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
      super.key});
  static const String routeName = AppRoutes.visitorForm;
  final HouseListLoader houseLoader;
  final SubmitVisitorLoader submitter;
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
  String? _error;
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
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.houseLoader();
      if (mounted) setState(() => _houses = result);
    } on Object catch (error) {
      final msg = describeError(error, fallback: '加载房屋失败，请重试');
      if (mounted) {
        setState(() => _error = msg);
        await PromptAction.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
        context: context,
        initialDate: _date ?? DateTime.now(),
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 365)));
    if (date != null && mounted) setState(() => _date = date);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_date == null) {
      await PromptAction.showWarning('请选择到访日期');
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.submitter(VisitorRecord(
          houseId: _houseId!,
          name: _name.text.trim(),
          gender: _gender,
          mobile: _mobile.text.trim(),
          visitDate: formatDate(_date!)));
      if (!mounted) return;
      await PromptAction.showSuccess('访客邀请已创建');
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      await PromptAction.showError(
          describeError(error, fallback: '创建访客邀请失败，请重试'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('新增访客邀请')),
      body: AsyncStateView(
          isLoading: _loading,
          errorMessage: _error,
          onRetry: _loadHouses,
          hasContent: _houses.isNotEmpty,
          builder: (_) => Form(
              key: _formKey,
              child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: <Widget>[
                    DropdownButtonFormField<String>(
                        initialValue: _houseId,
                        decoration: const InputDecoration(labelText: '到访房屋'),
                        validator: (v) => v == null ? '请选择到访房屋' : null,
                        items: _houses
                            .map((house) => DropdownMenuItem(
                                value: house.id, child: Text(house.fullName)))
                            .toList(),
                        onChanged: (value) => setState(() => _houseId = value)),
                    const SizedBox(height: 14),
                    TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: '访客姓名'),
                        validator: Validators.required('请输入访客姓名').validate),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<int>(
                        initialValue: _gender,
                        decoration: const InputDecoration(labelText: '访客性别'),
                        items: const <DropdownMenuItem<int>>[
                          DropdownMenuItem(value: 1, child: Text('男')),
                          DropdownMenuItem(value: 0, child: Text('女'))
                        ],
                        onChanged: (value) =>
                            setState(() => _gender = value ?? 1)),
                    const SizedBox(height: 14),
                    TextFormField(
                        controller: _mobile,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: '访客手机号'),
                        validator: Validators.required('请输入访客手机号')
                            .chain(Validators.mobile())
                            .validate),
                    const SizedBox(height: 14),
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_date == null
                            ? '请选择到访日期'
                            : formatDate(_date!)),
                        trailing: const Icon(Icons.calendar_today_outlined),
                        onTap: _pickDate),
                    const SizedBox(height: 28),
                    FilledButton(
                        onPressed: _submitting ? null : _submit,
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
