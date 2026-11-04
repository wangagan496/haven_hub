import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/house.dart';
import '../../models/house.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../widgets/async_state_view.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/house_status_tag.dart';
import '../../widgets/section_title.dart';
import 'house_form.dart';

class HouseDetail extends StatefulWidget {
  const HouseDetail({
    this.houseDetailLoader = getHouseDetailApi,
    this.deleteHouseLoader = deleteHouseApi,
    super.key,
  });

  static const String routeName = houseDetail;

  final HouseDetailLoader houseDetailLoader;
  final DeleteHouseLoader deleteHouseLoader;

  @override
  State<HouseDetail> createState() => _HouseDetailState();
}

class _HouseDetailState extends State<HouseDetail> {
  bool _didReadRouteArguments = false;
  bool _isLoading = false;
  bool _isDeleting = false;
  bool _isConfirming = false;
  bool _isEditing = false;
  bool _needsRefresh = false;
  final int _session = tokenManager.sessionId;
  bool get _active => mounted && tokenManager.sessionId == _session;
  bool get _busy => _isLoading || _isDeleting || _isConfirming || _isEditing;
  String _houseId = '';
  String? _errorMessage;
  House? _detail;

  @override
  void initState() {
    super.initState();
    tokenManager.sessionChanges.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (!mounted || _active) return;
    setState(() {
      _detail = null;
      _isLoading = false;
      _errorMessage = '登录账号已变化，请返回房屋列表重新进入';
    });
  }

  @override
  void dispose() {
    tokenManager.sessionChanges.removeListener(_onSessionChanged);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didReadRouteArguments) return;
    _didReadRouteArguments = true;

    final Object? arguments = ModalRoute.of(context)?.settings.arguments;
    _houseId = switch (arguments) {
      String() => arguments.trim(),
      HouseDetailArguments() => arguments.houseId.trim(),
      Map<dynamic, dynamic>() => arguments['id']?.toString().trim() ?? '',
      _ => '',
    };
    if (_houseId.isEmpty) {
      setState(() => _errorMessage = '房屋参数不正确');
      return;
    }

