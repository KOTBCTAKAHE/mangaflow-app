import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/remote/social_api.dart';
import '../../widgets/states.dart';
import 'reader_controller.dart';

const kRoomReactions = ['❤️', '😂', '😮', '😭', '🔥', '👍', '😱', '🤯'];

class FloatingReaction {
  FloatingReaction(this.emoji, this.from) : x = 0.15 + Random().nextDouble() * 0.7, born = DateTime.now();
  final String emoji, from;
  final double x;
  final DateTime born;
}

/// «Читать вместе»: one WebSocket per room; pages follow whoever turns them.
class ReadingRoom extends ChangeNotifier {
  ReadingRoom({required this.code, required this.api, required this.token, required this.reader});

  final String code;
  final SocialApi api;
  final Future<String?> Function() token;
  final ReaderController reader;

  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;
  bool _closed = false;
  int _retry = 0;
  String? me;
  List<String> members = const [];
  bool connected = false;
  bool follow = true;
  String? lastEvent;
  final reactions = <FloatingReaction>[];

  (String, int)? _remote; // last state applied from the room — don't echo it back
  (String, int)? _sent;
  Timer? _debounce;

  Future<void> connect() async {
    if (_closed) return;
    try {
      final t = await token();
      if (t == null) throw const HttpException('нужно войти в аккаунт');
      final ws = await WebSocket.connect(api.roomSocket(code, t).toString()).timeout(const Duration(seconds: 10));
      ws.pingInterval = const Duration(seconds: 25);
      _ws = ws;
      _retry = 0;
      connected = true;
      notifyListeners();
      _sub = ws.listen(_onMessage, onDone: _onDrop, onError: (Object _) => _onDrop(), cancelOnError: true);
    } catch (_) {
      _onDrop();
    }
  }

  void _onDrop() {
    connected = false;
    _ws = null;
    unawaited(_sub?.cancel());
    if (!_closed) {
      notifyListeners();
      final delay = Duration(seconds: min(30, 1 << min(_retry++, 5)));
      Future<void>.delayed(delay, connect);
    }
  }

  void _send(Map<String, Object?> msg) {
    final ws = _ws;
    if (ws != null && ws.readyState == WebSocket.open) ws.add(jsonEncode(msg));
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final fromMe = m['uid'] != null && m['uid'] == me;
    switch (m['t']) {
      case 'hello':
        me = m['me'] as String?;
        final st = (m['state'] as Map?)?.cast<String, dynamic>();
        if (st != null) _apply(st['chapter_id'] as String?, (st['page'] as num?)?.toInt() ?? 0);
      case 'join' || 'leave':
        members = [for (final x in (m['members'] as List?) ?? const []) x as String];
        if (!fromMe) lastEvent = '${m['name']} ${m['t'] == 'join' ? 'присоединился' : 'вышел'}';
      case 'page':
        if (!fromMe) {
          lastEvent = '${m['name']} → стр. ${((m['page'] as num?)?.toInt() ?? 0) + 1}';
          if (follow) _apply(m['chapter_id'] as String?, (m['page'] as num?)?.toInt() ?? 0);
        }
      case 'react':
        _float(m['emoji'] as String? ?? '❤️', m['name'] as String? ?? '');
      case 'say':
        lastEvent = '${m['name']}: ${m['text']}';
      case 'ping':
        _send({'t': 'pong'});
    }
    notifyListeners();
  }

  void _float(String emoji, String from) {
    reactions.add(FloatingReaction(emoji, from));
    HapticFeedback.selectionClick();
    Future<void>.delayed(const Duration(milliseconds: 2600), () {
      reactions.removeWhere((r) => DateTime.now().difference(r.born).inMilliseconds > 2400);
      if (!_closed) notifyListeners();
    });
  }

