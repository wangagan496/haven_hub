import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../house/house_list.dart';
import '../../repair/repair_pages.dart';
import '../../visitor/visitor_pages.dart';
import 'home_nav_item.dart';

class HomeNav extends StatelessWidget {
  const HomeNav({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    final List<({String label, String icon, String routeName})> items =
        <({String label, String icon, String routeName})>[
      (
        label: l10n.myHouses,
        icon: 'assets/images/house_nav_icon@2x.png',
        routeName: HouseList.routeName,
      ),
      (
        label: l10n.repair,
        icon: 'assets/images/repair_nav_icon@2x.png',
        routeName: RepairListPage.routeName,
      ),
      (
        label: l10n.visitorRegistration,
        icon: 'assets/images/visitor_nav_icon@2x.png',
        routeName: VisitorListPage.routeName,
      ),
    ];

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
            items.map((({String label, String icon, String routeName}) item) {
          return HomeNavItem(
            label: item.label,
            icon: item.icon,
            onTap: () => Navigator.pushNamed<void>(context, item.routeName),
          );
        }).toList(growable: false),
      ),
    );
  }
}
