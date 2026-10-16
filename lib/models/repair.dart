class RepairItem {
  const RepairItem({required this.id, required this.name});

  factory RepairItem.fromJson(Map<String, dynamic> json) => RepairItem(
        id: json['id']?.toString().trim() ?? '',
        name: json['name']?.toString().trim() ?? '',
      );

  final String id;
  final String name;
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
    this.description = '',
    this.status = unknownStatus,
    this.attachment = const <String>[],
    this.workflowVersion = 0,
    this.revision = 0,
    this.workerId = '',
    this.workerName = '',
    this.workerMobile = '',
    this.completionNote = '',
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
        completionNote: json['completionNote']?.toString() ?? '',
        timeline: json['timeline'] is List<dynamic>
            ? (json['timeline'] as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .map(RepairEvent.fromJson)
                .toList(growable: false)
            : const <RepairEvent>[],
      );

  final String id;
  final String houseId;
  final String houseInfo;
  final String repairItemId;
  final String repairItemName;
  final String mobile;
  final String appointment;
  final String description;
  final int status;
  final List<String> attachment;
  final int workflowVersion;
  final int revision;
  final String workerId;
  final String workerName;
  final String workerMobile;
  final String completionNote;
  final List<RepairEvent> timeline;

  bool get canCancel => status == 1;
  String get statusText => switch (status) {
        0 => '已取消',
        1 => workflowVersion == 1 ? '待派单' : '待处理',
        2 => '处理中',
        3 => '已完成',
        4 => '已取消',
        5 => '待接单',
        // 未识别或缺失的状态如实显示，不猜成某一个具体状态。
        _ => '状态未知',
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (id.isNotEmpty) 'id': id,
        'houseId': houseId,
        'repairItemId': repairItemId,
        'mobile': mobile,
        'appointment': appointment,
        if (description.isNotEmpty) 'description': description,
        'attachment': attachment,
      };
}

class RepairEvent {
  const RepairEvent(
      {required this.action,
      required this.label,
      required this.at,
      this.detail = ''});
  factory RepairEvent.fromJson(Map<String, dynamic> json) => RepairEvent(
      action: json['action']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      at: json['at']?.toString() ?? '',
      detail: json['detail']?.toString() ?? '');
  final String action;
  final String label;
  final String at;
  final String detail;
}

int _toInt(Object? value) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString().trim() ?? '') ??
        RepairRecord.unknownStatus;
