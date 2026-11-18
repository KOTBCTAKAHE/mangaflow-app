import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../widgets/states.dart';

/// Status / favorite / collections / remove for a library entry.
Future<void> showEntryActions(BuildContext context, WidgetRef ref, LibraryEntry e) async {
  final repo = ref.read(libraryRepositoryProvider);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: MfSpace.md),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.md),
            child: SelectableText(e.title, style: context.text.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
            child: Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [
              for (final s in LibraryStatus.values)
                ChoiceChip(
                  label: Text(s.label),
                  selected: e.status == s,
                  showCheckmark: false,
                  onSelected: (_) {
                    repo.setStatus(e.sourceId, e.mangaId, s);
                    Navigator.pop(context);
                  },
                ),
            ]),
          ),
          const SizedBox(height: MfSpace.md),
          ListTile(
            leading: Icon(e.isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                color: e.isFavorite ? MfColors.accent : null),
            title: Text(e.isFavorite ? 'Убрать из избранного' : 'В избранное'),
            onTap: () {
              repo.setFavorite(e.sourceId, e.mangaId, !e.isFavorite);
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Коллекции'),
            onTap: () {
              Navigator.pop(context);
              showCollectionPicker(context, ref, e);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: MfColors.danger),
            title: const Text('Удалить из библиотеки'),
            onTap: () async {
              Navigator.pop(context);
              await repo.remove(e.sourceId, e.mangaId);
              if (context.mounted) showSnack(context, 'Удалено из библиотеки');
            },
          ),
        ]),
      ),
    ),
  );
}

Future<void> showCollectionPicker(BuildContext context, WidgetRef ref, LibraryEntry e) async {
  final repo = ref.read(libraryRepositoryProvider);
  final all = await repo.allCollections();
  final selected = {...e.collectionIds};
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.sm, 0),
            child: Row(children: [
              Expanded(child: Text('Коллекции', style: context.text.titleMedium)),
              TextButton.icon(
                onPressed: () async {
                  final name = await promptText(context, title: 'Новая коллекция');
                  if (name == null || name.isEmpty) return;
                  final id = await repo.createCollection(name);
                  all.add(Collection(id: id, name: name));
                  setState(() => selected.add(id));
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('Создать'),
              ),
            ]),
          ),
          if (all.isEmpty)
            const Padding(padding: EdgeInsets.all(MfSpace.xl), child: Text('Коллекций пока нет')),
          for (final c in all)
            CheckboxListTile(
              value: selected.contains(c.id),
              title: Text(c.name),
              onChanged: (v) => setState(() => v == true ? selected.add(c.id) : selected.remove(c.id)),
            ),
          Padding(
            padding: const EdgeInsets.all(MfSpace.gutter),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  repo.setCollections(e.sourceId, e.mangaId, selected);
                  Navigator.pop(context);
                },
                child: const Text('Готово'),
              ),
            ),
          ),
        ]),
      ),
    ),
  );
}

Future<void> showCollectionsManager(BuildContext context, WidgetRef ref) async {
  final repo = ref.read(libraryRepositoryProvider);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Consumer(builder: (context, ref, _) {
      final cols = ref.watch(collectionsProvider).valueOrNull ?? const <Collection>[];
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.sm, MfSpace.sm),
            child: Row(children: [
              Expanded(child: Text('Пользовательские коллекции', style: context.text.titleMedium)),
              IconButton(
                tooltip: 'Создать',
                icon: const Icon(Icons.add_rounded),
                onPressed: () async {
                  final name = await promptText(context, title: 'Новая коллекция');
                  if (name != null && name.isNotEmpty) await repo.createCollection(name);
                },
              ),
            ]),
          ),
          if (cols.isEmpty)
            const Padding(
              padding: EdgeInsets.all(MfSpace.xl),
              child: Text('Создайте коллекцию, чтобы группировать тайтлы по своему усмотрению.'),
            ),
          for (final c in cols)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(c.name),
              subtitle: Text('${c.entryKeys.length} тайтлов'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Переименовать',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    final name = await promptText(context, title: 'Переименовать', initial: c.name);
                    if (name != null && name.isNotEmpty) await repo.renameCollection(c.id, name);
                  },
                ),
                IconButton(
                  tooltip: 'Удалить',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => repo.deleteCollection(c.id),
                ),
              ]),
            ),
          const SizedBox(height: MfSpace.lg),
        ]),
      );
    }),
  );
}

Future<String?> promptText(BuildContext context, {required String title, String initial = '', String? hint}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}
