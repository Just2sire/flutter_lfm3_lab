import 'package:flutter/material.dart';

import 'home_page.dart';

void main() {
  runApp(const Lfm3App());
}

class Lfm3App extends StatelessWidget {
  const Lfm3App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LFM3 Lab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.brown, useMaterial3: true),
      home: const HomePage(),
    );
  }
}
