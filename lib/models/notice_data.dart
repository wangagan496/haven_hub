class NoticeData {
  const NoticeData({
    this.id = '',
    required this.title,
    required this.content,
    required this.date,
    this.creatorName = '',
  });

  final String id;
  final String title;
  final String content;
  final String date;
  final String creatorName;

  factory NoticeData.fromJson(Map<String, dynamic> json) {
    return NoticeData(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      date: _formatDate(json['createdAt']?.toString() ?? ''),
      creatorName: json['creatorName']?.toString() ?? '',
    );
  }

  static String _formatDate(String value) {
    return value
        .replaceFirst('T', ' ')
        .replaceFirst(RegExp(r'\.\d+Z?$'), '')
        .replaceFirst(RegExp(r'Z$'), '');
  }
}
