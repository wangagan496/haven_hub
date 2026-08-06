import 'package:flutter/material.dart';

import '../../../models/house.dart';
import '../../../theme/app_colors.dart';
import '../../../widgets/house_status_tag.dart';

class HouseItem extends StatelessWidget {
  const HouseItem({
    required this.house,
    this.onTap,
    super.key,
  });

  final House house;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _orPlaceholder(house.point),
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  HouseStatusTag(status: house.status),
                ],
              ),
              const SizedBox(height: 16),
              _HouseInfoRow(
                label: '房间号',
                value: _orPlaceholder(house.roomLabel),
              ),
              const SizedBox(height: 14),
              _HouseInfoRow(
                label: '业主',
                value: _orPlaceholder(house.name),
              ),
            ],
          ),
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
            color: AppColors.textTertiary,
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
              color: AppColors.textBody,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

String _orPlaceholder(String value) => value.isEmpty ? '无' : value;
