// Native-backed image provider for Mihon (manga) source covers and pages.
//
// The manga twin of [AniyomiImage] (`lib/core/aniyomi/aniyomi_image_provider.dart`)
// — deliberately duplicated, not shared, so the frozen Aniyomi path never has to
// change for a manga change.
//
// Manga cover/page images frequently sit behind Cloudflare on a separate image
// host (e.g. `static.comix.to`). Flutter's `cached_network_image` can't pass CF
// because it has no access to the `cf_clearance` cookie. This provider fetches
// image bytes through the SOURCE'S OWN OkHttpClient (which carries the CF session
// cookie the browse path uses) via the `zangetsu/mihon` channel's `getImage`
// call, then decodes the bytes in Flutter.
//
// Keyed by `(sourceId, url)` so Flutter's ImageCache deduplicates identical
// requests. Constructed only where the `x-mihon-src` marker is present in a
// cover's headers — non-Mihon paths are untouched.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../cache/app_image_cache.dart';

const MethodChannel _kMihonChannel = MethodChannel('zangetsu/mihon');

/// [ImageProvider] that fetches image bytes via the native Mihon OkHttpClient.
///
/// Keyed by [sourceId] (the numeric Mihon source id) and [url] (the cover/page
/// image URL). Flutter's image cache deduplicates on the pair.
class MihonImage extends ImageProvider<MihonImage> {
  const MihonImage(this.sourceId, this.url, {this.persist = true});

  /// true = cover (kept while in use), false = reader page (kept up to a
  /// size limit). Both are stored on the phone.
  final bool persist;

  /// The numeric Mihon source id as registered in `MihonSourceManager`.
  final int sourceId;

  /// Absolute URL of the cover / page image.
  final String url;

  @override
  Future<MihonImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<MihonImage>(this);

  @override
  ImageStreamCompleter loadImage(MihonImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_loadAsync(key, decode));
  }

  Future<ImageInfo> _loadAsync(
    MihonImage key,
    ImageDecoderCallback decode,
  ) async {
    final store =
        key.persist ? MihonCoverDiskCache.covers : MihonCoverDiskCache.pages;
    Uint8List? bytes = await store.read(key.sourceId, key.url);
    final fromDisk = bytes != null;
    bytes ??= await _kMihonChannel.invokeMethod<Uint8List>(
      'getImage',
      {'sourceId': key.sourceId, 'url': key.url},
    );
    if (!fromDisk && bytes != null && bytes.isNotEmpty) {
      unawaited(store.write(key.sourceId, key.url, bytes));
    }
    if (bytes == null || bytes.isEmpty) {
      throw Exception(
        'MihonImage: native getImage returned empty bytes for ${key.url}',
      );
    }
    final ui.ImmutableBuffer buffer =
        await ui.ImmutableBuffer.fromUint8List(bytes);
    final ui.Codec codec = await decode(buffer);
    final ui.FrameInfo frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) =>
      other is MihonImage && sourceId == other.sourceId && url == other.url;

  @override
  int get hashCode => Object.hash(sourceId, url);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'MihonImage')}(sourceId: $sourceId, url: $url)';
}

/// Returns the right [ImageProvider] for a Mihon source cover: a native,
/// CF-aware [MihonImage] when [headers] carries the `x-mihon-src` marker,
/// otherwise the normal [CachedNetworkImageProvider].
ImageProvider mihonCoverProvider(String url, Map<String, String>? headers) {
  final marker = headers?['x-mihon-src'];
  if (marker != null) {
    final id = int.tryParse(marker);
    if (id != null) return MihonImage(id, url);
  }
  return AppImageCache.imageProvider(url, headers: headers);
}


/// Mihon images stored as files in the app's own storage (not the cache
/// folder Android empties), one file per (source, url):
///  - covers: kept while they are being shown, dropped after 90 days unseen
///  - pages:  the reader's pages, kept up to 2 GB (oldest go first)
/// Files are "touched" when shown, so what you use stays.
class MihonCoverDiskCache {
  MihonCoverDiskCache._(this._folder, this._keep, this._maxBytes);

  static final MihonCoverDiskCache covers = MihonCoverDiskCache._(
    'mihon_covers',
    const Duration(days: 90),
    3 << 30,
  );
  static final MihonCoverDiskCache pages = MihonCoverDiskCache._(
    'mihon_pages',
    const Duration(days: 60),
    2 << 30,
  );

  final String _folder;
  final Duration _keep;
  final int _maxBytes;
  Future<Directory?>? _dir;

  Future<Directory?> _directory() => _dir ??= () async {
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/$_folder');
      if (!d.existsSync()) d.createSync(recursive: true);
      unawaited(Future<void>.delayed(const Duration(seconds: 20), () => _prune(d)));
      return d;
    } catch (_) {
      return null;
    }
  }();

  static String _name(int sourceId, String url) =>
      sha1.convert(utf8.encode('$sourceId|$url')).toString();

  Future<bool> has(int sourceId, String url) async {
    final d = await _directory();
    if (d == null) return false;
    return File('${d.path}/${_name(sourceId, url)}').exists();
  }

  Future<Uint8List?> read(int sourceId, String url) async {
    final d = await _directory();
    if (d == null) return null;
    final f = File('${d.path}/${_name(sourceId, url)}');
    try {
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      final age = DateTime.now().difference(await f.lastModified());
      if (age > const Duration(days: 3)) {
        unawaited(f.setLastModified(DateTime.now()).catchError((_) {}));
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(int sourceId, String url, Uint8List bytes) async {
    final d = await _directory();
    if (d == null) return;
    final name = _name(sourceId, url);
    try {
      // Write to a temp file first so a half-written image is never read.
      final tmp = File('${d.path}/$name.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename('${d.path}/$name');
    } catch (_) {}
  }

  Future<void> _prune(Directory d) async {
    try {
      final cutoff = DateTime.now().subtract(_keep);
      final kept = <(File, DateTime, int)>[];
      var total = 0;
      await for (final e in d.list()) {
        if (e is! File) continue;
        try {
          final st = await e.stat();
          if (e.path.endsWith('.tmp') || st.modified.isBefore(cutoff)) {
            await e.delete();
            continue;
          }
          kept.add((e, st.modified, st.size));
          total += st.size;
        } catch (_) {}
      }
      if (total <= _maxBytes) return;
      kept.sort((a, b) => a.$2.compareTo(b.$2));
      for (final (f, _, size) in kept) {
        if (total <= _maxBytes) break;
        try {
          await f.delete();
          total -= size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Fetches and stores a cover that is not on the phone yet (no decoding).
  static Future<void> prefetchCover(int sourceId, String url) async {
    if (await covers.has(sourceId, url)) return;
    try {
      final bytes = await _kMihonChannel.invokeMethod<Uint8List>(
        'getImage',
        {'sourceId': sourceId, 'url': url},
      );
      if (bytes != null && bytes.isNotEmpty) {
        await covers.write(sourceId, url, bytes);
      }
    } catch (_) {}
  }
}
