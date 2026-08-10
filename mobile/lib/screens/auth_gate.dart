import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/settings_service.dart';
import 'chat_list_screen.dart';
import 'login_screen.dart';

/// Decides what the user sees on launch:
/// - "Stay signed in" is OFF -> always sign out and show Login.
/// - "Stay signed in" is ON (default) -> follow Firebase's own session
///   state, so a signed-in user goes straight to their chats instead of
///   being asked to log in again every time the app is reopened.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _authService = AuthService();
  late final Future<bool> _stayLoggedIn;

  @override
  void initState() {
    super.initState();
    _stayLoggedIn = _prepare();
  }

  Future<bool> _prepare() async {
    final stayLoggedIn = await SettingsService.getStayLoggedIn();
    if (!stayLoggedIn) {
      await _authService.logout();
    }
    return stayLoggedIn;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _stayLoggedIn,
      builder: (context, prefSnapshot) {
        if (!prefSnapshot.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return StreamBuilder(
          stream: _authService.authStateChanges,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }
            if (snapshot.hasData) {
              return const ChatListScreen();
            }
            return const LoginScreen();
          },
        );
      },
    );
  }
}
