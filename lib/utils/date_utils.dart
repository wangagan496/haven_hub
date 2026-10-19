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

/// 只格式化服务端时段窗口；保留原 formatVisitTime 的历史时间与截止时间语义。
String formatSlotWindow({String slot = '', String start = '', String end = ''}) {
  final List<String> parts = slot.split('#');
  final String wallStart = start.isNotEmpty ? start : parts.length != 2 ? '' : '${parts[0]}T${parts[1]}:00:00';
  if (wallStart.length < 16) return slot.isNotEmpty ? slot : start;
  final DateTime? date = DateTime.tryParse(wallStart.substring(0, 10));
  if (date == null) return wallStart;
  final String endTime = end.length >= 16 ? end.substring(11, 16)
      : '${_two((int.tryParse(wallStart.substring(11, 13)) ?? 0) + 1)}:00';
  const List<String> days = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return '${date.month}月${date.day}日 ${days[date.weekday - 1]} ${wallStart.substring(11, 16)}–$endTime';
}