  void _apply(String? chapterId, int page) {
    if (chapterId == null || chapterId.isEmpty) return;
    _remote = (chapterId, page);
    final seg = reader.current;
    if (seg != null && seg.chapter.id == chapterId) {
      if (reader.page != page) reader.jumpToPage(page);
      return;
    }
    final idx = reader.ordered.indexWhere((c) => c.id == chapterId);
    if (idx >= 0) unawaited(reader.openChapter(idx, page: page));
  }

  /// Called on every reader change: share our page with the room.
  void onReaderChanged() {
    final seg = reader.current;
    if (seg == null || _closed) return;
    final now = (seg.chapter.id, reader.page);
    if (now == _remote || now == _sent) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _sent = now;
      _remote = null;
      _send({'t': 'page', 'chapter_id': now.$1, 'chapter_title': seg.chapter.title, 'page': now.$2});
    });
  }

  void react(String emoji) => _send({'t': 'react', 'emoji': emoji, 'page': reader.page});
  void say(String text) => _send({'t': 'say', 'text': text});

  void setFollow(bool v) {
    follow = v;
    notifyListeners();
  }

  Future<void> close() async {
    _closed = true;
    _debounce?.cancel();
    await _sub?.cancel();
    await _ws?.close();
  }
}

/// Starts a room for the open chapter and shows its code to share.
Future<ReadingRoom?> startRoom(BuildContext context, WidgetRef ref, ReaderController c) async {
  final seg = c.current;
  final m = c.manga;
  if (seg == null || m == null) return null;
  if (!ref.read(authProvider.notifier).isSignedIn) {
    showSnack(context, 'Читать вместе можно после входа в аккаунт');
    return null;
  }
  try {
    final api = ref.read(socialApiProvider);
    final info = await api.createRoom(manga: m, chapter: seg.chapter, page: c.page);
    final room = ReadingRoom(code: info.code, api: api, token: ref.read(authProvider.notifier).accessToken, reader: c);
    unawaited(room.connect());
    if (context.mounted) await showRoomCode(context, info.code, m.title);
    return room;
  } catch (e) {
    if (context.mounted) showSnack(context, 'Не удалось создать комнату: ${errorText(e)}');
    return null;
  }
}

Future<void> showRoomCode(BuildContext context, String code, String title) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Читаем вместе', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: MfSpace.sm),
            const Text('Друг открывает MangaFlow → Профиль → «Читать вместе» и вводит код. '
                'Страницы листаются у обоих, реакции видны сразу.', textAlign: TextAlign.center),
            const SizedBox(height: MfSpace.lg),
            SelectableText(code,
                style: Theme.of(ctx).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 8)),
            const SizedBox(height: MfSpace.lg),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    showSnack(ctx, 'Код скопирован');
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Копировать'),
                ),
              ),
              const SizedBox(width: MfSpace.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => SharePlus.instance.share(ShareParams(
                      text: 'Давай читать «$title» вместе в MangaFlow! Профиль → «Читать вместе» → код $code')),
                  icon: const Icon(Icons.share_rounded),
                  label: const Text('Отправить'),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );

/// Profile → «Читать вместе»: enter a code, open the reader in that room.
Future<void> joinRoomFlow(BuildContext context, WidgetRef ref) async {
  if (!ref.read(authProvider.notifier).isSignedIn) {
    showSnack(context, 'Сначала войдите в аккаунт');
    return;
  }
  final ctrl = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Читать вместе'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        maxLength: 6,
        decoration: const InputDecoration(hintText: 'Код комнаты', counterText: ''),
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(d, ctrl.text), child: const Text('Войти')),
      ],
    ),
  );
  if (code == null || code.trim().length < 4 || !context.mounted) return;
  try {
    final r = await ref.read(socialApiProvider).room(code);
    if (!context.mounted) return;
    await context.push(Routes.reader(r.sourceId, r.mangaId, r.chapterId, page: r.page, room: r.code));
  } catch (e) {
    if (context.mounted) showSnack(context, 'Комната не найдена: ${errorText(e)}');
  }
}

