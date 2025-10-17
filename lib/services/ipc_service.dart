import 'dart:io';
import 'dart:convert';
import 'dart:async';

/// IPC Service for communication between app instances
/// Handles file passing from second instances to the running instance
class IPCService {
  static const int _port = 45678;
  static const String _appName = 'portrai_app';
  
  ServerSocket? _serverSocket;
  StreamSubscription? _subscription;
  Function(String, List<String>)? _onFilesReceived;
  static final Map<String, Completer<void>> _pendingRequests = {};
  
  /// Start the IPC server to receive files from other instances
  Future<bool> startServer(Function(String, List<String>) onFilesReceived) async {
    try {
      _onFilesReceived = onFilesReceived;
      _serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, _port);
      
      _subscription = _serverSocket!.listen((Socket client) {
        _handleClient(client);
      });
      
      // ignore: avoid_print
      print('✅ IPC Server started on port $_port');
      return true;
    } catch (e) {
      print('❌ Failed to start IPC server: $e');
      return false;
    }
  }
  
  /// Handle incoming client connections
  void _handleClient(Socket client) {
    client.listen(
      (data) {
        try {
          final message = utf8.decode(data);
          final payload = json.decode(message) as Map<String, dynamic>;
          final filePaths = (payload['files'] as List<dynamic>).cast<String>();
          final requestId = payload['id'] as String;

          // ignore: avoid_print
          print('📁 Received files: $filePaths (request $requestId)');
          _onFilesReceived?.call(requestId, filePaths);

          final completer = Completer<void>();
          _pendingRequests[requestId] = completer;

          client.write(json.encode({'status': 'OK', 'id': requestId}));

          completer.future.whenComplete(() {
            _pendingRequests.remove(requestId);
            client.write(json.encode({'status': 'DONE', 'id': requestId}));
            client.close();
          });
        } catch (e) {
          // ignore: avoid_print
          print('❌ Error handling client: $e');
          client.write('ERROR');
          client.close();
        }
      },
      onError: (error) {
            // ignore: avoid_print
            print('❌ Client error: $error');
        client.close();
      },
      onDone: () {
        client.destroy();
      },
    );
  }
  
  /// Send files to existing instance
  static Future<String?> sendFilesToExistingInstance(List<String> filePaths) async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, _port);
      final requestId = DateTime.now().microsecondsSinceEpoch.toString();
      socket.write(json.encode({'files': filePaths, 'id': requestId}));

      final response = await socket.first;
      final responseStr = utf8.decode(response);
      final data = json.decode(responseStr) as Map<String, dynamic>;
      final acknowledged = data['status'] == 'OK';
      if (!acknowledged) {
        socket.close();
        return null;
      }

      final completer = Completer<bool>();
      _pendingRequests.putIfAbsent(requestId, () => Completer<void>());

      socket.listen(
        (event) {
          final msg = utf8.decode(event);
          try {
            final result = json.decode(msg) as Map<String, dynamic>;
            if (result['id'] == requestId && result['status'] == 'DONE') {
              _pendingRequests.remove(requestId)?.complete();
              completer.complete(true);
            }
          } catch (_) {}
        },
        onError: (error) {
          print('❌ Client socket error: $error');
          completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(true);
          }
        },
      );

      final success = await completer.future;
      await socket.close();
      return success ? requestId : null;
    } catch (e) {
      print('❌ Failed to send files: $e');
      return null;
    }
  }

  static Future<void> waitForProcessingCompletion(String requestId) async {
    final completer = _pendingRequests.putIfAbsent(requestId, () => Completer<void>());
    await completer.future;
  }

  static Future<void> signalCompletion(String requestId) async {
    final completer = _pendingRequests.remove(requestId);
    completer?.complete();
  }
  
  /// Clean up resources
  void dispose() {
    _subscription?.cancel();
    _serverSocket?.close();
  }
}
