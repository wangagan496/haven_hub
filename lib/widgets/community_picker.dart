import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 选楼流程的顶部卡片：小区名 + 地址，可选地追加已选楼栋。
class CommunityHeader extends StatelessWidget {
  const CommunityHeader({
    required this.communityName,
    required this.address,
    this.selectedBuilding = '',
    super.key,
  });

  final String communityName;
  final String address;

  /// 已选中的楼栋，为空时不展示。
  final String selectedBuilding;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            communityName,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (address.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              address,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
          if (selectedBuilding.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              selectedBuilding,
              style: const TextStyle(
                color: AppColors.accent,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 选楼流程里“一列可点条目”的列表，楼栋和房间共用。
class PickerListView extends StatelessWidget {
  const PickerListView({
    required this.items,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final List<String> items;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
      itemBuilder: (BuildContext context, int index) {
        final String item = items[index];
        return ListTile(
          onTap: enabled ? () => onSelected(item) : null,
          tileColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(
            item,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
          ),
          trailing: const Icon(
            Icons.chevron_right_rounded,
            color: AppColors.divider,
          ),
        );
      },
    );
  }
}
