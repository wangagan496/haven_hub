import 'package:flutter/material.dart';

class HomeNavItem extends StatelessWidget {
  const HomeNavItem({
    required this.label,
    required this.icon,
    this.onTap,
    super.key,
  });

  final String label;
  final String icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Image.asset(
                icon,
                width: 52,
                height: 52,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
