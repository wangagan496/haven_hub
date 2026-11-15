import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart' show GetBuilder;

import '../../api/house.dart';
import '../../api/user.dart';
import '../../controller/build_controller.dart';
import '../../models/house.dart';
import '../../models/user_info.dart';
import '../../router/app_routes.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_exception.dart';
import '../../utils/house_submission_store.dart';
import '../../utils/toast.dart';
import '../../utils/token_manager.dart';
import '../../widgets/async_state_view.dart';
import '../location/location_list.dart';
import 'components/house_item.dart';
import 'house_detail.dart';

class HouseList extends StatefulWidget {
  const HouseList({
    this.houseListLoader = getHouseListApi,
    this.userInfoLoader = getUserInfoApi,
    this.submissionStore,
    super.key,
  });

  static const String routeName = houseList;

  final HouseListLoader houseListLoader;
  final UserInfoLoader userInfoLoader;
  final HouseSubmissionStore? submissionStore;

  @override
  State<HouseList> createState() => _HouseListState();
}

class _HouseListState extends State<HouseList> {
  List<House> _houses = const <House>[];
  bool _isLoading = false;
  String? _errorMessage;
  bool _checkingSubmission = true;
  bool _loadingSubmission = false;
  String? _submissionError;
  HouseSubmission? _pendingSubmission;
  final int _session = tokenManager.sessionId;
  HouseSubmissionStore get _submissionStore =>
      widget.submissionStore ?? houseSubmissionStore;

  @override
  void initState() {
    super.initState();
    tokenManager.sessionChanges.addListener(_onSessionChanged);
    unawaited(_loadHouseList());
    unawaited(_loadPendingSubmission());
  }

  void _onSessionChanged() {
    if (!mounted || tokenManager.sessionId == _session) return;
    setState(() {
      _pendingSubmission = null;
      _checkingSubmission = false;
      _submissionError = '登录状态已变化，请重新进入房屋列表';
    });
  }

  @override
  void dispose() {
    tokenManager.sessionChanges.removeListener(_onSessionChanged);
    super.dispose();
  }

