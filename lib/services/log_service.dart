import 'dart:io';
import 'package:path/path.dart' as p;

class LogService {
  static String? _logFilePath;

  static Future<void> init() async {
    try {
      final appData = Platform.environment['APPDATA'];
      final baseDir = appData != null && appData.isNotEmpty
          ? appData
          : Directory.current.path;
      final dirPath = p.join(baseDir, 'PortrAI');
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _logFilePath = p.join(dirPath, 'logs.txt');

      final banner = '===== ${DateTime.now().toIso8601String()} START =====\n';
      await File(_logFilePath!).writeAsString(banner, mode: FileMode.append, flush: true);
    } catch (_) {

    }
  }

  static Future<void> log(String message) async {
    try {
      if (_logFilePath == null) {
        await init();
      }
      final ts = DateTime.now().toIso8601String();
      await File(_logFilePath!)
          .writeAsString('[$ts] $message\n', mode: FileMode.append, flush: false);
    } catch (_) {

    }
  }

  static String? get logFilePath => _logFilePath;
}


