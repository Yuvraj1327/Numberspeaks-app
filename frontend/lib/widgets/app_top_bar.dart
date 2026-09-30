import 'package:flutter/material.dart';

import 'app_logo.dart';

/// The single shared top navbar for every tab inside [MainShell] — logo +
/// wordmark on the left, kept compact (standard toolbar height, no large
/// standalone heading), with a small account affordance on the right
/// instead of a logout icon (logout itself lives in the Account/Settings
/// tabs — see those screens).
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  final VoidCallback? onAccountTap;

  const AppTopBar({super.key, this.onAccountTap});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      titleSpacing: 16,
      title: const Row(
        children: [
          AppLogo(size: 28),
          SizedBox(width: 10),
          Text('Numberspeaks'),
        ],
      ),
      actions: [
        if (onAccountTap != null)
          IconButton(
            tooltip: 'Account',
            onPressed: onAccountTap,
            icon: const CircleAvatar(
              radius: 15,
              backgroundColor: Colors.white24,
              child: Icon(Icons.person_outline, size: 17, color: Colors.white),
            ),
          ),
        const SizedBox(width: 6),
      ],
    );
  }
}
