import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/home.dart';
import '../../api/repair.dart';
import '../../l10n/app_localizations.dart';
import '../../models/notice_data.dart';
import '../../utils/app_exception.dart';
import '../../utils/emitter.dart';
import '../../utils/toast.dart';
import '../../widgets/repair_availability_hint.dart';
import 'components/home_list.dart';
import 'components/home_nav.dart';

/// 不等待任务完成，让后面的代码继续执行。
const doNotWait = unawaited;

class HomePage extends StatefulWidget {
  const HomePage({
    this.announcementLoader = getAnnouncementListApi,
    this.repairPreloader = preloadRepairList,
    super.key,
  });

  final AnnouncementLoader announcementLoader;
  final Future<void> Function() repairPreloader;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<NoticeData> _notices = const <NoticeData>[];
  bool _isLoading = false;
  String? _errorMessage;
  late final StreamSubscription<LoginSuccessEvent> _loginSubscription;

  /// 页面状态是否仍有效；每次读取当前状态，不代表页面当前可见。
  bool get isPageAlive => mounted;

  /// 首页状态首次创建时，由 Flutter 自动调用。
  @override
  void initState() {
    // 先执行 Flutter 原有的初始化步骤。
    super.initState();
    doNotWait(_loadNotices());
    _loginSubscription = eventBus.on<LoginSuccessEvent>().listen((_) {
      _scheduleRepairPreload();
    });
    _scheduleRepairPreload();
  }

  void _scheduleRepairPreload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isPageAlive) doNotWait(widget.repairPreloader());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _loginSubscription.cancel();
    super.dispose();
  }

  Future<void> _loadNotices() async {
    if (_isLoading) {
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final List<NoticeData> loadedNotices = await widget.announcementLoader();
      if (!isPageAlive) {
        return;
      }
      _updateNoticeList(loadedNotices);
    } on Object catch (error) {
      final String message = describeError(
        error,
        fallback: '公告加载失败，请稍后重试',
      );
      if (!isPageAlive) {
        return;
      }
      setState(() => _errorMessage = message);
      await AppPrompt.showError(message);
    } finally {
      if (isPageAlive) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// 更新页面里的公告列表，并让界面显示最新数据。
  void _updateNoticeList(List<NoticeData> notices) {
    setState(() => _notices = notices);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _loadNotices,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: <Widget>[
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: <Widget>[
                      Expanded(child: Text(_errorMessage!)),
                      TextButton(
                        onPressed: _isLoading ? null : _loadNotices,
                        child: Text(l10n.retry),
                      ),
                    ],
                  ),
                ),
              if (_isLoading) const LinearProgressIndicator(minHeight: 2),
              SizedBox(
                height: 64,
                child: Center(
                  child: Text(
                    l10n.communityTitle,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const HomeNav(),
              const RepairAvailabilityHint(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/images/banner@2x.jpg',
                    width: double.infinity,
                    height: 132,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              HomeList(list: _notices),
              if (_notices.isEmpty && !_isLoading && _errorMessage == null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Text(l10n.noAnnouncement),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
