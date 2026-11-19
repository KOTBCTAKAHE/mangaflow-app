import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/models/manga.dart';
import '../../data/remote/social_api.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';

final friendsProvider = FutureProvider.autoDispose<FriendsData>((ref) => ref.watch(socialApiProvider).friends());
final activityProvider = FutureProvider.autoDispose<List<ActivityItem>>((ref) => ref.watch(socialApiProvider).activity());
final recommendationsProvider =
    FutureProvider.autoDispose<(List<RecommendationItem>, int)>((ref) => ref.watch(socialApiProvider).recommendations());
final trackersProvider = FutureProvider.autoDispose<List<TrackerInfo>>((ref) => ref.watch(socialApiProvider).trackers());

Widget _signInFirst(BuildContext context, String what) => EmptyState(
      icon: Icons.lock_outline_rounded,
      title: 'Нужен аккаунт',
      message: '$what работают через ваш сервер — войдите, чтобы пользоваться ими.',
      action: FilledButton(onPressed: () => context.push('/auth'), child: const Text('Войти')),
    );

class _TitleTile extends StatelessWidget {
  const _TitleTile({required this.t, this.subtitle, this.trailing});
  final TitleRef t;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: SizedBox(width: 36, child: MangaCover(url: t.coverUrl, width: 36, radius: MfRadius.sm, shadow: false)),
        title: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: subtitle == null ? null : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: trailing,
        onTap: () => context.push(Routes.title(t.sourceId, t.mangaId)),
      );
}

String _ago(DateTime? d) => d == null ? '' : formatDateTime(d);

// =================================================================== friends
class FriendsScreen extends ConsumerWidget {
  const FriendsScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Добавить друга'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Ник в MangaFlow', prefixText: '@'),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, ctrl.text), child: const Text('Отправить заявку')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    try {
      final msg = await ref.read(socialApiProvider).addFriend(name.trim());
      if (context.mounted) showSnack(context, msg);
      ref.invalidate(friendsProvider);
    } catch (e) {
      if (context.mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(authProvider.notifier).isSignedIn) {
      return Scaffold(appBar: AppBar(title: const Text('Друзья')), body: _signInFirst(context, 'Друзья'));
    }
    final unseen = ref.watch(recommendationsProvider).valueOrNull?.$2 ?? 0;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Друзья'),
          bottom: TabBar(tabs: [
            const Tab(text: 'Друзья'),
            const Tab(text: 'Лента'),
            Tab(child: Badge(isLabelVisible: unseen > 0, label: Text('$unseen'), child: const Text('Советы'))),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _add(context, ref),
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('Добавить'),
        ),
        body: const TabBarView(children: [_FriendsTab(), _ActivityTab(), _RecsTab()]),
      ),
    );
  }
}

class _FriendsTab extends ConsumerWidget {
  const _FriendsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(socialApiProvider);
    return AsyncBody(
      value: ref.watch(friendsProvider),
      onRetry: () => ref.invalidate(friendsProvider),
      data: (d) {
        if (d.friends.isEmpty && d.incoming.isEmpty && d.outgoing.isEmpty) {
          return const EmptyState(
            icon: Icons.group_add_outlined,
            title: 'Пока никого',
            message: 'Добавьте друга по нику — увидите, что он читает, его оценки и советы.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(friendsProvider),
          child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            if (d.incoming.isNotEmpty) const _Header('Заявки в друзья'),
            for (final r in d.incoming)
              ListTile(
                leading: CircleAvatar(child: Text(r.user.name.characters.first.toUpperCase())),
                title: Text(r.user.name),
                subtitle: Text('@${r.user.username}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Отклонить',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () async {
                      await api.dropRequest(r.id);
                      ref.invalidate(friendsProvider);
                    },
                  ),
                  FilledButton(
                    onPressed: () async {
                      await api.acceptFriend(r.id);
                      ref.invalidate(friendsProvider);
                    },
                    child: const Text('Принять'),
                  ),
                ]),
              ),
            if (d.friends.isNotEmpty) const _Header('Друзья'),
            for (final f in d.friends)
              ListTile(
                leading: CircleAvatar(child: Text(f.user.name.characters.first.toUpperCase())),
                title: Text(f.user.name),
                subtitle: Text(f.reading == null
                    ? '@${f.user.username}'
                    : 'Читает: ${f.reading!.title} · ${f.reading!.chapterTitle ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FriendProfileScreen(user: f.user))),
              ),
            if (d.outgoing.isNotEmpty) const _Header('Ждут ответа'),
            for (final r in d.outgoing)
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.hourglass_top_rounded, size: 18)),
                title: Text(r.user.name),
                trailing: TextButton(
                  onPressed: () async {
                    await api.dropRequest(r.id);
                    ref.invalidate(friendsProvider);
                  },
                  child: const Text('Отменить'),
                ),
              ),
          ]),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, MfSpace.xs),
        child: Text(text, style: context.text.titleSmall?.copyWith(color: context.colors.primary)),
      );
}

