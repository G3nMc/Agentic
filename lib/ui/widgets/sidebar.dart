import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/api_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/conversation.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/groq_service.dart';
import '../../services/llm_service.dart';
import '../../services/openrouter_service.dart';
import '../../services/orchestrator_manager.dart';
import '../../statemanagement/method_data.dart';
import '../../statemanagement/method_listener.dart';
import '../../statemanagement/state_manager.dart';
import '../screens/home_screen.dart';
import '../screens/settings_screen.dart';
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

  @override
  void initState() {
    super.initState();
    // _loadActiveBackend() also kicks off the first _loadConversations()
    // once the active backend is known, so the list is filtered correctly
    // from the start.
    _loadActiveBackend();
  }

  Future<void> _loadActiveBackend() async {
    final backend = await BackendSettingsRepository.instance.getActiveBackend();
    if (!mounted) return;
    setState(() => _activeBackend = backend);
    // Reload conversations with the correct filter now that the backend
    // is known (initState kicks off both in parallel).
    await _loadConversations();
  }

  Future<void> _onBackendChanged(LlmBackend v) async {
    if (v == _activeBackend) return;
    final messenger = ScaffoldMessenger.of(context);

    // If an orchestrator is running, stop it before switching.
    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }

    await BackendSettingsRepository.instance.setActiveBackend(v);
    if (!mounted) return;
    setState(() => _activeBackend = v);

    // Reload the conversation list so it only shows chats that belong
    // to the newly selected backend.
    await _loadConversations();

    // If the currently open chat doesn't belong to this backend anymore,
    // close it so the user isn't left looking at an orphaned conversation.
    if (widget.activeConversationId != null) {
      final stillVisible = _conversations.any((c) => c.id == widget.activeConversationId);
      if (!stillVisible && mounted) {
        await MethodListener<HomeScreen>().callMethod("closeActiveConversation");
      }
    }

    // Notify ChatView so it re-reads the active backend and repaints
    // panels (orchestrator log, local server) accordingly.
    await MethodListener<ChatView>().callMethod("backendChanged");

    messenger.showSnackBar(
      const SnackBar(
        content: Text("✓ Backend saved"),
        duration: Duration(milliseconds: 800),
      ),
    );
  }

  @override
  void onMethodListener(MethodData methodData) {
    switch (methodData.methodName) {
      case "refreshConversations":
        _loadConversations();
        break;
    }
  }

  Future<void> _loadConversations() async {
    print('[DEBUG] _loadConversations() called');
    final backend = _activeBackend ?? await BackendSettingsRepository.instance.getActiveBackend();
    final list = await ConversationRepository.instance.listByBackend(backend.name);
    print('[DEBUG] _loadConversations() got ${list.length} conversations for ${backend.name}');
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
      // For Groq backends use the saved Groq model so the new conversation
      // is initialised with the correct model ID from the start.
      LlmBackend.groq || LlmBackend.groqOrchestrator => await BackendSettingsRepository.instance.getGroqModel() ?? GroqService.fallbackModels.first,
      LlmBackend.openRouter || LlmBackend.openRouterOrchestrator => await BackendSettingsRepository.instance.getOpenRouterModel() ?? OpenRouterService.fallbackModels.first,
      _ => (await SettingsRepository.instance.getSelectedModelId()) ?? ApiConstants.defaultModelId,
    };

    final conversation = Conversation(
      id: id,
      title: "New chat",
      modelId: selectedModel,
      backend: backend.name,
      createdAt: now,
      updatedAt: now,
    );
    await ConversationRepository.instance.insert(conversation);
    await _loadConversations();

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
      // Immediately remove from local list — this updates the UI right now
      if (mounted) {
        setState(() {
          _conversations = _conversations.where((conv) => conv.id != c.id).toList();
        });
      }

      // Delete from database
      await ConversationRepository.instance.delete(c.id);

      // Close the active conversation if it was the one deleted
      if (widget.activeConversationId == c.id && mounted) {
        await MethodListener<HomeScreen>().callMethod("closeActiveConversation");
      }

      // Show confirmation
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✓ Conversation deleted"),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      // Rollback: reload from DB to restore correct state
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

  void _selectConversation(Conversation c) {
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header: app label + new chat button.
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 18, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 38),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.accentDarkMarrone),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<LlmBackend>(
                      isExpanded: true,
                      isDense: true,
                      value: _activeBackend,
                      hint: const Text(
                        "HF Chat",
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
                      // Only orchestrator-backed options are exposed —
                      // the rest don't route through orchestrator.py and
                      // are intentionally hidden.
                      items: const [
                        // DropdownMenuItem(
                        //   value: LlmBackend.huggingFace,
                        //   child: Text("Hugging Face (Direct)"),
                        // ),
                        DropdownMenuItem(
                          value: LlmBackend.orchestrator,
                          child: Text("HF + Orchestrator"),
                        ),
                        // DropdownMenuItem(
                        //   value: LlmBackend.ollama,
                        //   child: Text("Ollama (Direct)"),
                        // ),
                        DropdownMenuItem(
                          value: LlmBackend.ollamaOrchestrator,
                          child: Text("Ollama + Orchestrator"),
                        ),
                        // DropdownMenuItem(
                        //   value: LlmBackend.ollamaPython,
                        //   child: Text("Ollama (Python bridge)"),
                        // ),
                        // DropdownMenuItem(
                        //   value: LlmBackend.ollamaGenerate,
                        //   child: Text("Ollama /api/generate"),
                        // ),
                        // DropdownMenuItem(
                        //   value: LlmBackend.groq,
                        //   child: Text("Groq Cloud (Direct)"),
                        // ),
                        DropdownMenuItem(
                          value: LlmBackend.groqOrchestrator,
                          child: Text("Groq + Orchestrator"),
                        ),
                        DropdownMenuItem(
                          value: LlmBackend.geminiOrchestrator,
                          child: Text("Gemini + Orchestrator"),
                        ),
                        // DropdownMenuItem(
                        //   value: LlmBackend.openRouter,
                        //   child: Text("OpenRouter (Direct)"),
                        // ),
                        DropdownMenuItem(
                          value: LlmBackend.openRouterOrchestrator,
                          child: Text("OpenRouter + Orchestrator"),
                        ),
                        // DropdownMenuItem(
                        //   value: LlmBackend.local,
                        //   child: Text("Local Server (Python)"),
                        // ),
                      ],
                      onChanged: (v) {
                        if (v != null) _onBackendChanged(v);
                      },
                    ),
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
                side: const BorderSide(color: AppTheme.accentDarkMarrone),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 6, 12, 6),
          child: Text(
            "Recent",
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: AppTheme.textMuted,
            ),
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
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: _conversations.length,
                      itemBuilder: (ctx, i) {
                        final c = _conversations[i];
                        final isActive = c.id == widget.activeConversationId;
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

  // When the popup menu is open, the cursor moves off the tile into the
  // overlay, which fires `MouseRegion.onExit` → `_hover = false`. If we
  // relied purely on `_hover || isActive` to render the PopupMenuButton,
  // the button would unmount while the menu is open, which Flutter treats
  // as a cancel and closes the menu before the user can click "Delete".
  // Tracking `_menuOpen` pins the button in the tree for the menu's
  // lifetime, so the Rename / Delete actions fire for non-active tiles too.
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
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: widget.isActive ? AppTheme.bgSecondary : (_hover ? AppTheme.bgSecondary : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            // Fixed padding, never changes
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Expanded(
                    child: Container(
                  alignment: AlignmentGeometry.centerLeft,
                  constraints: const BoxConstraints(minHeight: 44),
                  decoration: BoxDecoration(color: widget.isActive ? AppTheme.bgSecondary : Colors.transparent),
                  child: Text(
                    widget.conversation.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: widget.isActive ? FontWeight.bold : FontWeight.normal,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                )),
                if (showActions)
                  PopupMenuButton<String>(
                    tooltip: "More",
                    icon: const Icon(Icons.more_horiz, size: 16, color: AppTheme.textSecondary),
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
              ],
            ),
          ),
        ),
      ),
    );
  }

