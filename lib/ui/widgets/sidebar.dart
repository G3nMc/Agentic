import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/notification_helper.dart';
import '../../data/models/conversation.dart';
import '../../data/repositories/agent_role_settings_repository.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/github_models_service.dart';
import '../../services/groq_service.dart';
import '../../services/llm_service.dart';
import '../../services/orchestrator_manager.dart';
import '../../statemanagement/method_data.dart';
import '../../statemanagement/method_listener.dart';
import '../../statemanagement/state_manager.dart';
import '../screens/home_screen.dart';
import '../screens/settings_screen.dart';
import 'chat_selection_modal.dart';
import 'chat_view.dart';

class Sidebar extends StatefulWidget {
  final String? activeConversationId;

  const Sidebar({super.key, this.activeConversationId});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends StateManager<Sidebar> {
  List<Conversation> _conversations = [];
  bool _loading = true;
  LlmBackend? _activeBackend;
  List<WorkflowGroup> _workflowGroups = [];
  String _activeGroupId = '';
  bool _selectMode = false;
  final Set<String> _selectedConversationIds = {};

  @override
  void initState() {
    super.initState();
    _loadActiveBackend();
    _loadWorkflowGroups();
    AgentRoleSettingsRepository.instance.activeGroupNotifier.addListener(_onActiveGroupChanged);
    AgentRoleSettingsRepository.instance.groupsChangedNotifier.addListener(_onGroupsChanged);
  }

  void _onActiveGroupChanged() {
    _loadWorkflowGroups();
  }

  void _onGroupsChanged() {
    _loadWorkflowGroups();
  }

  Future<void> _loadWorkflowGroups() async {
    final groups = await AgentRoleSettingsRepository.instance.listGroups();
    final activeGroupId = await AgentRoleSettingsRepository.instance.getActiveGroupId();
    if (!mounted) return;
    setState(() {
      _workflowGroups = groups;
      _activeGroupId = activeGroupId;
    });
  }

  Future<void> _loadActiveBackend() async {
    final backend = await BackendSettingsRepository.instance.getActiveBackend();
    await AgentRoleSettingsRepository.instance.isEnabled();
    if (!mounted) return;
    setState(() => _activeBackend = backend);
    await _loadConversations();
  }

  Future<void> _onBackendChanged(LlmBackend v) async {
    if (v == _activeBackend) return;
    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }

    await BackendSettingsRepository.instance.setActiveBackend(v);
    if (!mounted) return;
    setState(() => _activeBackend = v);
    await _loadConversations();

    if (widget.activeConversationId != null) {
      final stillVisible = _conversations.any((c) => c.id == widget.activeConversationId);
      if (!stillVisible && mounted) {
        await MethodListener<HomeScreen>().callMethod("closeActiveConversation");
      }
    }

    await MethodListener<ChatView>().callMethod("backendChanged");

    NotificationHelper.showSuccess(context, "✓ Backend saved");
  }

  @override
  void onMethodListener(MethodData methodData) {
    switch (methodData.methodName) {
      case "refreshConversations":
        _loadConversations();
        break;
      case "newConversation":
        _newChat();
        break;
    }
  }

  Future<void> _loadConversations() async {
    print('[DEBUG] _loadConversations() called');
    final backend = _activeBackend ?? await BackendSettingsRepository.instance.getActiveBackend();
    var list = await ConversationRepository.instance.listByBackend(backend.name);
    if (_activeGroupId.isNotEmpty) {
      list = list.where((c) => c.groupId == _activeGroupId).toList();
    }
    print(
      '[DEBUG] _loadConversations() got ${list.length} conversations for '
      '${backend.name}${_activeGroupId.isNotEmpty ? ' in group $_activeGroupId' : ''}',
    );
    if (!mounted) return;
    setState(() {
      _conversations = list;
      _loading = false;
    });
  }

  Future<void> _newChat() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = const Uuid().v4();
    final backend = await BackendSettingsRepository.instance.getActiveBackend();
    final selectedModel = switch (backend) {
      LlmBackend.ollama || LlmBackend.ollamaPython || LlmBackend.ollamaOrchestrator => await BackendSettingsRepository.instance.getOllamaModel(),
      LlmBackend.groq || LlmBackend.groqOrchestrator => await BackendSettingsRepository.instance.getGroqModel() ?? GroqService.fallbackModels.first,
      LlmBackend.openRouter || LlmBackend.openRouterOrchestrator => await BackendSettingsRepository.instance.getOpenRouterModel() ?? '',
      LlmBackend.githubOrchestrator => await BackendSettingsRepository.instance.getGithubModel() ?? GithubModelsService.fallbackModels.first,
      _ => (await SettingsRepository.instance.getSelectedModelId()) ?? '',
    };

