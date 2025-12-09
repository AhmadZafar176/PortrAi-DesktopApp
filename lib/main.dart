import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:window_manager/window_manager.dart';
import 'providers/app_state.dart';
import 'screens/main_screen.dart';
import 'screens/login_screen.dart';
import 'theme/app_theme.dart';
import 'services/firebase_config.dart';
import 'services/ipc_service.dart';
import 'services/file_processing_service.dart';
import 'services/log_service.dart';
import 'worker_overlay_app.dart';
import 'done_button_app.dart';
import 'services/event_server_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LogService.init();
  runZonedGuarded(() async {
    if (!Platform.isWindows) {
      runApp(const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Text(
              'This build is supported only on Windows.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ));
      return;
    }

    final allArgs = await _getAllArgs();
    await LogService.log('Startup args: $allArgs');

    if (allArgs.contains('--done-button')) {
      runApp(const DoneButtonApp());
      return;
    }

    final droppedFiles = await _getCommandLineFiles();
    if (droppedFiles.isNotEmpty) {
      await LogService.log('WorkerOverlay: files: $droppedFiles');
      runApp(WorkerOverlayApp(files: droppedFiles));
      return;
    }

    await windowManager.ensureInitialized();

    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setFullScreen(true);

    WindowOptions windowOptions = const WindowOptions(
      minimumSize: Size(1024, 768),
      center: true,
      title: 'PortrAI - Photobooth Setup',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: FirebaseConfig.apiKey,
        authDomain: FirebaseConfig.authDomain,
        projectId: FirebaseConfig.projectId,
        storageBucket: FirebaseConfig.storageBucket,
        messagingSenderId: FirebaseConfig.messagingSenderId,
        appId: FirebaseConfig.appId,
        measurementId: FirebaseConfig.measurementId,
      ),
    );

    await LogService.log('GUI started');
    runApp(const PortraiApp());
  }, (error, stack) async {
    await LogService.log('Uncaught error: $error\n$stack');
  });
}

Future<List<String>> _getCommandLineFiles() async {
  final args = await _getAllArgs();
  final cleaned = args.map(_stripQuotes).toList();
  return cleaned
      .where((arg) => File(arg).existsSync())
      .where((arg) => _isImageFile(arg))
      .toList();
}

String _stripQuotes(String s) {
  final t = s.trim();
  if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'")))) {
    return t.substring(1, t.length - 1);
  }
  return t;
}

Future<List<String>> _getAllArgs() async {
  final result = <String>[];
      try {
    final appData = Platform.environment['APPDATA'];
    final baseDir = appData != null && appData.isNotEmpty
        ? appData
        : Directory.current.path;
    final argsFile = File('$baseDir/PortrAI/args.txt');
    if (await argsFile.exists()) {
      final lines = await argsFile.readAsLines();
      result.addAll(lines.where((l) => l.trim().isNotEmpty));
    }
  } catch (_) {}
  try {
    result.addAll(Platform.executableArguments);
  } catch (_) {}
  return result;
}

bool _isImageFile(String filePath) {
  final extension = filePath.toLowerCase().split('.').last;
  return ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].contains(extension);
}

class PortraiApp extends StatefulWidget {
  const PortraiApp({super.key});

  @override
  State<PortraiApp> createState() => _PortraiAppState();
}

class _PortraiAppState extends State<PortraiApp> {
  final IPCService _ipcService = IPCService();
  final EventServerService _eventServer = EventServerService();

  @override
  void initState() {
    super.initState();
    _startIPCServer();
    _startEventServer();
  }

  void _startIPCServer() async {
    final success = await _ipcService.startServer((requestId, filePaths) {
      _processFilesInContext(filePaths, requestId);
    });

    if (success) {
      final commandLineFiles = await _getCommandLineFiles();
      if (commandLineFiles.isNotEmpty) {
        _processFilesInContext(commandLineFiles, '');
      }
    }
  }

  void _startEventServer() async {
    final ok = await _eventServer.start(port: 8000);
    if (!ok) {
      await LogService.log('EventServer: failed to bind');
    } else {
      await LogService.log('EventServer: started on 127.0.0.1:8000');
    }
  }

  void _processFilesInContext(List<String> filePaths, String requestId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        FileProcessingService.processFiles(filePaths, context, requestId);
      }
    });
  }

  @override
  void dispose() {
    _ipcService.dispose();
    _eventServer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => AppState()..initialize(),
      child: Consumer<AppState>(
        builder: (context, appState, child) {
          return MaterialApp(
            title: 'PortrAI - Photobooth Setup',
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: appState.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            home: appState.currentUser != null 
                ? const MainScreen() 
                : const LoginScreen(),
            debugShowCheckedModeBanner: false,
            builder: (context, child) {
              final mq = MediaQuery.of(context);
              return MediaQuery(
                data: mq.copyWith(
                  textScaler: const TextScaler.linear(1.0),
                ),
                child: child!,
              );
            },
          );
        },
      ),
    );
  }
}
