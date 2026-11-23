import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../di/injector.dart';
import '../mihon/mihon_manager.dart';
import '../mihon/mihon_mapping.dart' show parseChapterNumber;
import '../mode/content_mode.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../playback/category_store.dart';
import '../playback/my_list.dart';
import '../reading/read_store.dart';
import '../reading/unread_counts.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Import of a Mihon / Komikku / Tachiyomi backup (.tachibk / .proto.gz).
//
// Takes over every library manga whose extension also runs in Zangetsu
// ("mihon:<id>" sources), its categories and which chapters were read.
// Field numbers follow Mihon's backup models (Backup / BackupManga /
// BackupChapter / BackupCategory / BackupSource); Komikku/SY extras are
// skipped except the custom title and cover.
// ─────────────────────────────────────────────────────────────────────────────

class MihonBackupChapter {
  MihonBackupChapter({
    required this.url,
    required this.name,
    required this.scanlator,
    required this.read,
    required this.number,
  });
  final String url;
  final String name;
  final String? scanlator;
  final bool read;
  final double? number;

  /// The same id Zangetsu's Mihon bridge gives this chapter
  /// (see `episodeFromSChapter`), so read marks land on the right row.
  String get zangetsuId {
    final raw = number;
    final n = (raw != null && raw >= 0) ? raw : parseChapterNumber(name);
    final numbered = n != null ? 'ch-${n.toStringAsFixed(1)}' : null;
    final s = scanlator?.trim();
    final id = (numbered != null && s != null && s.isNotEmpty)
        ? '$numbered-$s'
        : (numbered ?? url);
    return id.isNotEmpty ? id : url;
  }
}

class MihonBackupManga {
  MihonBackupManga({
    required this.source,
    required this.url,
    required this.title,
    required this.thumbnailUrl,
    required this.genres,
    required this.dateAdded,
    required this.favorite,
    required this.categoryOrders,
    required this.chapters,
  });
  final int source;
  final String url;
  final String title;
  final String? thumbnailUrl;
  final List<String> genres;
  final int dateAdded;
  final bool favorite;
  final List<int> categoryOrders;
  final List<MihonBackupChapter> chapters;
}

class MihonBackup {
  MihonBackup({
    required this.manga,
    required this.categories,
    required this.sourceNames,
  });

  /// Library entries only (favorites).
  final List<MihonBackupManga> manga;

  /// Category order value → name.
  final Map<int, String> categories;

  /// Source id → name, for telling the user which extensions are missing.
  final Map<int, String> sourceNames;
}

class MihonImportPreview {
  MihonImportPreview({
    required this.backup,
    required this.importable,
    required this.missingSources,
    required this.readChapters,
  });
  final MihonBackup backup;

  /// Titles whose extension is installed in Zangetsu.
  final List<MihonBackupManga> importable;

  /// Extension name → number of titles that need it.
  final Map<String, int> missingSources;
  final int readChapters;
}

class MihonImportResult {
  MihonImportResult({
    required this.added,
    required this.alreadyThere,
    required this.categoriesCreated,
    required this.chaptersMarkedRead,
  });
  final int added;
  final int alreadyThere;
  final int categoriesCreated;
  final int chaptersMarkedRead;
}

class MihonBackupImport {
  /// Parses the raw file. Throws [FormatException] when it isn't a backup.
  static MihonBackup parse(Uint8List bytes) {
    var data = bytes;
    if (data.length > 2 && data[0] == 0x1f && data[1] == 0x8b) {
      data = Uint8List.fromList(GZipDecoder().decodeBytes(data));
    }
    final manga = <MihonBackupManga>[];
    final categories = <int, String>{};
    final sources = <int, String>{};
    final r = _Proto(data);
    while (!r.done) {
      final (field, wire) = r.tag();
      if (field == 1 && wire == 2) {
        final m = _parseManga(r.bytes());
        if (m != null && m.favorite) manga.add(m);
      } else if (field == 2 && wire == 2) {
        final c = _Proto(r.bytes());
        String? name;
        var order = 0;
        while (!c.done) {
          final (f, w) = c.tag();
          if (f == 1 && w == 2) {
            name = c.string();
          } else if (f == 2 && w == 0) {
            order = c.varint();
          } else {
            c.skip(w);
          }
        }
        if (name != null) categories[order] = name;
      } else if (field == 101 && wire == 2) {
        final s = _Proto(r.bytes());
        var name = '';
        int? id;
        while (!s.done) {
          final (f, w) = s.tag();
          if (f == 1 && w == 2) {
            name = s.string();
          } else if (f == 2 && w == 0) {
            id = s.varint();
          } else {
            s.skip(w);
          }
        }
        if (id != null) sources[id] = name;
      } else {
        r.skip(wire);
      }
    }
    if (manga.isEmpty && categories.isEmpty && sources.isEmpty) {
      throw const FormatException('Keine Mihon/Komikku-Sicherung');
    }
    return MihonBackup(manga: manga, categories: categories, sourceNames: sources);
  }

