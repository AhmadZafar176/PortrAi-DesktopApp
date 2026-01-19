import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../models/preset.dart';
import '../providers/app_state.dart';
import 'package:provider/provider.dart';

class SessionService {
  static const String phaseIdle = 'idle';
  static const String phaseCapturing = 'capturing';
  static const String phaseWaitingSessionEnd = 'waiting_session_end';

  static String _sessionDirPath() {
    final appData = Platform.environment['APPDATA'];
    final baseDir = appData != null && appData.isNotEmpty
        ? appData
        : Directory.current.path;
    return p.join(baseDir, 'PortrAI');
  }

  static String _activeSessionPath() {
    return p.join(_sessionDirPath(), 'active_session.txt');
  }

  static String _activeSessionPhasePath() {
    return p.join(_sessionDirPath(), 'active_session_phase.txt');
  }

  static String _sessionFilePath() {
    return p.join(_sessionDirPath(), 'session.json');
  }

  static Future<String> startSession() async {
    final dir = Directory(_sessionDirPath());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final token = DateTime.now().microsecondsSinceEpoch.toString();
    try {
      await File(_activeSessionPath()).writeAsString(token, flush: true);
      await File(_activeSessionPhasePath()).writeAsString(phaseCapturing, flush: true);
    } catch (e) {
      assert(() {
        print('âš ï¸ SessionService.startSession failed: $e');
        return true;
      }());
    }
    return token;
  }

  static Future<String?> getActiveSessionToken() async {
    try {
      final f = File(_activeSessionPath());
      if (!await f.exists()) return null;
      final token = (await f.readAsString()).trim();
      if (token.isEmpty) return null;
      return token;
    } catch (e) {
      assert(() {
        print('âš ï¸ SessionService.getActiveSessionToken failed: $e');
        return true;
      }());
      return null;
    }
  }

  static Future<String> getActiveSessionPhase() async {
    try {
      final f = File(_activeSessionPhasePath());
      if (!await f.exists()) return phaseIdle;
      final phase = (await f.readAsString()).trim();
      return phase.isEmpty ? phaseIdle : phase;
    } catch (e) {
      assert(() {
        print('âš ï¸ SessionService.getActiveSessionPhase failed: $e');
        return true;
      }());
      return phaseIdle;
    }
  }

  static Future<void> setActiveSessionPhase(String phase) async {
    try {
      final dir = Directory(_sessionDirPath());
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await File(_activeSessionPhasePath()).writeAsString(phase, flush: true);
    } catch (e) {
      assert(() {
        print('âš ï¸ SessionService.setActiveSessionPhase failed: $e');
        return true;
      }());
    }
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


      print('âŒ Failed to save session preset: $e');
    }
  }

  static Future<Preset?> loadSelectedPreset() async {
    try {
      final file = File(_sessionFilePath());
      if (!await file.exists()) {
        return null;
      }
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      final data = decoded.cast<String, dynamic>();
      return Preset(
        presetId: (data['presetId'] ?? '') as String,
        title: (data['title'] ?? '') as String,
        collection: (data['collection'] ?? 'Default') as String,
        postProcessingUrl: (data['postProcessingUrl'] ?? '') as String,
        isNoEffects: (data['isNoEffects'] ?? false) as bool,
      );
    } catch (e) {

      print('âŒ Failed to load session preset: $e');
      return null;
    }
  }

  static Future<String> loadPresetPassword() async {
    try {
      final file = File(_sessionFilePath());
      if (!await file.exists()) return '';
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is! Map) return '';
      final data = decoded.cast<String, dynamic>();
      final v = data['presetPassword'];
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

  static String _completionFilePath() {
    return p.join(_sessionDirPath(), 'worker_done.signal');
  }

  static Future<void> signalWorkerDoneToken(String token) async {
    try {
      final file = File(_completionFilePath());
      await file.writeAsString(token, flush: true);
    } catch (_) {}
  }

  static Future<bool> checkWorkerDoneToken(String token) async {
    try {
      final file = File(_completionFilePath());
      if (!await file.exists()) return false;
      final v = (await file.readAsString()).trim();
      return v == token;
    } catch (_) {
      return false;
    }
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

  static String _pendingSessionEndPath() {
    return p.join(_sessionDirPath(), 'pending_session_end.signal');
  }

  static Future<void> signalDonePressedToken(String token) async {
    try {
      final file = File(_donePressedFilePath());
      await file.writeAsString(token, flush: true);
    } catch (_) {}
  }

  static Future<bool> checkDonePressedToken(String token) async {
    try {
      final file = File(_donePressedFilePath());
      if (!await file.exists()) return false;
      final v = (await file.readAsString()).trim();
      return v == token;
    } catch (_) {
      return false;
    }
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

  static Future<void> setPendingSessionEnd() async {
    try {
      final file = File(_pendingSessionEndPath());
      await file.writeAsString('pending', flush: true);
    } catch (_) {}
  }

  static Future<bool> hasPendingSessionEnd() async {
    try {
      final file = File(_pendingSessionEndPath());
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearPendingSessionEnd() async {
    try {
      final file = File(_pendingSessionEndPath());
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static Future<void> clearSession() async {
    try {
      final file = File(_sessionFilePath());
      if (await file.exists()) {
        await file.delete();
        print('âœ… Session data cleared');
      }
    } catch (e) {
      print('âŒ Failed to clear session: $e');
    }
  }
}


