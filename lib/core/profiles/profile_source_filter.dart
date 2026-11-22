import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../di/injector.dart';
import 'profile_scope.dart';
import 'viewer_profile.dart';

/// Which installed sources each profile sees.
///
/// Extensions are installed once for the whole app; this only hides sources
/// per profile from browse, search and source pickers — e.g. profile 1 gets
/// the manga sources for one kind of title, profile 2 the others. Titles
/// already in a profile's library keep opening and updating normally even if
/// their source is hidden there.
class ProfileSourceFilter extends ChangeNotifier {
  ProfileSourceFilter._() {
    if (sl.isRegistered<ViewerProfileStore>()) {
      // Switching profile changes which list applies.
      sl<ViewerProfileStore>().active.addListener(notifyListeners);
    }
  }

  static ProfileSourceFilter? _instance;
  static ProfileSourceFilter get instance =>
      _instance ??= ProfileSourceFilter._();

  static const String boxName = 'profile_source_filter';
  static const String _legacyKey = 'hiddenSources';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<List>(boxName);
    }
  }

  Box<List>? get _box => Hive.isBoxOpen(boxName) ? Hive.box<List>(boxName) : null;

  String get profileId => sl.isRegistered<ViewerProfileStore>()
      ? sl<ViewerProfileStore>().dataProfileId
      : kDefaultProfileId;

  String get _key => profileScopedKey(profileId, _legacyKey);

  /// Changes whenever the hidden set or the active profile changes.
  int get revision => Object.hash(profileId, _rev);
  int _rev = 0;

  Set<String> get _hidden {
    final raw = _box?.get(_key);
    return raw == null ? const {} : raw.map((e) => '$e').toSet();
  }

  bool isHidden(String sourceId) => _hidden.contains(sourceId);

  bool get hasHidden => _hidden.isNotEmpty;

  Future<void> setHidden(String sourceId, bool hidden) async {
    final box = _box;
    if (box == null) return;
    final set = {..._hidden};
    if (hidden ? !set.add(sourceId) : !set.remove(sourceId)) return;
    await box.put(_key, set.toList());
    _rev++;
    notifyListeners();
  }

  Future<void> setAll(Iterable<String> sourceIds, {required bool hidden}) async {
    final box = _box;
    if (box == null) return;
    final set = {..._hidden};
    hidden ? set.addAll(sourceIds) : set.removeAll(sourceIds);
    await box.put(_key, set.toList());
    _rev++;
    notifyListeners();
  }
}
