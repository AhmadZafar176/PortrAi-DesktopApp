import 'dart:io';
import 'package:path/path.dart' as p;

class LogService {
  static String? _logFilePath;
  static const int maxLogFileSizeBytes = 10 * 1024 * 1024;

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

      await _rotateLogIfNeeded();

      final banner = '===== ${DateTime.now().toIso8601String()} START =====\n';
      await File(_logFilePath!).writeAsString(banner, mode: FileMode.append, flush: true);
    } catch (_) {

    }
  }

  static Future<void> _rotateLogIfNeeded() async {
    try {
      if (_logFilePath == null) return;
      final logFile = File(_logFilePath!);
      if (!await logFile.exists()) return;
      
      final fileSize = await logFile.length();
      if (fileSize > maxLogFileSizeBytes) {
        final backupPath = '${_logFilePath!}.old';
        final backupFile = File(backupPath);
        if (await backupFile.exists()) {
          await backupFile.delete();
        }
        await logFile.rename(backupPath);
        print('✅ Log file rotated (size: $fileSize bytes)');
      }
    } catch (e) {
      print('⚠️ Error rotating log file: $e');
    }
  }

  static Future<void> log(String message) async {
    try {
      if (_logFilePath == null) {
        await init();
      }
      
      await _rotateLogIfNeeded();
      
      final ts = DateTime.now().toIso8601String();
      await File(_logFilePath!)
          .writeAsString('[$ts] $message\n', mode: FileMode.append, flush: false);
    } catch (_) {

    }
  }

  static String? get logFilePath => _logFilePath;
}


