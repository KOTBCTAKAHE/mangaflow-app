import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/services/cross_source.dart';
import '../../widgets/manga_widgets.dart';
import 'title_providers.dart';

/// Search other sources for the open title (started on demand: it costs a few requests).
final otherSourcesRequestedProvider = StateProvider.autoDispose.family<bool, TitleKey>((_, __) => false);

final otherSourcesProvider = FutureProvider.autoDispose.family<List<SourceMatch>, TitleKey>((ref, k) async {
  final data = await ref.watch(titleProvider(k).future);
  final progress = await ref.read(titleProgressProvider(k).future); // read: don't re-search on every progress save
  double? lastRead;
  for (final c in data.chapters) {
    if ((progress[c.id]?.completed ?? false) && c.number != null && (lastRead == null || c.number! > lastRead)) {
      lastRead = c.number;
    }
  }
  return findInOtherSources(ref.read(catalogRepositoryProvider), data.manga, lastRead: lastRead);
});

String _num(double? n) => n == null ? '?' : (n % 1 == 0 ? n.toInt().toString() : n.toString());

/// "Есть в других источниках": chapter counts + "continue from chapter N there".
class OtherSourcesPanel extends ConsumerWidget {
  const OtherSourcesPanel({super.key, required this.k, required this.currentMax, this.dense = false});
  final TitleKey k;
  final double? currentMax;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requested = ref.watch(otherSourcesRequestedProvider(k));
    final pad = EdgeInsets.fromLTRB(dense ? 0 : MfSpace.gutter, MfSpace.lg, dense ? 0 : MfSpace.gutter, 0);
    if (!requested) {
      return Padding(
        padding: pad,
        child: OutlinedButton.icon(
          onPressed: () => ref.read(otherSourcesRequestedProvider(k).notifier).state = true,
          icon: const Icon(Icons.travel_explore_rounded),
          label: const Text('Найти в других источниках'),
        ),
      );
    }
    final res = ref.watch(otherSourcesProvider(k));
    return Padding(
      padding: pad,
      child: Container(
        padding: const EdgeInsets.all(MfSpace.md),
        decoration: BoxDecoration(color: context.colors.surfaceContainer, borderRadius: BorderRadius.circular(MfRadius.lg)),
        child: res.when(
          loading: () => const Row(children: [
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: MfSpace.md),
            Expanded(child: Text('Ищу этот тайтл в других источниках…')),
          ]),
          error: (e, _) => Text('Не получилось поискать: $e', style: context.text.bodySmall),
          data: (list) => list.isEmpty
              ? Text('В других источниках этот тайтл не нашёлся', style: context.text.bodyMedium)
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Есть в других источниках', style: MfType.titleSmall.copyWith(color: context.colors.onSurface)),
                  const SizedBox(height: MfSpace.sm),
                  for (final m in list) _MatchRow(match: m, currentMax: currentMax),
                ]),
        ),
      ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({required this.match, required this.currentMax});
  final SourceMatch match;
  final double? currentMax;

  @override
  Widget build(BuildContext context) {
    final c = match.card;
    final more = currentMax != null && match.maxNumber != null && match.maxNumber! > currentMax!;
    return InkWell(
      borderRadius: BorderRadius.circular(MfRadius.md),
      onTap: () => context.push(Routes.title(c.sourceId, c.id)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MfSpace.xs),
        child: Row(children: [
          MangaCover(url: c.coverUrl, width: 36, radius: MfRadius.sm, shadow: false),
          const SizedBox(width: MfSpace.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.sourceName ?? c.sourceId, style: MfType.bodyStrong.copyWith(color: context.colors.onSurface)),
              Row(children: [
                Text('${match.chapterCount} гл. · до ${_num(match.maxNumber)}', style: context.text.bodySmall),
                if (more) ...[
                  const SizedBox(width: MfSpace.xs),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: MfColors.accentSoft, borderRadius: BorderRadius.circular(MfRadius.pill)),
                    child: Text('+${_num(match.maxNumber! - currentMax!)}',
                        style: MfType.caption.copyWith(color: MfColors.accent, fontWeight: FontWeight.w800)),
                  ),
                ],
              ]),
            ]),
          ),
          if (match.continueFrom != null)
            FilledButton.tonal(
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => context.push(Routes.reader(c.sourceId, c.id, match.continueFrom!.id)),
              child: Text('С гл. ${_num(match.continueFrom!.number)}'),
            ),
        ]),
      ),
    );
  }
}

/// Bottom sheet version for the reader ("глав больше нет").
Future<void> showOtherSourcesSheet(BuildContext context, TitleKey k, double? currentMax) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => Consumer(builder: (context, ref, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!ref.read(otherSourcesRequestedProvider(k))) ref.read(otherSourcesRequestedProvider(k).notifier).state = true;
      });
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.lg),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Продолжение в других источниках', style: MfType.title.copyWith(color: context.colors.onSurface)),
            OtherSourcesPanel(k: k, currentMax: currentMax, dense: true),
          ]),
        ),
      );
    }),
  );
}
