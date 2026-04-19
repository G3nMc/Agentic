import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/api_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/conversation.dart';
import '../../data/models/message.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/local_server_config_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/agent_credentials_repository.dart';
import '../../services/huggingface_service.dart';
import '../../services/llm_service.dart';
import '../../services/local_server_manager.dart';
import '../../services/orchestrator_manager.dart';
import '../../statemanagement/method_data.dart';
import '../../statemanagement/method_listener.dart';
import '../../statemanagement/state_manager.dart';
import 'chat_input.dart';
import 'message_bubble.dart';
import 'model_switcher.dart';
import 'orchestrator_log_panel.dart';
import 'quick_server_panel.dart';
import 'sidebar.dart';

class ChatView extends StatefulWidget {
  // Null = empty state (no conversation opened yet).
  final String? conversationId;

  const ChatView({super.key, this.conversationId});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends StateManager<ChatView> {
  // In-memory full history for the current chat session.
  // This is what gets sent to HF on every send() call, just like HF.html.
  final List<ChatMessage> _messages = [];

  Conversation? _conversation;
  bool _loading = false;
  bool _sending = false;
  String? _sendError;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadConversation();
  }

  @override
  void onMethodListener(MethodData methodData) {
    switch (methodData.methodName) {
      case "modelChanged":
        final newModelId = methodData.methodParams?["modelId"] as String?;
        if (newModelId != null && _conversation != null) {
          _conversation = _conversation!.copyWith(modelId: newModelId);
          ConversationRepository.instance.updateModel(_conversation!.id, newModelId);
        }
        break;
      case "conversationUpdated":
        _loadConversation();
        break;
    }
  }

