import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// Remembers which list the My List screen was last switched to (own list vs
/// a tracker), so the tracker switcher re-opens where the viewer left it.
class TrackerSwitchPrefs {
  const TrackerSwitchPrefs._();

  static const String boxName = 'tracker_switch_prefs';
  static const String _key = 'lastTracker';

  // Separate memory for video (anime / movies / series) and reading (manga /
  // novels): e.g. anime from AniList, manga from the app's own list.
  static const String _videoKey = 'lastTracker_video';
  static const String _readingKey = 'lastTracker_reading';
  static const String _ownList = '__own_list__';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  static Box? get _boxOrNull =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// Display name of the last-picked tracker for video or reading, or null
  /// for the own list.
  ///
  /// Video falls back to the old shared setting so an existing choice
  /// survives the update; reading starts on the own list until a tracker is
  /// picked there.
  static String? lastTracker({required bool reading}) {
    final box = _boxOrNull;
    final saved = box?.get(reading ? _readingKey : _videoKey);
    if (saved == _ownList) return null;
    if (saved is String) return saved;
    if (reading) return null;
    final legacy = box?.get(_key);
    return legacy is String ? legacy : null;
  }

  static Future<void> saveLastTracker(
    String? displayName, {
    required bool reading,
  }) async {
    final box = _boxOrNull;
    if (box == null) return;
    try {
      await box.put(
        reading ? _readingKey : _videoKey,
        displayName ?? _ownList,
      );
    } catch (_) {
      // Remembering the view is optional; selecting a list must still work.
    }
  }
}