// @override
// Widget build(BuildContext context) {
//   final showActions = _hover || widget.isActive || _menuOpen;
//   return MouseRegion(
//     onEnter: (_) => setState(() => _hover = true),
//     onExit: (_) => setState(() => _hover = false),
//     cursor: SystemMouseCursors.click,
//     child: GestureDetector(
//       onTap: widget.onTap,
//       child: Container(
//         margin: const EdgeInsets.symmetric(vertical: 2),
//         padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
//         decoration: BoxDecoration(
//           color: widget.isActive ? AppTheme.bgSecondary : (_hover ? AppTheme.bgSecondary : Colors.transparent),
//           borderRadius: BorderRadius.circular(8),
//         ),
//         child: Row(
//           children: [
//             Expanded(
//               child: Text(
//                 widget.conversation.title,
//                 maxLines: 1,
//                 overflow: TextOverflow.ellipsis,
//                 style: TextStyle(
//                   fontSize: 14,
//                   fontWeight: widget.isActive ? FontWeight.bold : FontWeight.normal,
//                   color: AppTheme.textPrimary,
//                 ),
//               ),
//             ),
//             if (showActions)
//               PopupMenuButton<String>(
//                 tooltip: "More",
//                 icon: const Icon(Icons.more_horiz, size: 16, color: AppTheme.textSecondary),
//                 splashRadius: 14,
//                 padding: EdgeInsets.zero,
//                 onOpened: () {
//                   if (mounted) setState(() => _menuOpen = true);
//                 },
//                 onCanceled: () {
//                   if (mounted) setState(() => _menuOpen = false);
//                 },
//                 onSelected: (value) {
//                   if (mounted) setState(() => _menuOpen = false);
//                   if (value == "rename") widget.onRename();
//                   if (value == "delete") widget.onDelete();
//                 },
//                 itemBuilder: (ctx) => const [
//                   PopupMenuItem(value: "rename", child: Text("Rename")),
//                   PopupMenuItem(value: "delete", child: Text("Delete")),
//                 ],
//               ),
//           ],
//         ),
//       ),
//     ),
//   );
// }
}
