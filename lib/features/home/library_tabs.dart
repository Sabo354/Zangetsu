import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/cache/app_image_cache.dart';
import '../../core/mihon/mihon_image_provider.dart';
import '../../core/models/media_item.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'cubit/my_list_cubit.dart';

/// One tab in the library row: a label, the test that fills its page, and the
/// long-press that manages it (categories only).
class LibraryTab {
  const LibraryTab({
    required this.id,
    required this.label,
    required this.count,
    required this.test,
    this.onLongPress,
  });

  /// Stable across rebuilds, so the selected tab survives the list changing
  /// under it — an index would silently move when a status empties out.
  final String id;
  final String label;

  /// Counted before the search box narrows anything, so the row still shows
  /// where the rest of the list is while you are typing.
  final int count;
  final bool Function(MyListEntry) test;
  final VoidCallback? onLongPress;
}

/// The status row and the grid it filters, as a real [TabBar]/[TabBarView]
/// pair.
///
/// Was a horizontal `ListView` of tap targets over a single grid rebuilt by
/// `setState`: correct, but the pages could not be swiped and the underline
/// jumped between tabs instead of tracking the gesture. The detail screen
/// already uses a TabController for the same job, so this matches it.
class LibraryTabs extends StatefulWidget {
  const LibraryTabs({
    required this.tabs,
    required this.selectedId,
    required this.onSelected,
    required this.bodyFor,
    this.onAdd,
    this.tiled = false,
    this.coversFor,
  });

  /// Tile layout (Settings → Appearance, per profile): one tile per list
  /// with a cover collage instead of the tab row; tap a tile to open it.
  final bool tiled;

  /// Up to four titles of a list, for its tile's cover collage.
  final List<MediaItem> Function(LibraryTab)? coversFor;

  final List<LibraryTab> tabs;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final Widget Function(LibraryTab) bodyFor;

  /// Pinned to the right of the row rather than being its last item: it is an
  /// action, and a swipe should never land on it.
  final VoidCallback? onAdd;

  @override
  State<LibraryTabs> createState() => LibraryTabsState();
}

