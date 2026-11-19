import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reader for Mihon / Tachiyomi backups (`.tachibk`, `.proto.gz`): gzip + protobuf.
/// Only what we import is decoded: library titles, categories, read chapters.
/// Field numbers follow mihonapp/mihon `data/backup/models/*.kt`.
class MihonBackup {
  const MihonBackup({required this.manga, required this.sources, required this.categories});
  final List<MihonManga> manga;

  /// source id → source name ("MangaLib", "ReadManga", …)
  final Map<int, String> sources;
  final List<MihonCategory> categories;

  List<MihonManga> get library => manga.where((m) => m.favorite).toList();

  String sourceName(int id) => sources[id] ?? 'Источник $id';

  static MihonBackup parse(Uint8List file) {
    final bytes = file.length > 2 && file[0] == 0x1f && file[1] == 0x8b ? Uint8List.fromList(gzip.decode(file)) : file;
    final r = _Pb(bytes);
    final manga = <MihonManga>[];
    final sources = <int, String>{};
    final cats = <MihonCategory>[];
    var sawAny = false;
    while (!r.done) {
      final (field, wire) = r.tag();
      if (field == 1 && wire == 2) {
        manga.add(MihonManga._parse(r.sub()));
        sawAny = true;
      } else if (field == 2 && wire == 2) {
        cats.add(MihonCategory._parse(r.sub()));
      } else if ((field == 101 || field == 100) && wire == 2) {
        final s = r.sub();
        String name = '';
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
    if (!sawAny && cats.isEmpty) throw const FormatException('Это не резервная копия Mihon/Tachiyomi');
    return MihonBackup(manga: manga, sources: sources, categories: cats);
  }
}

class MihonCategory {
  const MihonCategory(this.name, this.order);
  final String name;
  final int order;

  static MihonCategory _parse(_Pb r) {
    var name = '';
    var order = 0;
    while (!r.done) {
      final (f, w) = r.tag();
      if (f == 1 && w == 2) {
        name = r.string();
      } else if (f == 2 && w == 0) {
        order = r.varint();
      } else {
        r.skip(w);
      }
    }
    return MihonCategory(name, order);
  }
}

class MihonChapter {
  const MihonChapter({required this.url, required this.name, required this.read, required this.number, this.lastPageRead = 0});
  final String url, name;
  final bool read;
  final double number;
  final int lastPageRead;

  static MihonChapter _parse(_Pb r) {
    var url = '', name = '';
    var read = false;
    var number = -1.0;
    var page = 0;
    while (!r.done) {
      final (f, w) = r.tag();
      switch ((f, w)) {
        case (1, 2):
          url = r.string();
        case (2, 2):
          name = r.string();
        case (4, 0):
          read = r.varint() != 0;
        case (6, 0):
          page = r.varint();
        case (9, 5):
          number = r.float32();
        default:
          r.skip(w);
      }
    }
    return MihonChapter(url: url, name: name, read: read, number: number, lastPageRead: page);
  }
}

class MihonManga {
  const MihonManga({
    required this.source,
    required this.url,
    required this.title,
    this.author,
    this.thumbnailUrl,
    this.genres = const [],
    this.status = 0,
    this.categoryOrders = const [],
    this.favorite = true,
    this.chapters = const [],
  });
  final int source;
  final String url, title;
  final String? author, thumbnailUrl;
  final List<String> genres;
  final int status;
  final List<int> categoryOrders;
  final bool favorite;
  final List<MihonChapter> chapters;

  /// Highest chapter number marked read (null: nothing read).
  double? get lastRead {
    double? best;
    for (final c in chapters) {
      if (c.read && c.number >= 0 && (best == null || c.number > best)) best = c.number;
    }
    return best;
  }

  int get readCount => chapters.where((c) => c.read).length;

  static MihonManga _parse(_Pb r) {
    var source = 0;
    var url = '', title = '';
    String? author, thumb;
    final genres = <String>[];
    var status = 0;
    final cats = <int>[];
    var favorite = true;
    final chapters = <MihonChapter>[];
    while (!r.done) {
      final (f, w) = r.tag();
      switch ((f, w)) {
        case (1, 0):
          source = r.varint();
        case (2, 2):
          url = r.string();
        case (3, 2):
          title = r.string();
        case (5, 2):
          author = r.string();
        case (7, 2):
          genres.add(r.string());
        case (8, 0):
          status = r.varint();
        case (9, 2):
          thumb = r.string();
        case (16, 2):
          chapters.add(MihonChapter._parse(r.sub()));
        case (17, 0):
          cats.add(r.varint());
        case (17, 2): // packed
          final p = r.sub();
          while (!p.done) {
            cats.add(p.varint());
          }
        case (100, 0):
          favorite = r.varint() != 0;
        default:
          r.skip(w);
      }
    }
    return MihonManga(
      source: source,
      url: url,
      title: title,
      author: author,
      thumbnailUrl: thumb,
      genres: genres,
      status: status,
      categoryOrders: cats,
      favorite: favorite,
      chapters: chapters,
    );
  }
}

/// Minimal protobuf wire reader.
class _Pb {
  _Pb(this.b, [this.pos = 0, int? end]) : end = end ?? b.length;
  final Uint8List b;
  int pos;
  final int end;

  bool get done => pos >= end;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= end) throw const FormatException('Повреждённая резервная копия');
      final byte = b[pos++];
      if (shift < 64) result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  (int, int) tag() {
    final t = varint();
    return (t >> 3, t & 7);
  }

  _Pb sub() {
    final len = varint();
    if (len < 0 || pos + len > end) throw const FormatException('Повреждённая резервная копия');
    final s = _Pb(b, pos, pos + len);
    pos += len;
    return s;
  }

  String string() {
    final s = sub();
    return utf8.decode(Uint8List.sublistView(b, s.pos, s.end), allowMalformed: true);
  }

  double float32() {
    final v = ByteData.sublistView(b, pos, pos + 4).getFloat32(0, Endian.little);
    pos += 4;
    return v;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        pos += 8;
      case 2:
        sub();
      case 5:
        pos += 4;
      default:
        throw FormatException('Неизвестный тип поля $wire');
    }
  }
}

/// Writer used by tests (and nothing else): builds protobuf the way Mihon does.
class PbWriter {
  final _out = BytesBuilder();

  void _varint(int v) {
    var x = v;
    while (true) {
      if (x & ~0x7f == 0) {
        _out.addByte(x);
        return;
      }
      _out.addByte((x & 0x7f) | 0x80);
      x = x >>> 7;
    }
  }

  void _tag(int field, int wire) => _varint(field << 3 | wire);

  void varint(int field, int v) {
    _tag(field, 0);
    _varint(v);
  }

  void bytes(int field, List<int> data) {
    _tag(field, 2);
    _varint(data.length);
    _out.add(data);
  }

  void string(int field, String s) => bytes(field, utf8.encode(s));

  void message(int field, PbWriter m) => bytes(field, m.toBytes());

  void float32(int field, double v) {
    _tag(field, 5);
    final d = ByteData(4)..setFloat32(0, v, Endian.little);
    _out.add(d.buffer.asUint8List());
  }

  Uint8List toBytes() => _out.toBytes();
}