    final conversation = Conversation(
      id: id,
      title: "New chat",
      modelId: selectedModel,
      backend: backend.name,
      createdAt: now,
      updatedAt: now,
      groupId: _activeGroupId.isNotEmpty ? _activeGroupId : null,
    );
    await ConversationRepository.instance.insert(conversation);
    await _loadConversations();

    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }

    await MethodListener<HomeScreen>().callMethod(
      "openConversation",
      params: {"conversationId": id},
    );
  }

  Future<void> _deleteConversation(Conversation c) async {
    print('[DEBUG] Starting deletion for conversation: ${c.id} "${c.title}"');
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete conversation"),
        content: Text('Delete "${c.title}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (confirm != true) {
      print('[DEBUG] User cancelled deletion');
      return;
    }

    try {
      if (mounted) {
        setState(() {
          _conversations = _conversations.where((conv) => conv.id != c.id).toList();
        });
      }

      await ConversationRepository.instance.delete(c.id);

      if (widget.activeConversationId == c.id && mounted) {
        await MethodListener<HomeScreen>().callMethod("closeActiveConversation");
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✓ Conversation deleted"),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      await _loadConversations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error deleting: $e"),
            backgroundColor: AppTheme.danger,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _renameConversation(Conversation c) async {
    final controller = TextEditingController(text: c.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Rename conversation"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: "Title"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text("Save"),
          ),
        ],
      ),
    );
    if (newTitle == null || newTitle.isEmpty) return;

    await ConversationRepository.instance.updateTitle(c.id, newTitle);
    await _loadConversations();

    if (widget.activeConversationId == c.id) {
      await MethodListener<ChatView>().callMethod(
        "conversationUpdated",
        params: {"conversationId": c.id},
      );
    }
  }

  Future<void> _selectConversation(Conversation c) async {
    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }
    MethodListener<HomeScreen>().callMethod(
      "openConversation",
      params: {"conversationId": c.id},
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _openChatSelectionModal() async {
    // Load all conversations for the current backend (ignoring group filter for the modal)
    final backend = _activeBackend ?? await BackendSettingsRepository.instance.getActiveBackend();
    final allConversations = await ConversationRepository.instance.listByBackend(backend.name);

    if (!mounted) return;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => ChatSelectionModal(
        conversations: allConversations,
        activeConversationId: widget.activeConversationId,
      ),
    );

    // If conversations were deleted, refresh the list
    if (result == true && mounted) {
      await _loadConversations();
    }
  }

  Future<void> _deleteSelectedConversations() async {
    if (_selectedConversationIds.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete conversations"),
        content: Text('Delete ${_selectedConversationIds.length} conversation${_selectedConversationIds.length == 1 ? '' : 's'}? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      for (final id in _selectedConversationIds) {
        await ConversationRepository.instance.delete(id);
      }

      if (widget.activeConversationId != null && _selectedConversationIds.contains(widget.activeConversationId)) {
        await MethodListener<HomeScreen>().callMethod("closeActiveConversation");
      }

      await _loadConversations();

      if (!mounted) return;
      setState(() {
        _selectMode = false;
        _selectedConversationIds.clear();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("✓ ${_selectedConversationIds.length} conversation${_selectedConversationIds.length == 1 ? '' : 's'} deleted"),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (e) {
      await _loadConversations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error deleting: $e"),
            backgroundColor: AppTheme.danger,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 18, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 38),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.accentMarrone),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: AgentRoleSettingsRepository.instance.enabledNotifier,
                    builder: (ctx, multiAgent, _) {
                      if (multiAgent) {
                        final activeGroup = _workflowGroups.firstWhere(
                          (g) => g.id == _activeGroupId,
                          orElse: () => _workflowGroups.isNotEmpty ? _workflowGroups.first : const WorkflowGroup(id: '', title: 'Default', roles: {}),
                        );
                        return DropdownButtonHideUnderline(
                          child: DropdownButton<WorkflowGroup>(
                            isExpanded: true,
                            isDense: true,
                            value: _workflowGroups.isNotEmpty ? activeGroup : null,
                            hint: const Text(
                              'Workflow',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                            icon: const Icon(Icons.account_tree_outlined, size: 16, color: AppTheme.accent),
                            items: [
                              for (final group in _workflowGroups)
                                DropdownMenuItem(
                                  value: group,
                                  child: Text(group.title, overflow: TextOverflow.ellipsis),
                                ),
                            ],
                            onChanged: (group) async {
                              if (group == null) return;
                              await AgentRoleSettingsRepository.instance.setActiveGroupId(group.id);
                              if (!mounted) return;
                              setState(() => _activeGroupId = group.id);
                            },
                          ),
                        );
                      }
                      return DropdownButtonHideUnderline(
                        child: DropdownButton<LlmBackend>(
                          isExpanded: true,
                          isDense: true,
                          value: _activeBackend,
                          hint: const Text(
                            "Agentic",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: LlmBackend.orchestrator,
                              child: Text("HF + Orchestrator"),
                            ),
                            DropdownMenuItem(
                              value: LlmBackend.ollamaOrchestrator,
                              child: Text("Ollama + Orchestrator"),
                            ),
                            DropdownMenuItem(
                              value: LlmBackend.groqOrchestrator,
                              child: Text("Groq + Orchestrator"),
                            ),
                            DropdownMenuItem(
                              value: LlmBackend.geminiOrchestrator,
                              child: Text("Gemini + Orchestrator"),
                            ),
                            DropdownMenuItem(
                              value: LlmBackend.openRouterOrchestrator,
                              child: Text("OpenRouter + Orchestrator"),
                            ),
                            DropdownMenuItem(
                              value: LlmBackend.githubOrchestrator,
                              child: Text("GitHub + Orchestrator"),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) _onBackendChanged(v);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 5),
              IconButton(
                tooltip: "Settings",
                icon: const Icon(Icons.settings_outlined, size: 18),
                onPressed: _openSettings,
                color: AppTheme.textSecondary,
                splashRadius: 18,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Container(
            constraints: const BoxConstraints(minHeight: 38),
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _newChat,
              icon: const Icon(Icons.add, size: 16),
              label: const Text("New chat"),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                side: const BorderSide(color: AppTheme.accentMarrone),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 12, 6),
          child: Row(
            children: [
              const Text(
                "Recent",
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textMuted,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: "Select multiple",
                icon: const Icon(Icons.checklist, size: 16),
                onPressed: _openChatSelectionModal,
                color: AppTheme.textMuted,
                splashRadius: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : _conversations.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 18),
                      child: Text(
                        "No conversations yet.\nStart a new chat.",
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        if (_selectMode && _selectedConversationIds.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Row(
                              children: [
                                Text(
                                  "${_selectedConversationIds.length} selected",
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.accent,
                                  ),
                                ),
                                const Spacer(),
                                TextButton(
                                  onPressed: _deleteSelectedConversations,
                                  style: TextButton.styleFrom(
                                    foregroundColor: AppTheme.danger,
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: const Text(
                                    "Delete",
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            itemCount: _conversations.length,
                            itemBuilder: (ctx, i) {
                              final c = _conversations[i];
                              final isActive = c.id == widget.activeConversationId;
                              if (_selectMode) {
                                final isSelected = _selectedConversationIds.contains(c.id);
                                return _SidebarConversationTileSelect(
                                  conversation: c,
                                  isSelected: isSelected,
                                  onToggle: () {
                                    setState(() {
                                      if (isSelected) {
                                        _selectedConversationIds.remove(c.id);
                                      } else {
                                        _selectedConversationIds.add(c.id);
                                      }
                                    });
                                  },
                                );
                              }
                              return _SidebarConversationTile(
                                conversation: c,
                                isActive: isActive,
                                onTap: () => _selectConversation(c),
                                onRename: () => _renameConversation(c),
                                onDelete: () => _deleteConversation(c),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
        ),
      ],
    );
  }
}

class _SidebarConversationTile extends StatefulWidget {
  final Conversation conversation;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _SidebarConversationTile({
    required this.conversation,
    required this.isActive,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_SidebarConversationTile> createState() => _SidebarConversationTileState();
}

class _SidebarConversationTileState extends State<_SidebarConversationTile> {
  bool _hover = false;
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final showActions = _hover || widget.isActive || _menuOpen;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: widget.isActive ? AppTheme.bgSecondary : (_hover ? AppTheme.bgSecondary : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    margin: EdgeInsets.only(right: showActions ? 6 : 0),
                    alignment: AlignmentGeometry.centerLeft,
                    height: 40,
                    decoration: BoxDecoration(color: widget.isActive ? AppTheme.bgSecondary : Colors.transparent),
                    child: Text(
                      widget.conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // fontSize: 14,
                        fontWeight: widget.isActive ? FontWeight.bold : FontWeight.normal,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                ),
                if (showActions)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 30),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.accentMarrone),
                    ),
                    child: PopupMenuButton<String>(
                      tooltip: "More",
                      icon: const Icon(Icons.more_horiz, size: 14, color: AppTheme.accentMarrone),
                      splashRadius: 14,
                      padding: EdgeInsets.zero,
                      onOpened: () {
                        if (mounted) setState(() => _menuOpen = true);
                      },
                      onCanceled: () {
                        if (mounted) setState(() => _menuOpen = false);
                      },
                      onSelected: (value) {
                        if (mounted) setState(() => _menuOpen = false);
                        if (value == "rename") widget.onRename();
                        if (value == "delete") widget.onDelete();
                      },
                      itemBuilder: (ctx) => const [
                        PopupMenuItem(value: "rename", child: Text("Rename")),
                        PopupMenuItem(value: "delete", child: Text("Delete")),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarConversationTileSelect extends StatefulWidget {
  final Conversation conversation;
  final bool isSelected;
  final VoidCallback onToggle;

  const _SidebarConversationTileSelect({
    required this.conversation,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  State<_SidebarConversationTileSelect> createState() => _SidebarConversationTileSelectState();
}

class _SidebarConversationTileSelectState extends State<_SidebarConversationTileSelect> {
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
          decoration: BoxDecoration(
            color: widget.isSelected ? AppTheme.bgSecondary : (_hover ? AppTheme.bgSecondary : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: widget.isSelected ? AppTheme.accent : Colors.transparent,
                    border: Border.all(color: AppTheme.accent),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: widget.isSelected ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    alignment: AlignmentGeometry.centerLeft,
                    height: 42,
                    child: Text(
                      widget.conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.normal,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
