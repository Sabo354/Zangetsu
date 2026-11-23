import 'dart:convert';

import 'package:hive/hive.dart';

import '../models/media_detail.dart';

/// Keeps the last loaded detail (description + chapter list) of every manga
/// opened from a Mihon source on the phone, like Mihon's own database. The
/// detail screen shows it at once and refreshes in the background.
class DetailDiskCache {
  DetailDiskCache._();

  static const String _boxName = 'detail_cache';
  static const int _maxEntries = 6000;
  static Box<String>? _box;

  static Future<void> init() async {
    try {
      _box = await Hive.openBox<String>(_boxName);
      await _prune();
    } catch (_) {
      _box = null;
    }
  }

  static String _key(String sourceId, String url) => '$sourceId|$url';

  /// Only sources whose data is ours to keep (Mihon manga extensions).
  static bool supports(String? sourceId) =>
      sourceId != null && sourceId.startsWith('mihon:');

  static MediaDetail? read(String sourceId, String url) {
    final raw = _box?.get(_key(sourceId, url));
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return MediaDetail.fromJson(m['d'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String sourceId, String url, MediaDetail d) async {
    final box = _box;
    if (box == null || d.title.isEmpty) return;
    try {
      await box.put(
        _key(sourceId, url),
        jsonEncode({'t': DateTime.now().millisecondsSinceEpoch, 'd': d}),
      );
    } catch (_) {}
  }

  /// Drops the oldest entries once there are more than [_maxEntries].
  static Future<void> _prune() async {
    final box = _box;
    if (box == null || box.length <= _maxEntries) return;
    final stamps = <String, int>{};
    for (final k in box.keys) {
      final raw = box.get(k);
      var t = 0;
      if (raw != null) {
        final i = raw.indexOf('"t":');
        if (i >= 0) {
          t = int.tryParse(
                RegExp(r'\d+').stringMatch(raw.substring(i + 4)) ?? '',
              ) ??
              0;
        }
      }
      stamps[k.toString()] = t;
    }
    final keys = stamps.keys.toList()
      ..sort((a, b) => stamps[a]!.compareTo(stamps[b]!));
    await box.deleteAll(keys.take(box.length - _maxEntries));
  }
}
