import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/data/models/settings.dart';
import 'package:mangaflow/data/services/upscale_service.dart';

class FakeBackend implements UpscaleBackend {
  final calls = <String>[]; // input paths in processing order
  final cancelled = <String>[];
  int released = 0;
  String status = 'ok';
  Completer<void>? gate;
  bool cancelHonoured = false;

  @override
  Future<UpscaleOutcome> run({
    required String id,
    required String input,
    required String output,
    required UpscaleQuality quality,
    required int maxSourceWidth,
    int maxOutPixels = 24000000,
  }) async {
    calls.add(input.split('/').last);
    if (gate != null) await gate!.future;
    if (cancelled.remove(id) && cancelHonoured) return const UpscaleOutcome('cancelled');
    if (status == 'ok') await File(output).writeAsBytes([1, 2, 3]);
    return UpscaleOutcome(status, ms: 1000);
  }

  @override
  Future<void> cancel(String id) async => cancelled.add(id);

  @override
  Future<void> release() async => released++;
}

void main() {
  late Directory tmp;
  late FakeBackend backend;
  late PageUpscaler up;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('up');
    backend = FakeBackend();
    up = PageUpscaler(
      backend: backend,
      cacheDir: () async => tmp,
      sourceFile: (p) async => File('${tmp.path}/src_${p.index}'),
    )..mode = UpscaleMode.auto;
  });

  tearDown(() async {
    up.dispose();
    await tmp.delete(recursive: true);
  });

  List<PageRef> pages(int n, {String chapter = 'c1'}) =>
      [for (var i = 0; i < n; i++) PageRef(index: i, url: 'https://x/$i?token=day1', key: 'src/$chapter/$i')];

  /// Lets queued work (real file IO) finish; returns early once the upscaler is idle.
  Future<void> idle({Duration max = const Duration(milliseconds: 600)}) async {
    final end = DateTime.now().add(max);
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (up.isIdle) break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  test('current page first, then the next ones, then the previous one', () async {
    up.focus(pages(10), 4, ahead: 3);
    await idle();
    expect(backend.calls, ['src_4', 'src_5', 'src_6', 'src_7', 'src_3']);
    expect(up.watch(pages(10)[5]).value.status, UpscaleStatus.done);
    expect(up.processed, 5);
  });

  test('page change re-prioritises the queue and drops pages that are no longer near', () async {
    backend.gate = Completer();
    final p = pages(30);
    up.focus(p, 0, ahead: 3); // 0 runs, 1-3 queued
    await idle();
    up.focus(p, 20, ahead: 2); // jump far ahead
    expect(up.watch(p[2]).value.status, UpscaleStatus.idle);
    expect(up.watch(p[21]).value.status, UpscaleStatus.queued);
    backend.gate!.complete();
    await idle();
    expect(backend.calls, ['src_0', 'src_20', 'src_21', 'src_22', 'src_19']);
  });

  test('finished pages are reused from disk, and the key survives daily URL re-signing', () async {
    up.focus(pages(2), 0, ahead: 1);
    await idle();
    expect(backend.calls.length, 2);
    final again = PageUpscaler(backend: backend, cacheDir: () async => tmp, sourceFile: (p) async => File('x'))
      ..mode = UpscaleMode.auto;
    final resigned = [for (final p in pages(2)) PageRef(index: p.index, url: 'https://x/${p.index}?token=day2', key: p.key)];
    again.focus(resigned, 0, ahead: 1);
    for (var i = 0; i < 100 && !again.isIdle; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(backend.calls.length, 2, reason: 'no new inference');
    expect(again.watch(resigned[1]).value.isDone, isTrue);
    again.dispose();
  });

  test('quality is part of the key', () {
    final p = pages(1).first;
    final a = up.keyFor(p);
    up.quality = UpscaleQuality.max;
    expect(up.keyFor(p), isNot(a));
  });

  test('skipped and failed outcomes are remembered and not retried on refocus', () async {
    backend.status = 'skipped';
    up.focus(pages(3), 0, ahead: 2);
    await idle();
    up.focus(pages(3), 1, ahead: 1);
    await idle();
    expect(backend.calls.length, 3);
    expect(up.watch(pages(3)[0]).value.status, UpscaleStatus.skipped);
  });

  test('enqueueAll appends the rest of the chapter; stop cancels and releases', () async {
    backend.gate = Completer();
    up.focus(pages(6), 0, ahead: 1);
    await idle();
    up.enqueueAll(pages(6));
    expect([for (final p in pages(6)) up.watch(p).value.status],
        [UpscaleStatus.running, UpscaleStatus.queued, UpscaleStatus.queued, UpscaleStatus.queued, UpscaleStatus.queued, UpscaleStatus.queued]);
    await up.stop();
    expect(backend.cancelled, [up.keyFor(pages(6)[0])]);
    expect(backend.released, 1);
    expect(up.watch(pages(6)[3]).value.status, UpscaleStatus.idle);
    backend.gate!.complete();
    await idle();
    expect(backend.calls, ['src_0']);
  });

  test('off mode does nothing', () async {
    up.mode = UpscaleMode.off;
    up.focus(pages(3), 0);
    await idle();
    expect(backend.calls, isEmpty);
  });

  test('auto mode leaves pages at least as wide as the screen alone; always caps at 1800', () {
    up.targetWidth = 1080;
    expect(up.maxSourceWidth, 1026);
    up.mode = UpscaleMode.always;
    expect(up.maxSourceWidth, 1800);
  });

  test('LRU prune keeps the cache under the limit', () async {
    final small = PageUpscaler(backend: backend, cacheDir: () async => tmp, maxCacheBytes: 1000)..mode = UpscaleMode.auto;
    final dir = Directory('${tmp.path}/upscaled')..createSync();
    for (var i = 0; i < 5; i++) {
      final f = File('${dir.path}/f$i.jpg')..writeAsBytesSync(List.filled(400, 0));
      f.setLastModifiedSync(DateTime(2026, 1, 1, 0, i));
    }
    await small.prune();
    final left = dir.listSync().map((e) => e.path.split('/').last).toList()..sort();
    expect(left, ['f3.jpg', 'f4.jpg']);
    small.dispose();
  });

  test('request(force) jumps the queue and ignores the width limit', () async {
    backend.gate = Completer();
    up.focus(pages(5), 0, ahead: 2);
    await idle(max: const Duration(milliseconds: 50));
    up.request(pages(5)[4], force: true);
    expect(up.watch(pages(5)[4]).value.status, UpscaleStatus.queued);
    backend.gate!.complete();
    await idle();
    expect(backend.calls, ['src_0', 'src_4', 'src_1', 'src_2']);
  });

  test('settings: AI upscaling is on (auto) by default, also for installs that saved the old default', () {
    expect(AppSettings(apiBaseUrl: 'x', updatedAt: DateTime.utc(2026)).upscaleMode, UpscaleMode.auto);
    final old = AppSettings.fromJson({'upscale_mode': 'off'}, fallbackUrl: 'x');
    expect(old.upscaleMode, UpscaleMode.auto);
    final chosen = AppSettings.fromJson(
        AppSettings(apiBaseUrl: 'x', updatedAt: DateTime.utc(2026), upscaleMode: UpscaleMode.off).toJson(),
        fallbackUrl: 'x');
    expect(chosen.upscaleMode, UpscaleMode.off);
  });

  test('turning the page cancels the page being processed and starts the new current one', () async {
    backend
      ..gate = Completer()
      ..cancelHonoured = true;
    final p = pages(10);
    up.focus(p, 4, ahead: 1); // 4 running, 5 queued
    await idle(max: const Duration(milliseconds: 50));
    up.focus(p, 5, ahead: 1); // user flipped: 5 first, then 6, then 4 (previous)
    expect(backend.cancelled, [up.keyFor(p[4])]);
    expect(up.watch(p[4]).value.status, UpscaleStatus.queued);
    backend.gate!.complete();
    await idle();
    expect(backend.calls, ['src_4', 'src_5', 'src_6', 'src_4']);
    expect(up.watch(p[4]).value.isDone, isTrue);
    expect(up.watch(p[5]).value.isDone, isTrue);
  });

  test('refocusing on the page being processed does not cancel it', () async {
    backend.gate = Completer();
    final p = pages(10);
    up.focus(p, 4, ahead: 1);
    await idle(max: const Duration(milliseconds: 50));
    up.focus(p, 4, ahead: 2);
    expect(backend.cancelled, isEmpty);
    backend.gate!.complete();
  });
}