  Future<void> _loadPendingSubmission() async {
    if (_loadingSubmission || tokenManager.sessionId != _session) return;
    final int sessionId = tokenManager.sessionId;
    setState(() {
      _loadingSubmission = true;
      _submissionError = null;
    });
    try {
      final UserInfo user = await widget.userInfoLoader();
      if (!mounted || tokenManager.sessionId != sessionId) return;
      if (user.id.trim().isEmpty) throw const FormatException('账号信息缺少用户 ID');
      final HouseSubmission? pending = await _submissionStore.load(user.id.trim());
      if (!mounted || tokenManager.sessionId != sessionId) return;
      setState(() {
        _pendingSubmission = pending;
        _checkingSubmission = false;
      });
    } on Object catch (error) {
      if (mounted && tokenManager.sessionId == sessionId) {
        setState(() {
          _submissionError = describeError(error, fallback: '待确认房屋提交状态读取失败');
          _checkingSubmission = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingSubmission = false);
    }
  }

  Future<void> _viewPendingSubmission() async {
    if (tokenManager.sessionId != _session) return;
    final HouseSubmission? pending = _pendingSubmission;
    if (pending == null) return;
    BuildController.instance().restoreSubmissionDraft(pending.draftId, pending.house);
    await Navigator.pushNamed<void>(context, houseForm,
        arguments: HouseFormArguments(mode: HouseFormMode.create, draftId: pending.draftId));
    if (!mounted) return;
    await _loadPendingSubmission();
    await _loadHouseList();
  }

  Future<void> _addHouse() async {
    if (_checkingSubmission || _loadingSubmission || tokenManager.sessionId != _session) return;
    await _loadPendingSubmission();
    if (!mounted || tokenManager.sessionId != _session) return;
    if (_pendingSubmission != null) {
      await AppPrompt.showWarning('当前账号有一份待确认的房屋提交，请先查看结果');
      if (mounted) await _viewPendingSubmission();
      return;
    }
    if (_submissionError != null) {
      await AppPrompt.showWarning('暂时无法确认是否有待处理的房屋提交，请先重新加载状态');
      return;
    }
    final id = BuildController.instance().startDraft();
    await Navigator.pushNamed<void>(context, LocationList.routeName,
        arguments: HouseSelectionArguments(id));
    if (mounted) await _loadPendingSubmission();
  }

  Future<void> _loadHouseList() async {
    if (_isLoading) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final List<House> result = await widget.houseListLoader();
      if (!mounted) {
        return;
      }
      setState(() {
        _houses = result;
      });
    } on Object catch (error) {
      final String message = describeError(
        error,
        fallback: '获取房屋列表失败，请重试',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = message;
      });
      await AppPrompt.showError(message);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _openHouseDetail(House house) async {
    if (house.id.isEmpty) {
      await AppPrompt.showWarning('房屋参数不正确');
      return;
    }

    await Navigator.pushNamed<void>(
      context,
      HouseDetail.routeName,
      arguments: house.id,
    );
    if (!mounted) return;
    await _loadHouseList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('我的房屋'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            if (_checkingSubmission || _submissionError != null || _pendingSubmission != null)
              _buildSubmissionNotice(),
            Expanded(child: _buildBody()),
            GetBuilder<BuildController>(init: BuildController.instance(), autoRemove: false,
              builder: (controller) => TextButton.icon(
                onPressed: () => Navigator.pushNamed<void>(context, houseDrafts),
                icon: const Icon(Icons.drafts_outlined),
                label: Text('选房草稿（${controller.drafts.length}）'),
              )),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _checkingSubmission || _loadingSubmission ? null : _addHouse,
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('添加房屋'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    backgroundColor: const Color(0xFFFBF8FF),
                    side: const BorderSide(color: Color(0xFFE8DFF3)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmissionNotice() {
    if (_checkingSubmission || _loadingSubmission) {
      return const LinearProgressIndicator();
    }
    if (_submissionError != null) {
      return Material(
        color: Colors.white,
        child: ListTile(
          title: const Text('待确认房屋提交状态暂不可用'),
          subtitle: Text(_submissionError!),
          trailing: TextButton(onPressed: _loadPendingSubmission, child: const Text('重试')),
        ),
      );
    }
    final HouseSubmission? pending = _pendingSubmission;
    if (pending == null) return const SizedBox.shrink();
    return Material(
      color: Colors.white,
      child: ListTile(
        leading: const Icon(Icons.pending_actions, color: AppColors.accent),
        title: const Text('有一份待确认的房屋提交'),
        subtitle: Text(pending.house.fullName),
        trailing: TextButton(onPressed: _viewPendingSubmission, child: const Text('查看结果')),
      ),
    );
  }

  Widget _buildBody() {
    return AsyncStateView(
      isLoading: _isLoading,
      errorMessage: _errorMessage,
      onRetry: _loadHouseList,
      hasContent: _houses.isNotEmpty,
      builder: (BuildContext context) {
        if (_houses.isEmpty) {
          return RefreshIndicator(
            onRefresh: _loadHouseList,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const <Widget>[
                SizedBox(height: 160),
                Icon(
                  Icons.home_outlined,
                  size: 52,
                  color: AppColors.divider,
                ),
                SizedBox(height: 12),
                Center(
                  child: Text(
                    '暂无房屋',
                    style: TextStyle(color: AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: _loadHouseList,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            itemCount: _houses.length,
            itemBuilder: (BuildContext context, int index) {
              final House house = _houses[index];
              return HouseItem(
                house: house,
                onTap: () => _openHouseDetail(house),
              );
            },
            separatorBuilder: (BuildContext context, int index) {
              return const SizedBox(height: 10);
            },
          ),
        );
      },
    );
  }
}
