import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal ZIP support for chapter transfer: images are already compressed,
/// so we only *write* stored entries (fast, streamable) and *read* stored or
/// deflated ones (what other apps' CBZ files use). No ZIP64: < 4 GiB.
class ZipFormatException implements Exception {
  ZipFormatException(this.message);
  final String message;
  @override
  String toString() => 'ZipFormatException: $message';
}

const _maxU32 = 0xFFFFFFFF;

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    t[n] = c;
  }
  return t;
}();

int crc32Update(int crc, List<int> data) {
  var c = crc ^ _maxU32;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  return c ^ _maxU32;
}

class _Written {
  _Written(this.name, this.offset, this.crc, this.size, this.time, this.date);
  final List<int> name;
  final int offset, crc, size, time, date;
}

/// Streams stored entries into [path]. Call [close] to write the directory.
class ZipWriter {
  ZipWriter._(this._raf);
  final RandomAccessFile _raf;
  final _entries = <_Written>[];
  var _pos = 0;

  static Future<ZipWriter> create(String path) async =>
      ZipWriter._(await File(path).open(mode: FileMode.write));

  int get bytesWritten => _pos;

  static (int, int) _dosTime(DateTime t) => (
        (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2),
        ((t.year - 1980).clamp(0, 127) << 9) | (t.month << 5) | t.day,
      );

  Uint8List _localHeader(List<int> name, int crc, int size, int time, int date) {
    final b = ByteData(30);
    b.setUint32(0, 0x04034b50, Endian.little);
    b.setUint16(4, 20, Endian.little);
    b.setUint16(6, 0x0800, Endian.little); // UTF-8 names
    b.setUint16(8, 0, Endian.little); // stored
    b.setUint16(10, time, Endian.little);
    b.setUint16(12, date, Endian.little);
    b.setUint32(14, crc, Endian.little);
    b.setUint32(18, size, Endian.little);
    b.setUint32(22, size, Endian.little);
    b.setUint16(26, name.length, Endian.little);
    b.setUint16(28, 0, Endian.little);
    return Uint8List.fromList([...b.buffer.asUint8List(), ...name]);
  }

  Future<void> addBytes(String name, List<int> data) async {
    final n = utf8.encode(name);
    final (time, date) = _dosTime(DateTime.now());
    final crc = crc32Update(0, data);
    final offset = _pos;
    _check(offset + 30 + n.length + data.length);
    final header = _localHeader(n, crc, data.length, time, date);
    await _raf.writeFrom(header);
    await _raf.writeFrom(data);
    _pos += header.length + data.length;
    _entries.add(_Written(n, offset, crc, data.length, time, date));
  }

  /// Copies [file] in chunks; the CRC is patched into the header afterwards.
  Future<void> addFile(String name, File file, {void Function(int bytes)? onBytes}) async {
    final n = utf8.encode(name);
    final (time, date) = _dosTime(DateTime.now());
    final offset = _pos;
    await _raf.writeFrom(_localHeader(n, 0, 0, time, date));
    _pos += 30 + n.length;
    var crc = 0, size = 0;
    final input = await file.open();
    try {
      final buf = Uint8List(1 << 16);
      while (true) {
        final read = await input.readInto(buf);
        if (read <= 0) break;
        final chunk = Uint8List.sublistView(buf, 0, read);
        crc = crc32Update(crc, chunk);
        await _raf.writeFrom(chunk);
        size += read;
        _pos += read;
        _check(_pos);
        onBytes?.call(read);
      }
    } finally {
      await input.close();
    }
    final patch = ByteData(12)
      ..setUint32(0, crc, Endian.little)
      ..setUint32(4, size, Endian.little)
      ..setUint32(8, size, Endian.little);
    await _raf.setPosition(offset + 14);
    await _raf.writeFrom(patch.buffer.asUint8List());
    await _raf.setPosition(_pos);
    _entries.add(_Written(n, offset, crc, size, time, date));
  }

  void _check(int pos) {
    if (pos >= _maxU32) throw ZipFormatException('архив больше 4 ГБ — выберите меньше глав');
  }

