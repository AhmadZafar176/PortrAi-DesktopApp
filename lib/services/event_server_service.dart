import 'dart:io';

import 'log_service.dart';
import 'session_service.dart';



class EventServerService {
  HttpServer? _server;

  Future<bool> start({int port = 8000}) async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server!.listen(_handleRequest, onError: (e) async {
        await LogService.log('EventServer error: $e');
      });
      await LogService.log('EventServer listening on 127.0.0.1:$port');
      return true;
    } catch (e) {
      await LogService.log('EventServer failed to bind: $e');
      return false;
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final qp = req.uri.queryParameters;
      final eventType = qp['event_type'] ?? '';
      final p1 = qp['param1'];
      final p2 = qp['param2'];
      final ts = DateTime.now().toIso8601String();

      final logParts = <String>["event_type: '$eventType'"];
      if (p1 != null) logParts.add("param1: '$p1'");
      if (p2 != null) logParts.add("param2: '$p2'");
      await LogService.log("$ts { ${logParts.join(', ')} }");

      if (eventType == 'session_end') {
        await SessionService.signalDonePressed();
        req.response
          ..statusCode = HttpStatus.ok
          ..write('OK: session_end received');
      } else {
        req.response
          ..statusCode = HttpStatus.ok
          ..write('IGNORED: unknown event_type');
      }
    } catch (e) {
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..write('ERROR: $e');
    } finally {
      await req.response.close();
    }
  }

  void dispose() {
    _server?.close(force: true);
    _server = null;
  }
}




