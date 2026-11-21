import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../data/models/settings.dart';
import 'reader_controller.dart';
import 'upscale_settings.dart';
import '../../widgets/beta_badge.dart';
import '../../widgets/setting_previews.dart';

Future<void> showReaderSettings(BuildContext context, ReaderController c) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
            child: GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: MfSpace.sm,
              crossAxisSpacing: MfSpace.sm,
              childAspectRatio: 0.62,
              children: [
                for (final m in ReadingMode.values)
                  _ModeCard(mode: m, selected: c.mode == m, onTap: () => c.setMode(m)),
              ],
            ),
          ),
          _h(context, 'Улучшение качества (ИИ)'),
          UpscaleSettingsPanel(
            onEnhanceChapter: c.current == null ? null : () => c.upscaler?.enqueueAll(c.current!.pages),
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
          _h(context, 'Тёплый свет (для чтения ночью)'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MfSpace.lg),
            child: Row(children: [
              const Icon(Icons.wb_sunny_outlined),
              Expanded(
                child: Slider(
                  value: s.readerWarmth.clamp(0.0, 1.0),
                  onChanged: (v) => ctrl.updateLocalOnly((x) => x.copyWith(readerWarmth: v)),
                ),
              ),
              const Icon(Icons.nightlight_round, color: Color(0xFFFFB366)),
            ]),
          ),
          if (!c.mode.isPaged) ...[
            _h(context, 'Скорость автопрокрутки'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MfSpace.lg),
              child: Row(children: [
                const Icon(Icons.directions_walk_rounded),
                Expanded(
                  child: Slider(
                    value: s.autoScrollSpeed.clamp(30.0, 600.0),
                    min: 30,
                    max: 600,
                    onChanged: (v) => ctrl.updateLocalOnly((x) => x.copyWith(autoScrollSpeed: v)),
                    onChangeEnd: (v) => ctrl.update((x) => x.copyWith(autoScrollSpeed: v)),
                  ),
                ),
                const Icon(Icons.directions_run_rounded),
              ]),
            ),
          ],
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
          PreviewSwitchTile(
            preview: SettingPreview(kind: PreviewKind.crop, enabled: s.autoCrop, width: 44, height: 70),
            title: const Text('Обрезать белые поля'),
            subtitle: const Text('В режиме страниц: картинка крупнее, номер страницы и пустые края не занимают экран'),
            value: s.autoCrop,
            onChanged: (v) => ctrl.update((x) => x.copyWith(autoCrop: v)),
          ),
          _h(context, 'По кадрам'),
          PreviewSwitchTile(
            preview: SettingPreview(kind: PreviewKind.panels, enabled: s.panelMode, width: 44, height: 70),
            title: const BetaTitle('Читать по кадрам'),
            subtitle: const Text('В режиме страниц: тап по краю или свайп — следующий кадр, двойной тап — вся страница'),
            value: s.panelMode,
            onChanged: (v) => ctrl.update((x) => x.copyWith(panelMode: v)),
          ),
          if (s.panelMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.sm),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Порядок кадров · «Авто»: манга справа налево, манхва и комиксы слева направо',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: MfSpace.xs),
                Wrap(spacing: MfSpace.sm, children: [
                  for (final o in PanelOrder.values)
                    ChoiceChip(
                      label: Text(o.label),
                      selected: s.panelOrder == o,
                      showCheckmark: false,
                      onSelected: (_) => ctrl.update((x) => x.copyWith(panelOrder: o)),
                    ),
                ]),
              ]),
            ),
          _h(context, 'Поведение'),
          PreviewSwitchTile(
            preview: SettingPreview(kind: PreviewKind.tapZones, enabled: s.tapZones, width: 44, height: 70),
            title: const Text('Зоны касания для листания'),
            subtitle: const Text('Края экрана листают, центр — меню'),
            value: s.tapZones,
            onChanged: (v) => ctrl.update((x) => x.copyWith(tapZones: v)),
          ),
          SwitchListTile(
            title: const Text('Листать кнопками громкости'),
            subtitle: Text(s.volumeKeysInverted ? 'Громкость + — следующая страница' : 'Громкость − — следующая страница'),
            value: s.volumeKeys,
            onChanged: (v) => ctrl.update((x) => x.copyWith(volumeKeys: v)),
          ),
          if (s.volumeKeys)
            SwitchListTile(
              title: const Text('Поменять кнопки местами'),
              value: s.volumeKeysInverted,
              onChanged: (v) => ctrl.update((x) => x.copyWith(volumeKeysInverted: v)),
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

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.mode, required this.selected, required this.onTap});
  final ReadingMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = modeShortLabel(mode);
    return Material(
      color: selected ? MfColors.accentSoft : context.colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(MfRadius.md),
        side: BorderSide(color: selected ? MfColors.accent : Colors.transparent, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          // the mode as it reads: a strip scrolling, pages turning, a spread
          SettingPreview(
            kind: PreviewKind.mode,
            mode: mode,
            width: mode == ReadingMode.doublePage ? 58 : 40,
            height: 64,
          ),
          const SizedBox(height: MfSpace.xs),
          Text(label, textAlign: TextAlign.center, maxLines: 2,
              style: MfType.caption.copyWith(color: selected ? MfColors.accent : context.colors.onSurface)),
        ]),
      ),
    );
  }
}
