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
    this.status = 0,
  });

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

  bool get canCancel => status == 1 || status == 0;
  String get statusText => switch (status) {
        1 => '待处理',
        2 => '处理中',
        3 => '已完成',
        4 => '已取消',
        _ => '待处理',
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (id.isNotEmpty) 'id': id,
        'houseId': houseId,
        'repairItemId': repairItemId,
        'mobile': mobile,
        'appointment': appointment,
        if (description.isNotEmpty) 'description': description,
      };
}

int _toInt(Object? value) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString().trim() ?? '') ?? 0;
