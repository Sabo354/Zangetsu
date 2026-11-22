import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../../features/home/cubit/my_list_cubit.dart';
import '../di/injector.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../playback/resume_store.dart';
import '../repository/catalogue_repository.dart';
import '../zmode/zmode_ids.dart';
import 'read_store.dart';

/// Mihon-style unread counter for the library.
///
/// Remembers each saved title's chapter/episode id list (Hive box
/// [boxName]) and counts how many of them are not finished yet:
///  - manga / novel: chapters not finished in [ReadStore]
///  - anime / series: episodes not finished in [ResumeStore]
///
/// Lists are fetched from the title's source in the background (2 at a time)
/// when the library shows a title without a cached list, or when the cached
/// list is older than [maxAge]. Read/watch progress is local, so the numbers
/// update right away while reading.
class UnreadCounts extends ChangeNotifier {
  UnreadCounts._() {
    ReadStore.changes.addListener(_onProgressChanged);
    ResumeStore.changes.addListener(_onProgressChanged);
  }

  static final UnreadCounts instance = UnreadCounts._();

  static const String boxName = 'unread_chapter_lists';
  static const Duration maxAge = Duration(hours: 6);
  static const int _parallel = 2;

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map>? get _box =>
      Hive.isBoxOpen(boxName) ? Hive.box<Map>(boxName) : null;

  final Set<String> _inFlight = {};
  // Failed fetches wait a while before the next try, so a dead source isn't
  // hammered on every rebuild.
  final Map<String, int> _failedAt = {};
  static const Duration _retryAfter = Duration(minutes: 30);
  final List<MediaItem> _queue = [];
  int _running = 0;
  Timer? _debounce;

  String _key(MediaItem item) => '${item.sourceId}::${item.id}';

  /// Titles we can count: source-backed (not metadata-only `zm://`), and not
  /// one-shot movies.
  bool supports(MediaItem item) {
    if (item.url.isEmpty || ZmodeIds.isZ(item.url)) return false;
    return item.type != ProviderType.movie;
  }

  bool _isReading(MediaItem item) =>
      item.type == ProviderType.manga || item.type == ProviderType.novel;

  List<String>? _cachedIds(MediaItem item) {
    final raw = _box?.get(_key(item));
    if (raw == null) return null;
    final ids = raw['ids'];
    if (ids is! List) return null;
    return ids.map((e) => '$e').toList();
  }

  bool _isFresh(MediaItem item) {
    final raw = _box?.get(_key(item));
    final at = (raw?['at'] as num?)?.toInt();
    if (at == null) return false;
    return DateTime.now().millisecondsSinceEpoch - at < maxAge.inMilliseconds;
  }

  /// Unread chapters (manga/novel) or unwatched episodes (anime/series) of
  /// one title. Null while the list is unknown.
  int? unreadFor(MediaItem item) {
    if (!supports(item)) return null;
    final ids = _cachedIds(item);
    if (ids == null) return null;
    if (_isReading(item)) {
      final read = sl<ReadStore>();
      return ids.where((id) => !read.finished(item.sourceId, item.id, id)).length;
    }
    final resume = sl<ResumeStore>();
    return ids
        .where((id) => !(resume.get(item.sourceId, item.url, id)?.finished ?? false))
        .length;
  }

  /// Same for a library row — a grouped series card sums its members.
  /// Falls back to the tracker's "behind" count for tracker lists.
  int? unreadForEntry(MyListEntry entry) {
    if (entry is SeriesCardEntry) {
      int? sum;
      for (final m in entry.memberItems) {
        final n = unreadFor(m);
        if (n != null) sum = (sum ?? 0) + n;
      }
      return sum;
    }
    return unreadFor(entry.item) ?? behindCount(entry);
  }

  /// Badge text for a library card: the number, or null when there is nothing
  /// unread / nothing known.
  String? badgeFor(MyListEntry entry) {
    final n = entry is SeriesCardEntry
        ? unreadForEntry(entry)
        : unreadFor(entry.item);
    if (n == null || n <= 0) return null;
    return '$n';
  }

  /// Make sure every shown title has a (fresh) list. Cheap to call on every
  /// build: titles already cached, queued or loading are skipped.
  void ensure(Iterable<MediaItem> items, {bool force = false}) {
    if (_box == null) return;
    var added = false;
    for (final item in items) {
      if (!supports(item)) continue;
      final key = _key(item);
      if (_inFlight.contains(key)) continue;
      if (!force && _isFresh(item)) continue;
      final failed = _failedAt[key];
      if (!force &&
          failed != null &&
          DateTime.now().millisecondsSinceEpoch - failed <
              _retryAfter.inMilliseconds) {
        continue;
      }
      _inFlight.add(key);
      _queue.add(item);
      added = true;
    }
    if (added) _pump();
  }

  void ensureForEntries(Iterable<MyListEntry> entries, {bool force = false}) {
    ensure([
      for (final e in entries)
        if (e is SeriesCardEntry) ...e.memberItems else e.item,
    ], force: force);
  }

  void _pump() {
    while (_running < _parallel && _queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      _running++;
      unawaited(
        _fetch(item).whenComplete(() {
          _running--;
          _inFlight.remove(_key(item));
          _pump();
        }),
      );
    }
  }

  Future<void> _fetch(MediaItem item) async {
    try {
      final episodes = await sl<CatalogueRepository>()
          .episodes(item.url, sourceId: item.sourceId)
          .timeout(const Duration(seconds: 45));
      // An empty answer is usually a hiccup, not "the title lost every
      // chapter" — keep the old list then.
      if (episodes.isEmpty && _cachedIds(item) != null) {
        _failedAt[_key(item)] = DateTime.now().millisecondsSinceEpoch;
        return;
      }
      _failedAt.remove(_key(item));
      await _box?.put(_key(item), {
        'ids': [for (final e in episodes) e.id],
        'at': DateTime.now().millisecondsSinceEpoch,
      });
      _notifySoon();
    } catch (e) {
      _failedAt[_key(item)] = DateTime.now().millisecondsSinceEpoch;
      debugPrint('[unread] could not load list for ${item.title}: $e');
    }
  }

  void _onProgressChanged() => _notifySoon();

  void _notifySoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), notifyListeners);
  }
}
