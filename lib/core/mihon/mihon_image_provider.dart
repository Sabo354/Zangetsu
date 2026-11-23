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

  /// Covers are kept on the phone (like Mihon's cover cache) so they show at
  /// once after an app restart. Reader pages pass false — those would fill
  /// the storage.
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
    Uint8List? bytes =
        key.persist ? await MihonCoverDiskCache.read(key.sourceId, key.url) : null;
    final fromDisk = bytes != null;
    bytes ??= await _kMihonChannel.invokeMethod<Uint8List>(
      'getImage',
      {'sourceId': key.sourceId, 'url': key.url},
    );
    if (key.persist && !fromDisk && bytes != null && bytes.isNotEmpty) {
      unawaited(MihonCoverDiskCache.write(key.sourceId, key.url, bytes));
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


/// Mihon covers stored as files in the app's own storage (not the cache
/// folder Android empties), one file per (source, url). Files are "touched"
/// when shown; anything not shown for 90 days is removed at startup, so
/// covers of titles in the library stay, browse leftovers go away.
class MihonCoverDiskCache {
  MihonCoverDiskCache._();

  static Future<Directory?>? _dir;
  static const Duration _keep = Duration(days: 90);

  static Future<Directory?> _directory() => _dir ??= () async {
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/mihon_covers');
      if (!d.existsSync()) d.createSync(recursive: true);
      unawaited(_prune(d));
      return d;
    } catch (_) {
      return null;
    }
  }();

  static String _name(int sourceId, String url) =>
      sha1.convert(utf8.encode('$sourceId|$url')).toString();

  static Future<Uint8List?> read(int sourceId, String url) async {
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

  static Future<void> write(int sourceId, String url, Uint8List bytes) async {
    final d = await _directory();
    if (d == null) return;
    final name = _name(sourceId, url);
    try {
      // Write to a temp file first so a half-written cover is never read.
      final tmp = File('${d.path}/$name.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename('${d.path}/$name');
    } catch (_) {}
  }

  static Future<void> _prune(Directory d) async {
    try {
      final cutoff = DateTime.now().subtract(_keep);
      await for (final e in d.list()) {
        if (e is! File) continue;
        try {
          if (e.path.endsWith('.tmp') ||
              (await e.lastModified()).isBefore(cutoff)) {
            await e.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Removes every stored cover (used by "clear image cache").
  static Future<void> clear() async {
    final d = await _directory();
    if (d == null) return;
    try {
      await for (final e in d.list()) {
        try {
          await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
