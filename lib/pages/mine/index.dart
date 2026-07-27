import 'package:flutter/material.dart';

import '../profile/index.dart';

class MinePage extends StatelessWidget {
  const MinePage({super.key});

  static const Color _backgroundColor = Color(0xFF5B9AB8);

  static const List<({String label, String icon})> _menuItems =
      <({String label, String icon})>[
    (
      label: '我的房屋',
      icon: 'assets/images/house_profile_icon@2x.png',
    ),
    (
      label: '我的报修',
      icon: 'assets/images/repair_profile_icon@2x.png',
    ),
    (
      label: '访客记录',
      icon: 'assets/images/visitor_profile_icon@2x.png',
    ),
  ];

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _backgroundColor,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            const SizedBox(
              height: 64,
              child: Center(
                child: Text(
                  '我的',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Row(
                children: <Widget>[
                  ClipOval(
                    child: Image.asset(
                      'assets/images/avatar_1.jpg',
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Text(
                      '用户名',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      Navigator.pushNamed(context, ProfilePage.routeName);
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            '去完善信息',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: _menuItems.map(
                  (({String label, String icon}) item) {
                    return InkWell(
                      onTap: () => _showMessage(context, item.label),
                      child: SizedBox(
                        height: 72,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            children: <Widget>[
                              Image.asset(
                                item.icon,
                                width: 48,
                                height: 48,
                                fit: BoxFit.contain,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  item.label,
                                  style: const TextStyle(
                                    color: Color(0xFF262626),
                                    fontSize: 20,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right_rounded,
                                color: Color(0xFFA7A7A7),
                                size: 32,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ).toList(growable: false),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
