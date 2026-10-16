/// 下拉提供常用楼层，手动输入也支持更高楼层和地下楼层。
String normalizeFloor(String value) {
  final String floor =
      value.trim().toUpperCase().replaceFirst(RegExp(r'层$'), '');
  final Match? basement = RegExp(r'^地下([1-9]\d?)$').firstMatch(floor);
  return basement == null ? floor : 'B${basement.group(1)}';
}

String? validateFloor(String value) {
  final String floor = normalizeFloor(value);
  if (floor.isEmpty ||
      RegExp(r'^(?:[1-9]\d{0,3}|B[1-9]\d?)$').hasMatch(floor)) {
    return null;
  }
  return '请输入有效楼层，例如33、100或B1';
}

String formatFloor(String value) {
  if (value.isEmpty) return '';
  return value.startsWith('B') ? '地下${value.substring(1)}层' : '$value层';
}
