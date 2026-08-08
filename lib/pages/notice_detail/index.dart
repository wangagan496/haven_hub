import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../../api/home.dart';
import '../../l10n/app_localizations.dart';
import '../../models/notice_data.dart';
import '../../router/app_routes.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';

class NoticeDetail extends StatefulWidget {
  const NoticeDetail({
    this.detailLoader = getAnnouncementDetailApi,
    super.key,
  });

  static const String routeName = AppRoutes.noticeDetail;

  final AnnouncementDetailLoader detailLoader;

  @override
  State<NoticeDetail> createState() => _NoticeDetailState();
}

class _NoticeDetailState extends State<NoticeDetail> {
  NoticeData? _detail;
  String? _errorMessage;
  String _noticeId = '';
  bool _isLoading = false;
  bool _didRequest = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didRequest) {
      return;
    }
    _didRequest = true;

    final Object? arguments = ModalRoute.of(context)?.settings.arguments;
    _noticeId = switch (arguments) {
      String() => arguments.trim(),
      NoticeDetailArguments() => arguments.noticeId.trim(),
      Map<dynamic, dynamic>() => arguments['id']?.toString().trim() ?? '',
      _ => '',
    };
    if (_noticeId.isEmpty) {
      setState(() => _errorMessage = '公告参数不正确');
      return;
    }
    _getNoticeDetail();
  }

  Future<void> _getNoticeDetail() async {
    if (_isLoading || _noticeId.isEmpty) {
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    final String detailLoadError =
        AppLocalizations.of(context)!.announcementDetailLoadFailed;
    try {
      final NoticeData result = await widget.detailLoader(_noticeId);
      if (!mounted) {
        return;
      }
      setState(() => _detail = result);
    } on Object catch (error) {
      final String message = describeError(
        error,
        fallback: detailLoadError,
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

  Widget _buildBody() {
    final String? errorMessage = _errorMessage;
    if (errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(errorMessage, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _isLoading ? null : _getNoticeDetail,
              child: Text(AppLocalizations.of(context)!.retry),
            ),
          ],
        ),
      );
    }

    final NoticeData? detail = _detail;
    if (_isLoading || detail == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            detail.title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  detail.creatorName,
                  style:
                      const TextStyle(color: Color(0xFF999999), fontSize: 16),
                ),
              ),
              Text(
                detail.date,
                style: const TextStyle(color: Color(0xFF999999), fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Html(
            data: detail.content,
            style: <String, Style>{
              'body': Style(
                margin: Margins.zero,
                padding: HtmlPaddings.zero,
                fontSize: FontSize(17),
                lineHeight: const LineHeight(1.7),
              ),
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.announcementDetail),
        centerTitle: false,
      ),
      body: _buildBody(),
    );
  }
}
