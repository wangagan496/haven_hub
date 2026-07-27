import 'package:flutter/material.dart';

class NoticeData {
  const NoticeData({
    this.id = '',
    required this.title,
    required this.content,
    required this.date,
    this.creatorName = '',
  });

  final String id;
  final String title;
  final String content;
  final String date;
  final String creatorName;

  factory NoticeData.fromJson(Map<String, dynamic> json) {
    return NoticeData(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      date: _formatDate(json['createdAt']?.toString() ?? ''),
      creatorName: json['creatorName']?.toString() ?? '',
    );
  }

  static String _formatDate(String value) {
    return value
        .replaceFirst('T', ' ')
        .replaceFirst(RegExp(r'\.\d+Z?$'), '')
        .replaceFirst(RegExp(r'Z$'), '');
  }
}

class NotifyItem extends StatelessWidget {
  const NotifyItem({
    required this.item,
    super.key,
  });

  final NoticeData item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            item.title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 10),
          Text(
            item.content,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.55,
                ),
          ),
          const SizedBox(height: 12),
          Text(
            item.date,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey,
                ),
          ),
        ],
      ),
    );
  }
}
