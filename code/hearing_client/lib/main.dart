import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'theme.dart';

void main() {
  // The WebSocket server and the database both start from HomeScreen, once the
  // binding is up -- see _HomeScreenState._boot.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HearingApp());
}

class HearingApp extends StatelessWidget {
  const HearingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hearing Screener',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppTheme.cyan,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}
