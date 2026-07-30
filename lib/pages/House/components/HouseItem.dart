// ignore_for_file: file_names

import 'package:flutter/material.dart';

class HouseItem extends StatelessWidget {
  const HouseItem({
    required this.data,
    super.key,
  });

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final int status = _parseStatus(data['status']);
    final _StatusStyle statusStyle = _getStatusStyle(status);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _displayValue(data['point']),
                    style: const TextStyle(
                      color: Color(0xFF262626),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusStyle.backgroundColor,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    getStatusText(status),
                    style: TextStyle(
                      color: statusStyle.foregroundColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _HouseInfoRow(
              label: '房间号',
              value: _getRoomLabel(data),
            ),
            const SizedBox(height: 14),
            _HouseInfoRow(
              label: '业主',
              value: _displayValue(data['name']),
            ),
          ],
        ),
      ),
    );
  }
}

class _HouseInfoRow extends StatelessWidget {
  const _HouseInfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF999999),
            fontSize: 14,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Color(0xFF333333),
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusStyle {
  const _StatusStyle({
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final Color backgroundColor;
  final Color foregroundColor;
}

String getStatusText(int value) {
  return switch (value) {
    1 => '审核中',
    2 => '审核成功',
    3 => '审核失败',
    _ => '未知状态',
  };
}

_StatusStyle _getStatusStyle(int value) {
  return switch (value) {
    1 => const _StatusStyle(
        backgroundColor: Color(0xFFE8E5FF),
        foregroundColor: Color(0xFF5A45F5),
      ),
    2 => const _StatusStyle(
        backgroundColor: Color(0xFFE7F8E5),
        foregroundColor: Color(0xFF31B824),
      ),
    3 => const _StatusStyle(
        backgroundColor: Color(0xFFFFE8E2),
        foregroundColor: Color(0xFFE75A3C),
      ),
    _ => const _StatusStyle(
        backgroundColor: Color(0xFFF0F0F0),
        foregroundColor: Color(0xFF666666),
      ),
  };
}

int _parseStatus(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String _getRoomLabel(Map<String, dynamic> data) {
  final String building = data['building']?.toString().trim() ?? '';
  final String room = data['room']?.toString().trim() ?? '';
  final String label = '$building$room';
  return label.isEmpty ? '无' : label;
}

String _displayValue(Object? value) {
  final String text = value?.toString().trim() ?? '';
  return text.isEmpty ? '无' : text;
}
