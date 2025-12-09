import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;

class ThumbnailCacheService {
  ThumbnailCacheService._();
  static final ThumbnailCacheService instance = ThumbnailCacheService._();

  final Map<String, Uint8List> _bytesByUrl = <String, Uint8List>{};
  final Map<String, ImageProvider> _providerByUrl = <String, ImageProvider>{};
  final List<String> _lru = <String>[];
  int maxEntries = 300;
  final Map<String, Future<void>> _inflight = <String, Future<void>>{};


  ImageProvider providerFor(String url) {
    final mem = _providerByUrl[url];
    if (mem != null) return mem;
    return NetworkImage(url);
  }

  Future<void> preloadUrls(Iterable<String> urls, {BuildContext? context}) async {
    for (final url in urls) {
      if (_bytesByUrl.containsKey(url) || _inflight.containsKey(url)) continue;
      _inflight[url] = _download(url).whenComplete(() => _inflight.remove(url));
    }

    await Future.wait(_inflight.values);
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


