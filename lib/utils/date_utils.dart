/// 日期工具函数。
String formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// 带本地时区偏移的时间，例如 `2026-10-20T10:00:00+08:00`，与服务端约定一致。
String formatLocalTime(DateTime time) {
  final DateTime local = time.toLocal();
  final Duration offset = local.timeZoneOffset;
  final String sign = offset.isNegative ? '-' : '+';
  final int minutes = offset.inMinutes.abs();
  return '${formatDate(local)}T${_two(local.hour)}:${_two(local.minute)}:00'
      '$sign${_two(minutes ~/ 60)}:${_two(minutes % 60)}';
}

/// 把服务端时间显示为“10月20日 周一 10:00”。无法解析时原样返回。
String formatVisitTime(String value) {
  final DateTime? parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final DateTime local = parsed.toLocal();
  const List<String> weekdays = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  final String date = '${local.month}月${local.day}日 ${weekdays[local.weekday - 1]}';
  // 只有日期的旧数据不显示时间。
  if (!value.contains('T')) return date;
  return '$date ${_two(local.hour)}:${_two(local.minute)}';
}

/// “早、中、晚”只是快捷选项和统计分类，住户仍须选择具体时间。
enum VisitPeriod {
  morning('早', 9, 12),
  noon('中', 14, 17),
  evening('晚', 18, 21);

  const VisitPeriod(this.label, this.startHour, this.endHour);
  final String label;
  final int startHour;
  final int endHour;

  List<int> get hours =>
      List<int>.generate(endHour - startHour, (int index) => startHour + index);
}
