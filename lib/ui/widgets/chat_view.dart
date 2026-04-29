import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/conversation.dart';
import '../../data/models/message.dart';
import '../../data/repositories/agent_credentials_repository.dart';
import '../../data/repositories/agent_role_settings_repository.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/local_server_config_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/settings_repository.dart';
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
import 'openrouter_usage_badge.dart';
import 'orchestrator_log_panel.dart';
import 'quick_server_panel.dart';
import 'workflow_breadcrumb.dart';
import 'sidebar.dart';
import '../screens/home_screen.dart';

class ChatView extends StatefulWidget {
  // Null = empty state (no conversation opened yet).
  final String? conversationId;

  const ChatView({super.key, this.conversationId});

  @override
  State<ChatView> createState() => _ChatViewState();
}

/// Lightweight single-use token that lets the UI cancel an in-flight request.
/// The underlying HTTP call cannot be aborted mid-flight, but its result is
/// discarded and the UI is immediately unblocked.
class _CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class _ChatViewState extends StateManager<ChatView> with WidgetsBindingObserver {
  // In-memory full history for the current chat session.
  // This is what gets sent to HF on every send() call, just like HF.html.
  final List<ChatMessage> _messages = [];

  Conversation? _conversation;
  bool _loading = false;
  bool _sending = false;
  String? _sendError;
  double _currentScroll = 0.0;

  /// Active backend — loaded once and cached so build() never needs a
  /// FutureBuilder (which tears down child widgets on every setState).
  LlmBackend? _activeBackend;

  /// Whether the OrchestratorLogPanel is currently expanded under the input.
  /// Toggled by the log button in [ChatInput] and auto-set to true when the
  /// orchestrator successfully starts.
  bool _logVisible = false;

