import '../utils/json_utils.dart';
import 'repair.dart';

/// 服务端与列表使用同一组筛选含义；处理中包含待住户确认。
enum RepairStatusFilter {
  all,
  pending,
  waiting,
  processing,
  completed;

  String get displayName => switch (this) {
        all => '全部',
        pending => '待派单',
        waiting => '待接单',
        processing => '处理中',
        completed => '已完成',
      };

  bool shouldShow(RepairRecord repair) => switch (this) {
        all => true,
        pending => repair.status == RepairStatus.pending,
        waiting => repair.status == RepairStatus.assigned,
        processing => repair.status == RepairStatus.processing ||
            repair.status == RepairStatus.confirming,
        completed => repair.status == RepairStatus.completed,
      };
}

/// 单页快照，不表示完整列表，也不能写进 MutationList 的完整结果缓存。
class RepairPage {
  RepairPage({
    required List<RepairRecord> rows,
    required this.current,
    required this.total,
    required this.pageTotal,
  }) : rows = List<RepairRecord>.unmodifiable(rows);

  final List<RepairRecord> rows;
  final int current;
  final int total;
  final int pageTotal;
  bool get hasMore => current < pageTotal;

  factory RepairPage.fromJson(dynamic data, {
    required int current,
    required int pageSize,
    required RepairStatusFilter filter,
  }) {
    const String invalid = '报修列表记录不完整或已变化，请刷新重试';
    final Map<String, dynamic> page = asMap(data, '报修列表');
    final int? total = int.tryParse(page['total']?.toString() ?? '');
    final int? pages = int.tryParse(page['pageTotal']?.toString() ?? '');
    final int? returnedCurrent = int.tryParse(page['current']?.toString() ?? '');
    if (total == null || total < 0 || total > 9007199254740991 ||
        (filter != RepairStatusFilter.all && page['filter'] != filter.name) ||
        pages != (total + pageSize - 1) ~/ pageSize ||
        returnedCurrent != current) {
      throw const FormatException(invalid);
    }
    final List<RepairRecord> rows = readRows(data, '报修列表')
        .map((dynamic row) => RepairRecord.fromJson(asMap(row, '报修')))
        .toList(growable: false);
    final int expected = (total - (current - 1) * pageSize).clamp(0, pageSize);
    final Set<String> ids = <String>{};
    if (rows.length != expected || rows.any((record) =>
        record.id.trim().isEmpty || !ids.add(record.id) || !filter.shouldShow(record))) {
      throw const FormatException(invalid);
    }
    return RepairPage(rows: rows, current: current, total: total, pageTotal: pages!);
  }
}
