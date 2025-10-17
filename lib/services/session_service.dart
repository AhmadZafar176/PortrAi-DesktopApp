import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../models/preset.dart';
import '../providers/app_state.dart';
import 'package:provider/provider.dart';

class SessionService {
  static String _sessionDirPath() {
    final appData = Platform.environment['APPDATA'];
    final baseDir = appData != null && appData.isNotEmpty
        ? appData
        : Directory.current.path;
    return p.join(baseDir, 'PortrAI');
  }

  static String _sessionFilePath() {
    return p.join(_sessionDirPath(), 'session.json');
  }

  static Future<void> saveSelectedPreset(Preset preset, {String presetPassword = ''}) async {
    try {
      final dir = Directory(_sessionDirPath());
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final file = File(_sessionFilePath());
      final data = <String, dynamic>{
        'presetId': preset.presetId,
        'title': preset.title,
        'collection': preset.collection,
        'postProcessingUrl': preset.postProcessingUrl,
        'isNoEffects': preset.isNoEffects,
        'presetPassword': presetPassword,
        'savedAt': DateTime.now().toIso8601String(),
      };

      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      // Best-effort; log and continue
      // ignore: avoid_print
      print('❌ Failed to save session preset: $e');
    }
  }

  static Future<Preset?> loadSelectedPreset() async {
    try {
      final file = File(_sessionFilePath());
      if (!await file.exists()) {
        return null;
      }
      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      return Preset(
        presetId: (data['presetId'] ?? '') as String,
        title: (data['title'] ?? '') as String,
        collection: (data['collection'] ?? 'Default') as String,
        postProcessingUrl: (data['postProcessingUrl'] ?? '') as String,
        isNoEffects: (data['isNoEffects'] ?? false) as bool,
      );
    } catch (e) {
      // ignore: avoid_print
      print('❌ Failed to load session preset: $e');
      return null;
    }
  }

  static Future<String> loadPresetPassword() async {
    try {
      final file = File(_sessionFilePath());
      if (!await file.exists()) return '';
      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      return (data['presetPassword'] ?? '') as String;
    } catch (_) {
      return '';
    }
  }

  static String _completionFilePath() {
    return p.join(_sessionDirPath(), 'worker_done.signal');
  }

  static Future<void> signalWorkerDone() async {
    try {
      final file = File(_completionFilePath());
      await file.writeAsString('done');
    } catch (_) {}
  }

  static Future<bool> checkWorkerDone() async {
    try {
      final file = File(_completionFilePath());
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearWorkerDone() async {
    try {
      final file = File(_completionFilePath());
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static String _donePressedFilePath() {
    return p.join(_sessionDirPath(), 'done_pressed.signal');
  }

  static Future<void> signalDonePressed() async {
    try {
      final file = File(_donePressedFilePath());
      await file.writeAsString('done');
    } catch (_) {}
  }

  static Future<bool> checkDonePressed() async {
    try {
      final file = File(_donePressedFilePath());
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearDonePressed() async {
    try {
      final file = File(_donePressedFilePath());
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}


