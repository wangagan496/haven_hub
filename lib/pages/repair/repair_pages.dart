import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/house.dart';
import '../../api/repair.dart';
import '../../models/house.dart';
import '../../models/repair.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/date_utils.dart';
import '../../utils/toast.dart';
import '../../utils/validators.dart';
import '../../widgets/async_state_view.dart';

class RepairListPage extends StatefulWidget {
  const RepairListPage({this.loader = getRepairListApi, super.key});
  static const String routeName = AppRoutes.repairList;
  final RepairListLoader loader;
  @override
  State<RepairListPage> createState() => _RepairListPageState();
}

class _RepairListPageState extends State<RepairListPage> {
  List<RepairRecord> _records = const <RepairRecord>[];
  bool _isLoading = false;
  String? _errorMessage;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final records = await widget.loader();
      if (!mounted) return;
      setState(() => _records = records);
    } on Object catch (error) {
      final msg = describeError(error, fallback: '获取报修列表失败，请重试');
      if (!mounted) return;
      setState(() => _errorMessage = msg);
      await PromptAction.showError(msg);
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
        appBar: AppBar(title: const Text('我的报修')),
        body: Column(children: <Widget>[
          Expanded(
              child: AsyncStateView(
            isLoading: _isLoading,
            errorMessage: _errorMessage,
            onRetry: _load,
            hasContent: _records.isNotEmpty,
            builder: (BuildContext context) => RefreshIndicator(
              onRefresh: _load,
              child: _records.isEmpty
                  ? ListView(children: const <Widget>[
                      SizedBox(height: 180),
                      Icon(Icons.build_outlined,
                          size: 52, color: AppColors.divider),
                      SizedBox(height: 12),
                      Center(
                          child: Text('暂无报修记录',
                              style: TextStyle(color: AppColors.textTertiary)))
                    ])
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _records.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, int index) {
                        final item = _records[index];
                        return Card(
                            child: ListTile(
                          title: Text(item.repairItemName.isEmpty
                              ? '维修服务'
                              : item.repairItemName),
                          subtitle: Text('${item.appointment}\n${item.mobile}'),
                          isThreeLine: true,
                          trailing: Text(item.statusText,
                              style: const TextStyle(color: AppColors.accent)),
                          onTap: item.id.isEmpty
                              ? null
                              : () =>
                                  _open(RepairDetailPage.routeName, item.id),
                        ));
                      }),
            ),
          )),
          SafeArea(
              top: false,
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton.icon(
                          onPressed: () => _open(RepairFormPage.routeName),
                          icon: const Icon(Icons.add),
                          label: const Text('新增报修'))))),
        ]),
      );
}

class RepairDetailPage extends StatefulWidget {
  const RepairDetailPage(
      {this.loader = getRepairDetailApi,
      this.cancelLoader = cancelRepairApi,
      super.key});
  static const String routeName = AppRoutes.repairDetail;
  final RepairDetailLoader loader;
  final CancelRepairLoader cancelLoader;
  @override
  State<RepairDetailPage> createState() => _RepairDetailPageState();
}

class _RepairDetailPageState extends State<RepairDetailPage> {
  String _id = '';
  RepairRecord? _record;
  String? _error;
  bool _loading = false;
  bool _cancelling = false;
  bool _confirming = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_id.isEmpty) {
      _id = ModalRoute.of(context)?.settings.arguments?.toString().trim() ?? '';
      if (_id.isEmpty) {
        _error = '报修参数不正确';
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
      final value = await widget.loader(_id);
      if (mounted) setState(() => _record = value);
    } on Object catch (error) {
      final msg = describeError(error, fallback: '获取报修详情失败，请重试');
      if (mounted) {
        setState(() => _error = msg);
        await PromptAction.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cancel() async {
    if (_cancelling || _confirming || _id.isEmpty) return;
    // The confirmation dialog is part of the operation too.
    setState(() => _confirming = true);
    try {
      final confirmed = await showDialog<bool>(
              context: context,
              builder: (dialog) => AlertDialog(
                      title: const Text('取消报修'),
                      content: const Text('确定取消该报修申请吗？'),
                      actions: <Widget>[
                        TextButton(
                            onPressed: () => Navigator.pop(dialog, false),
                            child: const Text('返回')),
                        FilledButton(
                            onPressed: () => Navigator.pop(dialog, true),
                            child: const Text('确认取消'))
                      ])) ??
          false;
      if (!confirmed || !mounted) return;
      setState(() => _cancelling = true);
      await widget.cancelLoader(_id);
      if (!mounted) return;
      await PromptAction.showSuccess('报修已取消');
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (!mounted) return;
      await PromptAction.showError(
          describeError(error, fallback: '取消报修失败，请重试'));
    } finally {
      if (mounted) {
        setState(() {
          _cancelling = false;
          _confirming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final RepairRecord? record = _record;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('报修详情')),
      body: AsyncStateView(
        isLoading: _loading,
        errorMessage: _error,
        onRetry: _load,
        hasContent: record != null,
        builder: (_) => record == null
            ? const SizedBox.shrink()
            : ListView(children: <Widget>[
                const _Section('报修信息'),
                _Row('维修项目', record.repairItemName),
                _Row('预约时间', record.appointment),
                _Row('联系电话', record.mobile),
                _Row('报修房屋', record.houseInfo),
                _Row('处理状态', record.statusText),
                const _Section('故障描述'),
                _Row('描述', record.description),
              ]),
      ),
      bottomNavigationBar: record?.canCancel != true
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: _cancelling || _confirming ? null : _cancel,
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.danger),
                  child: _cancelling
                      ? const CircularProgressIndicator()
                      : const Text('取消报修'),
                ),
              ),
            ),
    );
  }
}

