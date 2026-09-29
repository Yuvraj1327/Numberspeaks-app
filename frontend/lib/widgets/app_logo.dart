import 'package:flutter/material.dart';

/// The Numberspeaks brand mark. Used in the top nav bar and on the Login
/// screen so the same asset appears everywhere in the app.
class AppLogo extends StatelessWidget {
  final double size;

  const AppLogo({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/logo.png',
      width: size,
      height: size,
    );
  }
}
