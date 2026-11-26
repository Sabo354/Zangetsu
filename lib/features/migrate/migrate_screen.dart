import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/cache/detail_disk_cache.dart';
import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/mode/content_mode.dart';
import '../../core/playback/category_store.dart';
import '../../core/playback/my_list.dart';
import '../../core/reading/read_store.dart';
import '../../core/reading/unread_counts.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/global_messenger.dart';
import '../../core/ui/poster_card.dart';

/// Mihon-style "Migrieren": find a library title in your other sources and
/// move it there — read progress (by chapter number) and categories come
/// along, the old entry is removed (or kept, when copying).
class MigrateScreen extends StatefulWidget {
  const MigrateScreen({super.key, required this.items});

  final List<MediaItem> items;

  static Future<void> open(BuildContext context, List<MediaItem> items) {
    final list = [
      for (final m in items)
        if (m.type == ProviderType.manga || m.type == ProviderType.novel) m,
    ];
    if (list.isEmpty) {
      showGlobalSnack('Migrieren geht nur bei Mangas und Romanen');
      return Future.value();
    }
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MigrateScreen(items: list)),
    );
  }

  @override
  State<MigrateScreen> createState() => _MigrateScreenState();
}

class _SourceResult {
  _SourceResult(this.id, this.name);
  final String id;
  final String name;
  bool loading = true;
  bool failed = false;
  List<MediaItem> items = const [];
}

class _MigrateScreenState extends State<MigrateScreen> {
  int _index = 0;
  int _gen = 0;
  late final TextEditingController _query = TextEditingController();
  List<_SourceResult> _results = const [];
  bool _busy = false;

