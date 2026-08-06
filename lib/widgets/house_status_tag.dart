import 'package:flutter/material.dart';


/// 房屋审核状态：1 审核中、2 审核成功、3 审核失败，其余视为未知。
String getStatusText(int value) {
  return switch (value) {
    1 => '审核中',
    2 => '审核成功',
    3 => '审核失败',
    _ => '未知状态',
  };
}

/// 把接口返回的 status 字段（可能是数字或字符串）解析成状态码。
int parseHouseStatus(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

/// 房屋审核状态标签。列表页和详情页共用同一套配色与文案。
class HouseStatusTag extends StatelessWidget {
  const HouseStatusTag({required this.status, super.key});

  final int status;

  @override
  Widget build(BuildContext context) {
    final (Color background, Color foreground) = switch (status) {
      1 => (const Color(0xFFE8E5FF), const Color(0xFF5A45F5)),
      2 => (const Color(0xFFE7F8E5), const Color(0xFF31B824)),
      3 => (const Color(0xFFFFE8E2), const Color(0xFFE75A3C)),
      _ => (const Color(0xFFF0F0F0), const Color(0xFF666666)),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        getStatusText(status),
        style: TextStyle(
          color: foreground,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
