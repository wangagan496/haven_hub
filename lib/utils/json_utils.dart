/// JSON 解析工具函数，供各 API 层共用。
List<dynamic> readRows(dynamic data, String name) {
  if (data is! Map<dynamic, dynamic> || data['rows'] is! List<dynamic>) {
    throw FormatException('$name数据格式不正确');
  }
  return data['rows'] as List<dynamic>;
}

Map<String, dynamic> asMap(dynamic data, String name) {
  if (data is! Map<dynamic, dynamic>) throw FormatException('$name数据格式不正确');
  return Map<String, dynamic>.from(data);
}