  Future<void> close() async {
    final cdStart = _pos;
    final out = BytesBuilder(copy: false);
    for (final e in _entries) {
      final b = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 0x0314, Endian.little) // made by: unix, 2.0
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, 0x0800, Endian.little)
        ..setUint16(10, 0, Endian.little)
        ..setUint16(12, e.time, Endian.little)
        ..setUint16(14, e.date, Endian.little)
        ..setUint32(16, e.crc, Endian.little)
        ..setUint32(20, e.size, Endian.little)
        ..setUint32(24, e.size, Endian.little)
        ..setUint16(28, e.name.length, Endian.little)
        ..setUint32(38, 0x81A40000, Endian.little) // -rw-r--r--
        ..setUint32(42, e.offset, Endian.little);
      out
        ..add(b.buffer.asUint8List())
        ..add(e.name);
    }
    final cd = out.takeBytes();
    final end = ByteData(22)
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, _entries.length, Endian.little)
      ..setUint16(10, _entries.length, Endian.little)
      ..setUint32(12, cd.length, Endian.little)
      ..setUint32(16, cdStart, Endian.little);
    await _raf.writeFrom(cd);
    await _raf.writeFrom(end.buffer.asUint8List());
    await _raf.close();
  }

  Future<void> abort() async {
    try {
      await _raf.close();
    } catch (_) {}
  }
}

class ZipEntry {
  ZipEntry(this.name, this.method, this.compressedSize, this.size, this.headerOffset);
  final String name;
  final int method, compressedSize, size, headerOffset;
  bool get isDir => name.endsWith('/');
}

/// Random-access reader over the central directory.
class ZipReader {
  ZipReader._(this._raf, this.entries);
  final RandomAccessFile _raf;
  final List<ZipEntry> entries;

  /// Biggest single entry we agree to inflate (zip-bomb guard).
  static const maxEntryBytes = 200 << 20;

  static Future<ZipReader> open(String path) async {
    final raf = await File(path).open();
    try {
      final len = await raf.length();
      if (len < 22) throw ZipFormatException('файл слишком маленький');
      final tail = len < 65557 ? len : 65557;
      await raf.setPosition(len - tail);
      final buf = await raf.read(tail);
      var eocd = -1;
      for (var i = buf.length - 22; i >= 0; i--) {
        if (buf[i] == 0x50 && buf[i + 1] == 0x4b && buf[i + 2] == 0x05 && buf[i + 3] == 0x06) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) throw ZipFormatException('это не ZIP/CBZ-архив');
      final e = ByteData.sublistView(buf, eocd);
      final count = e.getUint16(10, Endian.little);
      final cdSize = e.getUint32(12, Endian.little);
      final cdOffset = e.getUint32(16, Endian.little);
      if (cdOffset == _maxU32 || count == 0xFFFF) throw ZipFormatException('архивы ZIP64 не поддерживаются');
      await raf.setPosition(cdOffset);
      final cd = await raf.read(cdSize);
      final d = ByteData.sublistView(cd);
      final entries = <ZipEntry>[];
      var p = 0;
      for (var i = 0; i < count; i++) {
        if (p + 46 > cd.length || d.getUint32(p, Endian.little) != 0x02014b50) {
          throw ZipFormatException('повреждённый каталог архива');
        }
        final flags = d.getUint16(p + 8, Endian.little);
        final method = d.getUint16(p + 10, Endian.little);
        final csize = d.getUint32(p + 20, Endian.little);
        final usize = d.getUint32(p + 24, Endian.little);
        final nlen = d.getUint16(p + 28, Endian.little);
        final xlen = d.getUint16(p + 30, Endian.little);
        final clen = d.getUint16(p + 32, Endian.little);
        final off = d.getUint32(p + 42, Endian.little);
        final rawName = cd.sublist(p + 46, p + 46 + nlen);
        final name = (flags & 0x0800) != 0 ? utf8.decode(rawName, allowMalformed: true) : latin1.decode(rawName);
        if ((flags & 1) != 0) throw ZipFormatException('архивы с паролем не поддерживаются');
        entries.add(ZipEntry(name.replaceAll('\\', '/'), method, csize, usize, off));
        p += 46 + nlen + xlen + clen;
      }
      return ZipReader._(raf, entries);
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  ZipEntry? find(String name) {
    for (final e in entries) {
      if (e.name == name) return e;
    }
    return null;
  }

  Future<Uint8List> read(ZipEntry e) async {
    if (e.size > maxEntryBytes || e.compressedSize > maxEntryBytes) {
      throw ZipFormatException('слишком большой файл в архиве: ${e.name}');
    }
    await _raf.setPosition(e.headerOffset);
    final h = ByteData.sublistView(await _raf.read(30));
    if (h.lengthInBytes < 30 || h.getUint32(0, Endian.little) != 0x04034b50) {
      throw ZipFormatException('повреждённая запись ${e.name}');
    }
    final skip = h.getUint16(26, Endian.little) + h.getUint16(28, Endian.little);
    await _raf.setPosition(e.headerOffset + 30 + skip);
    final data = await _raf.read(e.compressedSize);
    return switch (e.method) {
      0 => data,
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(data)),
      _ => throw ZipFormatException('неподдерживаемое сжатие (${e.method}) в ${e.name}'),
    };
  }

  Future<void> close() => _raf.close();
}
