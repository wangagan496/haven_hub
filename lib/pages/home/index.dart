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
  List<NoticeData> _dataList = const <NoticeData>[];
  bool _isLoading = false;
  String? _errorMessage;
  late final StreamSubscription<LoginSuccessEvent> _loginSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_getAnnouncementList());
    _loginSubscription = eventBus.on<LoginSuccessEvent>().listen((_) {
      _scheduleRepairPreload();
    });
    _scheduleRepairPreload();
  }

  void _scheduleRepairPreload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.repairPreloader());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _loginSubscription.cancel();
    super.dispose();
  }

  Future<void> _getAnnouncementList() async {
    if (_isLoading) {
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final List<NoticeData> result = await widget.announcementLoader();
      if (!mounted) {
        return;
      }
      setState(() => _dataList = result);
    } on Object catch (error) {
      final String message = describeError(
        error,
        fallback: '公告加载失败，请稍后重试',
      );
      if (!mounted) {
        return;
      }
      setState(() => _errorMessage = message);
      await PromptAction.showError(message);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _getAnnouncementList,
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
                        onPressed: _isLoading ? null : _getAnnouncementList,
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
              HomeList(list: _dataList),
              if (_dataList.isEmpty && !_isLoading && _errorMessage == null)
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
