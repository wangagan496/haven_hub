import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/home.dart';
import '../../l10n/app_localizations.dart';
import '../../models/notice_data.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';
import 'components/home_list.dart';
import 'components/home_nav.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    this.announcementLoader = getAnnouncementListApi,
    super.key,
  });

  final AnnouncementLoader announcementLoader;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const List<NoticeData> _fallbackData = <NoticeData>[
    NoticeData(
      title: '社区',
      content: '网络不可用时会显示本地示例内容。',
      date: '2024-08-22 15:00:00',
    ),
  ];

  List<NoticeData> _dataList = List<NoticeData>.of(_fallbackData);
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_getAnnouncementList());
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
            ],
          ),
        ),
      ),
    );
  }
}
