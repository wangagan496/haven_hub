import 'repair_slots.dart';
export 'repair_slots.dart';

class RepairRescheduleOffer {
  const RepairRescheduleOffer({required this.id, required this.deadline, this.resolvedAt = ''});
  factory RepairRescheduleOffer.fromJson(Map<String, dynamic> json) => RepairRescheduleOffer(
      id: json['id']?.toString() ?? '', deadline: json['deadline']?.toString() ?? '', resolvedAt: json['resolvedAt']?.toString() ?? '');
  final String id;
  final String deadline;
  final String resolvedAt;
  bool get isOpen => id.isNotEmpty && resolvedAt.isEmpty;
}

class RepairItem {
  const RepairItem({required this.id, required this.name});

  factory RepairItem.fromJson(Map<String, dynamic> json) => RepairItem(
        id: json['id']?.toString().trim() ?? '',
        name: json['name']?.toString().trim() ?? '',
      );

  final String id;
  final String name;
}

/// 服务端主状态编码。4 只为兼容历史“已取消”显示，不再写入。
abstract final class RepairStatus {
  static const int cancelled = 0;
  static const int pending = 1;
  static const int processing = 2;
  static const int completed = 3;
  static const int legacyCancelled = 4;
  static const int assigned = 5;
  static const int confirming = 6;
}

class RepairRecord {
  const RepairRecord({
    this.id = '',
    this.houseId = '',
    this.houseInfo = '',
    this.repairItemId = '',
    this.repairItemName = '',
    this.mobile = '',
    this.appointment = '',
    this.expectedTime = '',
    this.agreedTime = '',
    this.slot = '',
    this.slotWindow,
    this.pendingSchedule,
    this.expectedSlot = '',
    this.autoAccepted = false,
    this.shiftCount = 0,
    this.priority = '',
    this.priorityPending = false,
    this.urgentRequest = false,
    this.asap = false,
    this.needsAdmin = false,
    this.staffingIssue = '',
    this.staffingMessage = '',
    this.rescheduleOffer,
    this.description = '',
    this.status = unknownStatus,
    this.attachment = const <String>[],
    this.workflowVersion = 0,
    this.revision = 0,
    this.workerId = '',
    this.workerName = '',
    this.workerMobile = '',
    this.propertyPhone = '',
    this.completionNote = '',
    this.round = 1,
    this.reworkUsed = false,
    this.confirmDeadline = '',
    this.warrantyEnd = '',
    this.closed = false,
    this.rounds = const <RepairRound>[],
    this.pendings = const <RepairPending>[],
    this.timeline = const <RepairEvent>[],
  });

  /// 服务端未给出或无法解析 [status] 时使用。
  ///
  /// 不能用 0 代替：0 是服务端「已取消」的真实取值，把缺失当成 0 会把一条
  /// 状态未知的记录显示成「已取消」。
  static const int unknownStatus = -1;

  factory RepairRecord.fromJson(Map<String, dynamic> json) => RepairRecord(
        id: json['id']?.toString().trim() ?? '',
        houseId: json['houseId']?.toString().trim() ?? '',
        houseInfo: json['houseInfo']?.toString().trim() ?? '',
        repairItemId: json['repairItemId']?.toString().trim() ?? '',
        repairItemName: json['repairItemName']?.toString().trim() ?? '',
        mobile: json['mobile']?.toString().trim() ?? '',
        appointment: json['appointment']?.toString().trim() ?? '',
        expectedTime: json['expectedTime']?.toString().trim() ?? '',
        agreedTime: json['agreedTime']?.toString().trim() ?? '',
        slot: json['slot']?.toString() ?? '',
        slotWindow: json['slotWindow'] is Map<String, dynamic>
            ? RepairSlotWindow.fromJson(json['slotWindow'] as Map<String, dynamic>) : null,
        pendingSchedule: json['pendingSchedule'] is Map<String, dynamic>
            ? RepairPending.fromJson(json['pendingSchedule'] as Map<String, dynamic>) : null,
        expectedSlot: json['expectedSlot']?.toString() ?? '',
        autoAccepted: json['autoAccepted'] == true,
        shiftCount: int.tryParse('${json['shiftCount']}') ?? 0,
        priority: json['priority']?.toString() ?? '',
        priorityPending: json['priorityPending'] == true,
        urgentRequest: json['urgentRequest'] == true,
        asap: json['asap'] == true,
        needsAdmin: json['needsAdmin'] == true,
        staffingIssue: json['staffingIssue']?.toString() ?? '',
        staffingMessage: json['staffingMessage']?.toString() ?? '',
        rescheduleOffer: json['rescheduleOffer'] is Map<String, dynamic>
            ? RepairRescheduleOffer.fromJson(json['rescheduleOffer'] as Map<String, dynamic>) : null,
        description: json['description']?.toString().trim() ?? '',
        status: _toInt(json['status']),
        attachment: (json['attachment'] is List<dynamic>)
            ? (json['attachment'] as List<dynamic>)
                .whereType<String>()
                .toList(growable: false)
            : const <String>[],
        workflowVersion: int.tryParse('${json['workflowVersion']}') ?? 0,
        revision: int.tryParse('${json['revision']}') ?? 0,
        workerId: json['workerId']?.toString().trim() ?? '',
        workerName: json['workerName']?.toString() ?? '',
        workerMobile: json['workerMobile']?.toString() ?? '',
        propertyPhone: json['propertyPhone']?.toString() ?? '',
        completionNote: json['completionNote']?.toString() ?? '',
        round: int.tryParse('${json['round']}') ?? 1,
        reworkUsed: json['reworkUsed'] == true,
        confirmDeadline: json['confirmDeadline']?.toString() ?? '',
        warrantyEnd: json['warrantyEnd']?.toString() ?? '',
        closed: json['closed'] == true,
        rounds: _list(json['rounds'], RepairRound.fromJson),
        pendings: _list(json['pendings'], RepairPending.fromJson),
        timeline: _list(json['timeline'], RepairEvent.fromJson),
      );

