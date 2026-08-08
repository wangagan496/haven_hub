class UserInfo {
  const UserInfo({
    required this.avatarUrl, required this.nickName, this.id = '',
  });

  const UserInfo.empty()
      : id = '',
        avatarUrl = '',
        nickName = '';

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      id: (json['id'] ?? '').toString().trim(),
      avatarUrl: (json['avatar'] ?? '').toString().trim(),
      nickName: (json['nickName'] ?? '').toString().trim(),
    );
  }

  final String id;
  final String avatarUrl;
  final String nickName;
}
