import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:uuid/uuid.dart';

import '../models/preset.dart';
import '../providers/app_state.dart';
import '../widgets/processing_overlay.dart';
import 'session_service.dart';
import 'ipc_service.dart';
import 'log_service.dart';

class _PendingRequest {
  _PendingRequest({
    required this.context,
    required this.filePaths,
    required this.originalBytes,
  });

  final BuildContext context;
  final List<String> filePaths;
  final Map<String, List<int>> originalBytes;
}

class FileProcessingService {
  static bool _isProcessing = false;
  
  static final Map<String, _PendingRequest> _pendingRequests = {};
  static final Map<String, Map<String, dynamic>> _pendingResponses = {};

  static Future<void> processFiles(
    List<String> filePaths,
    BuildContext context,
    String? externalRequestId,
  ) async {
    if (_isProcessing) {
      print('⚠️ Already processing files, ignoring new request');
      if (externalRequestId != null) {
        await IPCService.signalCompletion(externalRequestId);
      }
      return;
    }

    bool completionSignaled = externalRequestId == null;

    Future<void> maybeSignalCompletion() async {
      if (!completionSignaled && externalRequestId != null) {
        await IPCService.signalCompletion(externalRequestId);
        completionSignaled = true;
      }
    }

    final appState = Provider.of<AppState>(context, listen: false);

    if (appState.presets.isEmpty) {
      _showErrorDialog(context, "Please add a preset first.");
      await maybeSignalCompletion();
      return;
    }

    if (appState.selectedIndex < 0 || appState.selectedIndex >= appState.presets.length) {
      _showErrorDialog(context, "Select a theme first.");
      await maybeSignalCompletion();
      return;
    }

    final validFiles = filePaths.where(_isImageFile).toList();
    if (validFiles.isEmpty) {
      _showErrorDialog(context, "No valid image files found (JPG/PNG only).");
      await maybeSignalCompletion();
      return;
    }
    
    _isProcessing = true;
    
    try {

      final preset = appState.presets[appState.selectedIndex];

      if (preset.isNoEffects) {
        await _processNoEffects(validFiles);
        _showSuccessDialog(context, "Done! Returned original image(s).");
        await maybeSignalCompletion();
      } else if (appState.dataSource == "post") {
        await _processPostDelivery(preset, validFiles);
        _showSuccessDialog(
          context,
          "Request sent! Images will be available in the sharing station.",
        );
        await maybeSignalCompletion();
      } else {
        await _processLive(
          preset,
          validFiles,
          context,
          appState,
          externalRequestId,
        );
        await maybeSignalCompletion();
      }
      
    } catch (e) {
      print('❌ Error processing files: $e');
      _showErrorDialog(context, "Error: $e");
      await maybeSignalCompletion();
    } finally {
      _isProcessing = false;
      _hideProcessingOverlay(context);

      await maybeSignalCompletion();

      if (appState.stayMinimizedDuringCapture && Platform.isWindows) {
        windowManager.minimize();
      }
    }
  }

  static bool _isImageFile(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    return ['.jpg', '.jpeg', '.png'].contains(extension);
  }

  static Future<void> _processNoEffects(List<String> filePaths) async {
    print('🔄 Processing no effects for ${filePaths.length} files');

    for (final filePath in filePaths) {
      final file = File(filePath);
      if (!await file.exists()) {
        continue;
      }

      try {
        final orig = await file.readAsBytes();
        final ext = path.extension(filePath).toLowerCase();
        Uint8List mutated;

        if (ext == '.jpg' || ext == '.jpeg') {
          mutated = _jpegInsertComment(orig, 'no_effects_${DateTime.now().millisecondsSinceEpoch}');
        } else if (ext == '.png') {
          mutated = _pngInsertTextChunk(
            orig,
            'no_effects',
            DateTime.now().millisecondsSinceEpoch.toString(),
          );
        } else {

          await file.writeAsBytes(orig, flush: true);
          try { await file.setLastModified(DateTime.now()); } catch (_) {}
          print('✅ Processed (no effects, timestamp only): $filePath');
          continue;
        }

        await file.writeAsBytes(mutated, flush: true);
        print('✅ Processed (no effects, metadata touch): $filePath');
      } catch (e) {

        try {
          final orig = await file.readAsBytes();
          await file.writeAsBytes(orig, flush: true);
          await file.setLastModified(DateTime.now());
          print('✅ Processed (no effects, fallback timestamp): $filePath');
        } catch (_) {

        }
      }
    }
  }

