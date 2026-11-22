import 'package:flutter/material.dart';

import '../../core/prefs/library_layout_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// "Reiter" or "Kacheln" for the library, saved for the active profile.
Future<void> showLibraryLayoutPicker(BuildContext context) async {
  final current = LibraryLayoutPrefs.layout;
  final picked = await showModalBottomSheet<LibraryLayout>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(
              children: [Text('Bibliothek-Ansicht', style: AppText.headline)],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Gilt nur für das Profil, in dem du gerade bist.',
              style: AppText.caption,
            ),
          ),
          const Divider(color: AppColors.hairline, height: 1),
          for (final (value, title, subtitle, icon) in [
            (
              LibraryLayout.tabs,
              'Reiter',
              'Kategorien als Reiter oben, zum Wischen',
              Icons.tab_rounded,
            ),
            (
              LibraryLayout.tiles,
              'Kacheln',
              'Jede Kategorie als große Kachel mit Covern',
              Icons.grid_view_rounded,
            ),
          ])
            ListTile(
              leading: Icon(icon, color: AppColors.textSecondary),
              title: Text(title),
              subtitle: Text(subtitle, style: AppText.caption),
              trailing: value == current
                  ? Icon(Icons.check, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(ctx, value),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (picked == null || picked == current) return;
  await LibraryLayoutPrefs.setLayout(picked);
}

