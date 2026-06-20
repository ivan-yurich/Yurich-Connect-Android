import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'theme/yurich_theme.dart';

class YurichConnectApp extends StatelessWidget {
  const YurichConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yurich Connect',
      debugShowCheckedModeBanner: false,
      theme: YurichTheme.dark(),
      home: const HomeScreen(),
    );
  }
}
