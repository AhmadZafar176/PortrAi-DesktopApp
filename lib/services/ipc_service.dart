import 'dart:io';
import 'dart:convert';
import 'dart:async';


class IPCService {
  static const int _port = 45678;
  static const String _appName = 'portrai_app';
  
  ServerSocket? _serverSocket;
  StreamSubscription? _subscription;
  Function(String, List<String>)? _onFilesReceived;
  static final Map<String, Completer<void>> _pendingRequests = {};

  Future<bool> startServer(Function(String, List<String>) onFilesReceived) async {
    try {
      _onFilesReceived = onFilesReceived;
      _serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, _port);
      
      _subscription = _serverSocket!.listen((Socket client) {
        _handleClient(client);
      });

      print('✅ IPC Server started on port $_port');
      return true;
    } catch (e) {
      print('❌ Failed to start IPC server: $e');
      return false;
    }
  }

  void _handleClient(Socket client) {
    StreamSubscription? subscription;
    String? currentRequestId;
    
    subscription = client.listen(
      (data) {
        try {
          final message = utf8.decode(data);
          final payload = json.decode(message) as Map<String, dynamic>;
          final filePaths = (payload['files'] as List<dynamic>).cast<String>();
          final requestId = payload['id'] as String;
          currentRequestId = requestId;

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
          print('❌ Error handling client: $e');
          if (currentRequestId != null) {
            _pendingRequests.remove(currentRequestId);
          }
          client.write('ERROR');
          client.close();
        }
      },
      onError: (error) {
        print('❌ Client error: $error');
        if (currentRequestId != null) {
          _pendingRequests.remove(currentRequestId);
        }
        subscription?.cancel();
        client.close();
        client.destroy();
      },
      onDone: () {
        if (currentRequestId != null) {
          _pendingRequests.remove(currentRequestId);
        }
        subscription?.cancel();
        client.destroy();
      },
    );
  }

  static Future<String?> sendFilesToExistingInstance(List<String> filePaths) async {
    Socket? socket;
    StreamSubscription? subscription;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, _port);
      final requestId = DateTime.now().microsecondsSinceEpoch.toString();
      socket.write(json.encode({'files': filePaths, 'id': requestId}));

      final response = await socket.first.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Socket response timeout');
        },
      );
      final responseStr = utf8.decode(response);
      final data = json.decode(responseStr) as Map<String, dynamic>;
      final acknowledged = data['status'] == 'OK';
      if (!acknowledged) {
        socket.close();
        return null;
      }

      final completer = Completer<bool>();

      subscription = socket.listen(
        (event) {
          final msg = utf8.decode(event);
          try {
            final result = json.decode(msg) as Map<String, dynamic>;
            if (result['id'] == requestId && result['status'] == 'DONE') {
              _pendingRequests.remove(requestId)?.complete();
              if (!completer.isCompleted) {
                completer.complete(true);
              }
            }
          } catch (_) {}
        },
        onError: (error) {
          print('❌ Client socket error: $error');
          _pendingRequests.remove(requestId);
          if (!completer.isCompleted) {
            completer.complete(false);
          }
        },
        onDone: () {
          _pendingRequests.remove(requestId);
          if (!completer.isCompleted) {
            completer.complete(true);
          }
        },
      );

      final success = await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          print('⚠️ Timeout waiting for processing completion');
          return false;
        },
      );
      await socket.close();
      return success ? requestId : null;
    } catch (e) {
      print('❌ Failed to send files: $e');
      subscription?.cancel();
      await socket?.close();
      return null;
    }
  }

  static Future<void> waitForProcessingCompletion(String requestId) async {
    final completer = _pendingRequests.putIfAbsent(requestId, () => Completer<void>());
    try {
      await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          print('⚠️ Timeout waiting for processing completion: $requestId');
          _pendingRequests.remove(requestId);
          throw TimeoutException('Processing completion timeout');
        },
      );
    } catch (e) {
      _pendingRequests.remove(requestId);
      rethrow;
    }
  }

  static Future<void> signalCompletion(String requestId) async {
    final completer = _pendingRequests.remove(requestId);
    completer?.complete();
  }

  void dispose() {
    _subscription?.cancel();
    _serverSocket?.close();
  }
}
