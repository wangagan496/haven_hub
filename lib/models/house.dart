/// 房屋信息，对应接口 `room` 的列表项与详情。
///
/// 接口返回的字段类型并不稳定（status、gender 可能是数字也可能是字符串），
/// 统一在 [House.fromJson] 里做一次解析，界面层不再直接读 Map。
///
/// 示例：
/// ```dart
/// final house = House(
///   point: '幸福小区',
///   building: 'A栋',
///   room: '101',
///   name: '张三',
///   mobile: '13800138000',
/// );
/// print(house.fullName); // 幸福小区 A栋 101
/// ```
class House {
  const House({
    this.id = '',
    this.point = '',
    this.building = '',
    this.room = '',
    this.name = '',
    this.gender = 1,
    this.mobile = '',
    this.idcardFrontUrl = '',
    this.idcardBackUrl = '',
    this.status = 0,
  });

  factory House.fromJson(Map<String, dynamic> json) {
    return House(
      id: _readText(json['id']),
      point: _readText(json['point']),
      building: _readText(json['building']),
      room: _readText(json['room']),
      name: _readText(json['name']),
      gender: _readGender(json['gender']),
      mobile: _readText(json['mobile']),
      idcardFrontUrl: _readFirstText(json, _idcardFrontKeys),
      idcardBackUrl: _readFirstText(json, _idcardBackKeys),
      status: _readStatus(json['status']),
    );
  }

  /// 身份证正面照在响应里可能的键名，按优先级排列。
  ///
  /// 详情接口的字段名没有正式约定，而 [toJson] 只在非空时才提交这两个字段，
  /// 一旦读不到就会呈现成「还没上传」：用户看到的是已有照片变成了空白的上传
  /// 占位，提交时又被校验拦下。多试几个常见拼写，比要求后端改名现实。
  static const List<String> _idcardFrontKeys = <String>[
    'idcardFrontUrl',
    'idcardFront',
    'idcard_front_url',
    'idcard_front',
    'frontUrl',
    'front_url',
  ];

  /// 身份证国徽面照的候选键名，规则同 [_idcardFrontKeys]。
  static const List<String> _idcardBackKeys = <String>[
    'idcardBackUrl',
    'idcardBack',
    'idcard_back_url',
    'idcard_back',
    'backUrl',
    'back_url',
  ];

  final String id;

  /// 小区名称。
  final String point;
  final String building;
  final String room;

  /// 业主姓名。
  final String name;

  /// 1 男、0 女。
  final int gender;
  final String mobile;
  final String idcardFrontUrl;
  final String idcardBackUrl;

  /// 审核状态：1 审核中、2 审核成功、3 审核失败，0 表示未知。
  final int status;

  /// 「小区 楼栋 房间」，缺失的部分自动跳过。
  String get fullName => <String>[point, building, room]
      .where((String value) => value.isNotEmpty)
      .join(' ');

  /// 「楼栋+房间」，房屋列表里的房间号展示。
  String get roomLabel => '$building$room';

  /// 性别文本（男/女）。
  String get genderText => gender == 0 ? '女' : '男';

  /// 审核状态文本。
  String get statusText => switch (status) {
        1 => '审核中',
        2 => '审核成功',
        3 => '审核失败',
        _ => '未知',
      };

  /// 是否正在审核中。
  bool get isPending => status == 1;

  /// 是否审核成功。
  bool get isApproved => status == 2;

  /// 是否审核失败。
  bool get isRejected => status == 3;

  House copyWith({
    String? id,
    String? point,
    String? building,
    String? room,
    String? name,
    int? gender,
    String? mobile,
    String? idcardFrontUrl,
    String? idcardBackUrl,
    int? status,
  }) {
    return House(
      id: id ?? this.id,
      point: point ?? this.point,
      building: building ?? this.building,
      room: room ?? this.room,
      name: name ?? this.name,
      gender: gender ?? this.gender,
      mobile: mobile ?? this.mobile,
      idcardFrontUrl: idcardFrontUrl ?? this.idcardFrontUrl,
      idcardBackUrl: idcardBackUrl ?? this.idcardBackUrl,
      status: status ?? this.status,
    );
  }

  /// 提交给服务端的请求体，空值字段一律省略。
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      if (id.isNotEmpty) 'id': id,
      'point': point,
      'building': building,
      'room': room,
      'name': name,
      'gender': gender,
      'mobile': mobile,
      if (idcardFrontUrl.isNotEmpty) 'idcardFrontUrl': idcardFrontUrl,
      if (idcardBackUrl.isNotEmpty) 'idcardBackUrl': idcardBackUrl,
    };
  }

  static String _readText(Object? value) => value?.toString().trim() ?? '';

  /// 按 [keys] 的顺序返回第一个非空值，都没有时返回空串。
  static String _readFirstText(Map<String, dynamic> json, List<String> keys) {
    for (final String key in keys) {
      final String value = _readText(json[key]);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  static int _readStatus(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(_readText(value)) ?? 0;
  }

  /// 只有明确是 0 才当作女，其余（含缺省、异常值）都按男处理。
  static int _readGender(Object? value) {
    if (value is num) return value.toInt() == 0 ? 0 : 1;
    return int.tryParse(_readText(value)) == 0 ? 0 : 1;
  }
}