  static Future<void> _processPostDelivery(Preset preset, List<String> filePaths) async {
    print('🔄 Processing post-delivery for ${filePaths.length} files');

    _sendRequestInBackground(preset, filePaths);

    _replaceWithOriginalImages(filePaths);
  }

  static Future<bool> _processLive(
    Preset preset,
    List<String> filePaths,
    BuildContext context,
    AppState appState,
    String? externalRequestId,
  ) async {
    final requestId = await _sendRequestAndWait(
      preset,
      filePaths,
      context: context,
    );

    final response = _takePendingResponse(requestId);
    if (response == null) {
      throw Exception('No response received from server');
    }

    await _handleLiveResponse(response, requestId, appState);

    if (externalRequestId == null) {
      await IPCService.signalCompletion(requestId);
    }
    return false;
  }

  static void _sendRequestInBackground(
    Preset preset,
    List<String> filePaths,
  ) {

    print('📤 Sending background request for ${filePaths.length} files to ${preset.postProcessingUrl}');

    _sendHttpRequest(
      preset,
      filePaths,
      waitForResponse: false,
      requestId: const Uuid().v4(),
      presetPassword: '',
    );
  }

  static Future<String> _sendRequestAndWait(
    Preset preset,
    List<String> filePaths, {
    BuildContext? context,
  }) async {
    final requestId = const Uuid().v4();

    if (context != null) {

      _pendingRequests[requestId] = _PendingRequest(
        context: context,
        filePaths: filePaths,
        originalBytes: const {},
      );

    }

    try {
      final presetPassword = context != null
          ? Provider.of<AppState>(context, listen: false).presetPassword
          : '';
      final sendFuture = _sendHttpRequest(
        preset,
        filePaths,
        waitForResponse: true,
        requestId: requestId,
        presetPassword: presetPassword,
      );
      if (context != null) {
        OverlayManager.showProcessing(context, 'Waiting for processed image…');
      }
      await sendFuture;
      return requestId;
    } catch (_) {
      _clearPendingRequest(requestId);
      rethrow;
    }
  }
  
  static Map<String, dynamic>? _takePendingResponse(String requestId) {
    return _pendingResponses.remove(requestId);
  }
  
  static void _clearPendingRequest(String requestId) {
    _pendingRequests.remove(requestId);
    _pendingResponses.remove(requestId);
  }
  
