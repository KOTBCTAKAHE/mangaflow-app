import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'chapter_transfer.dart';
import 'zip.dart';

/// «Открыть файл»: turns what the user picked on the phone — CBZ/ZIP, PDF, a bunch of pictures,
/// or several of those — into one CBZ that the regular import reads (one chapter per folder).
abstract final class LocalFiles {
  static const _pdf = MethodChannel('mangaflow/pdf');

  static bool isArchive(String path) => const {'.cbz', '.zip'}.contains(p.extension(path).toLowerCase());
  static bool isPdf(String path) => p.extension(path).toLowerCase() == '.pdf';
  static bool supported(String path) => isArchive(path) || isPdf(path) || isImageName(path);

  /// A single archive is imported as is; everything else is packed first.
  static Future<String> toPack(List<String> paths, {void Function(String status)? onStatus}) async {
    final files = paths.where(supported).toList()..sort((a, b) => naturalCompare(p.basename(a), p.basename(b)));
    if (files.isEmpty) throw const FormatException('Подходят CBZ, ZIP, PDF и картинки');
    if (files.length == 1 && isArchive(files.first)) return files.first;

    final tmp = await Directory(p.join((await getTemporaryDirectory()).path, 'local-open')).create(recursive: true);
    for (final old in tmp.listSync()) {
      if (DateTime.now().difference(old.statSync().modified) > const Duration(days: 1)) {
        try {
          old.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    final images = files.where(isImageName).toList();
    final books = files.where((f) => !isImageName(f)).toList();
    final title = _title(files);
    final out = p.join(tmp.path, '${DateTime.now().millisecondsSinceEpoch}_${_safe(title)}.cbz');
    final zip = await ZipWriter.create(out);
    try {
      // pictures alone: one chapter; next to books: a chapter of their own
      final chapterOf = books.isEmpty ? (String _) => '' : (String name) => '${_safe(name)}/';
      if (images.isNotEmpty) {
        onStatus?.call('Собираю ${images.length} картинок…');
        for (var i = 0; i < images.length; i++) {
          await zip.addFile('${chapterOf('Картинки')}${_n(i)}${p.extension(images[i]).toLowerCase()}', File(images[i]));
        }
      }
      for (var b = 0; b < books.length; b++) {
        final f = books[b];
        final folder = books.length == 1 && images.isEmpty ? '' : '${_safe(p.basenameWithoutExtension(f))}/';
        if (isPdf(f)) {
          onStatus?.call(books.length > 1 ? 'PDF ${b + 1} из ${books.length}: рисую страницы…' : 'Рисую страницы PDF…');
          final dir = await Directory(p.join(tmp.path, 'pdf_${DateTime.now().microsecondsSinceEpoch}')).create();
          try {
            final n = await _pdf.invokeMethod<int>('render', {'path': f, 'out': dir.path, 'width': 1400}) ?? 0;
            if (n == 0) throw const FormatException('в PDF нет страниц');
            for (var i = 0; i < n; i++) {
              await zip.addFile('$folder${_n(i)}.jpg', File(p.join(dir.path, '${_n(i)}.jpg')));
            }
          } on PlatformException catch (e) {
            throw FormatException(e.message?.contains('password') == true || e.message?.contains('ecur') == true
                ? 'PDF защищён паролем'
                : 'Не получилось открыть PDF: ${e.message}');
          } finally {
            try {
              await dir.delete(recursive: true);
            } catch (_) {}
          }
        } else {
          onStatus?.call(books.length > 1 ? 'Архив ${b + 1} из ${books.length}…' : 'Читаю архив…');
          final src = await ZipReader.open(f);
          try {
            final pages = src.entries.where((e) => !e.isDir && isImageName(e.name) && !e.name.contains('__MACOSX')).toList()
              ..sort((a, c) => naturalCompare(a.name, c.name));
            // keep an archive's own chapter folders under the file's folder
            for (var i = 0; i < pages.length; i++) {
              final e = pages[i];
              final sub = p.posix.dirname(e.name);
              final inner = sub == '.' || books.length == 1 ? '' : '${_safe(p.posix.basename(sub))}/';
              final chapterFolder = books.length == 1 && images.isEmpty ? (sub == '.' ? '' : '${_safe(sub)}/') : '$folder$inner';
              await zip.addBytes('$chapterFolder${_n(i)}${p.extension(e.name).toLowerCase()}', await src.read(e));
            }
          } finally {
            await src.close();
          }
        }
      }
      await zip.close();
      return out;
    } catch (_) {
      await zip.abort();
      rethrow;
    }
  }

  static String _n(int i) => (i + 1).toString().padLeft(4, '0');

  static String _safe(String s) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    return t.isEmpty ? 'file' : (t.length > 80 ? t.substring(0, 80) : t);
  }

  /// "Berserk vol 01.cbz" + "Berserk vol 02.cbz" → "Berserk".
  static String _title(List<String> files) {
    final names = [for (final f in files) p.basenameWithoutExtension(f).replaceFirst(RegExp(r'^\d+_'), '')];
    if (names.length == 1) return names.first;
    var prefix = names.first;
    for (final n in names.skip(1)) {
      var i = 0;
      while (i < prefix.length && i < n.length && prefix[i] == n[i]) {
        i++;
      }
      prefix = prefix.substring(0, i);
    }
    prefix = prefix
        .replaceFirst(RegExp(r'[\s._\-–—#(\[]*(?:\b(?:vol|tome|ch|chapter|том|глава)\.?)?[\s._\-–—#]*\d*$', caseSensitive: false), '')
        .trim();
    if (prefix.length >= 3) return prefix;
    return files.every(isImageName) ? 'Картинки' : names.first;
  }
}
