import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../widgets/states.dart';
import '../home/home_screen.dart' show sourcesProvider;

final _allSourcesProvider = FutureProvider.autoDispose<List<SourceInfo>>(
    (ref) => ref.watch(catalogRepositoryProvider).sources(refresh: true));

final _healthProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
    (ref, id) => ref.watch(catalogApiProvider).health(id));

class SourcesScreen extends ConsumerWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(_allSourcesProvider);
    final s = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Источники')),
      body: AsyncBody(
        value: sources,
        onRetry: () => ref.invalidate(_allSourcesProvider),
        data: (list) => ListView(padding: const EdgeInsets.only(bottom: MfSpace.huge), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.sm, MfSpace.gutter, MfSpace.md),
            child: Text(
              'Источники работают через ваш сервер. Многие сайты ограничивают доступ не из России — '
              'состояние каждого видно ниже. Русские источники перенесены из redcatpet/mangayomi-ru-sources (Apache-2.0).',
              style: context.text.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.sm),
            child: Wrap(spacing: MfSpace.sm, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Языки каталогов:', style: context.text.bodyMedium),
              for (final (code, label) in const [('ru', 'Русский'), ('en', 'English')])
                FilterChip(
                  label: Text(label),
                  selected: s.sourceLanguages.contains(code),
                  onSelected: (v) async {
                    final next = {...s.sourceLanguages};
                    v ? next.add(code) : next.remove(code);
                    if (next.isEmpty) return; // keep at least one language
                    await ref.read(settingsProvider.notifier).update((x) => x.copyWith(sourceLanguages: next.toList()));
                    ref.invalidate(sourcesProvider);
                  },
                ),
            ]),
          ),
          for (final src in list)
            if ((!src.isNsfw || s.showNsfw) && s.sourceLanguages.contains(src.lang))
              _SourceTile(
                source: src,
                enabled: !s.disabledSources.contains(src.id),
                onToggle: (v) async {
                  final next = {...s.disabledSources};
                  v ? next.remove(src.id) : next.add(src.id);
                  await ref.read(settingsProvider.notifier).update((x) => x.copyWith(disabledSources: next.toList()));
                  ref.invalidate(sourcesProvider);
                },
              ),
        ]),
      ),
    );
  }
}

class _SourceTile extends ConsumerWidget {
  const _SourceTile({required this.source, required this.enabled, required this.onToggle});
  final SourceInfo source;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(_healthProvider(source.id));
    final (color, label) = health.when(
      loading: () => (context.textTertiary, 'проверка…'),
      error: (e, _) => (MfColors.danger, errorText(e)),
      data: (h) => h['ok'] == true
          ? (MfColors.success, 'работает · ${h['latency_ms']} мс')
          : (MfColors.warning, (h['error'] as String?) ?? 'недоступен'),
    );
    return ListTile(
      leading: Icon(Icons.circle, size: 12, color: color),
      title: Row(children: [
        Flexible(child: Text(source.name)),
        if (source.isNsfw) ...[const SizedBox(width: MfSpace.sm), const Tag('18+')],
        if (source.langBadge != null) ...[const SizedBox(width: MfSpace.sm), Tag(source.langBadge!)],
      ]),
      subtitle: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => context.push(Routes.source(source.id)),
      onLongPress: () => ref.invalidate(_healthProvider(source.id)),
      trailing: Switch(value: enabled, onChanged: onToggle),
    );
  }
}
