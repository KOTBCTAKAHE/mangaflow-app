import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../data/models/settings.dart';
import 'reader_controller.dart';

Future<void> showReaderSettings(BuildContext context, ReaderController c) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ReaderSettings(c: c),
    );

class _ReaderSettings extends ConsumerWidget {
  const _ReaderSettings({required this.c});
  final ReaderController c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(controller: scroll, children: [
          _h(context, 'Режим для этого тайтла'),
          for (final m in ReadingMode.values)
            RadioListTile<ReadingMode>(
              value: m,
              groupValue: c.mode,
              title: Text(m.label),
              onChanged: (v) => v == null ? null : c.setMode(v),
            ),
          _h(context, 'Яркость'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MfSpace.lg),
            child: Row(children: [
              const Icon(Icons.brightness_low_rounded),
              Expanded(
                child: Slider(
                  value: s.readerBrightness,
                  min: 0.15,
                  max: 1,
                  onChanged: (v) => ctrl.updateLocalOnly((x) => x.copyWith(readerBrightness: v)),
                ),
              ),
              const Icon(Icons.brightness_high_rounded),
            ]),
          ),
          _h(context, 'Фон'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
            child: Wrap(spacing: MfSpace.sm, children: [
              for (final b in ReaderBackground.values)
                ChoiceChip(
                  label: Text(b.label),
                  selected: s.readerBackground == b,
                  showCheckmark: false,
                  onSelected: (_) => ctrl.update((x) => x.copyWith(readerBackground: b)),
                ),
            ]),
          ),
          _h(context, 'Поведение'),
          SwitchListTile(
            title: const Text('Зоны касания для листания'),
            subtitle: const Text('Края экрана листают, центр — меню'),
            value: s.tapZones,
            onChanged: (v) => ctrl.update((x) => x.copyWith(tapZones: v)),
          ),
          SwitchListTile(
            title: const Text('Автопереход к следующей главе'),
            value: s.autoNextChapter,
            onChanged: (v) => ctrl.update((x) => x.copyWith(autoNextChapter: v)),
          ),
          SwitchListTile(
            title: const Text('Не выключать экран'),
            value: s.keepScreenOn,
            onChanged: (v) {
              ctrl.update((x) => x.copyWith(keepScreenOn: v));
              v ? WakelockPlus.enable() : WakelockPlus.disable();
            },
          ),
          ListTile(
            title: const Text('Предзагрузка страниц'),
            subtitle: Text('${s.preloadPages} вперёд'),
            trailing: SizedBox(
              width: 180,
              child: Slider(
                value: s.preloadPages.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                onChanged: (v) => ctrl.update((x) => x.copyWith(preloadPages: v.round())),
              ),
            ),
          ),
          ListTile(
            title: const Text('Качество изображений'),
            subtitle: Text(s.imageQuality.label),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              final q = await showDialog<ImageQuality>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('Качество изображений'),
                  children: [
                    for (final q in ImageQuality.values)
                      RadioListTile<ImageQuality>(
                        value: q,
                        groupValue: s.imageQuality,
                        title: Text(q.label),
                        onChanged: (v) => Navigator.pop(context, v),
                      ),
                  ],
                ),
              );
              if (q != null) await ctrl.update((x) => x.copyWith(imageQuality: q));
            },
          ),
          const SizedBox(height: MfSpace.xxl),
        ]),
      ),
    );
  }

  Widget _h(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.xl, MfSpace.gutter, MfSpace.sm),
        child: Text(t.toUpperCase(), style: context.text.labelSmall),
      );
}
