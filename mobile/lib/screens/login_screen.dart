import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/settings_service.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();

  bool _loading = false;
  bool _obscurePassword = true;
  bool _stayLoggedIn = true;
  bool _usePhoneTab = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    SettingsService.getStayLoggedIn().then((value) {
      if (mounted) setState(() => _stayLoggedIn = value);
    });
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _authService.loginWithEmail(_emailController.text.trim(), _passwordController.text);
      await SettingsService.setStayLoggedIn(_stayLoggedIn);
      // AuthGate is listening to authStateChanges, so no manual navigation
      // is needed here — it will swap to ChatListScreen automatically.
    } catch (e) {
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('invalid-credential') || msg.contains('wrong-password')) {
      return 'Incorrect email or password.';
    }
    if (msg.contains('user-not-found')) return 'No account found for that email.';
    if (msg.contains('too-many-requests')) return 'Too many attempts. Try again later.';
    return 'Sign-in failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                Icon(Icons.lock_outline_rounded, size: 56, color: scheme.primary),
                const SizedBox(height: 12),
                Text(
                  'Welcome back',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Sign in to continue',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 28),

                // Email / Phone tab
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Email'), icon: Icon(Icons.email_outlined)),
                    ButtonSegment(value: true, label: Text('Phone'), icon: Icon(Icons.phone_outlined)),
                  ],
                  selected: {_usePhoneTab},
                  onSelectionChanged: (s) => setState(() => _usePhoneTab = s.first),
                ),
                const SizedBox(height: 16),

                if (_usePhoneTab)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, color: scheme.primary, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Phone sign-in needs a one-time setup in the Firebase console '
                            '(SMS verification). Use Email for now — ask to have Phone '
                            'sign-in enabled next.',
                            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  )
                else ...[
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Stay signed in'),
                    subtitle: const Text('Off = sign in again every time you open the app'),
                    value: _stayLoggedIn,
                    onChanged: (v) => setState(() => _stayLoggedIn = v),
                  ),
                  const SizedBox(height: 8),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: TextStyle(color: scheme.error)),
                    ),
                  ElevatedButton(
                    onPressed: _loading ? null : _login,
                    child: _loading
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                          )
                        : const Text('Sign in'),
                  ),
                ],

                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RegisterScreen()),
                  ),
                  child: const Text("Don't have an account? Sign up"),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
