import 'package:flutter/material.dart';

import '../../House/house_list.dart';
import '../../../utils/toast.dart';
import 'home_nav_item.dart';

class HomeNav extends StatelessWidget {
  const HomeNav({super.key});

  static const List<({String label, String icon, String? routeName})> _items =
      <({String label, String icon, String? routeName})>[
    (
      label: '我的房屋',
      icon: 'assets/images/house_nav_icon@2x.png',
      routeName: HouseList.routeName,
    ),
    (
      label: '我的报修',
      icon: 'assets/images/repair_nav_icon@2x.png',
      routeName: null,
    ),
    (
      label: '访客登记',
      icon: 'assets/images/visitor_nav_icon@2x.png',
      routeName: null,
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
        children:
            _items.map((({String label, String icon, String? routeName}) item) {
          return HomeNavItem(
            label: item.label,
            icon: item.icon,
            onTap: () {
              final String? routeName = item.routeName;
              if (routeName != null) {
                Navigator.pushNamed<void>(context, routeName);
                return;
              }
              PromptAction.showToast('${item.label}功能暂未开放');
            },
          );
        }).toList(growable: false),
      ),
    );
  }
}
