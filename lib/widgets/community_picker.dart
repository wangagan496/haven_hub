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
              style:
                  const TextStyle(color: AppColors.textSecondary, fontSize: 13),
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

/// 缺少楼栋、房间资料时，由用户按门牌填写，不生成可选房屋。
class ManualHouseInput extends StatelessWidget {
  const ManualHouseInput({
    required this.controller,
    required this.notice,
    required this.label,
    required this.hint,
    required this.buttonLabel,
    required this.onContinue,
    this.enabled = true,
    this.additionalField,
    this.canContinue = true,
    this.inputKey,
    this.inputField,
    super.key,
  });

  final TextEditingController controller;
  final String notice;
  final String label;
  final String hint;
  final String buttonLabel;
  final VoidCallback onContinue;
  final bool enabled;
  final Widget? additionalField;
  final bool canContinue;
  final Key? inputKey;
  final Widget? inputField;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            notice,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),
          if (additionalField != null) ...<Widget>[
            additionalField!,
            const SizedBox(height: 20),
          ],
          inputField ??
              TextField(
                key: inputKey,
                controller: controller,
                enabled: enabled,
                maxLength: 100,
                textInputAction: TextInputAction.done,
                onSubmitted: enabled ? (_) => onContinue() : null,
                decoration: InputDecoration(
                  labelText: label,
                  hintText: hint,
                  border: const OutlineInputBorder(),
                ),
              ),
          const SizedBox(height: 20),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder:
                (BuildContext context, TextEditingValue value, Widget? child) {
              return ElevatedButton(
                onPressed:
                    enabled && canContinue && value.text.trim().isNotEmpty
                        ? onContinue
                        : null,
                child: Text(buttonLabel),
              );
            },
          ),
        ],
      ),
    );
  }
}