  final String id;
  final String houseId;
  final String staffingIssue;
  final String staffingMessage;
  final RepairRescheduleOffer? rescheduleOffer;
  final String houseInfo;
  final String repairItemId;
  final String repairItemName;
  final String mobile;

  /// 期望日期（旧数据只有日期）。新数据以 [expectedTime] 为准。
  final String appointment;

  /// 住户期望的具体上门时间，ISO 8601 带时区。
  final String expectedTime;

  /// 双方约定的上门时间；空表示尚未约定（例如返修开始后需要重新约）。
  final String agreedTime;
  final String slot;
  final RepairSlotWindow? slotWindow;
  final RepairPending? pendingSchedule;
  final String expectedSlot;
  final bool autoAccepted;
  final int shiftCount;
  final String priority;
  final bool priorityPending;
  final bool urgentRequest;
  final bool asap;
  final bool needsAdmin;

  RepairPending? get firstSchedule => pendingSchedule ??
      ((reschedule?.firstSchedule ?? false) ? reschedule : null);

  bool get hasActiveSchedule => const <int>{RepairStatus.pending, RepairStatus.assigned, RepairStatus.processing}.contains(status);

  RepairEvent? get propertyScheduleEvent {
    for (final RepairEvent event in timeline.reversed) {
      if (const <String>{'admin_shifted', 'urgent_dispatched', 'rescheduled',
        'schedule_auto_accepted', 'rework_started'}.contains(event.action)) {
        return event.action == 'admin_shifted' || event.action == 'urgent_dispatched' ? event : null;
      }
    }
    return null;
  }
  bool get propertyAdjusted => propertyScheduleEvent != null;
  // 旧事件未记录此前排期，使用中性的“已安排”，不猜测是否调整。
  bool get propertyFirstScheduled => propertyScheduleEvent?.action == 'urgent_dispatched' &&
      (propertyScheduleEvent?.firstSchedule ?? true);
  final String description;
  final int status;
  final List<String> attachment;
  final int workflowVersion;
  final int revision;
  final String workerId;
  final String workerName;
  final String workerMobile;
  final String propertyPhone;
  final String completionNote;
  final int round;
  final bool reworkUsed;
  final String confirmDeadline;
  final String warrantyEnd;

  /// 任务彻底完成（售后期结束或已取消）。此后对方电话脱敏，不再能反馈或返修。
  final bool closed;
  final List<RepairRound> rounds;
  final List<RepairPending> pendings;
  final List<RepairEvent> timeline;

  RepairPending? openPending(String kind) {
    for (final RepairPending item in pendings) {
      if (item.kind == kind && !item.resolved) return item;
    }
    return null;
  }

  RepairPending? get reschedule => openPending('reschedule');
  RepairPending? get revokeRequest => openPending('revoke');
  RepairPending? get aftersale => openPending('aftersale');
  RepairPending? get feedback => openPending('feedback');

  /// 未接单前可直接撤销；师傅接单后改为“申请撤销”。
  bool get canRevoke =>
      (status == RepairStatus.pending ||
          status == RepairStatus.assigned ||
          status == RepairStatus.processing) &&
      revokeRequest == null;
  bool get revokeNeedsWorker => status == RepairStatus.processing;