class _ActivityTab extends ConsumerWidget {
  const _ActivityTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody(
        value: ref.watch(activityProvider),
        onRetry: () => ref.invalidate(activityProvider),
        data: (items) => items.isEmpty
            ? const EmptyState(icon: Icons.dynamic_feed_outlined, title: 'Лента пуста', message: 'Здесь появится, что читают и как оценивают друзья.')
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(activityProvider),
                child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                  for (final i in items)
                    _TitleTile(
                      t: i.title,
                      subtitle: i.kind == 'rated'
                          ? '${i.user.name} оценил(а): ${'★' * ((i.score ?? 0) / 2).round()} ${i.score}/10 · ${_ago(i.title.at)}'
                          : '${i.user.name} читает · ${i.title.chapterTitle ?? ''} · ${_ago(i.title.at)}',
                    ),
                ]),
              ),
      );
}

class _RecsTab extends ConsumerStatefulWidget {
  const _RecsTab();

  @override
  ConsumerState<_RecsTab> createState() => _RecsTabState();
}

class _RecsTabState extends ConsumerState<_RecsTab> {
  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(seconds: 2), () async {
      try {
        await ref.read(socialApiProvider).recommendationsSeen();
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) => AsyncBody(
        value: ref.watch(recommendationsProvider),
        onRetry: () => ref.invalidate(recommendationsProvider),
        data: (d) => d.$1.isEmpty
            ? const EmptyState(icon: Icons.recommend_outlined, title: 'Советов пока нет', message: 'Друзья могут посоветовать тайтл со страницы тайтла.')
            : ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                for (final r in d.$1)
                  _TitleTile(
                    t: r.title,
                    subtitle: '${r.from?.name ?? 'Друг'} советует${r.message.isEmpty ? '' : ': «${r.message}»'}',
                    trailing: r.seen ? null : Icon(Icons.fiber_new_rounded, color: context.colors.primary),
                  ),
              ]),
      );
}

class FriendProfileScreen extends ConsumerWidget {
  const FriendProfileScreen({super.key, required this.user});
  final PublicUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(_friendProfile(user.id));
    return Scaffold(
      appBar: AppBar(
        title: Text(user.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  title: Text('Удалить ${user.name} из друзей?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Нет')),
                    FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Удалить')),
                  ],
                ),
              );
              if (ok != true) return;
              await ref.read(socialApiProvider).unfriend(user.id);
              ref.invalidate(friendsProvider);
              if (context.mounted) Navigator.of(context).pop();
            },
            itemBuilder: (_) => [const PopupMenuItem(value: 'remove', child: Text('Удалить из друзей'))],
          ),
        ],
      ),
      body: AsyncBody(
        value: p,
        onRetry: () => ref.invalidate(_friendProfile(user.id)),
        data: (fp) => ListView(children: [
          ListTile(
            leading: CircleAvatar(radius: 24, child: Text(user.name.characters.first.toUpperCase())),
            title: Text(user.name, style: context.text.titleLarge),
            subtitle: Text('@${user.username} · ${fp.chapters30d} ${plural(fp.chapters30d, 'глава', 'главы', 'глав')} за месяц'),
          ),
          if (fp.reading.isNotEmpty) const _Header('Читает сейчас'),
          for (final t in fp.reading) _TitleTile(t: t, subtitle: '${t.chapterTitle ?? ''} · ${_ago(t.at)}'),
          if (fp.ratings.isNotEmpty) const _Header('Оценки'),
          for (final r in fp.ratings)
            _TitleTile(
              t: r.title,
              subtitle: r.review.isEmpty ? null : r.review,
              trailing: _ScoreChip(r.score),
            ),
          const SizedBox(height: MfSpace.xxl),
        ]),
      ),
    );
  }
}

final _friendProfile = FutureProvider.autoDispose.family<FriendProfile, String>((ref, id) => ref.watch(socialApiProvider).profile(id));

class _ScoreChip extends StatelessWidget {
  const _ScoreChip(this.score);
  final int score;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: context.colors.primaryContainer, borderRadius: BorderRadius.circular(MfRadius.pill)),
        child: Text('★ $score', style: TextStyle(color: context.colors.onPrimaryContainer, fontWeight: FontWeight.w700)),
      );
}

// ============================================================ title: social
final titleRatingsProvider = FutureProvider.autoDispose.family<TitleRatings, (String, String)>(
    (ref, k) => ref.watch(socialApiProvider).titleRatings(k.$1, k.$2));

