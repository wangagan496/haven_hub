import 'package:flutter/material.dart';

import '../../../models/notice_data.dart';
import '../../notice_detail/index.dart';
import 'notify_item.dart';

class HomeList extends StatelessWidget {
  const HomeList({
    required this.list,
    super.key,
  });

  final List<NoticeData> list;

  Widget _getTitleWidget() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: <Widget>[
          Image.asset(
            'assets/images/notice@2x.png',
            width: 30,
            height: 30,
          ),
          const SizedBox(width: 6),
          const Text(
            '社区',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Text(
            '公告',
            style: TextStyle(
              color: Colors.amber,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _getListWidget() {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: list.length,
      itemBuilder: (BuildContext context, int index) {
        final NoticeData item = list[index];
        return GestureDetector(
          onTap: item.id.isEmpty
              ? null
              : () {
                  Navigator.pushNamed(
                    context,
                    NoticeDetail.routeName,
                    arguments: item.id,
                  );
                },
          child: NotifyItem(item: item),
        );
      },
      separatorBuilder: (BuildContext context, int index) {
        return const SizedBox(height: 12);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _getTitleWidget(),
        _getListWidget(),
      ],
    );
  }
}
