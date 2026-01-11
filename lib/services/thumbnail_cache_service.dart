import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart'
    show consolidateHttpClientResponseBytes, debugPrint;

class ThumbnailCacheService {
  ThumbnailCacheService._();
  static final ThumbnailCacheService instance = ThumbnailCacheService._();

  final Map<String, Uint8List> _bytesByUrl = <String, Uint8List>{};
  final Map<String, ImageProvider> _providerByUrl = <String, ImageProvider>{};
  final List<String> _lru = <String>[];
  int maxEntries = 300;
  final Map<String, Future<void>> _inflight = <String, Future<void>>{};
  final Set<String> _failed = <String>{};
  int maxConcurrentDownloads = 6;

  static final Uint8List _transparent1x1Png = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);
  static final ImageProvider _transparentProvider =
      MemoryImage(_transparent1x1Png);

  bool isSupportedImageSource(String source) {
    final s = source.trim();
    if (s.isEmpty) return false;

    final uri = Uri.tryParse(s);
    if (uri != null && uri.hasScheme) {
      if (uri.scheme == 'http' || uri.scheme == 'https') return true;
      if (uri.scheme == 'file') {
        try {
          final path = uri.toFilePath(windows: Platform.isWindows);
          if (path.trim().isEmpty) return false;
          return FileSystemEntity.typeSync(path) == FileSystemEntityType.file;
        } catch (_) {
          return false;
        }
      }
      return false;
    }

    final isWindowsAbsPath = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(s);
    if (isWindowsAbsPath) {
      try {
        return FileSystemEntity.typeSync(s) == FileSystemEntityType.file;
      } catch (_) {
        return false;
      }
    }

    return false;
  }

  bool isNetworkImageUrl(String source) {
    final s = source.trim();
    if (s.isEmpty) return false;
    final uri = Uri.tryParse(s);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  ImageProvider _providerForAny(String source) {
    final s = source.trim();
    if (s.isEmpty) return _transparentProvider;

    final uri = Uri.tryParse(s);
    if (uri != null && uri.hasScheme) {
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        final mem = _providerByUrl[s];
        if (mem != null) return mem;
        return NetworkImage(s);
      }
      if (uri.scheme == 'file') {
        try {
          final path = uri.toFilePath(windows: Platform.isWindows);
          if (path.trim().isEmpty) return _transparentProvider;
          if (FileSystemEntity.typeSync(path) == FileSystemEntityType.file) {
            return FileImage(File(path));
          }
        } catch (_) {}
        return _transparentProvider;
      }
      return _transparentProvider;
    }

    final isWindowsAbsPath = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(s);
    if (isWindowsAbsPath) {
      try {
        if (FileSystemEntity.typeSync(s) == FileSystemEntityType.file) {
          return FileImage(File(s));
        }
      } catch (_) {}
      return _transparentProvider;
    }

    return _transparentProvider;
  }

  ImageProvider providerFor(String url) {
    return _providerForAny(url);
  }

  Future<void> preloadUrls(
    Iterable<String> urls, {
    BuildContext? context,
    int? maxConcurrent,
  }) async {
    final int concurrency = (maxConcurrent ?? maxConcurrentDownloads).clamp(1, 32);
    final List<Future<void>> started = <Future<void>>[];

    for (final url in urls) {
      if (!isNetworkImageUrl(url)) continue;
      if (_bytesByUrl.containsKey(url) || _inflight.containsKey(url)) continue;

      while (_inflight.length >= concurrency) {
        try {
          await Future.any(_inflight.values);
        } catch (_) {
        }
      }

      final future = _download(url).whenComplete(() => _inflight.remove(url));
      _inflight[url] = future;
      started.add(future);
    }

    if (started.isNotEmpty) {
      try {
        await Future.wait(started);
      } catch (_) {
      }
    }
    if (context != null) {
      for (final url in urls) {
        final provider = _providerByUrl[url];
        if (provider != null) {


          unawaited(precacheImage(provider, context));
        }
      }
    }
  }

  ImageProvider providerForResized(String url, {int? cacheWidth, int? cacheHeight}) {
    final base = providerFor(url);
    if (cacheWidth == null && cacheHeight == null) return base;
    return ResizeImage(base, width: cacheWidth, height: cacheHeight);
  }

  Future<void> _download(String url) async {
    HttpClient? client;
    try {
      if (!isNetworkImageUrl(url)) return;
      client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode == 200) {
        final bytes = await consolidateHttpClientResponseBytes(response);
        _bytesByUrl[url] = bytes;
        _providerByUrl[url] = MemoryImage(bytes);
        _touch(url);
        _evictIfNeeded();
        _failed.remove(url);
      } else {
        if (_failed.add(url)) {
          assert(() {
            debugPrint('ðŸ–¼ï¸ ThumbnailCacheService: HTTP ${response.statusCode} for $url');
            return true;
          }());
        }
      }
    } catch (e) {
      if (_failed.add(url)) {
        assert(() {
          debugPrint('ðŸ–¼ï¸ ThumbnailCacheService: download failed for $url -> $e');
          return true;
        }());
      }
    } finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }

  void _touch(String url) {
    _lru.remove(url);
    _lru.add(url);
  }

  void _evictIfNeeded() {
    while (_lru.length > maxEntries) {
      final oldest = _lru.removeAt(0);
      _bytesByUrl.remove(oldest);
      _providerByUrl.remove(oldest);
    }
  }
}


