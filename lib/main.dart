import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/app_state.dart';
import 'services/error_handler.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'widgets/error_boundary.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize global error handling
  ErrorHandler.instance.initialize();

  // Add error reporters
  ErrorHandler.instance.addReporter(ConsoleErrorReporter());
  if (kDebugMode) {
    ErrorHandler.instance.addReporter(MemoryErrorReporter());
  }

  // Run the app in a zone to catch async errors
  runZonedGuarded(
    () => runApp(const MyApp()),
    (error, stackTrace) {
      ErrorHandler.instance.reportError(
        error,
        stackTrace,
        context: 'Main zone error',
      );
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ErrorBoundary(
      errorMessage:
          'The app encountered a critical error and needs to restart.',
      onError: (error) {
        ErrorHandler.instance.reportError(
          error.exception,
          error.stack,
          context: 'App-level error boundary',
        );
      },
      child: ChangeNotifierProvider(
        create: (context) => AppState(),
        child: Consumer<AppState>(
          builder: (context, appState, child) {
            return MaterialApp(
              title: 'Voidweaver',
              theme: ThemeData(
                primarySwatch: Colors.deepPurple,
                visualDensity: VisualDensity.adaptivePlatformDensity,
                brightness: Brightness.light,
              ),
              darkTheme: ThemeData(
                primarySwatch: Colors.deepPurple,
                visualDensity: VisualDensity.adaptivePlatformDensity,
                brightness: Brightness.dark,
              ),
              themeMode:
                  appState.settingsService?.themeMode ?? ThemeMode.system,
              home: const AppRouter().withErrorBoundary(
                errorMessage: 'Failed to load the main application screen.',
              ),
            );
          },
        ),
      ),
    );
  }
}

class AppRouter extends StatefulWidget {
  const AppRouter({super.key});

  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await context.read<AppState>().initialize();
    if (mounted) {
      setState(() {
        _initialized = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Consumer<AppState>(
      builder: (context, appState, child) {
        return appState.isConfigured ? const HomeScreen() : const LoginScreen();
      },
    );
  }
}
