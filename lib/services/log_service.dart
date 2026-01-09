import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

class LogService {
  static String? _logFilePath;
  static const int maxLogFileSizeBytes = 10 * 1024 * 1024;
  static Future<void> _writeQueue = Future<void>.value();
  static bool _initialized = false;

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

      final banner =
          '===== ${DateTime.now().toIso8601String()} START pid=${pid} =====\n';
      await File(_logFilePath!)
          .writeAsString(banner, mode: FileMode.append, flush: true);
      _initialized = true;
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
        debugPrint('✅ Log file rotated (size: $fileSize bytes)');
      }
    } catch (e) {
      debugPrint('⚠️ Error rotating log file: $e');
    }
  }

  static Future<void> log(String message) async {
    _writeQueue = _writeQueue.then((_) async {
    try {
        if (_logFilePath == null || !_initialized) {
        await init();
      }
        if (_logFilePath == null) return;
      
      await _rotateLogIfNeeded();
      
      final ts = DateTime.now().toIso8601String();
        await File(_logFilePath!).writeAsString(
          '[$ts] $message\n',
          mode: FileMode.append,
          flush: true,
        );
    } catch (_) {
    }
    });
    return _writeQueue;
  }

  static String? get logFilePath => _logFilePath;
}


