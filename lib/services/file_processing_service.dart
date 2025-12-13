import 'dart:async';
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
  static final Map<String, DateTime> _pendingResponseTimestamps = {};
  
  static const int maxFileSizeBytes = 100 * 1024 * 1024;
  static const int maxResponseSizeBytes = 100 * 1024 * 1024;
  static DateTime? _lastRequestTime;
  static int _requestCount = 0;
  static const int maxRequestsPerMinute = 10;
  static const Duration rateLimitWindow = Duration(minutes: 1);
  static const Duration responseCleanupTimeout = Duration(minutes: 5);

  static Future<void> processFiles(
    List<String> filePaths,
    BuildContext context,
    String? externalRequestId,
  ) async {
    // Null safety check
    if (filePaths.isEmpty) {
      print('ΓÜá∩╕Å No files provided for processing');
      if (externalRequestId != null) {
        await IPCService.signalCompletion(externalRequestId);
      }
      return;
    }
    
    if (_isProcessing) {
      print('ΓÜá∩╕Å Already processing files, ignoring new request');
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

    AppState? appState;
    try {
      appState = Provider.of<AppState>(context, listen: false);
    } catch (e) {
      print('⚠️ Context is invalid or disposed, cannot process files: $e');
      await maybeSignalCompletion();
      return;
    }

    // Null safety checks
    if (appState.presets.isEmpty) {
      try {
        _showErrorDialog(context, "Please add a preset first.");
      } catch (_) {
        print('⚠️ Context invalid, cannot show error dialog');
      }
      await maybeSignalCompletion();
      return;
    }

    if (appState.selectedIndex < 0 || appState.selectedIndex >= appState.presets.length) {
      try {
        _showErrorDialog(context, "Select a theme first.");
      } catch (_) {
        print('⚠️ Context invalid, cannot show error dialog');
      }
      await maybeSignalCompletion();
      return;
    }
    
    // Additional null safety check
    final selectedPreset = appState.presets[appState.selectedIndex];
    if (selectedPreset.presetId.isEmpty) {
      try {
        _showErrorDialog(context, "Invalid preset selected.");
      } catch (_) {
        print('⚠️ Context invalid, cannot show error dialog');
      }
      await maybeSignalCompletion();
      return;
    }

    final validFiles = filePaths.where(_isImageFile).toList();
    if (validFiles.isEmpty) {
      try {
        _showErrorDialog(context, "No valid image files found (JPG/PNG only).");
      } catch (_) {
        print('⚠️ Context invalid, cannot show error dialog');
      }
      await maybeSignalCompletion();
      return;
    }
    
    bool processingFlagSet = false;
    try {
      _isProcessing = true;
      processingFlagSet = true;

      final preset = appState.presets[appState.selectedIndex];

      if (preset.isNoEffects) {
        await _processNoEffects(validFiles);
        try {
          _showSuccessDialog(context, "Done! Returned original image(s).");
        } catch (_) {
          print('⚠️ Context invalid, cannot show success dialog');
        }
        await maybeSignalCompletion();
      } else if (appState.dataSource == "post") {
        await _processPostDelivery(preset, validFiles);
        try {
          _showSuccessDialog(
            context,
            "Request sent! Images will be available in the sharing station.",
          );
        } catch (_) {
          print('⚠️ Context invalid, cannot show success dialog');
        }
        await maybeSignalCompletion();
      } else {
        await _processLive(
          preset,
          validFiles,
          context,
          appState,
          externalRequestId,
        );
      }
      
    } catch (e) {
      print('Γ¥î Error processing files: $e');
      try {
        _showErrorDialog(context, "Error: $e");
      } catch (_) {
        print('⚠️ Context invalid, cannot show error dialog');
      }
      await maybeSignalCompletion();
    } finally {
      if (processingFlagSet) {
        _isProcessing = false;
      }
      try {
        _hideProcessingOverlay(context);
      } catch (_) {
        print('⚠️ Context invalid, cannot hide processing overlay');
      }

      if (appState != null && appState.stayMinimizedDuringCapture && Platform.isWindows) {
        try {
          windowManager.minimize();
        } catch (e) {
          print('⚠️ Failed to minimize window: $e');
        }
      }
    }
  }

  static bool _isImageFile(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    return ['.jpg', '.jpeg', '.png'].contains(extension);
  }

  static Future<void> _processNoEffects(List<String> filePaths) async {
    print('≡ƒöä Processing no effects for ${filePaths.length} files');

    for (final filePath in filePaths) {
      final file = File(filePath);
      if (!await file.exists()) {
        continue;
      }

      try {
        final fileSize = await file.length();
        if (fileSize > maxFileSizeBytes) {
          print('⚠️ File too large, skipping: $filePath (${fileSize} bytes)');
          continue;
        }
        if (fileSize == 0) {
          print('⚠️ File is empty, skipping: $filePath');
          continue;
        }
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
          try {
            await file.writeAsBytes(orig, flush: true);
            try { await file.setLastModified(DateTime.now()); } catch (_) {}
            print('Γ£à Processed (no effects, timestamp only): $filePath');
          } on FileSystemException catch (e) {
            if (e.osError?.errorCode == 2 || e.osError?.errorCode == 3) {
              print('⚠️ File was deleted during write: $filePath');
              continue;
            }
            rethrow;
          }
          continue;
        }

        try {
          await file.writeAsBytes(mutated, flush: true);
          print('Γ£à Processed (no effects, metadata touch): $filePath');
        } on FileSystemException catch (e) {
          if (e.osError?.errorCode == 2 || e.osError?.errorCode == 3) {
            print('⚠️ File was deleted during write: $filePath');
            continue;
          }
          rethrow;
        }
      } catch (e) {
        if (e is FileSystemException && (e.osError?.errorCode == 2 || e.osError?.errorCode == 3)) {
          print('⚠️ File was deleted during read: $filePath');
          continue;
        }

        try {
          final orig = await file.readAsBytes();
          try {
            await file.writeAsBytes(orig, flush: true);
            await file.setLastModified(DateTime.now());
            print('Γ£à Processed (no effects, fallback timestamp): $filePath');
          } on FileSystemException catch (writeError) {
            if (writeError.osError?.errorCode == 2 || writeError.osError?.errorCode == 3) {
              print('⚠️ File was deleted during fallback write: $filePath');
            } else {
              rethrow;
            }
          }
        } catch (_) {

        }
      }
    }
  }

  static Future<void> _processPostDelivery(Preset preset, List<String> filePaths) async {
    print('≡ƒöä Processing post-delivery for ${filePaths.length} files');

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
    String? requestId;
    try {
      requestId = await _sendRequestAndWait(
        preset,
        filePaths,
        context: context,
      );

      Map<String, dynamic>? response = _takePendingResponse(requestId);
      
      if (response == null) {
        const maxRetries = 60;
        const retryDelay = Duration(milliseconds: 100);
        const timeout = Duration(minutes: 2);
        final startTime = DateTime.now();
        int retries = 0;
        
        while (response == null && retries < maxRetries) {
          final elapsed = DateTime.now().difference(startTime);
          if (elapsed > timeout) {
            throw Exception('No response received from server after 2 minutes timeout');
          }
          
          retries++;
          await Future.delayed(retryDelay);
          response = _takePendingResponse(requestId);
        }
        
        if (response == null) {
          throw Exception('No response received from server after $maxRetries attempts');
        }
      }

      await _handleLiveResponse(response, requestId, appState);

      if (externalRequestId != null) {
        await IPCService.signalCompletion(externalRequestId);
      }
      return false;
    } catch (e) {
      try {
        _hideProcessingOverlay(context);
      } catch (_) {
        print('⚠️ Context invalid, cannot hide processing overlay');
      }
      if (requestId != null) {
        _clearPendingRequest(requestId);
      }
      if (externalRequestId != null) {
        try {
          await IPCService.signalCompletion(externalRequestId);
        } catch (completionError) {
          print('⚠️ Failed to signal completion on error: $completionError');
        }
      }
      rethrow;
    }
  }

  static void _sendRequestInBackground(
    Preset preset,
    List<String> filePaths,
  ) {

    print('≡ƒôñ Sending background request for ${filePaths.length} files to ${preset.postProcessingUrl}');

    _sendHttpRequest(
      preset,
      filePaths,
      waitForResponse: false,
      requestId: const Uuid().v4(),
      presetPassword: '',
    ).catchError((error) {
      print('❌ Background request failed: $error');
      LogService.log('Background request error: $error').catchError((logError) {
        print('⚠️ Failed to log background request error: $logError');
      });
    });
  }

  static Future<String> _sendRequestAndWait(
    Preset preset,
    List<String> filePaths, {
    BuildContext? context,
  }) async {
    final requestId = const Uuid().v4();

    Map<String, List<int>> originalBytes = {};
    if (context != null) {
      try {
        originalBytes = await _readOriginalImages(filePaths);
      } catch (e) {
        print('⚠️ Failed to read original images for fallback: $e');
        originalBytes = {};
      }

      _pendingRequests[requestId] = _PendingRequest(
        context: context,
        filePaths: filePaths,
        originalBytes: originalBytes,
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
        try {
          OverlayManager.showProcessing(context, 'Waiting for processed imageΓÇª');
        } catch (e) {
          print('⚠️ Context is invalid, cannot show processing overlay: $e');
        }
      }
      await sendFuture;
      return requestId;
    } catch (_) {
      _clearPendingRequest(requestId);
      rethrow;
    }
  }
  
  static Map<String, dynamic>? _takePendingResponse(String requestId) {
    _pendingResponseTimestamps.remove(requestId);
    return _pendingResponses.remove(requestId);
  }
  
  static void _clearPendingRequest(String requestId) {
    _pendingRequests.remove(requestId);
    _pendingResponses.remove(requestId);
    _pendingResponseTimestamps.remove(requestId);
  }
  
  static void _cleanupOldResponses() {
    final now = DateTime.now();
    final toRemove = <String>[];
    
    _pendingResponseTimestamps.forEach((requestId, timestamp) {
      if (now.difference(timestamp) > responseCleanupTimeout) {
        toRemove.add(requestId);
      }
    });
    
    for (final requestId in toRemove) {
      _pendingResponses.remove(requestId);
      _pendingResponseTimestamps.remove(requestId);
      print('🧹 Cleaned up old pending response: $requestId');
    }
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
      
      print('≡ƒîÉ Making HTTP request to: $encodedUrl');
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
        
        if (!await file.exists()) {
          throw Exception('File does not exist: $first');
        }
        
        try {
          final length = await file.length();
          if (length == 0) {
            throw Exception('File is empty: $first');
          }
          final stream = http.ByteStream(Stream.castFrom(file.openRead()));
          final multipartFile = http.MultipartFile(
            'fileToUpload',
            stream,
            length,
            filename: path.basename(first),
            contentType: _contentTypeForPath(first),
          );
          request.files.add(multipartFile);
        } on FileSystemException catch (e) {
          if (e.osError?.errorCode == 2 || e.osError?.errorCode == 3) {
            throw Exception('File was deleted during upload preparation: $first');
          }
          rethrow;
        }
      }

      request.headers['User-Agent'] = 'PortrAI-Flutter/1.0';

      final now = DateTime.now();
      if (_lastRequestTime != null && now.difference(_lastRequestTime!) < rateLimitWindow) {
        _requestCount++;
        if (_requestCount > maxRequestsPerMinute) {
          throw Exception('Rate limit exceeded: Too many requests. Please wait before trying again.');
        }
      } else {
        _lastRequestTime = now;
        _requestCount = 1;
      }

      http.Response response;
      try {
        final streamed = await request.send().timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            throw TimeoutException('HTTP request timeout after 2 minutes');
          },
        );
        response = await http.Response.fromStream(streamed).timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            throw TimeoutException('HTTP response timeout after 2 minutes');
          },
        );
        
        if (response.bodyBytes.length > maxResponseSizeBytes) {
          throw Exception('Response too large: ${response.bodyBytes.length} bytes (max ${maxResponseSizeBytes} bytes)');
        }
        
        await LogService.log('HTTP: received id=$requestId status=${response.statusCode} bytes=${response.bodyBytes.length} contentType=${(response.headers['content-type'] ?? '').toLowerCase()}');
      } on SocketException catch (e) {
        throw Exception('Network error during upload: ${e.message}');
      } on TimeoutException catch (e) {
        throw Exception('Request timeout: ${e.message}');
      } catch (e) {
        if (e.toString().contains('timeout') || e.toString().contains('Timeout')) {
          rethrow;
        }
        throw Exception('Network error: $e');
      }
      
      if (waitForResponse) {

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final contentType = (response.headers['content-type'] ?? '').toLowerCase();
          print('Γ£à HTTP request successful: ${response.statusCode} (content-type: $contentType)');
          _cleanupOldResponses();
          
          if (contentType.startsWith('image/')) {

            _pendingResponses[requestId] = {
              'files': [
                {'bytes': response.bodyBytes},
              ]
            };
            _pendingResponseTimestamps[requestId] = DateTime.now();
          } else if (contentType.startsWith('application/json') || contentType.contains('json')) {
            try {
              _pendingResponses[requestId] =
                  jsonDecode(response.body) as Map<String, dynamic>;
              _pendingResponseTimestamps[requestId] = DateTime.now();
              print('≡ƒôä JSON Response parsed');
            } on FormatException catch (e) {
              print('⚠️ Invalid JSON response, storing as raw bytes: ${e.message}');
              _pendingResponses[requestId] = {
                'files': [
                  {'bytes': response.bodyBytes},
                ]
              };
              _pendingResponseTimestamps[requestId] = DateTime.now();
            } catch (e) {
              print('⚠️ Error parsing JSON response: $e');
              _pendingResponses[requestId] = {
                'files': [
                  {'bytes': response.bodyBytes},
                ]
              };
              _pendingResponseTimestamps[requestId] = DateTime.now();
            }
          } else {

            try {
              _pendingResponses[requestId] =
                  jsonDecode(response.body) as Map<String, dynamic>;
              _pendingResponseTimestamps[requestId] = DateTime.now();
              print('≡ƒôä Fallback JSON Response parsed');
            } on FormatException catch (_) {
              _pendingResponses[requestId] = {
                'files': [
                  {'bytes': response.bodyBytes},
                ]
              };
              _pendingResponseTimestamps[requestId] = DateTime.now();
              print('≡ƒôª Stored non-JSON response as raw bytes');
            } catch (e) {
              print('⚠️ Error parsing fallback JSON: $e');
              _pendingResponses[requestId] = {
                'files': [
                  {'bytes': response.bodyBytes},
                ]
              };
              _pendingResponseTimestamps[requestId] = DateTime.now();
            }
          }
        } else {
          throw Exception('HTTP request failed: ${response.statusCode} - ${response.body}');
        }
      } else {

        print('≡ƒôñ Background request sent: ${response.statusCode}');
      }
      
    } catch (e) {
      print('Γ¥î HTTP request error: $e');
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
    print('≡ƒöä Replacing with original images for ${filePaths.length} files');


    for (final filePath in filePaths) {
      print('≡ƒô╕ Replaced with original: $filePath');
    }
  }

  static void _showProcessingOverlay(BuildContext context, String message) {
    print('≡ƒöä Showing processing overlay: $message');

    OverlayManager.showProcessing(context, message);
  }

  static void _hideProcessingOverlay(BuildContext context) {
    print('Γ£à Hiding processing overlay');

    OverlayManager.hideOverlay();
  }

  static void _showSuccessDialog(BuildContext context, String message) {
    print('Γ£à Success: $message');
    
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
    print('Γ¥î Error: $message');
    
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
      try {
        final fileSize = await file.length();
        if (fileSize > maxFileSizeBytes) {
          throw Exception('File too large: $filePath (${fileSize} bytes, max ${maxFileSizeBytes} bytes)');
        }
        if (fileSize == 0) {
          throw Exception('File is empty: $filePath');
        }
        originals[filePath] = await file.readAsBytes();
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode == 2 || e.osError?.errorCode == 3) {
          throw Exception('Original file was deleted during read: $filePath');
        }
        if (e.osError?.errorCode == 33) {
          throw Exception('File is locked by another process: $filePath');
        }
        rethrow;
      }
    }
    return originals;
  }

  static Future<void> _handleLiveResponse(
    Map<String, dynamic> response,
    String requestId,
    AppState appState,
  ) async {
    final pending = _pendingRequests[requestId];
    if (pending == null) {
      print('⚠️ Pending request not found for requestId: $requestId');
      throw Exception('Pending request was removed before response handling');
    }
    
    final filePaths = pending.filePaths;
    final originalBytes = pending.originalBytes;
    
    _pendingRequests.remove(requestId);

    final fileEntries = response['files'];
    if (fileEntries == null) {
      throw Exception('Invalid response payload: files field is null');
    }
    if (fileEntries is! List) {
      throw Exception('Invalid response payload: files field is not a list');
    }
    if (fileEntries.isEmpty) {
      throw Exception('Invalid response payload: files array is empty');
    }

    for (var i = 0; i < filePaths.length; i++) {
      final targetPath = filePaths[i];
      final processed = i < fileEntries.length ? fileEntries[i] : null;
      final fallbackBytes = originalBytes[targetPath];
      if (fallbackBytes == null) {
        print('⚠️ No fallback bytes available for file: $targetPath');
      }
      await _storeProcessedFile(
        targetPath,
        processed,
        fallbackBytes,
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
    bool writeSuccessful = false;
    
    if (processedData is Map<String, dynamic>) {
      final raw = processedData['bytes'];
      if (raw is List<int>) {
        try {
          await file.writeAsBytes(raw, flush: true);
          final elapsed = DateTime.now().difference(start).inMilliseconds;
          await LogService.log('WRITE: done path=$filePath bytes=${raw.length} ms=$elapsed');
          writeSuccessful = true;
          return;
        } on FileSystemException catch (e) {
          if (e.osError?.errorCode == 2 || e.osError?.errorCode == 3) {
            throw Exception('File was deleted during write: $filePath');
          }
          if (e.osError?.errorCode == 33) {
            throw Exception('File is locked by another process: $filePath');
          }
          rethrow;
        }
      }

      final data = processedData['data'];
      if (data is String) {
        try {
          final base64Part = data.split(',').last;
          if (base64Part.isEmpty) {
            throw Exception('Empty base64 data string');
          }
          final bytes = base64Decode(base64Part);
          try {
            await file.writeAsBytes(bytes, flush: true);
            final elapsed = DateTime.now().difference(start).inMilliseconds;
            await LogService.log('WRITE: done(path-base64) path=$filePath bytes=${bytes.length} ms=$elapsed');
            writeSuccessful = true;
            return;
          } on FileSystemException catch (e) {
            if (e.osError?.errorCode == 2 || e.osError?.errorCode == 3) {
              throw Exception('File was deleted during write: $filePath');
            }
            if (e.osError?.errorCode == 33) {
              throw Exception('File is locked by another process: $filePath');
            }
            rethrow;
          }
        } on FormatException catch (e) {
          throw Exception('Invalid base64 data: ${e.message}');
        } catch (e) {
          if (e is Exception && e.toString().contains('base64')) {
            rethrow;
          }
          throw Exception('Failed to decode base64 data: $e');
        }
      }
    }

    if (fallbackBytes != null) {
      try {
        await file.writeAsBytes(fallbackBytes, flush: true);
        final elapsed = DateTime.now().difference(start).inMilliseconds;
        await LogService.log('WRITE: fallback path=$filePath bytes=${fallbackBytes.length} ms=$elapsed');
        writeSuccessful = true;
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode == 2 || e.osError?.errorCode == 3) {
          throw Exception('File was deleted during fallback write: $filePath');
        }
        if (e.osError?.errorCode == 33) {
          throw Exception('File is locked by another process: $filePath');
        }
        rethrow;
      }
    }
    
    if (!writeSuccessful) {
      throw Exception('No valid processed data or fallback bytes available for file: $filePath');
    }
  }

  static Future<int> processFilesHeadless(List<String> filePaths) async {
    await LogService.log('Headless: start, files=$filePaths');

    final preset = await SessionService.loadSelectedPreset();
    if (preset == null) {


      print('Γ¥î No saved preset found for headless processing');
      await LogService.log('Headless: no saved preset');
      return 2;
    }

    final validFiles = filePaths.where(_isImageFile).toList();
    if (validFiles.isEmpty) {
      print('Γ¥î No valid image files for headless processing');
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

      Map<String, dynamic>? response;
      int retries = 0;
      const maxRetries = 60;
      const retryDelay = Duration(seconds: 2);
      const timeout = Duration(minutes: 2);
      final startTime = DateTime.now();
      
      while (response == null && retries < maxRetries) {
        response = _takePendingResponse(requestId);
        if (response == null) {
          final elapsed = DateTime.now().difference(startTime);
          if (elapsed > timeout) {
            print('Γ¥î Response timeout after 2 minutes in headless mode');
            await LogService.log('Headless: response timeout after 2 minutes');
            return 4;
          }
          retries++;
          await Future.delayed(retryDelay);
        }
      }
      
      if (response == null) {
        print('Γ¥î No response received from server in headless mode after timeout');
        await LogService.log('Headless: no response from server after timeout');
        return 4;
      }

      final fileEntries = response['files'];
      if (fileEntries == null) {
        print('Γ¥î Invalid response payload: files field is null in headless mode');
        await LogService.log('Headless: files field is null');
        return 5;
      }
      if (fileEntries is! List) {
        print('Γ¥î Invalid response payload in headless mode');
        await LogService.log('Headless: invalid response payload');
        return 5;
      }
      if (fileEntries.isEmpty) {
        print('Γ¥î Invalid response payload: files array is empty in headless mode');
        await LogService.log('Headless: files array is empty');
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
      print('Γ¥î Headless processing error: $e');
      await LogService.log('Headless: error: $e');
      return 6;
    }
  }
}
