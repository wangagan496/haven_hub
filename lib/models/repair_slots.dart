class RepairSlotWindow {
  const RepairSlotWindow({required this.start, required this.end});
  factory RepairSlotWindow.fromJson(Map<String, dynamic> json) => RepairSlotWindow(
      start: json['start']?.toString() ?? '', end: json['end']?.toString() ?? '');
  final String start;
  final String end;
}

class RepairSlot {
  const RepairSlot({required this.slot, required this.start, required this.end,
    required this.period, required this.selectable});
  factory RepairSlot.fromJson(Map<String, dynamic> json) {
    if (json['slot'] is! String || json['start'] is! String || json['end'] is! String
        || json['period'] is! String || json['selectable'] is! bool) {
      throw const FormatException('时段数据不完整，请重试');
    }
    return RepairSlot(slot: json['slot'] as String, start: json['start'] as String,
        end: json['end'] as String, period: json['period'] as String, selectable: json['selectable'] as bool);
  }
  final String slot;
  final String start;
  final String end;
  final String period;
  final bool selectable;
}

class RepairSlots {
  const RepairSlots({required this.today, required this.dates, required this.slots});
  factory RepairSlots.fromJson(Map<String, dynamic> json) {
    if (json['today'] is! String || json['dates'] is! List || json['slots'] is! List) {
      throw const FormatException('时段查询数据不完整，请重试');
    }
    final List<dynamic> dates = json['dates'] as List<dynamic>;
    if (dates.isEmpty || dates.any((dynamic value) => value is! String)) {
      throw const FormatException('预约日期数据不完整，请重试');
    }
    return RepairSlots(today: json['today'] as String, dates: dates.cast<String>(),
        slots: (json['slots'] as List<dynamic>).map((dynamic value) {
          if (value is! Map<String, dynamic>) throw const FormatException('时段数据不完整，请重试');
          return RepairSlot.fromJson(value);
        }).toList(growable: false));
  }
  final String today;
  final List<String> dates;
  final List<RepairSlot> slots;
}