  Future<void> _loadConversation() async {
    final id = widget.conversationId;
    if (id == null) {
      setState(() {
        _conversation = null;
        _messages.clear();
        _loading = false;
      });
      return;
    }

    setState(() => _loading = true);
    final conv = await ConversationRepository.instance.getById(id);
    final msgs = await MessageRepository.instance.listByConversation(id);
    if (!mounted) return;

    setState(() {
      _conversation = conv;
      _messages
        ..clear()
        ..addAll(msgs);
      _loading = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  Future<void> _sendMessage(String text) async {
    if (_sending) return;
    final conv = _conversation;
    if (conv == null) return;

    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // Read settings and credentials.
    final backend = await BackendSettingsRepository.instance.getActiveBackend();

    // Get HF token from credentials
    final agentCreds = await AgentCredentialsRepository.instance.getCredentials();
    final token = agentCreds?.hfToken ?? await SettingsRepository.instance.getHfToken();

    final serverUrl = await BackendSettingsRepository.instance.getLocalServerUrl();
    final ollamaBaseUrl = await BackendSettingsRepository.instance.getOllamaBaseUrl();
    final ollamaModel = await BackendSettingsRepository.instance.getOllamaModel();
    final ollamaPythonBridgeUrl =
        await BackendSettingsRepository.instance.getOllamaPythonBridgeUrl();

    // Validate based on selected backend.
    if (backend == LlmBackend.huggingFace || backend == LlmBackend.orchestrator) {
      if (token == null || token.trim().isEmpty) {
        setState(() => _sendError = "Set your Hugging Face token in Settings first.");
        return;
      }
    } else if (backend == LlmBackend.local) {
      if (serverUrl == null || serverUrl.trim().isEmpty) {
        setState(() => _sendError = "Configure local server URL in Settings first.");
        return;
      }
    } else if (backend == LlmBackend.ollama ||
        backend == LlmBackend.ollamaPython ||
        backend == LlmBackend.ollamaOrchestrator) {
      final resolvedModel =
          (conv.modelId != null && conv.modelId!.trim().isNotEmpty)
              ? conv.modelId!
              : ollamaModel;
      if (resolvedModel == null || resolvedModel.trim().isEmpty) {
        setState(() => _sendError =
            "Select an Ollama model in Settings before sending a message.");
        return;
      }
    }

    final modelId = switch (backend) {
      LlmBackend.ollama ||
      LlmBackend.ollamaPython ||
      LlmBackend.ollamaOrchestrator =>
        (conv.modelId != null && conv.modelId!.trim().isNotEmpty)
            ? conv.modelId!
            : (ollamaModel ?? ''),
      _ => conv.modelId ?? ApiConstants.defaultModelId,
    };

    // Persist and append user message.
    final now = DateTime.now().millisecondsSinceEpoch;
    final userMsg = ChatMessage(
      id: const Uuid().v4(),
      conversationId: conv.id,
      role: MessageRole.user,
      content: trimmed,
      createdAt: now,
    );
    await MessageRepository.instance.insert(userMsg);
    await ConversationRepository.instance.touch(conv.id);

    setState(() {
      _messages.add(userMsg);
      _sending = true;
      _sendError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    // If this is the first message of a "New chat", use it as the title.
    if (conv.title == "New chat") {
      final newTitle = _autoTitleFrom(trimmed);
      await ConversationRepository.instance.updateTitle(conv.id, newTitle);
      _conversation = conv.copyWith(title: newTitle);
      await MethodListener<Sidebar>().callMethod("refreshConversations");
    }

    // Full conversation history sent to the model every call.
    final history = List<ChatMessage>.unmodifiable(_messages);

    try {
      final reply = await LlmService.instance.sendChat(
        backend: backend,
        token: token ?? "",
        modelId: modelId,
        history: history,
        conversationId: conv.id,
        localServerUrl: serverUrl,
        ollamaBaseUrl: ollamaBaseUrl,
        ollamaModelId: modelId,
        ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
      );

      final assistantMsg = ChatMessage(
        id: const Uuid().v4(),
        conversationId: conv.id,
        role: MessageRole.assistant,
        content: reply,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      await MessageRepository.instance.insert(assistantMsg);
      await ConversationRepository.instance.touch(conv.id);

      if (!mounted) return;
      setState(() {
        _messages.add(assistantMsg);
        _sending = false;
      });
      await MethodListener<Sidebar>().callMethod("refreshConversations");
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } on HuggingFaceException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = e.toString();
      });
    }
  }

  String _autoTitleFrom(String firstMessage) {
    final cleaned = firstMessage.replaceAll(RegExp(r"\s+"), " ").trim();
    if (cleaned.length <= 40) return cleaned;
    return "${cleaned.substring(0, 40)}...";
  }

  Future<void> _editChatTitle(Conversation conv) async {
    final controller = TextEditingController(text: conv.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Edit chat title"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: "Chat title"),
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
    if (newTitle == null || newTitle.isEmpty || newTitle == conv.title) return;

    await ConversationRepository.instance.updateTitle(conv.id, newTitle);
    _conversation = conv.copyWith(title: newTitle);
    setState(() {});
    await MethodListener<Sidebar>().callMethod("refreshConversations");
  }

  @override
  Widget build(BuildContext context) {
    if (widget.conversationId == null) {
      return _buildEmptyState();
    }
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_conversation == null) {
      return const Center(
        child: Text(
          "Conversation not found.",
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }

    return FutureBuilder<LlmBackend>(
      future: BackendSettingsRepository.instance.getActiveBackend(),
      builder: (ctx, backendSnapshot) {
        final backend = backendSnapshot.data;
        final showServerPanel = backend == LlmBackend.local;
        final showOrchestratorLog = backend == LlmBackend.orchestrator ||
            backend == LlmBackend.ollamaOrchestrator ||
            backend == LlmBackend.groqOrchestrator;

        return Column(
          children: [
            _buildHeader(_conversation!),
            if (showServerPanel)
              QuickServerPanel(
                modelId: _conversation!.modelId ?? ApiConstants.defaultModelId,
                onServerStatusChanged: () => setState(() {}),
              ),
            Expanded(child: _buildMessagesList()),
            if (_sendError != null) _buildErrorBar(),
            if (showOrchestratorLog) const OrchestratorLogPanel(),
            ChatInput(
              enabled: !_sending,
              sending: _sending,
              onSend: _sendMessage,
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(Conversation conv) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border)),
        color: AppTheme.bgPrimary,
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => _editChatTitle(conv),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  conv.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          ModelSwitcher(
            selectedModelId: conv.modelId ?? ApiConstants.defaultModelId,
            onChanged: (newId) {
              MethodListener<ChatView>().callMethod(
                "modelChanged",
                params: {"modelId": newId},
              );
            },
          ),
          const SizedBox(width: 12),
          // Orchestrator button (always visible)
          IconButton(
            tooltip: OrchestratorManager.instance.isRunning
                ? "🤖 Orchestrator active"
                : "🤖 Start orchestrator",
            icon: Icon(
              OrchestratorManager.instance.isRunning
                  ? Icons.smart_toy
                  : Icons.smart_toy_outlined,
              size: 16,
              color: OrchestratorManager.instance.isRunning
                  ? Colors.green
                  : AppTheme.textSecondary,
            ),
            onPressed: OrchestratorManager.instance.isRunning
                ? null
                : () => _startOrchestrator(),
          ),
          const SizedBox(width: 12),
          // Local server button (only for local backend)
          FutureBuilder<LlmBackend>(
            future: BackendSettingsRepository.instance.getActiveBackend(),
            builder: (ctx, backendSnapshot) {
              if (backendSnapshot.data != LlmBackend.local) {
                return const SizedBox.shrink();
              }
              final modelId = conv.modelId ?? ApiConstants.defaultModelId;
              final isRunning = LocalServerManager.instance.isServerRunning(modelId);
              return IconButton(
                tooltip: isRunning ? "Server running" : "Start local server",
                icon: Icon(
                  isRunning ? Icons.cloud_done : Icons.cloud_upload_outlined,
                  size: 16,
                  color: isRunning ? Colors.green : AppTheme.textSecondary,
                ),
                onPressed: isRunning ? null : () => _startLocalServer(modelId),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _startLocalServer(String modelId) async {
    try {
      final config = await LocalServerConfigRepository.instance.getByModelId(modelId);
      if (config == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                "No configuration found. Configure the server in Settings > Model > Configure Local Server"),
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Starting server..."),
          duration: Duration(seconds: 1),
        ),
      );

      final serverUrl = await LocalServerManager.instance.startServer(config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("✓ Server running at $serverUrl"),
          backgroundColor: Colors.green[700],
        ),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Error: $e"),
          backgroundColor: AppTheme.danger,
        ),
      );
    }
  }

  Future<void> _startOrchestrator() async {
    return _startOrchestratorForActiveBackend();
  }

  Future<void> _startOrchestratorForActiveBackend() async {
    try {
      final backend = await BackendSettingsRepository.instance.getActiveBackend();
      final ollamaModel = await BackendSettingsRepository.instance.getOllamaModel();
      final ollamaBaseUrl =
          await BackendSettingsRepository.instance.getOllamaBaseUrl();

      String? token;
      String? groqApiKey;
      OrchestratorBackend desiredBackend;
      String? modelId;

      if (backend == LlmBackend.ollamaOrchestrator) {
        desiredBackend = OrchestratorBackend.ollama;
        modelId = ollamaModel;
        if (modelId == null || modelId.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Select an Ollama model in Settings first"),
            ),
          );
          return;
        }
      } else if (backend == LlmBackend.groqOrchestrator) {
        desiredBackend = OrchestratorBackend.groq;
        groqApiKey = await BackendSettingsRepository.instance.getGroqApiKey();
        modelId = await BackendSettingsRepository.instance.getGroqModel();
        if (groqApiKey == null || groqApiKey.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Configure Groq API key in Settings first"),
            ),
          );
          return;
        }
      } else {
        desiredBackend = OrchestratorBackend.huggingface;
        final creds = await AgentCredentialsRepository.instance.getCredentials();
        token = creds?.hfToken;
        modelId = _conversation?.modelId;
        if (token == null || token.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Configure HF token in Settings first"),
            ),
          );
          return;
        }
      }

      if (OrchestratorManager.instance.isRunning &&
          OrchestratorManager.instance.currentBackend != desiredBackend) {
        await OrchestratorManager.instance.stop();
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            desiredBackend == OrchestratorBackend.ollama
                ? "Starting Ollama orchestrator..."
                : desiredBackend == OrchestratorBackend.groq
                    ? "Starting Groq orchestrator..."
                    : "Starting orchestrator...",
          ),
          duration: const Duration(seconds: 1),
        ),
      );

      final started = await OrchestratorManager.instance.start(
        hfToken: token,
        modelId: modelId,
        backend: desiredBackend,
        ollamaBaseUrl: ollamaBaseUrl,
        groqApiKey: groqApiKey,
      );

      if (!mounted) return;

      if (started) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (desiredBackend) {
              OrchestratorBackend.ollama => "Ollama orchestrator active",
              OrchestratorBackend.groq => "Groq orchestrator active",
              _ => "Orchestrator active",
            }),
            backgroundColor: const Color.fromARGB(255, 76, 175, 80),
          ),
        );
        setState(() {});
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (desiredBackend) {
              OrchestratorBackend.ollama => "Failed to start Ollama orchestrator",
              OrchestratorBackend.groq => "Failed to start Groq orchestrator",
              _ => "Failed to start orchestrator",
            }),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
      return;

      /*
      // Get HF token from credentials database
      final creds = await AgentCredentialsRepository.instance.getCredentials();
      final token = creds?.hfToken;

      if (token == null || token.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Configure HF token in Settings first"),
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("🤖 Starting orchestrator..."),
          duration: Duration(seconds: 1),
        ),
      );

      final started = await OrchestratorManager.instance.start(
        hfToken: token,
        modelId: _conversation?.modelId,
      );

      if (!mounted) return;

      if (started) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✓ Orchestrator active"),
            backgroundColor: Color.fromARGB(255, 76, 175, 80),
          ),
        );
        setState(() {});
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Failed to start orchestrator"),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
      */
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Error: $e"),
          backgroundColor: AppTheme.danger,
        ),
      );
    }
  }

  Widget _buildMessagesList() {
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Start the conversation",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                "Model: ${_conversation?.modelId ?? ApiConstants.defaultModelId}",
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      itemCount: _messages.length + (_sending ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (_sending && i == _messages.length) {
          return const _TypingIndicator();
        }
        final m = _messages[i];
        return MessageBubble(message: m);
      },
    );
  }

  Widget _buildErrorBar() {
    return Container(
      width: double.infinity,
      color: AppTheme.danger.withOpacity(0.08),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppTheme.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _sendError ?? "",
              style: const TextStyle(color: AppTheme.danger, fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _sendError ?? ""));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Error copied to clipboard"),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
            color: AppTheme.danger,
            splashRadius: 14,
            tooltip: "Copy error",
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => _sendError = null),
            color: AppTheme.danger,
            splashRadius: 14,
            tooltip: "Dismiss",
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "HF Chat",
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "Start a new chat from the sidebar.",
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text("New chat"),
            onPressed: () {
              MethodListener<Sidebar>().callMethod("refreshConversations");
              // Tell the Sidebar to create a new chat through its own flow is
              // not direct; instead we just let the user click New chat there.
              // The button label already hints at it.
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const SizedBox(width: 10),
          AnimatedBuilder(
            animation: _c,
            builder: (_, __) {
              return Row(
                children: List.generate(3, (i) {
                  final phase = (_c.value + i * 0.2) % 1.0;
                  final opacity = 0.3 + 0.7 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Opacity(
                      opacity: opacity.clamp(0.2, 1.0),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: AppTheme.textMuted,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                }),
              );
            },
          ),
          const SizedBox(width: 10),
          const Text(
            "Thinking...",
            style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
