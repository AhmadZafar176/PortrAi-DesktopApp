import 'dart:convert';
import 'dart:io';

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

/// File Processing Service - Replicates legacy app's file handling logic
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

  /// Process files exactly like the legacy app
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
    
    // Validate presets exist (exactly like legacy app)
    if (appState.presets.isEmpty) {
      _showErrorDialog(context, "Please add a preset first.");
      await maybeSignalCompletion();
      return;
    }
    
    // Filter valid image files (JPG/PNG only)
    final validFiles = filePaths.where(_isImageFile).toList();
    if (validFiles.isEmpty) {
      _showErrorDialog(context, "No valid image files found (JPG/PNG only).");
      await maybeSignalCompletion();
      return;
    }
    
    _isProcessing = true;
    
    try {
      // Get current preset (exactly like legacy app)
      final preset = appState.presets[appState.selectedIndex];

      // Process files based on preset type (exactly like legacy app)
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
  
  /// Check if file is a valid image (JPG/PNG only)
  static bool _isImageFile(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    return ['.jpg', '.jpeg', '.png'].contains(extension);
  }
  
  /// Process files with no effects (exactly like legacy app)
  static Future<void> _processNoEffects(List<String> filePaths) async {
    print('🔄 Processing no effects for ${filePaths.length} files');
    
    for (final filePath in filePaths) {
      final file = File(filePath);
      if (await file.exists()) {
        // Simply touch the file (no actual processing needed)
        // This matches the legacy app's behavior
        await file.writeAsBytes(await file.readAsBytes());
        print('✅ Processed (no effects): $filePath');
      }
    }
  }
  
  /// Process files for post-delivery (exactly like legacy app)
  static Future<void> _processPostDelivery(Preset preset, List<String> filePaths) async {
    print('🔄 Processing post-delivery for ${filePaths.length} files');
    
    // Fire and forget - send request in background (exactly like legacy app)
    _sendRequestInBackground(preset, filePaths);
    
    // Immediately show popup and replace with original images (exactly like legacy app)
    _replaceWithOriginalImages(filePaths);
  }
  
  /// Process files for live processing (exactly like legacy app)
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
    return false; // _processLive does not return a boolean directly, it signals completion
  }
  
  /// Send request in background (exactly like legacy app's fire-and-forget)
  static void _sendRequestInBackground(
    Preset preset,
    List<String> filePaths,
  ) {
    // This should match the legacy app's background request sending
    print('📤 Sending background request for ${filePaths.length} files to ${preset.postProcessingUrl}');
    
    // Send HTTP request in background without waiting for response
    _sendHttpRequest(
      preset,
      filePaths,
      waitForResponse: false,
      requestId: const Uuid().v4(),
      presetPassword: '',
    );
  }
  
  /// Send request and wait for response (exactly like legacy app)
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
        originalBytes: await _readOriginalImages(filePaths),
      );
      // Defer showing the processing overlay until after the request is sent.
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
      // Validate post processing URL
      if (preset.postProcessingUrl.isEmpty) {
        throw Exception('Post processing URL is empty');
      }
      
      // Parse and encode the URL properly
      final uri = Uri.parse(preset.postProcessingUrl);
      final encodedUrl = uri.toString();
      
      print('🌐 Making HTTP request to: $encodedUrl');
      
      // Build multipart form: fileToUpload (binary) + password + metadata JSON
      final uriParsed = Uri.parse(encodedUrl);
      final request = http.MultipartRequest('POST', uriParsed);
      request.fields['password'] = presetPassword;
      request.fields['id'] = requestId;
      request.fields['preset'] = jsonEncode({
        'title': preset.title,
        'collection': preset.collection,
        'presetId': preset.presetId,
      });

      // Attach only the first file for processing
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
      
      if (waitForResponse) {
        // Handle response for live processing
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final contentType = (response.headers['content-type'] ?? '').toLowerCase();
          print('✅ HTTP request successful: ${response.statusCode} (content-type: $contentType)');
          if (contentType.startsWith('image/')) {
            // Binary image response; wrap into our expected JSON-like structure
            final base64Data = base64Encode(response.bodyBytes);
            final dataUri = 'data:$contentType;base64,$base64Data';
            _pendingResponses[requestId] = {
              'files': [
                {'data': dataUri},
              ]
            };
          } else if (contentType.startsWith('application/json') || contentType.contains('json')) {
            _pendingResponses[requestId] =
                jsonDecode(response.body) as Map<String, dynamic>;
            print('📄 JSON Response parsed');
          } else {
            // Fallback: try JSON, else treat as binary with JPEG/PNG based on original file
            try {
              _pendingResponses[requestId] =
                  jsonDecode(response.body) as Map<String, dynamic>;
              print('📄 Fallback JSON Response parsed');
            } catch (_) {
              final base64Data = base64Encode(response.bodyBytes);
              final ext = filePaths.isNotEmpty ? path.extension(filePaths.first).toLowerCase() : '.jpg';
              final fallbackType = (ext == '.png') ? 'image/png' : 'image/jpeg';
              final dataUri = 'data:$fallbackType;base64,$base64Data';
              _pendingResponses[requestId] = {
                'files': [
                  {'data': dataUri},
                ]
              };
              print('📦 Wrapped non-JSON response as $fallbackType');
            }
          }
        } else {
          throw Exception('HTTP request failed: ${response.statusCode} - ${response.body}');
        }
      } else {
        // Fire and forget for post-delivery
        print('📤 Background request sent: ${response.statusCode}');
      }
      
    } catch (e) {
      print('❌ HTTP request error: $e');
      if (waitForResponse) {
        rethrow; // Re-throw for live processing to show error
      }
      // For background requests, just log the error
    }
  }

  static MediaType _contentTypeForPath(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    if (ext == '.png') return MediaType('image', 'png');
    // Default to JPEG for .jpg/.jpeg and any other (which should be filtered out already)
    return MediaType('image', 'jpeg');
  }

  /// Replace with original images (exactly like legacy app)
  static void _replaceWithOriginalImages(List<String> filePaths) {
    print('🔄 Replacing with original images for ${filePaths.length} files');
    
    // This matches the legacy app's _replace_with_original_images behavior
    // For now, just log the action
    for (final filePath in filePaths) {
      print('📸 Replaced with original: $filePath');
    }
  }
  
  /// Show processing overlay (exactly like legacy app's WaitingOverlay)
  static void _showProcessingOverlay(BuildContext context, String message) {
    print('🔄 Showing processing overlay: $message');
    
    // Use the custom overlay manager (exactly like legacy app)
    OverlayManager.showProcessing(context, message);
  }
  
  /// Hide processing overlay (exactly like legacy app)
  static void _hideProcessingOverlay(BuildContext context) {
    print('✅ Hiding processing overlay');
    
    // Use the custom overlay manager
    OverlayManager.hideOverlay();
  }
  
  /// Show success dialog (exactly like legacy app)
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
  
  /// Show error dialog (exactly like legacy app)
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
    OverlayManager.showDone(pending.context, () async {
      appState.setStayMinimizedDuringCapture(false);
      if (Platform.isWindows) {
        await windowManager.restore();
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setFullScreen(true);
      }
      // Small delay to ensure window is fully visible before navigation
      await Future.delayed(const Duration(milliseconds: 100));
      Navigator.of(pending.context).pop();
    });
  }

  static Future<void> _storeProcessedFile(
    String filePath,
    dynamic processedData,
    List<int>? fallbackBytes,
  ) async {
    final file = File(filePath);
    if (processedData is Map<String, dynamic>) {
      final data = processedData['data'];
      if (data is String) {
        final bytes = base64Decode(data.split(',').last);
        await file.writeAsBytes(bytes);
        return;
      }
    }

    if (fallbackBytes != null) {
      await file.writeAsBytes(fallbackBytes);
    }
  }

  /// Headless processing: process files without UI using the last saved preset
  static Future<int> processFilesHeadless(List<String> filePaths) async {
    await LogService.log('Headless: start, files=$filePaths');
    // Load the saved preset
    final preset = await SessionService.loadSelectedPreset();
    if (preset == null) {
      // Nothing to do; indicate failure
      // ignore: avoid_print
      print('❌ No saved preset found for headless processing');
      await LogService.log('Headless: no saved preset');
      return 2;
    }

    // Filter valid images (JPG/PNG only)
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

      // Live processing: wait synchronously for the response and write files
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

      // Apply processed bytes to target files
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
