import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../di/injector.dart';
import '../models/episode.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../playback/my_list.dart';
import '../profiles/profile_scope.dart';
import '../profiles/viewer_profile.dart';

/// One new chapter / episode found in the library.
class LibraryUpdate {
  const LibraryUpdate({
    required this.item,
    required this.episodeId,
    required this.episodeTitle,
    required this.number,
    required this.foundAtMs,
    this.profileId,
  });

  /// Profile whose library the update was found for (null = older rows).
  final String? profileId;
  final MediaItem item;
  final String episodeId;
  final String episodeTitle;
  final double? number;
  final int foundAtMs;

  bool get isReading =>
      item.type == ProviderType.manga || item.type == ProviderType.novel;

  DateTime get foundAt => DateTime.fromMillisecondsSinceEpoch(foundAtMs);

  /// "Kapitel 12" / "Folge 3", or the source's own title when it has one.
  String get label {
    final t = episodeTitle.trim();
    if (t.isNotEmpty) return t;
    final n = number;
    final unit = isReading ? 'Kapitel' : 'Folge';
    if (n == null) return unit;
    return n == n.roundToDouble() ? '$unit ${n.toInt()}' : '$unit $n';
  }

  Map<String, dynamic> toMap() => {
    'item': jsonEncode(item.toJson()),
    'ep': episodeId,
    'title': episodeTitle,
    'num': number,
    'at': foundAtMs,
    if (profileId != null) 'pid': profileId,
  };

  static LibraryUpdate? fromMap(Map m) {
    try {
      return LibraryUpdate(
        item: MediaItem.fromJson(
          Map<String, dynamic>.from(jsonDecode(m['item'] as String) as Map),
        ),
        episodeId: '${m['ep']}',
        episodeTitle: '${m['title'] ?? ''}',
        number: (m['num'] as num?)?.toDouble(),
        foundAtMs: (m['at'] as num?)?.toInt() ?? 0,
        profileId: m['pid'] as String?,
      );
    } catch (_) {
      return null; // a broken row is skipped, never crashes the screen
    }
  }
}

/// Mihon-style "Updates" history: every new chapter / episode the library
/// update (or a title's page) found, kept on the device across restarts.
class LibraryUpdates extends ChangeNotifier {
  LibraryUpdates._();

  static final LibraryUpdates instance = LibraryUpdates._();

  static const String boxName = 'library_updates';
  static const String _lastSeenKey = '__last_seen__';
  static const int _maxEntries = 1500;

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map>? get _box => Hive.isBoxOpen(boxName) ? Hive.box<Map>(boxName) : null;

  /// Records the [added] chapters / episodes of [item]. Same timestamp for
  /// the whole batch, so one update run shows up together.
  void record(MediaItem item, List<Episode> added) {
    final box = _box;
    if (box == null || added.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = <String, Map>{};
    var i = 0;
    for (final e in added) {
      // Short key (Hive allows 255 chars): time first, so keys sort by age.
      final id = '$_profileId::${item.sourceId}::${item.id}::${e.id}'.hashCode
          .toUnsigned(32)
          .toRadixString(16);
      final key = '$now|${(i++).toString().padLeft(5, '0')}|$id';
      try {
        rows[key] = LibraryUpdate(
          item: item,
          episodeId: e.id,
          episodeTitle: e.title,
          number: e.number,
          foundAtMs: now,
          profileId: _profileId,
        ).toMap();
      } catch (err) {
        debugPrint('[updates] could not store ${item.title}: $err');
      }
    }
    unawaited(_write(rows));
  }

  Future<void> _write(Map<String, Map> rows) async {
    final box = _box;
    if (box == null) return;
    await box.putAll(rows);
    final keys =
        box.keys.where((k) => !'$k'.startsWith(_lastSeenKey)).toList();
    if (keys.length > _maxEntries) {
      // Keys start with the timestamp, so sorting them is oldest-first.
      keys.sort((a, b) => '$a'.compareTo('$b'));
      await box.deleteAll(keys.take(keys.length - _maxEntries));
    }
    notifyListeners();
  }

  List<LibraryUpdate>? _cache;
  String? _cachePid;

  static String get _profileId => sl.isRegistered<ViewerProfileStore>()
      ? sl<ViewerProfileStore>().dataProfileId
      : kDefaultProfileId;

  @override
  void notifyListeners() {
    _cache = null; // every change goes through here
    super.notifyListeners();
  }

  /// Rows of the active profile. Rows from before profiles were recorded
  /// count for a profile only when that title is in its library.
  bool _mine(LibraryUpdate u, String pid) {
    if (u.profileId != null) return u.profileId == pid;
    try {
      return sl<MyListStore>().contains(u.item);
    } catch (_) {
      return false;
    }
  }

  /// Newest first — only the active profile's updates.
  List<LibraryUpdate> all() {
    final pid = _profileId;
    if (_cache == null || _cachePid != pid) {
      _cachePid = pid;
      _cache = _load(pid);
    }
    return _cache!;
  }

  List<LibraryUpdate> _load(String pid) {
    final box = _box;
    if (box == null) return const [];
    final out = <LibraryUpdate>[];
    for (final key in box.keys) {
      if ('$key'.startsWith(_lastSeenKey)) continue;
      final raw = box.get(key);
      if (raw == null) continue;
      final u = LibraryUpdate.fromMap(raw);
      if (u != null && _mine(u, pid)) out.add(u);
    }
    out.sort((a, b) {
      final byTime = b.foundAtMs.compareTo(a.foundAtMs);
      if (byTime != 0) return byTime;
      return (b.number ?? 0).compareTo(a.number ?? 0);
    });
    return out;
  }

  String get _seenKey => '$_lastSeenKey:${_profileId}';

  int get _lastSeenMs =>
      ((_box?.get(_seenKey) ?? _box?.get(_lastSeenKey))?['at'] as num?)
          ?.toInt() ??
      0;

  /// How many updates arrived since the screen was last opened (badge).
  int get unseenCount {
    final seen = _lastSeenMs;
    return all().where((u) => u.foundAtMs > seen).length;
  }

  Future<void> markAllSeen() async {
    await _box?.put(_seenKey, {'at': DateTime.now().millisecondsSinceEpoch});
    notifyListeners();
  }

  Future<void> clear() async {
    final box = _box;
    if (box == null) return;
    // Only this profile's history.
    final pid = _profileId;
    final drop = <dynamic>[];
    for (final key in box.keys) {
      if ('$key'.startsWith(_lastSeenKey)) continue;
      final raw = box.get(key);
      final u = raw == null ? null : LibraryUpdate.fromMap(raw);
      if (u == null || _mine(u, pid)) drop.add(key);
    }
    await box.deleteAll(drop);
    notifyListeners();
  }
}
