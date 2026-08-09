import 'package:flutter/material.dart';
import 'screens/login_screen.dart';

void main() => runApp(const SecureChatApp());

class SecureChatApp extends StatelessWidget {
  const SecureChatApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Secure Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const LoginScreen(),
    );
  }
}