    unawaited(_loadDetail());
  }

  Future<void> _loadDetail({bool forceRefresh = false}) async {
    if (_busy || _houseId.isEmpty || !_active) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final House detail = (forceRefresh || _needsRefresh) &&
              widget.houseDetailLoader == getHouseDetailApi
          ? await getHouseDetailApi(_houseId, forceRefresh: true)
          : await widget.houseDetailLoader(_houseId);
      if (!_active) return;
      if (detail.id != _houseId) {
        throw const FormatException('房屋详情不匹配，请重新加载');
      }
      setState(() {
        _detail = detail;
        _needsRefresh = false;
      });
    } on Object catch (error) {
      if (!_active) return;
      final String msg = describeError(
        error,
        fallback: '获取房屋详情失败，请重试',
      );
      setState(() {
        _errorMessage = msg;
        _needsRefresh = true;
        if ((error is NetworkException && error.statusCode == 404) ||
            (error is BusinessException && error.code == 40400)) {
          _detail = null;
        }
      });
      await AppPrompt.showError(msg);
    } finally {
      if (_active) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteHouse() async {
    final House? detail = _detail;
    if (!_active ||
        _busy ||
        _needsRefresh ||
        _errorMessage != null ||
        detail == null ||
        _houseId.isEmpty) {
      return;
    }

    setState(() => _isConfirming = true);
    try {
      final bool confirmed = await showDialog<bool>(
            context: context,
            builder: (BuildContext dialogContext) {
              return AlertDialog(
                title: const Text('温馨提示'),
                content: Text(
                    '将删除${detail.fullName}（业主：${detail.name}），删除后无法恢复，确定继续吗？'),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('确认'),
                  ),
                ],
              );
            },
          ) ??
          false;
      if (!confirmed || !_active) return;
      setState(() {
        _isConfirming = false;
        _isDeleting = true;
      });
      await widget.deleteHouseLoader(detail.id, revision: detail.revision);
      if (!_active) return;

      await AppPrompt.showSuccess('删除成功');
      if (!mounted || !_active) return;

      Navigator.pop(context, true);
    } on Object catch (error) {
      if (!_active) return;
      setState(() => _needsRefresh = true);
      final String msg = describeError(error, fallback: '删除房屋失败，请重试');
      await AppPrompt.showError(msg);
    } finally {
      if (mounted) {
        setState(() {
          _isDeleting = false;
          _isConfirming = false;
        });
      }
    }
  }

  Future<void> _editHouse() async {
    if (!_active ||
        _busy ||
        _needsRefresh ||
        _errorMessage != null ||
        _houseId.isEmpty) {
      return;
    }
    setState(() => _isEditing = true);
    final Object? result;
    try {
      result = await Navigator.pushNamed<Object?>(
        context,
        HouseForm.routeName,
        arguments: _houseId,
      );
    } finally {
      if (mounted) setState(() => _isEditing = false);
    }
    if (!_active) return;
    if (result == true) {
      await _loadDetail();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('房屋详情'),
        actions: <Widget>[
          IconButton(
              tooltip: '刷新审核结果',
              onPressed: _busy || !_active
                  ? null
                  : () => _loadDetail(forceRefresh: true),
              icon: const Icon(Icons.refresh))
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            if (_needsRefresh && _active && _detail != null)
              MaterialBanner(
                content: const Text('请先刷新核对房屋资料，再决定是否删除。'),
                actions: <Widget>[
                  TextButton(
                    onPressed:
                        _busy ? null : () => _loadDetail(forceRefresh: true),
                    child: const Text('刷新房屋资料'),
                  ),
                ],
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      bottomNavigationBar: _detail == null ? null : _buildActions(),
    );
  }

  Widget _buildBody() {
    return AsyncStateView(
      isLoading: _isLoading,
      errorMessage: _errorMessage,
      onRetry: _active ? () => _loadDetail(forceRefresh: true) : null,
      hasContent: _detail != null,
      builder: (BuildContext context) {
        final House? detail = _detail;
        if (detail == null) return const SizedBox.shrink();

        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: <Widget>[
            const SectionTitle('房屋信息'),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      detail.fullName.isEmpty ? '暂无房屋信息' : detail.fullName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  HouseStatusTag(status: detail.status),
                ],
              ),
            ),
            const SectionTitle('业主信息'),
            if (detail.isRejected)
              _DetailRow(
                  label: '打回原因',
                  value: detail.reviewReason.isEmpty
                      ? '请联系物业了解原因'
                      : detail.reviewReason),
            _DetailRow(label: '房间号', value: detail.room),
            const Divider(height: 1, indent: 16),
            _DetailRow(label: '业主', value: detail.name),
            const Divider(height: 1, indent: 16),
            _DetailRow(label: '手机号', value: detail.mobile),
            const SectionTitle('本人身份证照片'),
            _IdentityPhoto(
              title: '人像面',
              imageUrl: detail.idcardFrontUrl,
            ),
            const SizedBox(height: 12),
            _IdentityPhoto(
              title: '国徽面',
              imageUrl: detail.idcardBackUrl,
            ),
          ],
        );
      },
    );
  }

  Widget _buildActions() {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    _busy || _needsRefresh || _errorMessage != null || !_active
                        ? null
                        : _deleteHouse,
                icon: _isDeleting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline_rounded),
                label: const Text('删除房屋'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  minimumSize: const Size(0, 48),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    _busy || _needsRefresh || _errorMessage != null || !_active
                        ? null
                        : _editHouse,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('修改房屋'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.textTertiary),
            ),
          ),
          Expanded(child: Text(value.isEmpty ? '暂无' : value)),
        ],
      ),
    );
  }
}

class _IdentityPhoto extends StatelessWidget {
  const _IdentityPhoto({required this.title, required this.imageUrl});

  final String title;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 10),
          AspectRatio(
            aspectRatio: 1.58,
            child: imageUrl.isEmpty
                ? const ColoredBox(
                    color: AppColors.placeholder,
                    child: Center(
                      child: Icon(
                        Icons.image_not_supported_outlined,
                        size: 42,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  )
                : CachedImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.contain,
                    errorWidget: const ColoredBox(
                      color: AppColors.placeholder,
                      child: Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          size: 42,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