class LibraryTabsState extends State<LibraryTabs>
    with TickerProviderStateMixin {
  late TabController _c = _makeController();

  int get _wantedIndex {
    final i = widget.tabs.indexWhere((t) => t.id == widget.selectedId);
    return i < 0 ? 0 : i;
  }

  TabController _makeController() => TabController(
    length: widget.tabs.length,
    initialIndex: _wantedIndex,
    vsync: this,
  )..addListener(_onTabChanged);

  void _onTabChanged() {
    // Fires twice per tap (start and end of the animation) and mid-way through
    // a swipe; only the settled index is worth reporting up.
    if (_c.indexIsChanging || !mounted) return;
    final id = widget.tabs[_c.index].id;
    if (id != widget.selectedId) widget.onSelected(id);
  }

  @override
  void didUpdateWidget(LibraryTabs old) {
    super.didUpdateWidget(old);
    // A tab appearing or disappearing (a status emptying out, a category made)
    // invalidates the controller's length, which is fixed at construction.
    if (widget.tabs.length != _c.length) {
      _c.removeListener(_onTabChanged);
      _c.dispose();
      _c = _makeController();
    } else if (_c.index != _wantedIndex) {
      // Moved from outside — creating a category lands on its new tab.
      _c.animateTo(_wantedIndex);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onTabChanged);
    _c.dispose();
    super.dispose();
  }

  /// Tile layout: the list that is open, or null for the tile overview.
  String? _openTileId;

  @override
  Widget build(BuildContext context) {
    if (widget.tiled) return _buildTiled(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 42,
          child: Row(
            children: [
              Expanded(
                // Rebuilt against the controller's animation so the labels
                // recolour with the underline as the page slides, instead of
                // snapping once the swipe settles.
                child: AnimatedBuilder(
                  animation: _c.animation ?? _c,
                  builder: (context, _) => TabBar(
                    controller: _c,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    padding: const EdgeInsetsDirectional.only(start: 16),
                    labelPadding: const EdgeInsetsDirectional.only(end: 22),
                    indicatorSize: TabBarIndicatorSize.label,
                    indicator: UnderlineTabIndicator(
                      borderSide: BorderSide(
                        color: AppColors.accent,
                        width: 2.5,
                      ),
                    ),
                    // The row sat under a hairline; the grid below it reads as
                    // its own block without one.
                    dividerColor: Colors.transparent,
                    splashFactory: NoSplash.splashFactory,
                    overlayColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    tabs: [
                      for (var i = 0; i < widget.tabs.length; i++)
                        _tab(widget.tabs[i], i),
                    ],
                  ),
                ),
              ),
              if (widget.onAdd != null)
                GestureDetector(
                  onTap: widget.onAdd,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(4, 8, 16, 10),
                    child: Icon(
                      Icons.add_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TabBarView(
            controller: _c,
            children: [for (final t in widget.tabs) widget.bodyFor(t)],
          ),
        ),
      ],
    );
  }

  Widget _buildTiled(BuildContext context) {
    LibraryTab? open;
    for (final t in widget.tabs) {
      if (t.id == _openTileId) open = t;
    }
    if (open != null) {
      final tab = open;
      return PopScope(
        // Back closes the list and returns to the tiles, not the app.
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _openTileId = null);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, size: 20),
                    color: AppColors.textSecondary,
                    onPressed: () => setState(() => _openTileId = null),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onLongPress: tab.onLongPress,
                      child: Text(
                        tab.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 16, left: 8),
                    child: Text(
                      '${tab.count}',
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: widget.bodyFor(tab)),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 3 / 4,
      ),
      itemCount: widget.tabs.length + (widget.onAdd != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == widget.tabs.length) return _addTile();
        final t = widget.tabs[i];
        return _LibraryListTile(
          tab: t,
          covers: widget.coversFor?.call(t) ?? const [],
          onTap: () {
            setState(() => _openTileId = t.id);
            if (t.id != widget.selectedId) widget.onSelected(t.id);
          },
        );
      },
    );
  }

  Widget _addTile() => GestureDetector(
    onTap: widget.onAdd,
    child: Container(
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Center(
        child: Icon(Icons.add_rounded, size: 32, color: AppColors.textSecondary),
      ),
    ),
  );

  Widget _tab(LibraryTab t, int i) {
    // Distance from this tab, so a half-finished swipe is half-coloured.
    final at = _c.animation?.value ?? _c.index.toDouble();
    final near = (1 - (at - i).abs()).clamp(0.0, 1.0);
    final label = Color.lerp(AppColors.textSecondary, AppColors.accent, near)!;
    final count = Color.lerp(AppColors.textTertiary, AppColors.accent, near)!;
    return Tab(
      height: 42,
      child: GestureDetector(
        onLongPress: t.onLongPress,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.label,
              style: AppText.body.copyWith(
                color: label,
                fontWeight: FontWeight.w700,
                fontSize: 14.5,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${t.count}',
              style: AppText.caption.copyWith(color: count, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}


/// One list as a big tile: 2×2 cover collage (or one cover), name and count.
class _LibraryListTile extends StatelessWidget {
  const _LibraryListTile({
    required this.tab,
    required this.covers,
    required this.onTap,
  });

  final LibraryTab tab;
  final List<MediaItem> covers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    return GestureDetector(
      onTap: onTap,
      onLongPress: tab.onLongPress,
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: AppColors.surface2, child: _collage()),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.4, 1.0],
                  colors: [Colors.transparent, Color(0xDD000000)],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tab.label.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tab.count == 1 ? '1 Titel' : '${tab.count} Titel',
                    style: AppText.caption.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _collage() {
    if (covers.isEmpty) {
      return const Center(
        child: Icon(
          Icons.collections_bookmark_outlined,
          size: 36,
          color: AppColors.textTertiary,
        ),
      );
    }
    if (covers.length < 4) return _cover(covers.first);
    return Column(
      children: [
        for (final row in [covers.sublist(0, 2), covers.sublist(2, 4)])
          Expanded(
            child: Row(
              children: [
                for (final m in row) Expanded(child: _cover(m)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cover(MediaItem m) {
    final url = m.cover;
    if (url == null || url.isEmpty) return const SizedBox.expand();
    final mihonSrc = m.coverHeaders?['x-mihon-src'];
    final ImageProvider image = mihonSrc != null && int.tryParse(mihonSrc) != null
        // Mihon covers go through the extension (headers / Cloudflare cookie).
        ? MihonImage(int.parse(mihonSrc), url)
        : CachedNetworkImageProvider(
            url,
            headers: m.coverHeaders,
            cacheManager: AppImageCache.manager,
            maxWidth: 300,
          );
    return Image(
      image: image,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const SizedBox.expand(),
    );
  }
}
