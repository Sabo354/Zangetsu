import 'dart:async';

import '../di/injector.dart';
import '../mihon/mihon_image_provider.dart';
import '../playback/my_list.dart';

/// Loads every library cover onto the phone once in the background, so the
/// tiles and lists show all covers at once — even the ones never scrolled to.
/// Covers already stored are skipped, so after the first run this is cheap.
class CoverPrefetch {
  CoverPrefetch._();

  static bool _started = false;

  static void startOnce() {
    if (_started || !sl.isRegistered<MyListStore>()) return;
    _started = true;
    unawaited(
      Future<void>.delayed(const Duration(seconds: 8), _run),
    );
  }

  static Future<void> _run() async {
    final jobs = <(int, String)>[];
    final seen = <String>{};
    try {
      for (final m in sl<MyListStore>().all()) {
        final url = m.cover;
        final src = int.tryParse(m.coverHeaders?['x-mihon-src'] ?? '');
        if (url == null || url.isEmpty || src == null) continue;
        if (seen.add('$src|$url')) jobs.add((src, url));
      }
    } catch (_) {
      return;
    }
    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        final (src, url) = jobs[next++];
        await MihonCoverDiskCache.prefetchCover(src, url);
      }
    }

    await Future.wait([for (var i = 0; i < 3; i++) worker()]);
  }
}
