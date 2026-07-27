import 'package:flutter/material.dart';

import '../../api/home.dart';
import '../../constants/tab_config.dart';
import '../home/index.dart';
import '../mine/index.dart';

class TabsPage extends StatefulWidget {
  const TabsPage({
    this.announcementLoader = getAnnouncementListApi,
    super.key,
  });

  final AnnouncementLoader announcementLoader;

  @override
  State<TabsPage> createState() => _TabsPageState();
}

class _TabsPageState extends State<TabsPage> {
  int _currentIndex = 0;

  List<BottomNavigationBarItem> getTabs() {
    return tabsList.map((TabConfig item) {
      return BottomNavigationBarItem(
        icon: Image.asset(
          item.icon,
          width: 28,
          height: 28,
          fit: BoxFit.contain,
        ),
        activeIcon: Image.asset(
          item.activeIcon,
          width: 28,
          height: 28,
          fit: BoxFit.contain,
        ),
        label: item.label,
      );
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: <Widget>[
          HomePage(announcementLoader: widget.announcementLoader),
          const MinePage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: getTabs(),
        currentIndex: _currentIndex,
        selectedItemColor: const Color(0xFF5591AF),
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        onTap: (int index) {
          setState(() {
            _currentIndex = index;
          });
        },
      ),
    );
  }
}
