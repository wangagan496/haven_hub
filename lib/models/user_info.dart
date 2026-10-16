class UserInfo {
  const UserInfo({
    required this.avatarUrl,
    required this.nickName,
    this.id = '',
    this.role = 'resident',
  });

  const UserInfo.empty()
      : id = '',
        avatarUrl = '',
        role = 'resident',
        nickName = '';

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      id: (json['id'] ?? '').toString().trim(),
      avatarUrl: (json['avatar'] ?? '').toString().trim(),
      nickName: (json['nickName'] ?? '').toString().trim(),
      role: (json['role'] ?? 'resident').toString(),
    );
  }

  final String id;
  final String avatarUrl;
  final String nickName;
  final String role;
}
