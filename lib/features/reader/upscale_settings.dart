import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/settings.dart';
import '../../widgets/states.dart';

/// Mode + model pickers for on-device AI upscaling (used in Settings and in the reader sheet).
class UpscaleSettingsPanel extends ConsumerWidget {
  const UpscaleSettingsPanel({super.key, this.onEnhanceChapter, this.showCache = false});

  /// Reader only: queue every page of the open chapter.
  final VoidCallback? onEnhanceChapter;
  final bool showCache;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final on = s.upscaleMode != UpscaleMode.off;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'Нейросеть waifu2x увеличивает страницы в 2 раза прямо на телефоне, без интернета: '
          'чётче текст в облачках, линии и растр, меньше JPEG-мусора.',
          style: context.text.bodySmall,
        ),
        const SizedBox(height: MfSpace.md),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<UpscaleMode>(
            showSelectedIcon: false,
            segments: [for (final m in UpscaleMode.values) ButtonSegment(value: m, label: Text(m.label))],
            selected: {s.upscaleMode},
            onSelectionChanged: (v) => ctrl.update((x) => x.copyWith(upscaleMode: v.first)),
          ),
        ),
        const SizedBox(height: MfSpace.xs),
        Text(
          switch (s.upscaleMode) {
            UpscaleMode.off => 'Страницы показываются как есть.',
            UpscaleMode.auto => 'Только страницы уже экрана — там улучшение заметно сильнее всего.',
            UpscaleMode.always => 'Все страницы шириной до 1800 px. Дольше и больше расход батареи.',
          },
          style: MfType.caption.copyWith(color: context.textTertiary),
        ),
        if (on) ...[
          const SizedBox(height: MfSpace.lg),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<UpscaleQuality>(
              showSelectedIcon: false,
              segments: [
                for (final q in UpscaleQuality.values)
                  ButtonSegment(value: q, label: Text(q.label)),
              ],
              selected: {s.upscaleQuality},
              onSelectionChanged: (v) => ctrl.update((x) => x.copyWith(upscaleQuality: v.first)),
            ),
          ),
          const SizedBox(height: MfSpace.xs),
          Text(
            switch (s.upscaleQuality) {
              UpscaleQuality.fast => '${UpscaleQuality.fast.model}: самый быстрый, почти как «Баланс» по качеству.',
              UpscaleQuality.balanced => '${UpscaleQuality.balanced.model}: чище линии и текст, примерно в 2,5 раза медленнее.',
              UpscaleQuality.max => '${UpscaleQuality.max.model}: лучший результат для текста и скринтона, самый медленный.',
            },
            style: MfType.caption.copyWith(color: context.textTertiary),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Улучшать скачанные главы в фоне'),
            subtitle: const Text('После загрузки служба сама улучшит страницы — можно оставить на ночь на зарядке'),
            value: s.upscaleDownloads,
            onChanged: (v) => ctrl.update((x) => x.copyWith(upscaleDownloads: v)),
          ),
          if (onEnhanceChapter != null) ...[
            const SizedBox(height: MfSpace.md),
            OutlinedButton.icon(
              onPressed: () {
                onEnhanceChapter!();
                showSnack(context, 'Улучшаю всю главу в фоне, пока открыта читалка');
              },
              icon: const Icon(Icons.auto_fix_high_rounded),
              label: const Text('Улучшить всю главу заранее'),
            ),
          ],
          if (showCache) const _CacheRow(),
        ],
      ]),
    );
  }
}

class _CacheRow extends ConsumerStatefulWidget {
  const _CacheRow();

  @override
  ConsumerState<_CacheRow> createState() => _CacheRowState();
}

class _CacheRowState extends ConsumerState<_CacheRow> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await ref.read(pageUpscalerProvider).cacheBytes();
      if (mounted) setState(() => _bytes = b);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final up = ref.read(pageUpscalerProvider);
    final avg = up.processed == 0 ? null : (up.totalMs / up.processed / 1000);
    return Padding(
      padding: const EdgeInsets.only(top: MfSpace.md),
      child: Row(children: [
        Expanded(
          child: Text(
            [
              'Кэш: ${_bytes == null ? '…' : '${(_bytes! / 1048576).toStringAsFixed(0)} МБ'}',
              if (avg != null) 'в среднем ${avg.toStringAsFixed(1)} с на страницу',
            ].join(' · '),
            style: context.text.bodySmall,
          ),
        ),
        TextButton(
          onPressed: () async {
            await up.clearCache();
            await _load();
          },
          child: const Text('Очистить'),
        ),
      ]),
    );
  }
}