  /// 兼容旧调用：未接单前可直接撤销。
  bool get canCancel =>
      status == RepairStatus.pending || status == RepairStatus.assigned;
  bool get canConfirm => status == RepairStatus.confirming;
  bool get canReject => status == RepairStatus.confirming && !reworkUsed;
  bool get inWarranty =>
      status == RepairStatus.completed && warrantyEnd.isNotEmpty && !closed;
  bool get canApplyAftersale => inWarranty && !reworkUsed && aftersale == null;
  bool get canFeedback => !closed && feedback == null;
  bool get canReschedule =>
      status == RepairStatus.processing &&
      reschedule == null &&
      revokeRequest == null;

  /// 当前约定或期望的上门时间，用于展示。
  String get visitTime =>
      agreedTime.isNotEmpty ? agreedTime : expectedTime;

  String get statusText => switch (status) {
        RepairStatus.cancelled => '已取消',
        RepairStatus.pending => workflowVersion == 1 ? '待派单' : '待处理',
        RepairStatus.processing => '处理中',
        RepairStatus.completed => '已完成',
        RepairStatus.legacyCancelled => '已取消',
        RepairStatus.assigned => '待接单',
        RepairStatus.confirming => '待确认',
        // 未识别或缺失的状态如实显示，不猜成某一个具体状态。
        _ => '状态未知',
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (id.isNotEmpty) 'id': id,
        'houseId': houseId,
        'repairItemId': repairItemId,
        'mobile': mobile,
        'slot': slot,
        'urgentRequest': urgentRequest,
        'asap': asap,
        if (description.isNotEmpty) 'description': description,
        'attachment': attachment,
      };
}

class RepairRound {
  const RepairRound({
    required this.number,
    this.workerName = '',
    this.note = '',
    this.cost,
    this.completedAt = '',
    this.confirmedAt = '',
    this.confirmedBy = '',
    this.rejectReason = '',
    this.verifiedNote = '',
  });

  factory RepairRound.fromJson(Map<String, dynamic> json) => RepairRound(
        number: int.tryParse('${json['number']}') ?? 1,
        workerName: json['workerName']?.toString() ?? '',
        note: json['note']?.toString() ?? '',
        cost: num.tryParse('${json['cost']}'),
        completedAt: json['completedAt']?.toString() ?? '',
        confirmedAt: json['confirmedAt']?.toString() ?? '',
        confirmedBy: json['confirmedBy']?.toString() ?? '',
        rejectReason: json['rejectReason']?.toString() ?? '',
        verifiedNote: json['verifiedNote']?.toString() ?? '',
      );

  final int number;
  final String workerName;
  final String note;

  /// 师傅上报的费用，不等于物业已核实或已报销的金额。
  final num? cost;
  final String completedAt;
  final String confirmedAt;
  final String confirmedBy;
  final String rejectReason;
  final String verifiedNote;
}

/// 待对方回应的事项：改约、撤销申请、售后申请、问题反馈。
class RepairPending {
  const RepairPending({
    required this.kind,
    required this.by,
    this.at = '',
    this.reason = '',
    this.proposedTime = '',
    this.proposedSlot = '',
    this.firstSchedule = false,
    this.deadline = '',
    this.resolved = false,
    this.reply = '',
  });

  factory RepairPending.fromJson(Map<String, dynamic> json) => RepairPending(
        kind: json['kind']?.toString() ?? '',
        by: json['by']?.toString() ?? '',
        at: json['at']?.toString() ?? '',
        reason: json['reason']?.toString() ?? '',
        proposedTime: json['proposedTime']?.toString() ?? '',
        proposedSlot: json['proposedSlot']?.toString() ?? '',
        firstSchedule: json['firstSchedule'] == true,
        deadline: json['deadline']?.toString() ?? '',
        resolved: (json['resolvedAt']?.toString() ?? '').isNotEmpty,
        reply: json['reply']?.toString() ?? '',
      );

  final String kind;
  final String by;
  final String at;
  final String reason;
  final String proposedTime;
  final String proposedSlot;
  final bool firstSchedule;
  final String deadline;
  final bool resolved;
  final String reply;
}

class RepairEvent {
  const RepairEvent(
      {required this.action,
      required this.label,
      required this.at,
      this.firstSchedule,
      this.detail = ''});
  factory RepairEvent.fromJson(Map<String, dynamic> json) => RepairEvent(
      action: json['action']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      at: json['at']?.toString() ?? '',
      firstSchedule: json['firstSchedule'] is bool ? json['firstSchedule'] as bool : null,
      detail: json['detail']?.toString() ?? '');
  final String action;
  final String label;
  final String at;
  final bool? firstSchedule;
  final String detail;
}

List<T> _list<T>(Object? value, T Function(Map<String, dynamic>) parse) =>
    value is List<dynamic>
        ? value
            .whereType<Map<String, dynamic>>()
            .map(parse)
            .toList(growable: false)
        : <T>[];

int _toInt(Object? value) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString().trim() ?? '') ??
        RepairRecord.unknownStatus;