/// Room HUD over the reader: members, last event, reactions, floating emojis.
class RoomOverlay extends StatelessWidget {
  const RoomOverlay({super.key, required this.room, required this.uiVisible, required this.onLeave});
  final ReadingRoom room;
  final bool uiVisible;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) => Stack(children: [
        for (final r in room.reactions)
          Positioned.fill(child: IgnorePointer(child: _Floating(key: ObjectKey(r), reaction: r))),
        Positioned(
          left: MfSpace.sm,
          top: pad.top + (uiVisible ? 64 : 8),
          child: GestureDetector(
            onTap: () => _menu(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(MfRadius.pill)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(room.connected ? Icons.groups_rounded : Icons.cloud_off_rounded,
                    size: 16, color: room.connected ? MfColors.accent : Colors.white54),
                const SizedBox(width: 6),
                Text('${room.code} · ${room.members.length}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                if (room.lastEvent != null) ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 170),
                    child: Text(room.lastEvent!, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
                ],
              ]),
            ),
          ),
        ),
        if (uiVisible)
          Positioned(
            right: MfSpace.sm,
            bottom: pad.bottom + 150,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(MfRadius.pill)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final e in kRoomReactions.take(6))
                  InkWell(
                    onTap: () => room.react(e),
                    child: Padding(padding: const EdgeInsets.all(6), child: Text(e, style: const TextStyle(fontSize: 22))),
                  ),
              ]),
            ),
          ),
      ]),
    );
  }

  Future<void> _menu(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => ListenableBuilder(
          listenable: room,
          builder: (ctx, _) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: const Icon(Icons.groups_rounded),
                title: Text('Комната ${room.code}'),
                subtitle: Text(room.members.isEmpty ? 'Пока никого' : room.members.join(', ')),
                trailing: IconButton(
                  icon: const Icon(Icons.share_rounded),
                  onPressed: () => SharePlus.instance.share(ShareParams(text: 'MangaFlow → Профиль → «Читать вместе» → код ${room.code}')),
                ),
              ),
              SwitchListTile(
                value: room.follow,
                onChanged: room.setFollow,
                secondary: const Icon(Icons.sync_rounded),
                title: const Text('Листать вместе'),
                subtitle: const Text('Выключите, чтобы читать в своём темпе и только видеть реакции'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
                child: TextField(
                  decoration: const InputDecoration(hintText: 'Написать в комнату…', prefixIcon: Icon(Icons.chat_bubble_outline_rounded)),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) room.say(v.trim());
                    Navigator.pop(ctx);
                  },
                ),
              ),
              Wrap(alignment: WrapAlignment.center, children: [
                for (final e in kRoomReactions)
                  IconButton(onPressed: () => room.react(e), icon: Text(e, style: const TextStyle(fontSize: 24))),
              ]),
              ListTile(
                leading: const Icon(Icons.logout_rounded, color: MfColors.danger),
                title: const Text('Выйти из комнаты'),
                onTap: () {
                  Navigator.pop(ctx);
                  onLeave();
                },
              ),
            ]),
          ),
        ),
      );
}

class _Floating extends StatefulWidget {
  const _Floating({super.key, required this.reaction});
  final FloatingReaction reaction;

  @override
  State<_Floating> createState() => _FloatingState();
}

class _FloatingState extends State<_Floating> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..forward();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        return AnimatedBuilder(
          animation: _a,
          builder: (_, __) {
            final t = Curves.easeOut.transform(_a.value);
            return Stack(children: [Positioned(
              left: box.maxWidth * widget.reaction.x,
              bottom: 80 + t * box.maxHeight * 0.55,
              child: Opacity(
                opacity: (1 - _a.value).clamp(0.0, 1.0),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.reaction.emoji, style: TextStyle(fontSize: 34 + 10 * sin(t * pi))),
                  Text(widget.reaction.from, style: const TextStyle(color: Colors.white70, fontSize: 10)),
                ]),
              ),
            )]);
          },
        );
      });
}
