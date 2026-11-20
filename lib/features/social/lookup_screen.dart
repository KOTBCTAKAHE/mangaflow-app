import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../data/remote/social_api.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';
import '../discover/search_controller.dart';
import '../../widgets/beta_badge.dart';

/// Shrinks a screenshot to ≤1200px JPEG-ish PNG before upload (faster, enough for matching).
Future<(Uint8List, String)> _prepare(Uint8List bytes) async {
  if (bytes.length < 900 * 1024) return (bytes, _sniff(bytes));
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1200);
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (png != null && png.lengthInBytes < bytes.length) return (png.buffer.asUint8List(), 'image/png');
  } catch (_) {}
  return (bytes, _sniff(bytes));
}

String _sniff(Uint8List b) {
  if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
  if (b.length > 11 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) return 'image/webp';
  return 'image/jpeg';
}

/// Cuts the normalized [area] (0..1) out of [bytes] → PNG, longest side ≤1600px.
Future<Uint8List> cropImage(Uint8List bytes, Rect area) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final img = (await codec.getNextFrame()).image;
  final src = Rect.fromLTRB(area.left * img.width, area.top * img.height, area.right * img.width, area.bottom * img.height);
  final scale = (1600 / src.longestSide).clamp(0.0, 1.0);
  final w = (src.width * scale).round().clamp(1, 1600), h = (src.height * scale).round().clamp(1, 1600);
  final rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(img, src, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..filterQuality = FilterQuality.high);
  final out = await rec.endRecording().toImage(w, h);
  final png = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  out.dispose();
  return png!.buffer.asUint8List();
}

/// «Найти по скриншоту»: a page, panel or a TikTok frame → title (+ chapter).
class LookupScreen extends ConsumerStatefulWidget {
  const LookupScreen({super.key, this.path});
  final String? path;

  @override
  ConsumerState<LookupScreen> createState() => _LookupScreenState();
}

class _LookupScreenState extends ConsumerState<LookupScreen> {
  Uint8List? _image;
  bool _busy = false;
  String? _error;
  List<LookupMatch> _matches = const [];
  List<MangaCard> _results = const [];
  List<LookupEngine> _engines = const [];

  /// Selected area (normalized) — TikTok UI, captions and borders spoil matching.
  Rect? _crop;
  Size? _imageSize;
  Uint8List? _original;

