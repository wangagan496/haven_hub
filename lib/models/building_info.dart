/// 选楼流程中的建筑信息。
///
/// 替代原来 [BuildController] 中用 Map 存储的方式，提供类型安全的数据结构。
class BuildingInfo {
  const BuildingInfo({
    this.name = '',
    this.address = '',
    this.building = '',
    this.room = '',
    this.floor = '',
    this.communityId = '',
    this.latitude,
    this.longitude,
  });

  /// 小区名称。
  final String name;

  /// 小区地址。
  final String address;

  /// 已选择的楼栋。
  final String building;

  /// 已选择的房间。
  final String room;

  /// 用户填写的楼层，空值表示未填写；地下楼层使用 B1 等形式。
  final String floor;

  /// 腾讯小区地点及其 GCJ-02 坐标，用于围绕所选小区查询。
  final String communityId;
  final double? latitude;
  final double? longitude;

  /// 返回一个新的 [BuildingInfo]，仅更新指定字段。
  BuildingInfo copyWith({
    String? name,
    String? address,
    String? building,
    String? room,
    String? floor,
    String? communityId,
    double? latitude,
    double? longitude,
  }) {
    return BuildingInfo(
      name: name ?? this.name,
      address: address ?? this.address,
      building: building ?? this.building,
      room: room ?? this.room,
      floor: floor ?? this.floor,
      communityId: communityId ?? this.communityId,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
    );
  }

  /// 小区信息是否已选择（name 不为空）。
  bool get hasCommunity => name.trim().isNotEmpty;

  /// 楼栋信息是否已选择。
  bool get hasBuilding => building.trim().isNotEmpty;

  /// 房间信息是否已选择。
  bool get hasRoom => room.trim().isNotEmpty;

  /// 是否已完成所有必填信息选择。
  bool get isComplete => hasCommunity && hasBuilding && hasRoom;

  /// 将对象转换为 Map，用于向后兼容或序列化。
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'address': address,
      'build': building,
      'room': room,
      'floor': floor,
      'communityId': communityId,
      'latitude': latitude,
      'longitude': longitude,
    };
  }

  /// 从 Map 创建实例，用于向后兼容或反序列化。
  factory BuildingInfo.fromJson(Map<String, dynamic> json) {
    return BuildingInfo(
      name: json['name']?.toString().trim() ?? '',
      address: json['address']?.toString().trim() ?? '',
      building: json['build']?.toString().trim() ?? '',
      room: json['room']?.toString().trim() ?? '',
      floor: json['floor']?.toString().trim() ?? '',
      communityId: json['communityId']?.toString().trim() ?? '',
      latitude: double.tryParse(json['latitude']?.toString() ?? ''),
      longitude: double.tryParse(json['longitude']?.toString() ?? ''),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BuildingInfo &&
        other.name == name &&
        other.address == address &&
        other.building == building &&
        other.room == room &&
        other.floor == floor &&
        other.communityId == communityId &&
        other.latitude == latitude &&
        other.longitude == longitude;
  }

  @override
  int get hashCode => Object.hash(
      name, address, building, room, floor, communityId, latitude, longitude);

  @override
  String toString() {
    return 'BuildingInfo(name: $name, address: $address, '
        'building: $building, room: $room)';
  }
}