  static Future<void> _sendHttpRequest(
    Preset preset,
    List<String> filePaths, {
    required bool waitForResponse,
    required String requestId,
    String presetPassword = '',
  }) async {
    try {

      if (preset.postProcessingUrl.isEmpty) {
        throw Exception('Post processing URL is empty');
      }

      final uri = Uri.parse(preset.postProcessingUrl);
      final encodedUrl = uri.toString();
      
      print('🌐 Making HTTP request to: $encodedUrl');
      await LogService.log('HTTP: send id=$requestId url=$encodedUrl files=${filePaths.length} wait=$waitForResponse');

      final uriParsed = Uri.parse(encodedUrl);
      final request = http.MultipartRequest('POST', uriParsed);
      request.fields['password'] = presetPassword;
      request.fields['id'] = requestId;
      request.fields['preset'] = jsonEncode({
        'title': preset.title,
        'collection': preset.collection,
        'presetId': preset.presetId,
      });

      if (filePaths.isNotEmpty) {
        final first = filePaths.first;
        final file = File(first);
        final stream = http.ByteStream(Stream.castFrom(file.openRead()));
        final length = await file.length();
        final multipartFile = http.MultipartFile(
          'fileToUpload',
          stream,
          length,
          filename: path.basename(first),
          contentType: _contentTypeForPath(first),
        );
        request.files.add(multipartFile);
      }

      request.headers['User-Agent'] = 'PortrAI-Flutter/1.0';

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      await LogService.log('HTTP: received id=$requestId status=${response.statusCode} bytes=${response.bodyBytes.length} contentType=${(response.headers['content-type'] ?? '').toLowerCase()}');
      
      if (waitForResponse) {

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final contentType = (response.headers['content-type'] ?? '').toLowerCase();
          print('✅ HTTP request successful: ${response.statusCode} (content-type: $contentType)');
          if (contentType.startsWith('image/')) {

            _pendingResponses[requestId] = {
              'files': [
                {'bytes': response.bodyBytes},
              ]
            };
          } else if (contentType.startsWith('application/json') || contentType.contains('json')) {
            _pendingResponses[requestId] =
                jsonDecode(response.body) as Map<String, dynamic>;
            print('📄 JSON Response parsed');
          } else {

            try {
              _pendingResponses[requestId] =
                  jsonDecode(response.body) as Map<String, dynamic>;
              print('📄 Fallback JSON Response parsed');
            } catch (_) {
              _pendingResponses[requestId] = {
                'files': [
                  {'bytes': response.bodyBytes},
                ]
              };
              print('📦 Stored non-JSON response as raw bytes');
            }
          }
        } else {
          throw Exception('HTTP request failed: ${response.statusCode} - ${response.body}');
        }
      } else {

        print('📤 Background request sent: ${response.statusCode}');
      }
      
    } catch (e) {
      print('❌ HTTP request error: $e');
      if (waitForResponse) {
        rethrow;
      }

    }
  }

  static MediaType _contentTypeForPath(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    if (ext == '.png') return MediaType('image', 'png');

    return MediaType('image', 'jpeg');
  }

  static Uint8List _jpegInsertComment(Uint8List bytes, String comment) {

    if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) return bytes;
    final payload = Uint8List.fromList(comment.codeUnits);

    final len = payload.length + 2;
    final builder = BytesBuilder();
    builder.add([0xFF, 0xFE, (len >> 8) & 0xFF, len & 0xFF]);
    builder.add(payload);

    final out = BytesBuilder();
    out.add([0xFF, 0xD8]);
    out.add(builder.toBytes());
    out.add(bytes.sublist(2));
    return out.toBytes();
  }

  static Uint8List _pngInsertTextChunk(Uint8List bytes, String key, String text) {

    const sig = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 8) return bytes;
    for (int i = 0; i < 8; i++) {
      if (bytes[i] != sig[i]) return bytes;
    }

    int i = 8;
    while (i + 12 <= bytes.length) {
      final length = _u32be(bytes, i);
      final type = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
      final next = i + 12 + length;
      if (next > bytes.length) break;
      if (type == 'IEND') {

        final data = Uint8List.fromList([
          ...key.codeUnits,
          0x00,
          ...text.codeUnits,
        ]);
        final chunk = _pngChunk('tEXt', data);
        final out = BytesBuilder();
        out.add(bytes.sublist(0, i));
        out.add(chunk);
        out.add(bytes.sublist(i));
        return out.toBytes();
      }
      i = next;
    }
    return bytes;
  }

  static int _u32be(Uint8List b, int off) {
    return (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
  }

  static Uint8List _pngChunk(String type, Uint8List data) {
    final typeBytes = Uint8List.fromList(type.codeUnits);
    final len = data.length;
    final buf = BytesBuilder();

    buf.add([ (len >> 24) & 0xFF, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF ]);

    final body = BytesBuilder();
    body.add(typeBytes);
    body.add(data);
    final bodyBytes = body.toBytes();
    buf.add(bodyBytes);

    final crc = _crc32(bodyBytes);
    buf.add([ (crc >> 24) & 0xFF, (crc >> 16) & 0xFF, (crc >> 8) & 0xFF, crc & 0xFF ]);
    return buf.toBytes();
  }

  static int _crc32(Uint8List data) {

    const poly = 0xEDB88320;
    final table = List<int>.generate(256, (n) {
      var c = n;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (poly ^ (c >> 1)) : (c >> 1);
      }
      return c;
    });
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static void _replaceWithOriginalImages(List<String> filePaths) {
    print('🔄 Replacing with original images for ${filePaths.length} files');


    for (final filePath in filePaths) {
      print('📸 Replaced with original: $filePath');
    }
  }

  static void _showProcessingOverlay(BuildContext context, String message) {
    print('🔄 Showing processing overlay: $message');

    OverlayManager.showProcessing(context, message);
  }

  static void _hideProcessingOverlay(BuildContext context) {
    print('✅ Hiding processing overlay');

    OverlayManager.hideOverlay();
  }

  static void _showSuccessDialog(BuildContext context, String message) {
    print('✅ Success: $message');
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Success'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  static void _showErrorDialog(BuildContext context, String message) {
    print('❌ Error: $message');
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  static Future<Map<String, List<int>>> _readOriginalImages(
    List<String> filePaths,
  ) async {
    final originals = <String, List<int>>{};
    for (final filePath in filePaths) {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('Original file not found: $filePath');
      }
      originals[filePath] = await file.readAsBytes();
    }
    return originals;
  }

  static Future<void> _handleLiveResponse(
    Map<String, dynamic> response,
    String requestId,
    AppState appState,
  ) async {
    final pending = _pendingRequests.remove(requestId);
    if (pending == null) {
      return;
    }

    final fileEntries = response['files'];
    if (fileEntries is! List) {
      throw Exception('Invalid response payload');
    }

    for (var i = 0; i < pending.filePaths.length; i++) {
      final targetPath = pending.filePaths[i];
      final processed = i < fileEntries.length ? fileEntries[i] : null;
      await _storeProcessedFile(
        targetPath,
        processed,
        pending.originalBytes[targetPath],
      );
    }

    OverlayManager.hideOverlay();

  }

  static Future<void> _storeProcessedFile(
    String filePath,
    dynamic processedData,
    List<int>? fallbackBytes,
  ) async {
    final file = File(filePath);
    final start = DateTime.now();
    await LogService.log('WRITE: start path=$filePath');
    if (processedData is Map<String, dynamic>) {
      final raw = processedData['bytes'];
      if (raw is List<int>) {
        await file.writeAsBytes(raw, flush: true);
        final elapsed = DateTime.now().difference(start).inMilliseconds;
        await LogService.log('WRITE: done path=$filePath bytes=${raw.length} ms=$elapsed');
        return;
      }

      final data = processedData['data'];
      if (data is String) {
        final bytes = base64Decode(data.split(',').last);
        await file.writeAsBytes(bytes, flush: true);
        final elapsed = DateTime.now().difference(start).inMilliseconds;
        await LogService.log('WRITE: done(path-base64) path=$filePath bytes=${bytes.length} ms=$elapsed');
        return;
      }
    }

    if (fallbackBytes != null) {
      await file.writeAsBytes(fallbackBytes, flush: true);
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      await LogService.log('WRITE: fallback path=$filePath bytes=${fallbackBytes.length} ms=$elapsed');
    }
  }

  static Future<int> processFilesHeadless(List<String> filePaths) async {
    await LogService.log('Headless: start, files=$filePaths');

    final preset = await SessionService.loadSelectedPreset();
    if (preset == null) {


      print('❌ No saved preset found for headless processing');
      await LogService.log('Headless: no saved preset');
      return 2;
    }

    final validFiles = filePaths.where(_isImageFile).toList();
    if (validFiles.isEmpty) {
      print('❌ No valid image files for headless processing');
      await LogService.log('Headless: no valid image files');
      return 3;
    }

    try {
      if (preset.isNoEffects) {
        await _processNoEffects(validFiles);
        await LogService.log('Headless: no-effects processed');
        return 0;
      }

      final requestId = const Uuid().v4();
      await _sendHttpRequest(
        preset,
        validFiles,
        waitForResponse: true,
        requestId: requestId,
        presetPassword: await SessionService.loadPresetPassword(),
      );

      final response = _takePendingResponse(requestId);
      if (response == null) {
        print('❌ No response received from server in headless mode');
        await LogService.log('Headless: no response from server');
        return 4;
      }

      final fileEntries = response['files'];
      if (fileEntries is! List) {
        print('❌ Invalid response payload in headless mode');
        await LogService.log('Headless: invalid response payload');
        return 5;
      }
      for (var i = 0; i < validFiles.length; i++) {
        final targetPath = validFiles[i];
        final processed = i < fileEntries.length ? fileEntries[i] : null;
        await _storeProcessedFile(
          targetPath,
          processed,
          null,
        );
      }

      await LogService.log('Headless: success');
      return 0;
    } catch (e) {
      print('❌ Headless processing error: $e');
      await LogService.log('Headless: error: $e');
      return 6;
    }
  }
}