  @override
  void initState() {
    super.initState();
    final p = widget.path;
    if (p != null && p.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async => _load(await File(p).readAsBytes()));
    }
  }

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final f = r?.files.single;
    final bytes = f?.bytes ?? (f?.path != null ? await File(f!.path!).readAsBytes() : null);
    if (bytes != null) await _load(bytes);
  }

  Future<void> _load(Uint8List bytes) async {
    _original = bytes;
    _crop = null;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final f = await codec.getNextFrame();
      _imageSize = Size(f.image.width.toDouble(), f.image.height.toDouble());
      f.image.dispose();
    } catch (_) {
      _imageSize = null;
    }
    await _run(bytes);
  }

  Future<void> _searchCrop() async {
    final o = _original, c = _crop;
    if (o == null || c == null || c.width < 0.05 || c.height < 0.05) return;
    try {
      await _run(await cropImage(o, c), keepPreview: true);
    } catch (e) {
      if (mounted) showSnack(context, 'Не удалось вырезать: $e');
    }
  }

  Future<void> _paste() async {
    // Android clipboards rarely carry images to Flutter; offer a hint instead of failing silently.
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted) return;
    showSnack(context, text == null ? 'Сохраните скриншот и выберите его из галереи' : 'В буфере текст, а не картинка');
  }

  Future<void> _run(Uint8List bytes, {bool keepPreview = false}) async {
    if (!ref.read(authProvider.notifier).isSignedIn) {
      setState(() => _error = 'Поиск по картинке работает после входа в аккаунт');
      return;
    }
    setState(() {
      if (!keepPreview) _image = bytes;
      _busy = true;
      _engines = const [];
      _error = null;
      _matches = const [];
      _results = const [];
    });
    try {
      final (data, type) = await _prepare(bytes);
      final r = await ref.read(socialApiProvider).lookupImage(data, contentType: type);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _matches = r.matches;
        _results = r.results;
        _engines = r.engines;
        if (r.matches.isEmpty) {
          _error = _crop == null
              ? 'Ничего не нашлось. Выделите пальцем только рисунок (без подписей и интерфейса ТикТока) и нажмите «Искать в выделенном».'
              : 'В выделенном тоже ничего. Попробуйте другой кадр или страницу целиком без надписей.';
        }
      });
    } catch (e) {
      if (mounted) setState(() {
          _busy = false;
          _error = errorText(e);
        });
    }
  }

  void _searchTitle(String t) {
    ref.read(searchControllerProvider.notifier)
      ..setQuery(t)
      ..submit();
    context.go('/discover');
  }

  @override
  Widget build(BuildContext context) {
    final best = _matches.isEmpty ? null : _matches.first;
    return Scaffold(
      appBar: AppBar(title: const BetaTitle('Найти по скриншоту')),
      body: ListView(padding: const EdgeInsets.all(MfSpace.gutter), children: [
        if (_image == null) ...[
          const SizedBox(height: MfSpace.xl),
          Icon(Icons.image_search_rounded, size: 72, color: context.colors.primary),
          const SizedBox(height: MfSpace.md),
          Text('Пришлите страницу или кадр', textAlign: TextAlign.center, style: context.text.titleLarge),
          const SizedBox(height: MfSpace.sm),
          Text('Скриншот из ТикТока, страница из чата, панель — найдём тайтл и, если повезёт, главу. '
              'Можно также «Поделиться» картинкой из галереи в MangaFlow.',
              textAlign: TextAlign.center, style: context.text.bodyMedium),
          const SizedBox(height: MfSpace.xl),
        ] else
          _CropPreview(
            image: _image!,
            size: _imageSize,
            crop: _crop,
            enabled: !_busy,
            onChanged: (r) => setState(() => _crop = r),
          ),
        if (_image != null && _imageSize != null)
          Padding(
            padding: const EdgeInsets.only(top: MfSpace.xs),
            child: Row(children: [
              Expanded(
                child: Text(_crop == null ? 'Проведите пальцем по картинке, чтобы выделить только рисунок' : 'Выделено',
                    style: context.text.bodySmall),
              ),
              if (_crop != null) ...[
                TextButton(onPressed: _busy ? null : () => setState(() => _crop = null), child: const Text('Сбросить')),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _searchCrop,
                  icon: const Icon(Icons.crop_rounded),
                  label: const Text('Искать в выделенном'),
                ),
              ],
            ]),
          ),
        const SizedBox(height: MfSpace.md),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _busy ? null : _pick,
              icon: const Icon(Icons.photo_library_rounded),
              label: Text(_image == null ? 'Выбрать из галереи' : 'Другая картинка'),
            ),
          ),
          if (_image == null) ...[
            const SizedBox(width: MfSpace.sm),
            IconButton.outlined(onPressed: _paste, icon: const Icon(Icons.content_paste_rounded)),
          ],
        ]),
        if (_busy) ...[
          const SizedBox(height: MfSpace.xl),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: MfSpace.sm),
          Text('Ищу в нашем индексе страниц, SauceNAO и trace.moe…', textAlign: TextAlign.center, style: context.text.bodySmall),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: MfSpace.lg), child: Text(_error!, textAlign: TextAlign.center)),
        if (_engines.isNotEmpty && (best == null || _engines.any((e) => e.status == 'no_key' || e.status == 'error')))
          Padding(
            padding: const EdgeInsets.only(top: MfSpace.md),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: MfSpace.xs),
                child: Column(children: [
                  for (final e in _engines)
                    ListTile(
                      dense: true,
                      leading: Icon(switch (e.status) {
                        'ok' => Icons.check_circle_rounded,
                        'nothing' => Icons.remove_circle_outline_rounded,
                        'no_key' => Icons.key_off_rounded,
                        _ => Icons.error_outline_rounded,
                      }),
                      title: Text(e.name),
                      subtitle: Text(switch (e.status) {
                        'nothing' => e.detail.contains('индексе') ? 'совпадений нет · ${e.detail.split(', ').last}' : 'совпадений нет',
                        _ => e.detail,
                      }),
                    ),
                ]),
              ),
            ),
          ),
        if (best != null) ...[
          const SizedBox(height: MfSpace.lg),
          if (best.confidence == 'low')
            Padding(
              padding: const EdgeInsets.only(bottom: MfSpace.sm),
              child: Text('Точного совпадения нет — сравните картинки вариантов со своей. '
                  'Выделите только рисунок без надписей, и поиск станет точнее.',
                  style: context.text.bodySmall),
            ),
          for (final (i, m) in _matches.indexed)
            _CandidateCard(
              match: m,
              primary: i == 0,
              // older servers send results only for the best match
              results: m.results.isEmpty && i == 0 ? _results : m.results,
              onSearch: () => _searchTitle(m.searchName),
            ),
        ],
      ]),
    );
  }
}

/// Image preview where a finger drag draws the area to search in.
class _CropPreview extends StatefulWidget {
  const _CropPreview({required this.image, required this.size, required this.crop, required this.enabled, required this.onChanged});
  final Uint8List image;
  final Size? size;
  final Rect? crop;
  final bool enabled;
  final ValueChanged<Rect?> onChanged;

