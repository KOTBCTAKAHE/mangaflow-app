import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/remote/social_api.dart';
import '../../widgets/states.dart';

/// Comments under a chapter (from the reader's ⋮ menu / chapter-end card).
Future<void> showChapterComments(
  BuildContext context, {
  required String sourceId,
  required String mangaId,
  required String chapterId,
  required String chapterTitle,
  int? pageIndex,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => _CommentsSheet(
        sourceId: sourceId,
        mangaId: mangaId,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        pageIndex: pageIndex,
      ),
    );

class _CommentsSheet extends ConsumerStatefulWidget {
  const _CommentsSheet({
    required this.sourceId,
    required this.mangaId,
    required this.chapterId,
    required this.chapterTitle,
    this.pageIndex,
  });
  final String sourceId, mangaId, chapterId, chapterTitle;
  final int? pageIndex;

  @override
  ConsumerState<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<_CommentsSheet> {
  final _text = TextEditingController();
  final _items = <CommentItem>[];
  int _total = 0;
  bool _hasMore = false, _loading = true, _sending = false, _attachPage = false;
  String? _error;

  SocialApi get _api => ref.read(socialApiProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() => _loading = true);
    try {
      final r = await _api.comments(widget.sourceId, widget.chapterId, before: more && _items.isNotEmpty ? _items.last.createdAt : null);
      if (!mounted) return;
      setState(() {
        if (!more) _items.clear();
        _items.addAll(r.items);
        _total = r.total;
        _hasMore = r.hasMore;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() {
          _loading = false;
          _error = errorText(e);
        });
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final c = await _api.addComment(widget.sourceId, widget.mangaId, widget.chapterId, t,
          pageIndex: _attachPage ? widget.pageIndex : null);
      _text.clear();
      if (mounted) setState(() {
          _items.insert(0, c);
          _total++;
          _sending = false;
        });
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showSnack(context, errorText(e));
      }
    }
  }

  Future<void> _like(int i) async {
    final c = _items[i];
    try {
      final (likes, liked) = await _api.likeComment(c.id);
      if (mounted) setState(() => _items[i] = c.copyWith(likes: likes, liked: liked));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(authProvider.notifier).isSignedIn) {
      return SizedBox(
        height: 260,
        child: EmptyState(
          icon: Icons.forum_outlined,
          title: 'Комментарии',
          message: 'Читать и писать комментарии можно после входа.',
          action: FilledButton(
            onPressed: () {
              Navigator.pop(context);
              context.push('/auth');
            },
            child: const Text('Войти'),
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.sm),
            child: Row(children: [
              Expanded(child: Text('Комментарии · ${widget.chapterTitle}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.titleMedium)),
              Text('$_total', style: context.text.titleMedium?.copyWith(color: context.colors.primary)),
            ]),
          ),
          if (_loading && _items.isEmpty) const LinearProgressIndicator(),
          Expanded(
            child: _error != null && _items.isEmpty
                ? EmptyState(icon: Icons.cloud_off_rounded, title: 'Не загрузилось', message: _error, action: TextButton(onPressed: _load, child: const Text('Повторить')))
                : _items.isEmpty && !_loading
                    ? const EmptyState(icon: Icons.forum_outlined, title: 'Пока пусто', message: 'Будьте первым — поделитесь впечатлением от главы.')
                    : ListView.builder(
                        itemCount: _items.length + (_hasMore ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= _items.length) {
                            return TextButton(onPressed: _loading ? null : () => _load(more: true), child: const Text('Показать ещё'));
                          }
                          final c = _items[i];
                          return ListTile(
                            leading: CircleAvatar(child: Text((c.user?.name ?? '?').characters.first.toUpperCase())),
                            title: Row(children: [
                              Flexible(child: Text(c.user?.name ?? 'Удалён', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelLarge)),
                              const SizedBox(width: 6),
                              Text(formatDateTime(c.createdAt), style: context.text.bodySmall),
                              if (c.pageIndex != null) ...[
                                const SizedBox(width: 6),
                                Text('· стр. ${c.pageIndex! + 1}', style: context.text.bodySmall),
                              ],
                            ]),
                            subtitle: Text(c.text, style: context.text.bodyMedium),
                            trailing: Column(mainAxisSize: MainAxisSize.min, children: [
                              InkWell(
                                onTap: () => _like(i),
                                child: Icon(c.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                    size: 20, color: c.liked ? MfColors.danger : null),
                              ),
                              if (c.likes > 0) Text('${c.likes}', style: context.text.bodySmall),
                            ]),
                            onLongPress: !c.mine
                                ? null
                                : () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (d) => AlertDialog(
                                        title: const Text('Удалить комментарий?'),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Нет')),
                                          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Удалить')),
                                        ],
                                      ),
                                    );
                                    if (ok != true) return;
                                    await _api.deleteComment(c.id);
                                    if (mounted) setState(() {
                                      _items.removeAt(i);
                                      _total--;
                                    });
                                  },
                          );
                        },
                      ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.md, MfSpace.sm, MfSpace.sm, MfSpace.sm),
            child: Row(children: [
              if (widget.pageIndex != null)
                IconButton(
                  tooltip: 'Привязать к странице ${widget.pageIndex! + 1}',
                  isSelected: _attachPage,
                  selectedIcon: const Icon(Icons.bookmark_rounded),
                  icon: const Icon(Icons.bookmark_border_rounded),
                  onPressed: () => setState(() => _attachPage = !_attachPage),
                ),
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Ваш комментарий… (без спойлеров 🙏)', counterText: ''),
                ),
              ),
              IconButton(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