/// Title screen block: your score, friends' scores, «Посоветовать», trackers.
class TitleSocialPanel extends ConsumerWidget {
  const TitleSocialPanel({super.key, required this.manga});
  final MangaDetails manga;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(authProvider.notifier).isSignedIn) return const SizedBox.shrink();
    final key = (manga.sourceId, manga.id);
    final r = ref.watch(titleRatingsProvider(key)).valueOrNull;
    final mine = r?.mine?.score;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MfSpace.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Ваша оценка', style: context.text.titleSmall),
          const Spacer(),
          if (r?.average != null)
            Text('★ ${r!.average} · ${r.count} ${plural(r.count, 'оценка', 'оценки', 'оценок')}', style: context.text.bodySmall),
        ]),
        const SizedBox(height: MfSpace.xs),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (var i = 1; i <= 10; i++)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ChoiceChip(
                  label: Text('$i'),
                  selected: mine == i,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) async {
                    try {
                      if (mine == i) {
                        await ref.read(socialApiProvider).unrate(manga.sourceId, manga.id);
                      } else {
                        await ref.read(socialApiProvider).rate(manga, i);
                      }
                      ref.invalidate(titleRatingsProvider(key));
                    } catch (e) {
                      if (context.mounted) showSnack(context, errorText(e));
                    }
                  },
                ),
              ),
          ]),
        ),
        if (r != null && r.friends.isNotEmpty) ...[
          const SizedBox(height: MfSpace.sm),
          Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.xs, children: [
            for (final f in r.friends)
              Tooltip(
                message: f.review,
                child: Chip(
                  avatar: CircleAvatar(child: Text((f.user?.name ?? '?').characters.first.toUpperCase())),
                  label: Text('${f.user?.name ?? 'Друг'} · ${f.score}/10'),
                ),
              ),
          ]),
        ],
        const SizedBox(height: MfSpace.sm),
        Wrap(spacing: MfSpace.sm, children: [
          OutlinedButton.icon(
            onPressed: () => recommendSheet(context, ref, manga),
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('Посоветовать другу'),
          ),
          OutlinedButton.icon(
            onPressed: () => trackersSheet(context, ref, manga),
            icon: const Icon(Icons.sync_alt_rounded, size: 18),
            label: const Text('Трекеры'),
          ),
        ]),
      ]),
    );
  }
}

Future<void> recommendSheet(BuildContext context, WidgetRef ref, MangaDetails manga) async {
  FriendsData data;
  try {
    data = await ref.read(socialApiProvider).friends();
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
    return;
  }
  if (!context.mounted) return;
  if (data.friends.isEmpty) {
    showSnack(context, 'Сначала добавьте друзей: Профиль → Друзья');
    return;
  }
  final picked = <String>{};
  final msg = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Посоветовать «${manga.title}»', style: Theme.of(ctx).textTheme.titleMedium, textAlign: TextAlign.center),
            for (final f in data.friends)
              CheckboxListTile(
                value: picked.contains(f.user.id),
                onChanged: (v) => set(() => v == true ? picked.add(f.user.id) : picked.remove(f.user.id)),
                title: Text(f.user.name),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
              child: TextField(controller: msg, maxLength: 300, decoration: const InputDecoration(hintText: 'Пара слов, почему стоит прочитать')),
            ),
            Padding(
              padding: const EdgeInsets.all(MfSpace.gutter),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: picked.isEmpty
                      ? null
                      : () async {
                          try {
                            await ref.read(socialApiProvider).recommend(manga, picked.toList(), msg.text.trim());
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (context.mounted) showSnack(context, 'Совет отправлен');
                          } catch (e) {
                            if (ctx.mounted) showSnack(ctx, errorText(e));
                          }
                        },
                  child: const Text('Отправить'),
                ),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}

// ================================================================= trackers
const _trackerIcons = {'shikimori': '🦊', 'mal': '📘', 'anilist': '🅰️'};

class TrackersScreen extends ConsumerStatefulWidget {
  const TrackersScreen({super.key});

  @override
  ConsumerState<TrackersScreen> createState() => _TrackersScreenState();
}