class RepairFormPage extends StatefulWidget {
  const RepairFormPage(
      {this.houseLoader = getHouseListApi,
      this.itemLoader = getRepairItemsApi,
      this.submitter = submitRepairApi,
      super.key});
  static const String routeName = AppRoutes.repairForm;
  final HouseListLoader houseLoader;
  final RepairItemLoader itemLoader;
  final SubmitRepairLoader submitter;
  @override
  State<RepairFormPage> createState() => _RepairFormPageState();
}

class _RepairFormPageState extends State<RepairFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _mobile = TextEditingController();
  final _description = TextEditingController();
  List<House> _houses = const <House>[];
  List<RepairItem> _items = const <RepairItem>[];
  String? _houseId;
  String? _itemId;
  DateTime? _date;
  bool _loading = false;
  bool _submitting = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_loadOptions());
  }

  @override
  void dispose() {
    _mobile.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await Future.wait(
          <Future<Object>>[widget.houseLoader(), widget.itemLoader()]);
      if (!mounted) return;
      setState(() {
        _houses = values[0] as List<House>;
        _items = values[1] as List<RepairItem>;
      });
    } on Object catch (error) {
      final msg = describeError(error, fallback: '加载报修选项失败，请重试');
      if (mounted) {
        setState(() => _error = msg);
        await PromptAction.showError(msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate() async {
    final selected = await showDatePicker(
        context: context,
        initialDate: _date ?? DateTime.now(),
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 365)));
    if (selected != null && mounted) setState(() => _date = selected);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_date == null) {
      await PromptAction.showWarning('请选择预约日期');
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.submitter(RepairRecord(
          houseId: _houseId!,
          repairItemId: _itemId!,
          mobile: _mobile.text.trim(),
          appointment: formatDate(_date!),
          description: _description.text.trim()));
      if (!mounted) return;
      await PromptAction.showSuccess('报修提交成功');
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (!mounted) return;
      await PromptAction.showError(
          describeError(error, fallback: '报修提交失败，请重试'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('新增报修')),
      body: AsyncStateView(
          isLoading: _loading,
          errorMessage: _error,
          onRetry: _loadOptions,
          hasContent: _houses.isNotEmpty && _items.isNotEmpty,
          builder: (_) => Form(
              key: _formKey,
              child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: <Widget>[
                    DropdownButtonFormField<String>(
                        initialValue: _houseId,
                        decoration: const InputDecoration(labelText: '报修房屋'),
                        validator: (v) => v == null ? '请选择报修房屋' : null,
                        items: _houses
                            .map((house) => DropdownMenuItem(
                                value: house.id, child: Text(house.fullName)))
                            .toList(),
                        onChanged: (value) => setState(() => _houseId = value)),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                        initialValue: _itemId,
                        decoration: const InputDecoration(labelText: '维修项目'),
                        validator: (v) => v == null ? '请选择维修项目' : null,
                        items: _items
                            .map((item) => DropdownMenuItem(
                                value: item.id, child: Text(item.name)))
                            .toList(),
                        onChanged: (value) => setState(() => _itemId = value)),
                    const SizedBox(height: 14),
                    TextFormField(
                        controller: _mobile,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(labelText: '联系电话'),
                        validator: Validators.required('请输入联系电话')
                            .chain(Validators.mobile())
                            .validate),
                    const SizedBox(height: 14),
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                            _date == null ? '请选择预约日期' : formatDate(_date!)),
                        trailing: const Icon(Icons.calendar_today_outlined),
                        onTap: _pickDate),
                    TextFormField(
                        controller: _description,
                        decoration:
                            const InputDecoration(labelText: '故障描述（选填）'),
                        maxLines: 4),
                    const SizedBox(height: 28),
                    FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const CircularProgressIndicator()
                            : const Text('提交报修'))
                  ]))));
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(text,
          style: const TextStyle(
              fontWeight: FontWeight.w600, color: AppColors.textSecondary)));
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      child: Row(children: <Widget>[
        SizedBox(
            width: 82,
            child: Text(label,
                style: const TextStyle(color: AppColors.textTertiary))),
        Expanded(child: Text(value.isEmpty ? '暂无' : value))
      ]));
}