  /// Token for the currently in-flight send. Non-null only while [_sending].
  _CancelToken? _currentCancel;

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadConversation();
    _refreshActiveBackend();

    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      setState(() {
        _currentScroll = _scrollController.offset;
      });
    });
  }

  // @override
  // void initState() {
  //   super.initState();
  //   WidgetsBinding.instance.addObserver(this);
  //   _loadConversation();
  //   _refreshActiveBackend();
  // }

  @override
  void didUpdateWidget(ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _loadConversation();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-read backend when app comes back to foreground (user may have
    // changed it in Settings).
    if (state == AppLifecycleState.resumed) _refreshActiveBackend();
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
      case "backendChanged":
        _refreshActiveBackend();
        break;
    }
  }

  Future<void> _refreshActiveBackend() async {
    final backend = await BackendSettingsRepository.instance.getActiveBackend();
    if (!mounted) return;
    setState(() => _activeBackend = backend);
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

  /// Immediately cancels the in-flight generation and resets the UI.
  void _stopGeneration() {
    _currentCancel?.cancel();
    _currentCancel = null;
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _sendMessage(String text) async {
    if (_sending) return;

    final conv = _conversation;
    if (conv == null) return;

    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final safeText = trimmed.replaceAll('\u0000', '').replaceAll(RegExp(r'[\uD800-\uDFFF]'), '');

    final backend = await BackendSettingsRepository.instance.getActiveBackend();

    if (mounted && _activeBackend != backend) {
      setState(() => _activeBackend = backend);
    }

    final agentCreds = await AgentCredentialsRepository.instance.getCredentials();

    final token = agentCreds?.hfToken ?? await SettingsRepository.instance.getHfToken();

    final serverUrl = await BackendSettingsRepository.instance.getLocalServerUrl();

    final ollamaBaseUrl = await BackendSettingsRepository.instance.getOllamaBaseUrl();

    final ollamaModel = await BackendSettingsRepository.instance.getOllamaModel();

    final openRouterApiKey = await BackendSettingsRepository.instance.getOpenRouterApiKey();

    final openRouterModel = await BackendSettingsRepository.instance.getOpenRouterModel();

    final ollamaPythonBridgeUrl = await BackendSettingsRepository.instance.getOllamaPythonBridgeUrl();

    if (backend == LlmBackend.huggingFace || backend == LlmBackend.orchestrator) {
      if (token == null || token.trim().isEmpty) {
        setState(() {
          _sendError = "Set your Hugging Face token in Settings first.";
        });
        return;
      }
    } else if (backend == LlmBackend.local) {
      if (serverUrl == null || serverUrl.trim().isEmpty) {
        setState(() {
          _sendError = "Configure local server URL in Settings first.";
        });
        return;
      }
    } else if (backend == LlmBackend.ollama || backend == LlmBackend.ollamaPython || backend == LlmBackend.ollamaOrchestrator) {
      final resolvedModel = (conv.modelId != null && conv.modelId!.trim().isNotEmpty) ? conv.modelId! : ollamaModel;

      if (resolvedModel == null || resolvedModel.trim().isEmpty) {
        setState(() {
          _sendError = "Select an Ollama model in Settings before sending a message.";
        });
        return;
      }
    } else if (backend == LlmBackend.openRouter) {
      if (openRouterApiKey == null || openRouterApiKey.trim().isEmpty) {
        setState(() {
          _sendError = "Set your OpenRouter API key in Settings first.";
        });
        return;
      }

      final resolvedModel = resolveOpenRouterModel(
        conv.modelId ?? '',
        openRouterModel ?? '',
      );

      if (resolvedModel.trim().isEmpty) {
        setState(() {
          _sendError = "Select an OpenRouter model in Settings before sending a message.";
        });
        return;
      }
    }

    String? geminiModel;
    if (backend == LlmBackend.geminiOrchestrator) {
      geminiModel = await BackendSettingsRepository.instance.getGeminiModel();
    }

    final modelId = switch (backend) {
      LlmBackend.ollama || LlmBackend.ollamaPython || LlmBackend.ollamaOrchestrator => (conv.modelId != null && conv.modelId!.trim().isNotEmpty) ? conv.modelId! : (ollamaModel ?? ''),
      LlmBackend.openRouter => resolveOpenRouterModel(
          conv.modelId ?? '',
          openRouterModel ?? '',
        ),
      LlmBackend.geminiOrchestrator => (conv.modelId != null && conv.modelId!.startsWith('gemini')) ? conv.modelId! : (geminiModel ?? BackendSettingsRepository.defaultGeminiModel),
      _ => conv.modelId ?? '',
    };

    final now = DateTime.now().millisecondsSinceEpoch;

    final userMsg = ChatMessage(
      id: const Uuid().v4(),
      conversationId: conv.id,
      role: MessageRole.user,
      content: safeText,
      createdAt: now,
    );

    await MessageRepository.instance.insert(userMsg);
    await ConversationRepository.instance.touch(conv.id);

    final cancelToken = _CancelToken();
    _currentCancel = cancelToken;

    setState(() {
      _messages.add(userMsg);
      _sending = true;
      _sendError = null;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
    });

    if (conv.title == "New chat") {
      final newTitle = _autoTitleFrom(safeText);
      await ConversationRepository.instance.updateTitle(
        conv.id,
        newTitle,
      );

      _conversation = conv.copyWith(title: newTitle);
      await MethodListener<Sidebar>().callMethod("refreshConversations");
    }

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

      if (cancelToken.isCancelled) return;

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
        _currentCancel = null;
      });

      await MethodListener<Sidebar>().callMethod("refreshConversations");

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    } on HuggingFaceException catch (e) {
      if (cancelToken.isCancelled || !mounted) return;

      setState(() {
        _sending = false;
        _currentCancel = null;
        _sendError = e.message;
      });
    } catch (e) {
      if (cancelToken.isCancelled || !mounted) return;

      setState(() {
        _sending = false;
        _currentCancel = null;
        _sendError = e.toString();
      });
    }
  }

  // Future<void> _sendMessage(String text) async {
  //   if (_sending) return;
  //   final conv = _conversation;
  //   if (conv == null) return;
  //
  //   final trimmed = text.trim();
  //   if (trimmed.isEmpty) return;
  //
  //   // Read settings and credentials.
  //   final backend = await BackendSettingsRepository.instance.getActiveBackend();
  //   // Keep the cached backend in sync so panels (orchestrator log, local
  //   // server) show/hide correctly even when the user changed backends in
  //   // Settings and navigated back without triggering a lifecycle event.
  //   if (mounted && _activeBackend != backend) {
  //     setState(() => _activeBackend = backend);
  //   }
  //
  //   // Get HF token from credentials
  //   final agentCreds = await AgentCredentialsRepository.instance.getCredentials();
  //   final token = agentCreds?.hfToken ?? await SettingsRepository.instance.getHfToken();
  //
  //   final serverUrl = await BackendSettingsRepository.instance.getLocalServerUrl();
  //   final ollamaBaseUrl = await BackendSettingsRepository.instance.getOllamaBaseUrl();
  //   final ollamaModel = await BackendSettingsRepository.instance.getOllamaModel();
  //   final openRouterApiKey = await BackendSettingsRepository.instance.getOpenRouterApiKey();
  //   final openRouterModel = await BackendSettingsRepository.instance.getOpenRouterModel();
  //   final ollamaPythonBridgeUrl = await BackendSettingsRepository.instance.getOllamaPythonBridgeUrl();
  //
  //   // Validate based on selected backend.
  //   if (backend == LlmBackend.huggingFace || backend == LlmBackend.orchestrator) {
  //     if (token == null || token.trim().isEmpty) {
  //       setState(() => _sendError = "Set your Hugging Face token in Settings first.");
  //       return;
  //     }
  //   } else if (backend == LlmBackend.local) {
  //     if (serverUrl == null || serverUrl.trim().isEmpty) {
  //       setState(() => _sendError = "Configure local server URL in Settings first.");
  //       return;
  //     }
  //   } else if (backend == LlmBackend.ollama || backend == LlmBackend.ollamaPython || backend == LlmBackend.ollamaOrchestrator) {
  //     final resolvedModel = (conv.modelId != null && conv.modelId!.trim().isNotEmpty) ? conv.modelId! : ollamaModel;
  //     if (resolvedModel == null || resolvedModel.trim().isEmpty) {
  //       setState(() => _sendError = "Select an Ollama model in Settings before sending a message.");
  //       return;
  //     }
  //   } else if (backend == LlmBackend.openRouter) {
  //     if (openRouterApiKey == null || openRouterApiKey.trim().isEmpty) {
  //       setState(() => _sendError = "Set your OpenRouter API key in Settings first.");
  //       return;
  //     }
  //     final resolvedModel = resolveOpenRouterModel(
  //       conv.modelId ?? '',
  //       openRouterModel ?? '',
  //     );
  //     if (resolvedModel.trim().isEmpty) {
  //       setState(() => _sendError = "Select an OpenRouter model in Settings before sending a message.");
  //       return;
  //     }
  //   }
  //
  //   String? geminiModel;
  //   if (backend == LlmBackend.geminiOrchestrator) {
  //     geminiModel = await BackendSettingsRepository.instance.getGeminiModel();
  //   }
  //
  //   final modelId = switch (backend) {
  //     LlmBackend.ollama || LlmBackend.ollamaPython || LlmBackend.ollamaOrchestrator => (conv.modelId != null && conv.modelId!.trim().isNotEmpty) ? conv.modelId! : (ollamaModel ?? ''),
  //     LlmBackend.openRouter => resolveOpenRouterModel(conv.modelId ?? '', openRouterModel ?? ''),
  //     LlmBackend.geminiOrchestrator => (conv.modelId != null && conv.modelId!.startsWith('gemini')) ? conv.modelId! : (geminiModel ?? BackendSettingsRepository.defaultGeminiModel),
  //     _ => conv.modelId ?? '',
  //   };
  //
  //   // Persist and append user message.
  //   final now = DateTime.now().millisecondsSinceEpoch;
  //   final userMsg = ChatMessage(
  //     id: const Uuid().v4(),
  //     conversationId: conv.id,
  //     role: MessageRole.user,
  //     content: trimmed,
  //     createdAt: now,
  //   );
  //   await MessageRepository.instance.insert(userMsg);
  //   await ConversationRepository.instance.touch(conv.id);
  //
  //   final cancelToken = _CancelToken();
  //   _currentCancel = cancelToken;
  //   setState(() {
  //     _messages.add(userMsg);
  //     _sending = true;
  //     _sendError = null;
  //   });
  //   WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  //
  //   // If this is the first message of a "New chat", use it as the title.
  //   if (conv.title == "New chat") {
  //     final newTitle = _autoTitleFrom(trimmed);
  //     await ConversationRepository.instance.updateTitle(conv.id, newTitle);
  //     _conversation = conv.copyWith(title: newTitle);
  //     await MethodListener<Sidebar>().callMethod("refreshConversations");
  //   }
  //
  //   // Full conversation history sent to the model every call.
  //   final history = List<ChatMessage>.unmodifiable(_messages);
  //
  //   try {
  //     final reply = await LlmService.instance.sendChat(
  //       backend: backend,
  //       token: token ?? "",
  //       modelId: modelId,
  //       history: history,
  //       conversationId: conv.id,
  //       localServerUrl: serverUrl,
  //       ollamaBaseUrl: ollamaBaseUrl,
  //       ollamaModelId: modelId,
  //       ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
  //     );
  //
  //     // Discard result if the user stopped generation while we were waiting.
  //     if (cancelToken.isCancelled) return;
  //
  //     final assistantMsg = ChatMessage(
  //       id: const Uuid().v4(),
  //       conversationId: conv.id,
  //       role: MessageRole.assistant,
  //       content: reply,
  //       createdAt: DateTime.now().millisecondsSinceEpoch,
  //     );
  //     await MessageRepository.instance.insert(assistantMsg);
  //     await ConversationRepository.instance.touch(conv.id);
  //
  //     if (!mounted) return;
  //     setState(() {
  //       _messages.add(assistantMsg);
  //       _sending = false;
  //       _currentCancel = null;
  //     });
  //     await MethodListener<Sidebar>().callMethod("refreshConversations");
  //     WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  //   } on HuggingFaceException catch (e) {
  //     if (cancelToken.isCancelled || !mounted) return;
  //     setState(() {
  //       _sending = false;
  //       _currentCancel = null;
  //       _sendError = e.message;
  //     });
  //   } catch (e) {
  //     if (cancelToken.isCancelled || !mounted) return;
  //     setState(() {
  //       _sending = false;
  //       _currentCancel = null;
  //       _sendError = e.toString();
  //     });
  //   }
  // }

  /// Handles the "Resend" action on a user message bubble.
  ///
  /// Removes every entry that comes after the selected message (both user
  /// prompts and model replies), then re-sends the original request so the
  /// model generates a fresh response.
  Future<void> _handleResend(String messageId) async {
    if (_sending) return;

    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;

    // Nothing to truncate if the selected message is already the last entry.
    if (idx == _messages.length - 1) {
      // Still re-send it without truncation.
      _sendMessage(_messages[idx].content);
      return;
    }

    final conv = _conversation;
    if (conv == null) return;

    // Collect IDs of messages that will be removed so we can delete them from
    // the database. We delete from the end backwards to avoid index shifts.
    final idsToRemove = _messages.sublist(idx + 1).map((m) => m.id).toList();

    // Truncate the in-memory history up to (and including) the selected message.
    setState(() {
      _messages.removeRange(idx + 1, _messages.length);
      _sending = true;
      _sendError = null;
    });

    // Persist the truncation in the database.
    for (final id in idsToRemove) {
      await MessageRepository.instance.deleteById(id);
    }

    // Re-send the original user message — the UI is already updated; the
    // new assistant reply will be appended in _sendMessage once it arrives.
    final original = _messages[idx];
    await _sendMessage(original.content);
  }

  String _autoTitleFrom(String firstMessage) {
    final cleaned = firstMessage.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 40) return cleaned;
    return '${cleaned.substring(0, 40)}...';
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

    // Use the cached backend value so the widget tree is never torn down
    // on a setState() — FutureBuilder was previously doing that, which made
    // OrchestratorLogPanel lose its stream subscription on every repaint.
    final backend = _activeBackend;
    final showServerPanel = backend == LlmBackend.local;
    final showOrchestratorLog = backend == LlmBackend.orchestrator ||
        backend == LlmBackend.ollamaOrchestrator ||
        backend == LlmBackend.groqOrchestrator ||
        backend == LlmBackend.geminiOrchestrator ||
        backend == LlmBackend.openRouterOrchestrator ||
        backend == LlmBackend.githubOrchestrator;

    return Column(
      children: [
        _buildHeader(_conversation!),
        Expanded(child: _buildMessagesList()),
        if (_sendError != null) _buildErrorBar(),
        _buildScrollToBottomButton(),
        ChatInput(
          enabled: !_sending,
          sending: _sending,
          onSend: _sendMessage,
          onStop: _stopGeneration,
          showLogToggle: showOrchestratorLog,
          logVisible: _logVisible,
          onToggleLog: () => setState(() => _logVisible = !_logVisible),
          onProjectFolderChanged: _startOrchestrator,
          onDownload: _downloadChatAsJson,
          onNewChatFromJson: _newChatFromJson,
        ),
        if (showServerPanel)
          QuickServerPanel(
            modelId: _conversation!.modelId ?? '',
            onServerStatusChanged: () => setState(() {}),
          ),
        if (showOrchestratorLog && _logVisible) const OrchestratorLogPanel(),
      ],
    );
  }

  Widget _buildHeader(Conversation conv) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
          const OpenRouterUsageBadge(),
          const SizedBox(width: 8),
          ValueListenableBuilder<bool>(
            valueListenable:
                AgentRoleSettingsRepository.instance.enabledNotifier,
            builder: (ctx, multiAgent, _) {
              if (multiAgent) {
                // Multi-agent mode owns the per-role models in Settings,
                // so the per-conversation model picker is replaced by a
                // breadcrumb that shows the four roles + their models.
                return const WorkflowBreadcrumb();
              }
              return ModelSwitcher(
                selectedModelId: conv.modelId ?? '',
                onChanged: (newId) {
                  MethodListener<ChatView>().callMethod(
                    "modelChanged",
                    params: {"modelId": newId},
                  );
                },
              );
            },
          ),
          const SizedBox(width: 12),
          Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.accentDarkMarrone, width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: IconButton(
                tooltip: OrchestratorManager.instance.isRunning ? "Stop orchestrator" : "Start orchestrator",
                icon: Icon(
                  OrchestratorManager.instance.isRunning ? Icons.stop_outlined : Icons.play_arrow_outlined,
                  size: 20,
                  color: OrchestratorManager.instance.isRunning ? AppTheme.danger : AppTheme.textSecondary,
                ),
                onPressed: () => OrchestratorManager.instance.isRunning ? _stopOrchestrator() : _startOrchestrator(),
              )),
          const SizedBox(width: 12),
          // Local server button (only for local backend)
          if (_activeBackend == LlmBackend.local)
            Builder(
              builder: (ctx) {
                final modelId = conv.modelId ?? '';
                final isRunning = LocalServerManager.instance.isServerRunning(modelId);
                return IconButton(
                  tooltip: isRunning ? "Server running" : "Start local server",
                  icon: Icon(
                    isRunning ? Icons.cloud_done : Icons.cloud_upload_outlined,
                    size: 16,
                    color: isRunning ? AppTheme.accentMarrone : AppTheme.textSecondary,
                  ),
                  onPressed: isRunning ? null : () => _startLocalServer(modelId),
                );
              },
            ),

          // FutureBuilder<LlmBackend>(
          //   future: BackendSettingsRepository.instance.getActiveBackend(),
          //   builder: (ctx, backendSnapshot) {
          //     if (backendSnapshot.data != LlmBackend.local) {
          //       return const SizedBox.shrink();
          //     }
          //     final modelId = conv.modelId ?? '';
          //     final isRunning = LocalServerManager.instance.isServerRunning(modelId);
          //     return IconButton(
          //       tooltip: isRunning ? "Server running" : "Start local server",
          //       icon: Icon(
          //         isRunning ? Icons.cloud_done : Icons.cloud_upload_outlined,
          //         size: 16,
          //         color: isRunning ? AppTheme.accentMarrone : AppTheme.textSecondary,
          //       ),
          //       onPressed: isRunning ? null : () => _startLocalServer(modelId),
          //     );
          //   },
          // ),
        ],
      ),
    );
  }

  Future<void> _startLocalServer(String modelId) async {
    try {
      final config = await LocalServerConfigRepository.instance.getByModelId(modelId);

      if (!mounted) return;

      if (config == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("No configuration found. Configure the server in Settings > Model > Configure Local Server"),
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
          backgroundColor: AppTheme.accentMarrone,
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

  // Future<void> _startLocalServer(String modelId) async {
  //   try {
  //     final config = await LocalServerConfigRepository.instance.getByModelId(modelId);
  //     if (config == null) {
  //       if (!mounted) return;
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         const SnackBar(
  //           content: Text("No configuration found. Configure the server in Settings > Model > Configure Local Server"),
  //         ),
  //       );
  //       return;
  //     }
  //
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       const SnackBar(
  //         content: Text("Starting server..."),
  //         duration: Duration(seconds: 1),
  //       ),
  //     );
  //
  //     final serverUrl = await LocalServerManager.instance.startServer(config);
  //     if (!mounted) return;
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(
  //         content: Text("✓ Server running at $serverUrl"),
  //         backgroundColor: AppTheme.accentMarrone,
  //       ),
  //     );
  //     setState(() {});
  //   } catch (e) {
  //     if (!mounted) return;
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(
  //         content: Text("Error: $e"),
  //         backgroundColor: AppTheme.danger,
  //       ),
  //     );
  //   }
  // }

  Future<void> _startOrchestrator() async {
    return _startOrchestratorForActiveBackend();
  }

  Future<void> _downloadChatAsJson() async {
    final conv = _conversation;
    if (conv == null) return;

    final messages = await MessageRepository.instance.listByConversation(conv.id);

    // Build an AI-model-friendly format: OpenAI chat-completion shape.
    // The top-level object contains metadata and a "messages" array where
    // each entry has "role" and "content" — exactly what most LLM APIs expect.
    final jsonData = {
      "conversation": {
        "id": conv.id,
        "title": conv.title,
        "modelId": conv.modelId,
        "backend": conv.backend,
        "createdAt": conv.createdAt,
        "updatedAt": conv.updatedAt,
      },
      "messages": messages.map((msg) {
        final entry = <String, dynamic>{
          "role": msg.role.apiValue,
          "content": msg.content,
        };
        if (msg.agent != null) entry["agent"] = msg.agent;
        return entry;
      }).toList(),
    };

    final jsonString = const JsonEncoder.withIndent('  ').convert(jsonData);
    final safeName = conv.title.replaceAll(RegExp(r'[\/:*?"<>|]'), '_');

    try {
      // Prefer a save dialog on platforms that support it (desktop).
      String? savePath = await FilePicker.saveFile(
        dialogTitle: 'Save chat as JSON',
        fileName: '$safeName.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (savePath == null && mounted) {
        // User cancelled the save dialog.
        return;
      }

      // If saveFile returned null (mobile / web fallback), write to a
      // well-known directory so the user can retrieve it.
      if (savePath == null) {
        final dir = await getApplicationDocumentsDirectory();
        savePath = '${dir.path}${Platform.pathSeparator}$safeName.json';
      }

      final file = File(savePath);
      await file.writeAsString(jsonString, flush: true);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved to $savePath'),
          backgroundColor: AppTheme.accentMarrone,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save JSON: $e'),
          backgroundColor: AppTheme.danger,
        ),
      );
    }
  }

  Future<void> _newChatFromJson() async {
    final conv = _conversation;
    if (conv == null) return;

    final messages = await MessageRepository.instance.listByConversation(conv.id);

    // Build JSON like the download button, but we'll extract just messages
    final jsonData = {
      "messages": messages.map((msg) {
        final entry = <String, dynamic>{
          "role": msg.role.apiValue,
          "content": msg.content,
        };
        if (msg.agent != null) entry["agent"] = msg.agent;
        return entry;
      }).toList(),
    };

    // Create a new conversation with the same metadata (excluding "conversation" node)
    final newConv = Conversation(
      id: const Uuid().v4(),
      title: 'New chat from JSON',
      modelId: conv.modelId,
      backend: conv.backend,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await ConversationRepository.instance.insert(newConv);

    // Insert messages into the new conversation (only "messages" array, no "conversation" node)
    for (final msgData in jsonData['messages'] as List<dynamic>) {
      final msg = msgData as Map<String, dynamic>;
      final role = msg['role'] as String;
      final content = msg['content'] as String;
      final agent = msg['agent'] as String?;

      final chatMessage = ChatMessage(
        id: const Uuid().v4(),
        conversationId: newConv.id,
        role: MessageRole.fromString(role),
        content: content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        agent: agent,
      );

      await MessageRepository.instance.insert(chatMessage);
    }

    // Navigate to the new conversation
    if (!mounted) return;
    // Use MethodListener to notify Sidebar to refresh conversations
    final sidebarListener = MethodListener<Sidebar>();
    await sidebarListener.callMethod("refreshConversations");
    
    // Navigate to the new conversation via HomeScreen (which handles openConversation)
    final homeListener = MethodListener<HomeScreen>();
    homeListener.callMethod(
      "openConversation",
      params: {"conversationId": newConv.id},
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('New chat created from JSON context'),
        backgroundColor: AppTheme.accentMarrone,
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _stopOrchestrator() async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Stopping orchestrator..."),
          duration: Duration(seconds: 1),
        ),
      );
      await OrchestratorManager.instance.stop();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Orchestrator stopped")),
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

  Future<void> _startOrchestratorForActiveBackend() async {
    try {
      final backend = await BackendSettingsRepository.instance.getActiveBackend();
      final ollamaModel = await BackendSettingsRepository.instance.getOllamaModel();
      final ollamaBaseUrl = await BackendSettingsRepository.instance.getOllamaBaseUrl();

      if (!mounted) return;

      String? token;
      String? groqApiKey;
      OrchestratorBackend desiredBackend;
      String? modelId;

      if (backend == LlmBackend.ollamaOrchestrator) {
        desiredBackend = OrchestratorBackend.ollama;
        modelId = ollamaModel;

        if (modelId == null || modelId.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Select an Ollama model in Settings first")),
          );
          return;
        }
      } else if (backend == LlmBackend.groqOrchestrator) {
        desiredBackend = OrchestratorBackend.groq;

        groqApiKey = await BackendSettingsRepository.instance.getGroqApiKey();
        modelId = await BackendSettingsRepository.instance.getGroqModel();

        if (!mounted) return;

        if (groqApiKey == null || groqApiKey.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Configure Groq API key in Settings first")),
          );
          return;
        }
      } else {
        desiredBackend = OrchestratorBackend.huggingface;

        final creds = await AgentCredentialsRepository.instance.getCredentials();
        if (!mounted) return;

        token = creds?.hfToken;
        modelId = _conversation?.modelId;

        if (token == null || token.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Configure HF token in Settings first")),
          );
          return;
        }
      }

      // Stop existing orchestrator if backend changed
      if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend != desiredBackend) {
        await OrchestratorManager.instance.stop();
        if (!mounted) return;
      }

      // Start message
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
            content: Text(
              switch (desiredBackend) {
                OrchestratorBackend.ollama => "Ollama orchestrator active",
                OrchestratorBackend.groq => "Groq orchestrator active",
                _ => "Orchestrator active",
              },
            ),
            backgroundColor: const Color.fromARGB(255, 76, 175, 80),
          ),
        );
        setState(() => _logVisible = true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              switch (desiredBackend) {
                OrchestratorBackend.ollama => "Failed to start Ollama orchestrator",
                OrchestratorBackend.groq => "Failed to start Groq orchestrator",
                _ => "Failed to start orchestrator",
              },
            ),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
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

  // Future<void> _startOrchestratorForActiveBackend() async {
  //   try {
  //     final backend = await BackendSettingsRepository.instance.getActiveBackend();
  //     final ollamaModel = await BackendSettingsRepository.instance.getOllamaModel();
  //     final ollamaBaseUrl = await BackendSettingsRepository.instance.getOllamaBaseUrl();
  //
  //     String? token;
  //     String? groqApiKey;
  //     OrchestratorBackend desiredBackend;
  //     String? modelId;
  //
  //     if (backend == LlmBackend.ollamaOrchestrator) {
  //       desiredBackend = OrchestratorBackend.ollama;
  //       modelId = ollamaModel;
  //       if (modelId == null || modelId.isEmpty) {
  //         if (!mounted) return;
  //         ScaffoldMessenger.of(context).showSnackBar(
  //           const SnackBar(
  //             content: Text("Select an Ollama model in Settings first"),
  //           ),
  //         );
  //         return;
  //       }
  //     } else if (backend == LlmBackend.groqOrchestrator) {
  //       desiredBackend = OrchestratorBackend.groq;
  //       groqApiKey = await BackendSettingsRepository.instance.getGroqApiKey();
  //       modelId = await BackendSettingsRepository.instance.getGroqModel();
  //       if (groqApiKey == null || groqApiKey.isEmpty) {
  //         if (!mounted) return;
  //         ScaffoldMessenger.of(context).showSnackBar(
  //           const SnackBar(
  //             content: Text("Configure Groq API key in Settings first"),
  //           ),
  //         );
  //         return;
  //       }
  //     } else {
  //       desiredBackend = OrchestratorBackend.huggingface;
  //       final creds = await AgentCredentialsRepository.instance.getCredentials();
  //       token = creds?.hfToken;
  //       modelId = _conversation?.modelId;
  //       if (token == null || token.isEmpty) {
  //         if (!mounted) return;
  //         ScaffoldMessenger.of(context).showSnackBar(
  //           const SnackBar(
  //             content: Text("Configure HF token in Settings first"),
  //           ),
  //         );
  //         return;
  //       }
  //     }
  //
  //     if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend != desiredBackend) {
  //       await OrchestratorManager.instance.stop();
  //     }
  //
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(
  //         content: Text(
  //           desiredBackend == OrchestratorBackend.ollama
  //               ? "Starting Ollama orchestrator..."
  //               : desiredBackend == OrchestratorBackend.groq
  //                   ? "Starting Groq orchestrator..."
  //                   : "Starting orchestrator...",
  //         ),
  //         duration: const Duration(seconds: 1),
  //       ),
  //     );
  //
  //     final started = await OrchestratorManager.instance.start(
  //       hfToken: token,
  //       modelId: modelId,
  //       backend: desiredBackend,
  //       ollamaBaseUrl: ollamaBaseUrl,
  //       groqApiKey: groqApiKey,
  //     );
  //
  //     if (!mounted) return;
  //
  //     if (started) {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         SnackBar(
  //           content: Text(switch (desiredBackend) {
  //             OrchestratorBackend.ollama => "Ollama orchestrator active",
  //             OrchestratorBackend.groq => "Groq orchestrator active",
  //             _ => "Orchestrator active",
  //           }),
  //           backgroundColor: const Color.fromARGB(255, 76, 175, 80),
  //         ),
  //       );
  //       setState(() {});
  //     } else {
  //       ScaffoldMessenger.of(context).showSnackBar(
  //         SnackBar(
  //           content: Text(switch (desiredBackend) {
  //             OrchestratorBackend.ollama => "Failed to start Ollama orchestrator",
  //             OrchestratorBackend.groq => "Failed to start Groq orchestrator",
  //             _ => "Failed to start orchestrator",
  //           }),
  //           backgroundColor: AppTheme.danger,
  //         ),
  //       );
  //     }
  //     return;
  //   } catch (e) {
  //     if (!mounted) return;
  //     ScaffoldMessenger.of(context).showSnackBar(
  //       SnackBar(
  //         content: Text("Error: $e"),
  //         backgroundColor: AppTheme.danger,
  //       ),
  //     );
  //   }
  // }

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
                "Model: ${_conversation?.modelId ?? ''}",
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      itemCount: _messages.length + (_sending ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (_sending && i == _messages.length) {
          return const _TypingIndicator();
        }
        final m = _messages[i];
        return MessageBubble(
          message: m,
          // Show resend only on user bubbles and only when not already sending.
          onResend: (m.role == MessageRole.user && !_sending) ? () => _handleResend(m.id) : null,
        );
      },
    );
  }

  Widget _buildErrorBar() {
    return Container(
      width: double.infinity,
      color: AppTheme.danger.withAlpha(200),
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

  Widget _buildScrollToBottomButton() {
    if (!_scrollController.hasClients) {
      return const SizedBox.shrink();
    }

    final maxScroll = _scrollController.position.maxScrollExtent;
    final showButton = maxScroll > 0 && _currentScroll < maxScroll - 100;

    if (!showButton) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.only(left: 20),
      alignment: AlignmentGeometry.bottomCenter,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _scrollToBottom,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.accentDarkMarrone, width: 1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 30,
              color: AppTheme.accent,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Chat",
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Please use the '+' button in the sidebar to start a new chat")),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
            "Working...",
            style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
