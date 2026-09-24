class VisitorRecord {
  const VisitorRecord({
    this.id = '',
    this.houseId = '',
    this.houseInfo = '',
    this.name = '',
    this.gender = 1,
    this.mobile = '',
    this.visitDate = '',
    this.status = 0,
    this.url = '',
    this.validTime = 0,
    this.encryptedData = '',
  });

  factory VisitorRecord.fromJson(Map<String, dynamic> json) => VisitorRecord(
        id: json['id']?.toString().trim() ?? '',
        houseId: json['houseId']?.toString().trim() ?? '',
        houseInfo: json['houseInfo']?.toString().trim() ?? '',
        name: json['name']?.toString().trim() ?? '',
        gender: _gender(json['gender']),
        mobile: json['mobile']?.toString().trim() ?? '',
        visitDate: json['visitDate']?.toString().trim() ?? '',
        status: _integer(json['status']),
        url: json['url']?.toString().trim() ?? '',
        validTime: _integer(json['validTime']),
        encryptedData: json['encryptedData']?.toString().trim() ?? '',
      );

  final String id;
  final String houseId;
  final String houseInfo;
  final String name;
  final int gender;
  final String mobile;
  final String visitDate;
  final int status;
  final String url;
  final int validTime;
  final String encryptedData;

  // validTime is a duration, not an expiry timestamp. Use server status.
  bool get canShare => (status == 0 || status == 1) && url.trim().isNotEmpty;

  String get statusText => switch (status) {
        1 => '待访问',
        2 => '已访问',
        3 => '已失效',
        _ => '待访问',
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'houseId': houseId,
        'name': name,
        'gender': gender,
        'mobile': mobile,
        'visitDate': visitDate,
      };
}

int _integer(Object? value) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString().trim() ?? '') ?? 0;

int _gender(Object? value) => _integer(value) == 0 ? 0 : 1;
