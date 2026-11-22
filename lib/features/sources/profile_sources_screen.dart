import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/profile_source_filter.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Picks which installed sources the ACTIVE profile sees in browse, search
/// and source pickers. Other profiles keep their own choice.
class ProfileSourcesScreen extends StatefulWidget {
  const ProfileSourcesScreen({super.key});

  @override
  State<ProfileSourcesScreen> createState() => _ProfileSourcesScreenState();
}

class _ProfileSourcesScreenState extends State<ProfileSourcesScreen> {
  String _query = '';

  String _groupOf(String id) {
    if (id.startsWith('mihon:')) return 'Manga (Mihon)';
    if (id.startsWith('lnr') || id.startsWith('lnreader')) return 'Novels';
    if (id.startsWith('aniyomi:') || id.startsWith('ani:')) return 'Anime (Aniyomi)';
    if (id.startsWith('cs:') || id.startsWith('cloudstream')) {
      return 'Streaming (CloudStream)';
    }
    if (id.startsWith('mangayomi')) return 'Mangayomi';
    return 'Weitere';
  }

  @override
  Widget build(BuildContext context) {
    final filter = ProfileSourceFilter.instance;
    final profileName = sl.isRegistered<ViewerProfileStore>()
        ? sl<ViewerProfileStore>().activeProfile.name
        : '';
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          profileName.isEmpty ? 'Quellen im Profil' : 'Quellen für $profileName',
        ),
      ),
      body: ListenableBuilder(
        listenable: filter,
        builder: (context, _) {
          final all = sl<SourceRepository>().allInstalledSources;
          final q = _query.trim().toLowerCase();
          final shown = [
            for (final s in all)
              if (q.isEmpty || s.name.toLowerCase().contains(q)) s,
          ];
          final groups = <String, List<({String id, String name})>>{};
          for (final s in shown) {
            (groups[_groupOf(s.id)] ??= []).add(s);
          }
          for (final g in groups.values) {
            g.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
          }
          final visibleCount = all.where((s) => !filter.isHidden(s.id)).length;
          return ListView(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'Nur eingeschaltete Quellen erscheinen in diesem Profil beim '
                  'Stöbern, in der Suche und bei der Quellenauswahl. Andere '
                  'Profile haben ihre eigene Auswahl. Titel in deiner Bibliothek '
                  'lassen sich weiter lesen und aktualisieren.',
                  style: AppText.caption.copyWith(color: AppColors.textTertiary),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Quelle suchen',
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled: true,
                    fillColor: AppColors.surface2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$visibleCount von ${all.length} sichtbar',
                        style: AppText.caption,
                      ),
                    ),
                    TextButton(
                      onPressed: () => filter.setAll(
                        shown.map((s) => s.id),
                        hidden: false,
                      ),
                      child: const Text('Alle an'),
                    ),
                    TextButton(
                      onPressed: () => filter.setAll(
                        shown.map((s) => s.id),
                        hidden: true,
                      ),
                      child: const Text('Alle aus'),
                    ),
                  ],
                ),
              ),
              for (final entry in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    entry.key.toUpperCase(),
                    style: AppText.caption.copyWith(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                for (final s in entry.value)
                  SwitchListTile(
                    value: !filter.isHidden(s.id),
                    onChanged: (on) => filter.setHidden(s.id, !on),
                    title: Text(s.name),
                    activeThumbColor: AppColors.accent,
                    dense: true,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
