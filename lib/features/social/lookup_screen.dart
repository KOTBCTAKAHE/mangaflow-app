import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
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

  @override
  void initState() {
    super.initState();
    final p = widget.path;
    if (p != null && p.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async => _run(await File(p).readAsBytes()));
    }
  }

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final f = r?.files.single;
    final bytes = f?.bytes ?? (f?.path != null ? await File(f!.path!).readAsBytes() : null);
    if (bytes != null) await _run(bytes);
  }

  Future<void> _paste() async {
    // Android clipboards rarely carry images to Flutter; offer a hint instead of failing silently.
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted) return;
    showSnack(context, text == null ? 'Сохраните скриншот и выберите его из галереи' : 'В буфере текст, а не картинка');
  }

  Future<void> _run(Uint8List bytes) async {
    if (!ref.read(authProvider.notifier).isSignedIn) {
      setState(() => _error = 'Поиск по картинке работает после входа в аккаунт');
      return;
    }
    setState(() {
      _image = bytes;
      _busy = true;
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
        if (r.matches.isEmpty) _error = 'Ничего похожего не нашлось. Лучше всего работает чистая страница манги без обрезки.';
      });
    } catch (e) {
      if (mounted) setState(() => (_busy, _error) = (false, errorText(e)));
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
      appBar: AppBar(title: const Text('Найти по скриншоту')),
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
          ClipRRect(
            borderRadius: BorderRadius.circular(MfRadius.md),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: Image.memory(_image!, fit: BoxFit.contain, cacheWidth: 800),
            ),
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
          Text('Ищу среди миллионов страниц…', textAlign: TextAlign.center, style: context.text.bodySmall),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: MfSpace.lg), child: Text(_error!, textAlign: TextAlign.center)),
        if (best != null) ...[
          const SizedBox(height: MfSpace.lg),
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_awesome_rounded),
              title: Text(best.title, style: context.text.titleMedium),
              subtitle: Text([
                if (best.part.isNotEmpty) best.part,
                'совпадение ${best.similarity.round()}%',
              ].join(' · ')),
            ),
          ),
          if (_results.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: MfSpace.sm),
              child: Text('Читать в источниках', style: context.text.titleSmall),
            ),
            for (final m in _results.take(8))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(width: 36, child: MangaCover(url: m.coverUrl, width: 36, radius: MfRadius.sm, shadow: false)),
                title: Text(m.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([m.sourceName ?? m.sourceId, ...m.alsoIn.map((a) => a.sourceName ?? a.sourceId)].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push(Routes.title(m.sourceId, m.id)),
              ),
          ] else
            OutlinedButton.icon(
              onPressed: () => _searchTitle(best.title),
              icon: const Icon(Icons.search_rounded),
              label: const Text('Искать по названию'),
            ),
          if (_matches.length > 1) ...[
            Padding(
              padding: const EdgeInsets.only(top: MfSpace.lg, bottom: MfSpace.xs),
              child: Text('Другие варианты', style: context.text.titleSmall),
            ),
            for (final m in _matches.skip(1))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(m.title),
                subtitle: Text('${m.part.isEmpty ? '' : '${m.part} · '}${m.similarity.round()}%'),
                onTap: () => _searchTitle(m.title),
              ),
          ],
        ],
      ]),
    );
  }
}
