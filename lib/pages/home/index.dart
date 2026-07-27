import 'package:flutter/material.dart';

import '../../api/home.dart';
import '../../utils/toast.dart';
import 'components/home_list.dart';
import 'components/home_nav.dart';
import 'components/notify_item.dart';

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
      title: '祝愿每一位开发者都能拥有理想的编程工作',
      content: '要到了收获的季节，任何事情都没有百分之百的成功概率。'
          '不要让任何人定义你的未来，努力的人一定会有收获。',
      date: '2024-08-22 15:00:00',
    ),
    NoticeData(
      title: '社区公共区域维护通知',
      content: '本周六上午将对社区公共区域进行维护，请大家合理安排出行时间，感谢理解与配合。',
      date: '2024-08-20 10:30:00',
    ),
    NoticeData(
      title: '文明社区共建倡议',
      content: '爱护公共设施，保持公共区域整洁，让我们共同建设安全、温暖、舒适的社区。',
      date: '2024-08-18 09:00:00',
    ),
  ];

  List<NoticeData> _dataList = List<NoticeData>.of(_fallbackData);

  @override
  void initState() {
    super.initState();
    _getAnnouncementList();
  }

  Future<void> _getAnnouncementList() async {
    try {
      final List<Map<String, dynamic>> result =
          await widget.announcementLoader();
      if (!mounted) {
        return;
      }

      setState(() {
        _dataList = result.map(NoticeData.fromJson).toList(growable: false);
      });
      await PromptAction.showSuccess('数据获取成功');
    } on Object {
      // 网络不可用时保留本地公告，避免首页出现空白。
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          children: <Widget>[
            const SizedBox(
              height: 64,
              child: Center(
                child: Text(
                  '享+社区',
                  style: TextStyle(
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
    );
  }
}