  MediaItem get _current => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _startFor(_current);
  }

  @override
  void dispose() {
    _gen++;
    _query.dispose();
    super.dispose();
  }

  List<({String id, String name})> _sourcesFor(MediaItem m) {
    final mode = m.type == ProviderType.novel
        ? ContentMode.novel
        : ContentMode.manga;
    return [
      for (final s in sl<SourceRepository>().loadedSources)
        if (s.id != m.sourceId && sourceIdMatchesContentMode(s.id, mode)) s,
    ];
  }

  void _startFor(MediaItem m) {
    _query.text = m.title;
    _search();
  }

  void _search() {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    final gen = ++_gen;
    final sources = _sourcesFor(_current);
    setState(() {
      _results = [for (final s in sources) _SourceResult(s.id, s.name)];
    });
    var next = 0;
    Future<void> worker() async {
      while (next < _results.length) {
        if (gen != _gen || !mounted) return;
        final r = _results[next++];
        try {
          final found = await sl<CatalogueRepository>()
              .search(q, sourceId: r.id)
              .timeout(const Duration(seconds: 25));
          r.items = found.take(8).toList();
        } catch (_) {
          r.failed = true;
        }
        r.loading = false;
        if (gen == _gen && mounted) setState(() {});
      }
    }

    for (var i = 0; i < 4; i++) {
      unawaited(worker());
    }
  }

  void _next() {
    if (_index + 1 >= widget.items.length) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _index++);
    _startFor(_current);
  }

  Future<List<Episode>?> _episodes(MediaItem m) async {
    final cached = DetailDiskCache.read(m.sourceId, m.url)?.episodes;
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      return await sl<CatalogueRepository>()
          .episodes(m.url, sourceId: m.sourceId)
          .timeout(const Duration(seconds: 45));
    } catch (_) {
      return null;
    }
  }

  Future<void> _pick(MediaItem target) async {
    var keepProgress = true;
    var keepCategories = true;
    var removeOld = true;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nach „${_sourceName(target.sourceId)}“', style: AppText.title),
                const SizedBox(height: 4),
                Text(
                  '${_current.title}  →  ${target.title}',
                  style: AppText.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: keepProgress,
                  contentPadding: EdgeInsets.zero,
                  activeColor: AppColors.accent,
                  title: const Text('Gelesene Kapitel übernehmen'),
                  onChanged: (v) => setLocal(() => keepProgress = v ?? true),
                ),
                CheckboxListTile(
                  value: keepCategories,
                  contentPadding: EdgeInsets.zero,
                  activeColor: AppColors.accent,
                  title: const Text('Kategorien übernehmen'),
                  onChanged: (v) => setLocal(() => keepCategories = v ?? true),
                ),
                CheckboxListTile(
                  value: removeOld,
                  contentPadding: EdgeInsets.zero,
                  activeColor: AppColors.accent,
                  title: const Text('Alten Eintrag entfernen'),
                  subtitle: const Text('Aus = kopieren, beide bleiben'),
                  onChanged: (v) => setLocal(() => removeOld = v ?? true),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                    ),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(removeOld ? 'Migrieren' : 'Kopieren'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final old = _current;
    try {
      final newEps = await _episodes(target);
      // Read progress: every chapter up to the highest one read before
      // (like Mihon), matched by chapter number.
      var progressNote = '';
      if (keepProgress && newEps != null) {
        final oldEps = await _episodes(old);
        final rs = sl<ReadStore>();
        double? maxRead;
        for (final e in oldEps ?? const <Episode>[]) {
          final n = e.number;
          if (n != null && rs.finished(old.sourceId, old.id, e.id)) {
            if (maxRead == null || n > maxRead) maxRead = n;
          }
        }
        if (maxRead != null) {
          final batch = [
            for (final e in newEps)
              if (e.number != null && e.number! <= maxRead)
                (sourceId: target.sourceId, showId: target.id, chapterId: e.id),
          ];
          if (batch.isNotEmpty) await rs.setReadMany(batch);
          progressNote = ', bis Kapitel ${_fmt(maxRead)} gelesen';
        } else if (oldEps == null) {
          progressNote = ', Fortschritt nicht übernommen (alte Quelle offline)';
        }
      }
      final cats = keepCategories
          ? sl<CategoryStore>().categoriesOf(old)
          : const <String>{};
      await sl<MyListStore>().addAll([target]);
      if (cats.isNotEmpty) {
        await sl<CategoryStore>().addMembershipsBulk({target: cats});
      }
      if (newEps != null) UnreadCounts.instance.remember(target, newEps);
      if (removeOld) await sl<MyListStore>().remove(old);
      showGlobalSnack(
        '„${old.title}“ ${removeOld ? 'migriert' : 'kopiert'}$progressNote',
      );
    } catch (e) {
      showGlobalSnack('Migrieren fehlgeschlagen: $e');
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _next();
  }

  static String _fmt(double n) =>
      n == n.roundToDouble() ? n.toInt().toString() : n.toString();

  String _sourceName(String id) => sl<SourceRepository>().displayName(id);

  @override
  Widget build(BuildContext context) {
    final m = _current;
    final total = widget.items.length;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(
          total > 1 ? 'Migrieren (${_index + 1}/$total)' : 'Migrieren',
        ),
        actions: [
          if (total > 1)
            TextButton(
              onPressed: _busy ? null : _next,
              child: const Text('Überspringen'),
            ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '${m.title}\naktuell: ${_sourceName(m.sourceId)}',
                  style: AppText.caption,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: 'Titel suchen',
                    filled: true,
                    fillColor: AppColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search_rounded),
                      onPressed: _search,
                    ),
                  ),
                ),
              ),
              if (_results.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Keine anderen Quellen installiert.',
                    style: AppText.body,
                  ),
                ),
              for (final r in _results) _sourceSection(r),
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x88000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sourceSection(_SourceResult r) {
    if (!r.loading && (r.failed || r.items.isEmpty)) {
      // Keep the screen short: sources without hits collapse to one line.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Text(
          '${r.name}: ${r.failed ? 'nicht erreichbar' : 'nichts gefunden'}',
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  r.name,
                  style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (r.loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        if (r.items.isNotEmpty)
          SizedBox(
            height: 210,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: r.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final item = r.items[i];
                return SizedBox(
                  width: 112,
                  child: PosterCard(
                    title: item.title,
                    imageUrl: item.cover,
                    headers: item.coverHeaders,
                    isAdult: item.isAdult,
                    cellWidth: 112,
                    onTap: _busy ? null : () => _pick(item),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
