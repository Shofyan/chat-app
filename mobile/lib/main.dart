import 'package:flutter/material.dart';

import 'core/app_controller.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'widgets/common.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RuangApp());
}

class RuangApp extends StatefulWidget {
  const RuangApp({super.key});
  @override
  State<RuangApp> createState() => _RuangAppState();
}

class _RuangAppState extends State<RuangApp> with WidgetsBindingObserver {
  final app = AppController();
  final _navigator = GlobalKey<NavigatorState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(_sessionChanged);
    app.initialize();
  }

  void _sessionChanged() {
    if (app.user == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _navigator.currentState?.popUntil((route) => route.isFirst);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) app.realtime.reconnect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(_sessionChanged);
    app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => MaterialApp(
      navigatorKey: _navigator,
      title: 'Ruang Chat',
      debugShowCheckedModeBanner: false,
      theme: ruangTheme(Brightness.light),
      darkTheme: ruangTheme(Brightness.dark),
      themeMode: app.themeMode,
      home: app.loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : app.startupError != null
          ? Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const BrandMark(),
                      const SizedBox(height: 24),
                      Text(app.startupError!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: app.initialize,
                        child: const Text('Coba lagi'),
                      ),
                      TextButton(
                        onPressed: app.forgetSession,
                        child: const Text('Kembali ke halaman masuk'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : app.user == null
          ? AuthScreen(app: app)
          : HomeScreen(key: ValueKey(app.user!.id), app: app),
    ),
  );
}
