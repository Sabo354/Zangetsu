import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../di/injector.dart';
import '../profiles/profile_scope.dart';
import '../profiles/viewer_profile.dart';

/// How the library shows its lists, chosen per profile:
///  - [tabs]: a row of tabs over the grid (the app's default)
///  - [tiles]: one big tile per list / category with a cover collage, tap to
///    open it (like the Mihon / Komikku setup)
enum LibraryLayout { tabs, tiles }

class LibraryLayoutPrefs {
  static const String boxName = 'ui_prefs';
  static const String _key = 'libLayout';

  /// Bumped on every change, so open screens can rebuild.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  static String get _profileId => sl.isRegistered<ViewerProfileStore>()
      ? sl<ViewerProfileStore>().dataProfileId
      : kDefaultProfileId;

  static String get _scopedKey => profileScopedKey(_profileId, _key);

  /// The active profile's layout.
  static LibraryLayout get layout {
    final name = _box?.get(_scopedKey) as String?;
    return name == LibraryLayout.tiles.name
        ? LibraryLayout.tiles
        : LibraryLayout.tabs;
  }

  static Future<void> setLayout(LibraryLayout value) async {
    await _box?.put(_scopedKey, value.name);
    changes.value++;
  }

  static const String _hideAllKey = 'libHideAll';

  /// Whether the active profile hides the "Alle" list (tab / tile).
  static bool get hideAll =>
      _box?.get(profileScopedKey(_profileId, _hideAllKey)) == true;

  static Future<void> setHideAll(bool value) async {
    await _box?.put(profileScopedKey(_profileId, _hideAllKey), value);
    changes.value++;
  }

  static const String _tileColsKey = 'libTileColumns';

  /// Tiles per row in the tile view (2–4), per profile.
  static int get tileColumns {
    final v = _box?.get(profileScopedKey(_profileId, _tileColsKey));
    return v is int && v >= 2 && v <= 4 ? v : 2;
  }

  static Future<void> setTileColumns(int value) async {
    await _box?.put(profileScopedKey(_profileId, _tileColsKey), value);
    changes.value++;
  }
}
