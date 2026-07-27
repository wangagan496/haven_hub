import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../../api/home.dart';
import '../home/components/notify_item.dart';

class NoticeDetail extends StatefulWidget {
  const NoticeDetail({
    this.detailLoader = getAnnouncementDetailApi,
    super.key,
  });

  static const String routeName = '/noticedetail';

  final AnnouncementDetailLoader detailLoader;

  @override
  State<NoticeDetail> createState() => _NoticeDetailState();
}

class _NoticeDetailState extends State<NoticeDetail> {
  NoticeData? _detail;
  String? _errorMessage;
  bool _didRequest = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didRequest) {
      return;
    }
    _didRequest = true;

    final Object? arguments = ModalRoute.of(context)?.settings.arguments;
    if (arguments is! String || arguments.isEmpty) {
      setState(() {
        _errorMessage = '公告参数不正确';
      });
      return;
    }
    _getNoticeDetail(arguments);
  }

  Future<void> _getNoticeDetail(String id) async {
    try {
      final Map<String, dynamic> result = await widget.detailLoader(id);
      if (!mounted) {
        return;
      }
      setState(() {
        _detail = NoticeData.fromJson(result);
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = '公告详情获取失败';
      });
    }
  }

  Widget _buildBody() {
    final String? errorMessage = _errorMessage;
    if (errorMessage != null) {
      return Center(
        child: Text(
          errorMessage,
          style: const TextStyle(color: Colors.red),
        ),
      );
    }

    final NoticeData? detail = _detail;
    if (detail == null) {
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
                  style: const TextStyle(
                    color: Color(0xFF999999),
                    fontSize: 16,
                  ),
                ),
              ),
              Text(
                detail.date,
                style: const TextStyle(
                  color: Color(0xFF999999),
                  fontSize: 16,
                ),
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
        title: const Text('公告详情'),
        centerTitle: false,
      ),
      body: _buildBody(),
    );
  }
}
