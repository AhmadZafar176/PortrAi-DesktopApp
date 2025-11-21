import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;

/// Simple app-wide thumbnail cache. Downloads once and serves MemoryImage thereafter.
class ThumbnailCacheService {
  ThumbnailCacheService._();
  static final ThumbnailCacheService instance = ThumbnailCacheService._();

  final Map<String, Uint8List> _bytesByUrl = <String, Uint8List>{};
  final Map<String, ImageProvider> _providerByUrl = <String, ImageProvider>{};
  final List<String> _lru = <String>[];
  int maxEntries = 300; // soft cap
  final Map<String, Future<void>> _inflight = <String, Future<void>>{};

  /// Returns a provider for the URL. If cached bytes exist, returns the cached MemoryImage.
  /// Otherwise returns a NetworkImage and starts a background fetch optionally.
  ImageProvider providerFor(String url) {
    final mem = _providerByUrl[url];
    if (mem != null) return mem;
    return NetworkImage(url);
  }

  /// Preload a list of URLs. If [context] is provided, also decode into the image cache.
  Future<void> preloadUrls(Iterable<String> urls, {BuildContext? context}) async {
    for (final url in urls) {
      if (_bytesByUrl.containsKey(url) || _inflight.containsKey(url)) continue;
      _inflight[url] = _download(url).whenComplete(() => _inflight.remove(url));
    }
    // Optionally await all
    await Future.wait(_inflight.values);
    if (context != null) {
      for (final url in urls) {
        final provider = _providerByUrl[url];
        if (provider != null) {
          // Best-effort; ignore errors
          // Precaches decoded image into global ImageCache
          unawaited(precacheImage(provider, context));
        }
      }
    }
  }

  /// Returns a resized provider wrapper for a given desired size, using cached bytes when available.
  ImageProvider providerForResized(String url, {int? cacheWidth, int? cacheHeight}) {
    final base = providerFor(url);
    if (cacheWidth == null && cacheHeight == null) return base;
    return ResizeImage(base, width: cacheWidth, height: cacheHeight);
  }

  Future<void> _download(String url) async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode == 200) {
        final bytes = await consolidateHttpClientResponseBytes(response);
        _bytesByUrl[url] = bytes;
        _providerByUrl[url] = MemoryImage(bytes);
        _touch(url);
        _evictIfNeeded();
      }
      client.close(force: true);
    } catch (_) {
      // Keep silent; NetworkImage will still be used
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