  static MihonBackupManga? _parseManga(Uint8List bytes) {
    final r = _Proto(bytes);
    int? source;
    var url = '', title = '';
    String? thumb, customTitle, customThumb;
    final genres = <String>[];
    var dateAdded = 0;
    var favorite = true;
    final cats = <int>[];
    final chapters = <MihonBackupChapter>[];
    while (!r.done) {
      final (f, w) = r.tag();
      switch ((f, w)) {
        case (1, 0):
          source = r.varint();
        case (2, 2):
          url = r.string();
        case (3, 2):
          title = r.string();
        case (7, 2):
          genres.add(r.string());
        case (9, 2):
          thumb = r.string();
        case (13, 0):
          dateAdded = r.varint();
        case (16, 2):
          final c = _parseChapter(r.bytes());
          if (c != null) chapters.add(c);
        case (17, 0):
          cats.add(r.varint());
        case (17, 2): // packed
          final p = _Proto(r.bytes());
          while (!p.done) {
            cats.add(p.varint());
          }
        case (100, 0):
          favorite = r.varint() != 0;
        case (603, 2):
          customThumb = r.string();
        case (800, 2):
          customTitle = r.string();
        default:
          r.skip(w);
      }
    }
    if (source == null || url.isEmpty) return null;
    return MihonBackupManga(
      source: source,
      url: url,
      title: (customTitle?.isNotEmpty ?? false) ? customTitle! : title,
      thumbnailUrl: (customThumb?.isNotEmpty ?? false) ? customThumb : thumb,
      genres: genres,
      dateAdded: dateAdded,
      favorite: favorite,
      categoryOrders: cats,
      chapters: chapters,
    );
  }

  static MihonBackupChapter? _parseChapter(Uint8List bytes) {
    final r = _Proto(bytes);
    var url = '', name = '';
    String? scanlator;
    var read = false;
    double? number;
    while (!r.done) {
      final (f, w) = r.tag();
      switch ((f, w)) {
        case (1, 2):
          url = r.string();
        case (2, 2):
          name = r.string();
        case (3, 2):
          scanlator = r.string();
        case (4, 0):
          read = r.varint() != 0;
        case (9, 5):
          number = r.float32();
        default:
          r.skip(w);
      }
    }
    if (url.isEmpty) return null;
    return MihonBackupChapter(
      url: url,
      name: name,
      scanlator: scanlator,
      read: read,
      number: number,
    );
  }

  static String sourceIdOf(MihonBackupManga m) => MihonManager.idFor(m.source);

  static MihonImportPreview preview(MihonBackup b) {
    final mihon = sl<MihonManager>();
    final importable = <MihonBackupManga>[];
    final missing = <String, int>{};
    var read = 0;
    for (final m in b.manga) {
      if (mihon.get(sourceIdOf(m)) != null) {
        importable.add(m);
        read += m.chapters.where((c) => c.read).length;
      } else {
        final name = b.sourceNames[m.source] ?? 'Quelle ${m.source}';
        missing[name] = (missing[name] ?? 0) + 1;
      }
    }
    return MihonImportPreview(
      backup: b,
      importable: importable,
      missingSources: missing,
      readChapters: read,
    );
  }

