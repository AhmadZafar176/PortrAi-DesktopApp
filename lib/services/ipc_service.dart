import 'dart:io';
import 'dart:convert';
import 'dart:async';


class IPCService {
  static const int _port = 45678;
  static const String _appName = 'portrai_app';
  static const String _newline = '\n';
  static const int _maxBufferedChars = 1024 * 1024;
  
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

      print('âœ… IPC Server started on port $_port');
      return true;
    } catch (e) {
      print('âŒ Failed to start IPC server: $e');
      return false;
    }
  }

  void _handleClient(Socket client) {
    StreamSubscription? subscription;
    String? currentRequestId;
    final buffer = StringBuffer();
    
    subscription = client.listen(
      (data) {
        buffer.write(utf8.decode(data));
        if (buffer.length > _maxBufferedChars) {
          try {
            client.write('ERROR$_newline');
          } catch (_) {}
          if (currentRequestId != null) {
            _pendingRequests.remove(currentRequestId);
          }
          subscription?.cancel();
          client.destroy();
          return;
        }

        final content = buffer.toString();
        final lines = content.split(_newline);

        buffer.clear();
        if (lines.isNotEmpty) {
          buffer.write(lines.removeLast());
        }

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          _handleIncomingJsonLine(trimmed, client, (requestId) {
          currentRequestId = requestId;
          });
        }
      },
      onError: (error) {
        print('âŒ Client error: $error');
        if (currentRequestId != null) {
          _pendingRequests.remove(currentRequestId);
        }
        subscription?.cancel();
        client.close();
        client.destroy();
      },
      onDone: () {
        final trailing = buffer.toString().trim();
        if (trailing.isNotEmpty) {
          try {
            _handleIncomingJsonLine(trailing, client, (requestId) {
              currentRequestId = requestId;
            });
          } catch (_) {
          }
        }
        if (currentRequestId != null) {
          _pendingRequests.remove(currentRequestId);
        }
        subscription?.cancel();
        client.destroy();
      },
    );
  }

  void _handleIncomingJsonLine(
    String jsonLine,
    Socket client,
    void Function(String requestId) setRequestId,
  ) {
    try {
      final decoded = json.decode(jsonLine);
      if (decoded is! Map) {
        client.write('ERROR$_newline');
        client.close();
        return;
      }
      final payload = decoded.cast<String, dynamic>();
      final idVal = payload['id'];
      final filesVal = payload['files'];
      if (idVal is! String || idVal.trim().isEmpty || filesVal is! List) {
        client.write('ERROR$_newline');
        client.close();
        return;
      }
      final requestId = idVal.trim();
      final filePaths = <String>[];
      for (final f in filesVal) {
        if (f is String && f.trim().isNotEmpty) {
          filePaths.add(f);
        }
      }
      if (filePaths.isEmpty) {
        client.write('ERROR$_newline');
        client.close();
        return;
      }
      setRequestId(requestId);

      print('ðŸ“ Received files: $filePaths (request $requestId)');
      _onFilesReceived?.call(requestId, filePaths);

      final completer = Completer<void>();
      if (_pendingRequests.containsKey(requestId)) {
        client.write('ERROR$_newline');
        client.close();
        return;
      }
      _pendingRequests[requestId] = completer;

      try {
        client.write('${json.encode({'status': 'OK', 'id': requestId})}$_newline');
      } catch (_) {}

      completer.future.whenComplete(() {
        _pendingRequests.remove(requestId);
        try {
          client.write('${json.encode({'status': 'DONE', 'id': requestId})}$_newline');
        } catch (_) {}
        try {
          client.close();
        } catch (_) {}
      });
    } catch (e) {
      print('âŒ Error handling client payload: $e');
      client.write('ERROR$_newline');
      client.close();
    }
  }

  static Future<String?> sendFilesToExistingInstance(List<String> filePaths) async {
    Socket? socket;
    StreamSubscription? subscription;
    String? requestId;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, _port);
      requestId = DateTime.now().microsecondsSinceEpoch.toString();
      socket.write('${json.encode({'files': filePaths, 'id': requestId})}$_newline');

      final completer = Completer<bool>();
      final okCompleter = Completer<bool>();
      final buffer = StringBuffer();
      var receivedDone = false;

      subscription = socket.listen(
        (event) {
          buffer.write(utf8.decode(event));
          final content = buffer.toString();
          final lines = content.split(_newline);
          buffer.clear();
          if (lines.isNotEmpty) {
            buffer.write(lines.removeLast());
          }

          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) continue;
            try {
              final decoded = json.decode(trimmed);
              if (decoded is! Map) continue;
              final result = decoded.cast<String, dynamic>();
              if (result['id'] == requestId && result['status'] == 'OK') {
                if (!okCompleter.isCompleted) okCompleter.complete(true);
              }
            if (result['id'] == requestId && result['status'] == 'DONE') {
              _pendingRequests.remove(requestId)?.complete();
              receivedDone = true;
              if (!completer.isCompleted) {
                completer.complete(true);
              }
            }
            } catch (_) {
            }
          }
        },
        onError: (error) {
          print('âŒ Client socket error: $error');
          _pendingRequests.remove(requestId);
          if (!okCompleter.isCompleted) okCompleter.complete(false);
          if (!completer.isCompleted) {
            completer.complete(false);
          }
        },
        onDone: () {
          _pendingRequests.remove(requestId);
          if (!okCompleter.isCompleted) okCompleter.complete(receivedDone);
          if (!completer.isCompleted) completer.complete(receivedDone);
        },
      );

      final acknowledged = await okCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Socket OK response timeout');
        },
      );
      if (!acknowledged) {
        await socket.close();
        return null;
      }

      final success = await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          print('âš ï¸ Timeout waiting for processing completion');
          _pendingRequests.remove(requestId);
          if (!completer.isCompleted) {
            completer.complete(false);
          }
          return false;
        },
      );
      await socket.close();
      return success ? requestId : null;
    } catch (e) {
      print('âŒ Failed to send files: $e');
      if (requestId != null) {
        _pendingRequests.remove(requestId);
      }
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
          print('âš ï¸ Timeout waiting for processing completion: $requestId');
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