  @override
  State<_CropPreview> createState() => _CropPreviewState();
}

class _CropPreviewState extends State<_CropPreview> {
  Offset? _start;

  @override
  Widget build(BuildContext context) {
    final sz = widget.size, image = widget.image, crop = widget.crop, enabled = widget.enabled;
    return ClipRRect(
      borderRadius: BorderRadius.circular(MfRadius.md),
      child: LayoutBuilder(builder: (context, c) {
        if (sz == null || sz.isEmpty) {
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: Image.memory(image, fit: BoxFit.contain, cacheWidth: 900),
          );
        }
        // fit the image into width × 380 keeping its aspect
        final scale = [c.maxWidth / sz.width, 380 / sz.height].reduce((a, b) => a < b ? a : b);
        final w = sz.width * scale, h = sz.height * scale;
        Offset norm(Offset p) => Offset((p.dx / w).clamp(0.0, 1.0), (p.dy / h).clamp(0.0, 1.0));
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            // the drag must beat the list's scroll: claim the pointer eagerly, read raw positions
            child: RawGestureDetector(
              gestures: {
                if (enabled)
                  EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(EagerGestureRecognizer.new, (_) {}),
              },
              child: Listener(
              onPointerDown: enabled ? (e) => _start = norm(e.localPosition) : null,
              onPointerMove: enabled
                  ? (e) {
                      final s0 = _start;
                      if (s0 != null) widget.onChanged(Rect.fromPoints(s0, norm(e.localPosition)));
                    }
                  : null,
              onPointerUp: (_) => _start = null,
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(image, fit: BoxFit.fill, cacheWidth: 900),
                if (crop != null)
                  CustomPaint(painter: _CropPainter(crop, Theme.of(context).colorScheme.primary)),
              ]),
            ),
            ),
          ),
        );
      }),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.area, this.color);
  final Rect area;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(area.left * size.width, area.top * size.height, area.right * size.width, area.bottom * size.height);
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawRect(r, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.area != area || old.color != color;
}

/// One guess: its picture from the engine (to compare by eye), how sure we are, and where to read it.
class _CandidateCard extends StatelessWidget {
  const _CandidateCard({required this.match, required this.primary, required this.results, required this.onSearch});
  final LookupMatch match;
  final bool primary;
  final List<MangaCard> results;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final m = match;
    final (label, color) = switch (m.confidence) {
      'high' => ('точно', MfColors.success),
      'medium' => ('похоже', context.colors.primary),
      'low' => ('возможно', context.colors.outline),
      _ => ('', context.colors.outline),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: MfSpace.md),
      child: Padding(
        padding: const EdgeInsets.all(MfSpace.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (m.thumbnail.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(MfRadius.sm),
                child: Image.network(m.thumbnail, width: 72, height: 100, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox(width: 72, height: 100)),
              ),
            if (m.thumbnail.isNotEmpty) const SizedBox(width: MfSpace.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (label.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: MfSpace.xs),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(MfRadius.pill),
                    ),
                    child: Text('$label · ${m.similarity.round()}%', style: context.text.labelSmall?.copyWith(color: color)),
                  ),
                Text(m.searchName, style: primary ? context.text.titleMedium : context.text.titleSmall,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                if (m.searchName != m.title)
                  Text(m.title, style: context.text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text([
                  if (m.part.isNotEmpty) m.part,
                  (m.engines.isEmpty ? [m.engine] : m.engines).where((e) => e.isNotEmpty).join(' + '),
                ].where((e) => e.isNotEmpty).join(' · '), style: context.text.bodySmall),
              ]),
            ),
          ]),
          if (m.hasPage) ...[
            const SizedBox(height: MfSpace.sm),
            FilledButton.icon(
              onPressed: () => context.push(Routes.reader(m.sourceId!, m.mangaId!, m.chapterId!, page: m.pageIndex)),
              icon: const Icon(Icons.menu_book_rounded),
              label: Text(m.pageIndex == null ? 'Открыть главу' : 'Открыть на этой странице'),
            ),
          ],
          const SizedBox(height: MfSpace.sm),
          if (results.isNotEmpty)
            for (final r in results.take(primary ? 5 : 3))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(width: 32, child: MangaCover(url: r.coverUrl, width: 32, radius: MfRadius.sm, shadow: false)),
                title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([r.sourceName ?? r.sourceId, ...r.alsoIn.map((a) => a.sourceName ?? a.sourceId)].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push(Routes.title(r.sourceId, r.id)),
              )
          else
            Text('В источниках с таким названием не нашлось', style: context.text.bodySmall),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onSearch,
              icon: const Icon(Icons.search_rounded, size: 18),
              label: Text('Искать «${m.searchName}»', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ]),
      ),
    );
  }
}