  /// Adds the importable titles to My List, puts them in their categories
  /// (created as manga categories when missing) and marks read chapters.
  /// [categories]: only titles in these category orders (plus titles with
  /// no category when [includeUncategorized]) are taken over; null = all.
  /// Lets one backup be split across profiles.
  static Future<MihonImportResult> apply(
    MihonImportPreview p, {
    Set<int>? categories,
    bool includeUncategorized = true,
    void Function(double progress)? onProgress,
  }) async {
    final todo = [
      for (final m in p.importable)
        if (categories == null ||
            (m.categoryOrders.isEmpty
                ? includeUncategorized
                : m.categoryOrders.any(categories.contains)))
          m,
    ];
    final list = sl<MyListStore>();
    final cats = sl.isRegistered<CategoryStore>() ? sl<CategoryStore>() : null;
    final read = sl<ReadStore>();
    final mihon = sl<MihonManager>();

    // Category name → Zangetsu id (existing ones are reused by name).
    final catIds = <int, String>{};
    var created = 0;
    if (cats != null) {
      for (final entry in p.backup.categories.entries) {
        if (categories != null && !categories.contains(entry.key)) continue;
        final existing = cats.all().where(
          (c) => c.name.toLowerCase() == entry.value.trim().toLowerCase(),
        );
        if (existing.isNotEmpty) {
          catIds[entry.key] = existing.first.id;
          continue;
        }
        final c = await cats.create(entry.value, kind: ContentMode.manga.name);
        if (c != null) {
          catIds[entry.key] = c.id;
          created++;
        }
      }
    }

    // Everything below is batched: thousands of titles one by one meant a
    // network call and a full library rebuild per title.
    final items = <MediaItem>[];
    final memberships = <MediaItem, Set<String>>{};
    final readMarks = <({String sourceId, String showId, String chapterId})>[];
    final chapterLists = <MediaItem, List<String>>{};
    for (var i = 0; i < todo.length; i++) {
      final m = todo[i];
      final sourceId = sourceIdOf(m);
      final headers = mihon.get(sourceId)?.info.headers ?? const {};
      final item = MediaItem(
        id: m.url,
        title: m.title,
        cover: m.thumbnailUrl,
        // Same marker the bridge sets: covers load through the extension
        // (its headers / cookies), not a plain web request.
        coverHeaders: {...headers, 'x-mihon-src': '${m.source}'},
        url: m.url,
        type: ProviderType.manga,
        sourceId: sourceId,
        genres: m.genres,
        savedAtMs: m.dateAdded > 0 ? m.dateAdded : null,
      );
      items.add(item);
      final ids = {
        for (final order in m.categoryOrders)
          if (catIds[order] != null) catIds[order]!,
      };
      if (ids.isNotEmpty) memberships[item] = ids;
      for (final c in m.chapters) {
        if (c.read) {
          readMarks.add((
            sourceId: sourceId,
            showId: item.id,
            chapterId: c.zangetsuId,
          ));
        }
      }
      chapterLists[item] = [for (final c in m.chapters) c.zangetsuId];
    }
    onProgress?.call(0.25);
    final added = await list.addAll(items);
    final already = items.length - added;
    onProgress?.call(0.5);
    if (cats != null) await cats.addMembershipsBulk(memberships);
    onProgress?.call(0.75);
    await read.setReadMany(readMarks);
    final marked = readMarks.length;
    // Seed the unread counter with the backup's chapter lists, so numbers
    // show right away instead of after the first library update.
    await UnreadCounts.instance.seedMany(chapterLists);
    onProgress?.call(1);
    debugPrint('[mihon-import] added=$added already=$already read=$marked');
    return MihonImportResult(
      added: added,
      alreadyThere: already,
      categoriesCreated: created,
      chaptersMarkedRead: marked,
    );
  }
}

/// Minimal protobuf wire reader — just enough for the backup format.
class _Proto {
  _Proto(this._b);
  final Uint8List _b;
  int _i = 0;

  bool get done => _i >= _b.length;

  int varint() {
    var result = 0, shift = 0;
    while (true) {
      final byte = _b[_i++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('varint too long');
    }
  }

  (int, int) tag() {
    final t = varint();
    return (t >> 3, t & 7);
  }

  Uint8List bytes() {
    final len = varint();
    final out = Uint8List.sublistView(_b, _i, _i + len);
    _i += len;
    return out;
  }

  String string() => utf8.decode(bytes(), allowMalformed: true);

  double float32() {
    final v = ByteData.sublistView(_b, _i, _i + 4).getFloat32(0, Endian.little);
    _i += 4;
    return v;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        _i += 8;
      case 2:
        // Read the length FIRST: `_i += varint()` reads `_i` before the call
        // advances it, which loses the length bytes and derails the parse.
        final len = varint();
        _i += len;
      case 5:
        _i += 4;
      default:
        throw FormatException('unknown wire type $wire');
    }
  }
}
