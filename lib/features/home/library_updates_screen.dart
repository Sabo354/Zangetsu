import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/cache/app_image_cache.dart';
import '../../core/di/injector.dart';
import '../../core/playback/resume_store.dart';
import '../../core/reading/library_updates.dart';
import '../../core/reading/unread_counts.dart';
import '../../core/reading/read_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../detail/detail_screen.dart';

enum _UpdatesFilter { all, reading, video }

/// "Neuigkeiten": every new chapter / episode the library found, newest
/// first and grouped by day — like the Updates tab in Mihon / Komikku.
class LibraryUpdatesScreen extends StatefulWidget {
  const LibraryUpdatesScreen({
    super.key,
    this.startOnReading = true,
    this.onUpdateAll,
  });

  /// Checks the whole library (all categories) for new chapters.
  final Future<void> Function()? onUpdateAll;

  /// Opens on the manga side when coming from the manga library.
  final bool startOnReading;

  @override
  State<LibraryUpdatesScreen> createState() => _LibraryUpdatesScreenState();
}

class _LibraryUpdatesScreenState extends State<LibraryUpdatesScreen> {
  late _UpdatesFilter _filter = widget.startOnReading
      ? _UpdatesFilter.reading
      : _UpdatesFilter.video;

  @override
  void initState() {
    super.initState();
    ReadStore.changes.addListener(_onChange);
    ResumeStore.changes.addListener(_onChange);
    // Opening the screen counts as having seen everything in it.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(LibraryUpdates.instance.markAllSeen()),
    );
  }

  @override
  void dispose() {
    ReadStore.changes.removeListener(_onChange);
    ResumeStore.changes.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  bool _isDone(LibraryUpdate u) {
    if (u.isReading) {
      return sl<ReadStore>().finished(u.item.sourceId, u.item.id, u.episodeId);
    }
    return sl<ResumeStore>()
            .get(u.item.sourceId, u.item.url, u.episodeId)
            ?.finished ??
        false;
  }

  String _dayLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Heute';
    if (diff == 1) return 'Gestern';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year}';
  }

  String _time(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Verlauf leeren?'),
        content: const Text(
          'Alle Einträge in den Neuigkeiten werden gelöscht. '
          'Deine Bibliothek und dein Lesefortschritt bleiben erhalten.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leeren'),
          ),
        ],
      ),
    );
    if (ok == true) await LibraryUpdates.instance.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        title: const Text('Neuigkeiten'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: ValueListenableBuilder<double?>(
            valueListenable: UnreadCounts.instance.updateProgress,
            builder: (context, p, _) => p == null
                ? const SizedBox(height: 3)
                : LinearProgressIndicator(
                    value: p,
                    minHeight: 3,
                    color: AppColors.accent,
                    backgroundColor: AppColors.surface2,
                  ),
          ),
        ),
        actions: [
          if (widget.onUpdateAll != null)
            IconButton(
              tooltip: 'Alles aktualisieren',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => widget.onUpdateAll!(),
            ),
          IconButton(
            tooltip: 'Verlauf leeren',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: widget.onUpdateAll == null
          ? _body()
          : RefreshIndicator(
              color: AppColors.accent,
              backgroundColor: AppColors.surface,
              notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
              onRefresh: () async {
                unawaited(widget.onUpdateAll!());
              },
              child: _body(),
            ),
    );
  }

  Widget _body() {
    return ListenableBuilder(
        listenable: LibraryUpdates.instance,
        builder: (context, _) {
          final all = LibraryUpdates.instance.all();
          final shown = [
            for (final u in all)
              if (_filter == _UpdatesFilter.all ||
                  (_filter == _UpdatesFilter.reading) == u.isReading)
                u,
          ];
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    _chip('Manga', _UpdatesFilter.reading),
                    const SizedBox(width: 8),
                    _chip('Anime & Serien', _UpdatesFilter.video),
                    const SizedBox(width: 8),
                    _chip('Alle', _UpdatesFilter.all),
                  ],
                ),
              ),
              Expanded(
                child: shown.isEmpty
                    ? _empty()
                    : ListView.builder(
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.paddingOf(context).bottom + 24,
                        ),
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final u = shown[i];
                          final header =
                              i == 0 ||
                              _dayLabel(shown[i - 1].foundAt) !=
                                  _dayLabel(u.foundAt);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (header)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    16,
                                    16,
                                    6,
                                  ),
                                  child: Text(
                                    _dayLabel(u.foundAt),
                                    style: AppText.caption.copyWith(
                                      color: AppColors.textTertiary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              _row(u),
                            ],
                          );
                        },
                      ),
              ),
            ],
          );
        },
      );
  }

  Widget _chip(String label, _UpdatesFilter value) {
    final selected = _filter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      selectedColor: AppColors.accent,
      backgroundColor: AppColors.surface2,
      side: BorderSide.none,
      labelStyle: AppText.caption.copyWith(
        color: selected ? Colors.white : AppColors.textSecondary,
        fontWeight: FontWeight.w700,
      ),
      onSelected: (_) => setState(() => _filter = value),
    );
  }

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        'Noch keine Neuigkeiten.\n\n'
        'Zieh in der Bibliothek nach unten oder tippe auf '
        '„Bibliothek aktualisieren“ – neue Kapitel und Folgen erscheinen dann hier.',
        textAlign: TextAlign.center,
        style: AppText.body.copyWith(color: AppColors.textTertiary),
      ),
    ),
  );

  Widget _row(LibraryUpdate u) {
    final done = _isDone(u);
    final cover = u.item.cover;
    return InkWell(
      onTap: () => Navigator.push(context, DetailScreen.route(u.item)),
      child: Opacity(
        opacity: done ? 0.45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 44,
                  height: 64,
                  child: cover == null || cover.isEmpty
                      ? Container(color: AppColors.surface2)
                      : CachedNetworkImage(
                          imageUrl: cover,
                          cacheManager: AppImageCache.manager,
                          httpHeaders: u.item.coverHeaders,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              Container(color: AppColors.surface2),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      u.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      u.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (done)
                Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: AppColors.textTertiary,
                )
              else
                Text(
                  _time(u.foundAt),
                  style: AppText.caption.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
