import 'package:flutter/material.dart';

import '../../../utils/toast.dart';
import 'home_nav_item.dart';

class HomeNav extends StatelessWidget {
  const HomeNav({super.key});

  static const List<({String label, String icon})> _items =
      <({String label, String icon})>[
    (
      label: '我的房屋',
      icon: 'assets/images/house_nav_icon@2x.png',
    ),
    (
      label: '我的报修',
      icon: 'assets/images/repair_nav_icon@2x.png',
    ),
    (
      label: '访客登记',
      icon: 'assets/images/visitor_nav_icon@2x.png',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE4E7EC)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: _items.map((({String label, String icon}) item) {
          return HomeNavItem(
            label: item.label,
            icon: item.icon,
            onTap: () {
              PromptAction.showToast('点击了${item.label}');
            },
          );
        }).toList(growable: false),
      ),
    );
  }
}