class _TrackersScreenState extends ConsumerState<TrackersScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // back from the browser after signing in
    if (state == AppLifecycleState.resumed) ref.invalidate(trackersProvider);
  }

  Future<void> _connect(TrackerInfo t) async {
    try {
      final url = await ref.read(socialApiProvider).trackerAuthorizeUrl(t.service);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(authProvider.notifier).isSignedIn) {
      return Scaffold(appBar: AppBar(title: const Text('Трекеры')), body: _signInFirst(context, 'Трекеры'));
    }
    final api = ref.read(socialApiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Трекеры')),
      body: AsyncBody(
        value: ref.watch(trackersProvider),
        onRetry: () => ref.invalidate(trackersProvider),
        data: (items) => ListView(padding: const EdgeInsets.all(MfSpace.gutter), children: [
          Text('Прочитанные главы и ваши оценки сами уходят в подключённые трекеры. '
              'Тайтл находится по названию; если не угадали — поправьте на странице тайтла → «Трекеры».',
              style: context.text.bodySmall),
          const SizedBox(height: MfSpace.md),
          for (final t in items)
            Card(
              child: ListTile(
                leading: Text(_trackerIcons[t.service] ?? '🔗', style: const TextStyle(fontSize: 26)),
                title: Text(t.name),
                subtitle: Text(!t.configured
                    ? 'Не настроен на сервере. Администратору: client id/secret в .env, Redirect URI: ${t.redirectUri}'
                    : t.connected
                        ? 'Подключён: ${t.username ?? ''}${t.lastError != null ? '\nОшибка: ${t.lastError}' : ''}'
                        : 'Не подключён'),
                isThreeLine: !t.configured || t.lastError != null,
                trailing: !t.configured
                    ? null
                    : t.connected
                        ? TextButton(
                            onPressed: () async {
                              await api.disconnectTracker(t.service);
                              ref.invalidate(trackersProvider);
                            },
                            child: const Text('Отключить'))
                        : FilledButton(onPressed: () => _connect(t), child: const Text('Подключить')),
              ),
            ),
          const SizedBox(height: MfSpace.md),
          if (items.any((t) => t.connected))
            OutlinedButton.icon(
              onPressed: () async {
                await api.syncTrackers();
                if (context.mounted) showSnack(context, 'Отправляю прогресс библиотеки в трекеры');
              },
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Отправить прогресс всей библиотеки'),
            ),
        ]),
      ),
    );
  }
}

Future<void> trackersSheet(BuildContext context, WidgetRef ref, MangaDetails manga) async {
  final api = ref.read(socialApiProvider);
  List<TrackerLinkInfo> links;
  try {
    links = await api.trackerLinks(manga.sourceId, manga.id);
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
    return;
  }
  if (!context.mounted) return;
  if (links.isEmpty) {
    showSnack(context, 'Трекеры не подключены: Профиль → Трекеры');
    await context.push('/trackers');
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final l in links)
          ListTile(
            leading: Text(_trackerIcons[l.service] ?? '🔗', style: const TextStyle(fontSize: 24)),
            title: Text(l.name),
            subtitle: Text(l.remoteId == null
                ? (l.searched ? 'Не нашёлся автоматически — выберите вручную' : 'Найдётся после первой прочитанной главы')
                : '${l.remoteTitle}${l.chaptersSent != null ? ' · отправлено глав: ${l.chaptersSent}' : ''}'),
            trailing: const Icon(Icons.edit_rounded),
            onTap: () async {
              final picked = await _pickCandidate(ctx, ref, l.service, manga);
              if (picked == null) return;
              await api.setTrackerLink(l.service, manga.sourceId, manga.id, picked);
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) showSnack(context, '${l.name}: «${picked.title}»');
            },
          ),
      ]),
    ),
  );
}

Future<TrackerCandidate?> _pickCandidate(BuildContext context, WidgetRef ref, String service, MangaDetails manga) {
  return showModalBottomSheet<TrackerCandidate>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _CandidatePicker(service: service, initial: manga.altTitles.isNotEmpty ? manga.altTitles.first : manga.title),
  );
}

class _CandidatePicker extends ConsumerStatefulWidget {
  const _CandidatePicker({required this.service, required this.initial});
  final String service, initial;

  @override
  ConsumerState<_CandidatePicker> createState() => _CandidatePickerState();
}

class _CandidatePickerState extends ConsumerState<_CandidatePicker> {
  late final _q = TextEditingController(text: widget.initial);
  List<TrackerCandidate>? _items;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  Future<void> _search() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(socialApiProvider).trackerSearch(widget.service, _q.text.trim());
      if (mounted) setState(() => (_items, _error, _busy) = (r, null, false));
    } catch (e) {
      if (mounted) setState(() => (_error, _busy) = (errorText(e), false));
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Название (лучше на английском или японском)',
                suffixIcon: IconButton(onPressed: _search, icon: const Icon(Icons.search_rounded)),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(MfSpace.md), child: Text(_error!)),
          Expanded(
            child: ListView(children: [
              for (final c in _items ?? const <TrackerCandidate>[])
                ListTile(
                  leading: SizedBox(width: 36, child: MangaCover(url: c.cover, width: 36, radius: MfRadius.sm, shadow: false)),
                  title: Text(c.title),
                  subtitle: Text([
                    if (c.year != null) '${c.year}',
                    if (c.chapters != null) '${c.chapters} гл.',
                    ...c.altTitles.take(2),
                  ].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, c),
                ),
            ]),
          ),
        ]),
      );
}
