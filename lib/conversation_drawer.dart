import 'package:flutter/material.dart';

import 'conversation.dart';
import 'lfm3_model.dart';

enum ConversationAction { rename, delete }

class ConversationDrawer extends StatelessWidget {
  const ConversationDrawer({
    super.key,
    required this.conversations,
    required this.activeId,
    required this.modelKind,
    required this.onNewChat,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
    required this.onSelectModel,
    required this.onAbout,
  });

  final List<Conversation> conversations;
  final String? activeId;
  final Lfm3ModelKind modelKind;
  final VoidCallback onNewChat;
  final ValueChanged<Conversation> onSelect;
  final ValueChanged<Conversation> onRename;
  final ValueChanged<Conversation> onDelete;
  final ValueChanged<Lfm3ModelKind> onSelectModel;
  final VoidCallback onAbout;

  void _selectModel(BuildContext context, Lfm3ModelKind kind) {
    if (kind == modelKind) return;
    Navigator.of(context).maybePop();
    onSelectModel(kind);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final sorted = [...conversations]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    colors.primaryContainer,
                    colors.surfaceContainerHighest,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.memory, color: colors.onPrimaryContainer),
                      const SizedBox(width: 8),
                      Text(
                        'LFM3 Lab',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    'LFM3-1.7B · Q4_K_M · CPU',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '100 % local, sans serveur',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onPrimaryContainer.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onNewChat,
                  icon: const Icon(Icons.add_comment_outlined),
                  label: const Text('Nouveau chat'),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Modèle',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            _ModelTile(
              label: 'LFM3-1.7B · texte',
              icon: Icons.chat_bubble_outline,
              selected: modelKind == Lfm3ModelKind.text,
              onTap: () => _selectModel(context, Lfm3ModelKind.text),
            ),
            _ModelTile(
              label: 'LFM3-Audio-2B · voix',
              icon: Icons.graphic_eq,
              selected: modelKind == Lfm3ModelKind.audio,
              onTap: () => _selectModel(context, Lfm3ModelKind.audio),
            ),
            const Divider(height: 16),
            Expanded(
              child: sorted.isEmpty
                  ? Center(
                      child: Text(
                        'Aucune conversation',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      itemCount: sorted.length,
                      itemBuilder: (context, index) {
                        final conversation = sorted[index];
                        return _ConversationTile(
                          conversation: conversation,
                          selected: conversation.id == activeId,
                          onSelect: () => onSelect(conversation),
                          onRename: () => onRename(conversation),
                          onDelete: () => onDelete(conversation),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('À propos'),
              onTap: onAbout,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: colors.primaryContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, size: 20),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      trailing: selected
          ? Icon(Icons.check, size: 18, color: colors.primary)
          : null,
      onTap: onTap,
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selected,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return ListTile(
      selected: selected,
      selectedTileColor: colors.primaryContainer.withValues(alpha: 0.45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.only(left: 12, right: 4),
      leading: Icon(
        conversation.messages.isEmpty
            ? Icons.chat_bubble_outline
            : Icons.chat_bubble,
        color: selected ? colors.primary : null,
      ),
      title: Text(
        conversation.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              conversation.preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _relativeTime(conversation.updatedAt),
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
      trailing: PopupMenuButton<ConversationAction>(
        tooltip: 'Actions',
        icon: const Icon(Icons.more_vert, size: 18),
        padding: EdgeInsets.zero,
        onSelected: (action) {
          if (action == ConversationAction.rename) {
            onRename();
          } else {
            onDelete();
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: ConversationAction.rename,
            child: Row(
              children: [
                Icon(Icons.edit_outlined, size: 18),
                SizedBox(width: 12),
                Text('Renommer'),
              ],
            ),
          ),
          PopupMenuItem(
            value: ConversationAction.delete,
            child: Row(
              children: [
                Icon(Icons.delete_outline, size: 18),
                SizedBox(width: 12),
                Text('Supprimer'),
              ],
            ),
          ),
        ],
      ),
      onTap: onSelect,
    );
  }
}

String _relativeTime(DateTime dateTime) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dateTime.year, dateTime.month, dateTime.day);
  final days = today.difference(day).inDays;

  if (days <= 0) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:'
        '${dateTime.minute.toString().padLeft(2, '0')}';
  }
  if (days == 1) return 'Hier';
  if (days < 7) return 'Il y a $days j';
  return '${dateTime.day.toString().padLeft(2, '0')}/'
      '${dateTime.month.toString().padLeft(2, '0')}';
}
