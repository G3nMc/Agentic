import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/notification_helper.dart';
import '../../data/models/conversation.dart';
import '../../data/models/message.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../statemanagement/method_listener.dart';
import '../screens/home_screen.dart';

class ChatSelectionModal extends StatefulWidget {
  final List<Conversation> conversations;
  final String? activeConversationId;

  const ChatSelectionModal({
    super.key,
    required this.conversations,
    this.activeConversationId,
  });

  @override
  State<ChatSelectionModal> createState() => _ChatSelectionModalState();
}

class _ChatSelectionModalState extends State<ChatSelectionModal> {
  final Set<String> _selectedIds = {};

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
        decoration: BoxDecoration(
          color: AppTheme.bgPrimary,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            _buildHeader(),
            const Divider(height: 1, color: AppTheme.border),
            Expanded(child: _buildConversationList()),
            const Divider(height: 1, color: AppTheme.border),
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Select Conversations',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_selectedIds.length} selected',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(),
            color: AppTheme.textSecondary,
            splashRadius: 20,
          ),
        ],
      ),
    );
  }

  Widget _buildConversationList() {
    if (widget.conversations.isEmpty) {
      return const Center(
        child: Text(
          'No conversations available',
          style: TextStyle(color: AppTheme.textMuted),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.conversations.length,
      itemBuilder: (ctx, i) {
        final conv = widget.conversations[i];
        final isSelected = _selectedIds.contains(conv.id);
        final isActive = conv.id == widget.activeConversationId;

        return _ConversationTile(
          conversation: conv,
          isSelected: isSelected,
          isActive: isActive,
          onToggle: () {
            setState(() {
              if (isSelected) {
                _selectedIds.remove(conv.id);
              } else {
                _selectedIds.add(conv.id);
              }
            });
          },
        );
      },
    );
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          const Spacer(),
          if (_selectedIds.isNotEmpty) ...[
            TextButton.icon(
              onPressed: _selectedIds.length > 1 ? _handleSummarize : null,
              icon: const Icon(Icons.summarize, size: 18),
              label: const Text('Summarize'),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.accent,
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _handleDelete,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.danger,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _handleDelete() async {
    if (_selectedIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete conversations'),
        content: Text(
          'Delete ${_selectedIds.length} conversation${_selectedIds.length == 1 ? '' : 's'}? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      for (final id in _selectedIds) {
        await ConversationRepository.instance.delete(id);
      }

      // Close active conversation if it was deleted
      if (widget.activeConversationId != null &&
          _selectedIds.contains(widget.activeConversationId)) {
        await MethodListener<HomeScreen>()
            .callMethod('closeActiveConversation');
      }

      if (!mounted) return;

      Navigator.of(context).pop(true); // Signal that changes were made

      NotificationHelper.showSuccess(
        context,
        '✓ ${_selectedIds.length} conversation${_selectedIds.length == 1 ? '' : 's'} deleted',
      );
    } catch (e) {
      if (!mounted) return;
      NotificationHelper.showError(context, 'Error deleting: $e');
    }
  }

  Future<void> _handleSummarize() async {
    if (_selectedIds.length < 2) {
      NotificationHelper.showError(context, 'Select at least 2 conversations to summarize');
      return;
    }

    // Close the modal first
    if (!mounted) return;
    Navigator.of(context).pop(true);

    // Show loading indicator
    if (!mounted) return;
    NotificationHelper.showInfo(context, 'Loading conversations...');

    try {
      // Load all selected conversations with their messages
      final conversationsData = <Map<String, dynamic>>[];

      for (final id in _selectedIds) {
        final conv = await ConversationRepository.instance.getById(id);
        if (conv == null) continue;

        final messages =
            await MessageRepository.instance.listByConversation(id);

        conversationsData.add({
          'title': conv.title,
          'messages': messages
              .map((m) => {
                    'role': m.role.apiValue,
                    'content': m.content,
                    if (m.agent != null) 'agent': m.agent,
                  })
              .toList(),
        });
      }

      if (conversationsData.isEmpty) {
        NotificationHelper.showError(context, 'No conversations found');
        return;
      }

      // Create JSON string for the prompt
      final conversationsJson =
          const JsonEncoder.withIndent('  ').convert(conversationsData);

      // Create a new conversation for the summary
      final newConv = Conversation(
        id: const Uuid().v4(),
        title: 'Summary of ${_selectedIds.length} conversations',
        modelId: null,
        backend: null,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        groupId: null,
      );

      await ConversationRepository.instance.insert(newConv);

      // Create system message with the conversations JSON
      final systemPrompt = '''You are an expert conversation analyst and summarizer. The user has provided multiple chat conversations in JSON format.

Your task is to:
1. Summarize each conversation concisely, highlighting key points, decisions, and action items
2. Identify common themes or patterns across conversations
3. Provide an overall summary that synthesizes the key insights from all conversations

Format your response clearly with headings for each conversation summary, followed by a cross-conversation analysis.

Here are the conversations:

$conversationsJson''';

      final systemMsg = ChatMessage(
        id: const Uuid().v4(),
        conversationId: newConv.id,
        role: MessageRole.system,
        content: systemPrompt,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

      await MessageRepository.instance.insert(systemMsg);

      // Create user message requesting the summary
      final userMsg = ChatMessage(
        id: const Uuid().v4(),
        conversationId: newConv.id,
        role: MessageRole.user,
        content:
            'Please analyze and summarize these ${conversationsData.length} conversations as described in the system prompt.',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

      await MessageRepository.instance.insert(userMsg);

      // Navigate to the new conversation
      if (!mounted) return;
      await MethodListener<HomeScreen>().callMethod(
        'openConversation',
        params: {'conversationId': newConv.id},
      );

      NotificationHelper.showSuccess(context, 'New summary chat created');
    } catch (e) {
      if (!mounted) return;
      NotificationHelper.showError(context, 'Error creating summary: $e');
    }
  }
}

class _ConversationTile extends StatefulWidget {
  final Conversation conversation;
  final bool isSelected;
  final bool isActive;
  final VoidCallback onToggle;

  const _ConversationTile({
    required this.conversation,
    required this.isSelected,
    required this.isActive,
    required this.onToggle,
  });

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onToggle,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppTheme.bgSecondary
                : (_hover ? AppTheme.bgSecondary : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
            border: widget.isActive
                ? Border.all(color: AppTheme.accent, width: 1.5)
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: widget.isSelected
                      ? AppTheme.accent
                      : Colors.transparent,
                  border: Border.all(color: AppTheme.accent),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: widget.isSelected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: widget.isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatDate(widget.conversation.updatedAt),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.isActive)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Active',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.accent,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return 'Today';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} days ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
