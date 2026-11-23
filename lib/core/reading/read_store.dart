import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/hive/hive_key.dart';

import '../privacy/incognito_mode.dart';
import '../profiles/profile_scope.dart';

/// Hive-backed per-(sourceId, showId, chapterId) reading positions.
///
/// The reading analogue of ResumeStore: local-only, not synced (Continue
/// Reading syncs via ReadHistory, added separately).
///
/// Convention:
///  - manga: pos = page index, total = page count.
///  - novel: pos = scroll permille (0–1000), total = 1000.
class ReadStore {
  ReadStore({String? Function()? currentProfileId})
    : _currentProfileId = currentProfileId;

  final String? Function()? _currentProfileId;
  String get _profileId => _currentProfileId?.call() ?? kDefaultProfileId;

  static const String boxName = 'read_positions';

  /// Bumped on every saved position / read mark, so the library's unread
  /// counter can refresh without polling.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  // Key includes the SHOW because chapter ids can repeat across titles —
  // without it, one show's read position collides with another's.
  String _key(String sourceId, String showId, String chapterId) =>
      profileScopedKey(_profileId, hiveKey('$sourceId::$showId::$chapterId'));

  Future<void> save(
    String sourceId,
    String showId,
    String chapterId, {
    required int pos,
    required int total,
  }) async {
    if (IncognitoMode.on) return; // incognito: don't remember reading position
    final key = _key(sourceId, showId, chapterId);
    // Carry a hand-set read flag across. This REPLACES the record, so without
    // this, marking a chapter read and then scrolling a single pixel wiped the
    // flag on the next autosave and the chapter quietly un-marked itself.
    final prev = _box.get(key);
    final wasMarkedRead = prev is Map && prev['read'] == true;
    final wasFinished = finished(sourceId, showId, chapterId);
    await _box.put(key, {
      'pos': pos,
      'total': total,
      if (wasMarkedRead) 'read': true,
    });
    // The reader autosaves about once a second while you scroll. Only a
    // change in read/unread matters to listeners (library unread counter),
    // so don't wake them for every position write — that rebuilt the
    // library mid-scroll and made the reader stutter.
    if (finished(sourceId, showId, chapterId) != wasFinished) {
      changes.value++;
    }
  }

  ({int pos, int total})? get(
    String sourceId,
    String showId,
    String chapterId,
  ) {
    final raw = _box.get(_key(sourceId, showId, chapterId));
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw);
    return (
      pos: (m['pos'] as num?)?.toInt() ?? 0,
      total: (m['total'] as num?)?.toInt() ?? 0,
    );
  }

  /// True when the chapter is effectively done: last page (manga) or ≥95%
  /// scrolled (novel, where total is always 1000).
  /// Mark a chapter read (or not) by hand, from the chapter list's long-press
  /// menu.
  ///
  /// Stores a flag rather than faking a read position. Writing `pos == total`
  /// would make it "finished" but would also tell the reader to reopen the
  /// chapter at its last page, which is not what someone who never opened it
  /// meant. Unmarking clears the position too, or a genuinely-read chapter
  /// would still pass the 95% rule below and read as finished anyway.
  ///
  /// Runs in incognito on purpose: this is an explicit request to record
  /// something, not the passive history incognito exists to suppress.
  Future<void> setRead(
    String sourceId,
    String showId,
    String chapterId, {
    required bool read,
  }) async {
    final key = _key(sourceId, showId, chapterId);
    final raw = _box.get(key);
    final m = raw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(raw);
    if (read) {
      m['read'] = true;
    } else {
      m.remove('read');
      m['pos'] = 0;
    }
    await _box.put(key, m);
    changes.value++;
  }

  /// Marks many chapters read in one batch write (backup import).
  Future<void> setReadMany(
    Iterable<({String sourceId, String showId, String chapterId})> chapters,
  ) async {
    final writes = <String, Map>{};
    for (final c in chapters) {
      final key = _key(c.sourceId, c.showId, c.chapterId);
      final raw = writes[key] ?? _box.get(key);
      final m = raw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(raw);
      m['read'] = true;
      writes[key] = m;
    }
    if (writes.isEmpty) return;
    await _box.putAll(writes);
    changes.value++;
  }

  bool finished(String sourceId, String showId, String chapterId) {
    // The hand-set flag wins: it is the only signal for a chapter that was
    // never opened.
    final raw = _box.get(_key(sourceId, showId, chapterId));
    if (raw is Map && raw['read'] == true) return true;
    final mark = get(sourceId, showId, chapterId);
    if (mark == null || mark.total <= 0) return false;
    if (mark.total == 1000) return mark.pos >= 950; // novel: 95% of permille
    // Manga: 95% of the way through, not the literal last page. Vertical
    // (webtoon) position is estimated proportionally from scroll pixels, which
    // assumes uniform page heights — manhwa pages vary wildly and the reader
    // adds a next-chapter footer, so the estimate tops out short of the final
    // index. Measured on a 99-page chapter: scrolling to the visible end
    // ("To be continued") reported pos=95, so `pos >= total - 1` was
    // unreachable and the chapter could never be marked read — which also
    // meant it never scrobbled. 95% matches the novel rule above and the
    // player's 92%.
    final last = mark.total - 1;
    return mark.pos >= last || mark.pos >= last * 0.95;
  }
}
