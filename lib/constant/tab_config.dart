class TabConfig {
  const TabConfig({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });

  final String label;
  final String icon;
  final String activeIcon;
}

const List<TabConfig> tabsList = <TabConfig>[
  TabConfig(
    label: '首页',
    icon: 'assets/tabs/home_default.png',
    activeIcon: 'assets/tabs/home_active.png',
  ),
  TabConfig(
    label: '我的',
    icon: 'assets/tabs/my_default.png',
    activeIcon: 'assets/tabs/my_active.png',
  ),
];
