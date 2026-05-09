import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/notification_helper.dart';
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
import '../screens/home_screen.dart';
import 'chat_input.dart';
import 'message_bubble.dart';
import 'model_switcher.dart';
import 'openrouter_usage_badge.dart';
import 'orchestrator_log_panel.dart';
import 'quick_server_panel.dart';
import 'resize_handle.dart';
import 'sidebar.dart';
import 'workflow_breadcrumb.dart';

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

  /// Current height of the orchestrator log panel when visible.
  double _logPanelHeight = 220.0;

  /// Token for the currently in-flight send. Non-null only while [_sending].
  _CancelToken? _currentCancel;

  final ScrollController _scrollController = ScrollController();

  /// Controller for the chat input. Owned here so we can push text into it
  /// when the user taps the edit icon on a message bubble.
  final TextEditingController _inputController = TextEditingController();

  /// ID of the message currently staged for edit. Set when the user taps the
  /// edit icon; cleared after the next send (or if it disappears from the
  /// list). When non-null, [_sendMessage] truncates the conversation at this
  /// message before appending the new one.
  String? _editingMessageId;

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

    // Entering an existing chat should always ensure the orchestrator is up
    // for orchestrator-backed modes so the next action is instant.
    await _startOrchestratorForActiveBackend(silent: true);

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  bool _isOrchestratorBackend(LlmBackend backend) {
    return backend == LlmBackend.orchestrator ||
        backend == LlmBackend.ollamaOrchestrator ||
        backend == LlmBackend.groqOrchestrator ||
        backend == LlmBackend.geminiOrchestrator ||
        backend == LlmBackend.openRouterOrchestrator ||
        backend == LlmBackend.githubOrchestrator;
  }

  OrchestratorBackend _desiredOrchestratorBackend(LlmBackend backend) {
    return switch (backend) {
      LlmBackend.ollamaOrchestrator => OrchestratorBackend.ollama,
      LlmBackend.groqOrchestrator => OrchestratorBackend.groq,
      LlmBackend.geminiOrchestrator => OrchestratorBackend.gemini,
      LlmBackend.openRouterOrchestrator => OrchestratorBackend.openrouter,
      LlmBackend.githubOrchestrator => OrchestratorBackend.github,
      _ => OrchestratorBackend.huggingface,
    };
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;
    _scrollController.animateTo(
      position.maxScrollExtent,
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

    // Only remove null bytes - preserve emoji and unicode for proper display
    // and markdown formatting. Sanitization for API calls happens in Python.
    final safeText = trimmed.replaceAll('\u0000', '');

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

    // If the user staged an edit, drop the original message and every turn
    // that came after it before recording the new (edited) user message.
    final pendingEditId = _editingMessageId;
    if (pendingEditId != null) {
      _editingMessageId = null;
      await _truncateForEdit(pendingEditId);
    }

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

    // Capture the moment the request is dispatched so we can measure
    // how long the assistant takes to reply.
    final sendStartMs = DateTime.now().millisecondsSinceEpoch;

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

    if (_isOrchestratorBackend(backend)) {
      await _startOrchestratorForActiveBackend(silent: true);
    }

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

      final responseTimeMs = DateTime.now().millisecondsSinceEpoch - sendStartMs;

      final assistantMsg = ChatMessage(
        id: const Uuid().v4(),
        conversationId: conv.id,
        role: MessageRole.assistant,
        content: _sanitizeAssistantReply(reply),
        createdAt: DateTime.now().millisecondsSinceEpoch,
        responseTimeMs: responseTimeMs,
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

    final backend = await BackendSettingsRepository.instance.getActiveBackend();
    if (_isOrchestratorBackend(backend)) {
      await _startOrchestratorForActiveBackend(silent: true);
    }

    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;

    final conv = _conversation;
    if (conv == null) return;

    // Capture the content before we drop the message from the list.
    final originalContent = _messages[idx].content;

    // Remove the selected user message *and* everything after it. _sendMessage
    // will re-insert the user message itself; if we left it in place we would
    // end up with two identical user turns in the history sent to the model
    // (which previously caused the assistant to reply with a terse "OK.").
    final idsToRemove = _messages.sublist(idx).map((m) => m.id).toList();

    setState(() {
      _messages.removeRange(idx, _messages.length);
      _sendError = null;
    });

    for (final id in idsToRemove) {
      await MessageRepository.instance.deleteById(id);
    }

    await _sendMessage(originalContent);
  }

  /// Handles the "Edit" action on a user message bubble.
  ///
  /// Loads the message content into the chat input and remembers which
  /// message was selected. The chat history stays intact — truncation is
  /// applied later in [_sendMessage], so the user can dismiss the edit
  /// (clear the input, navigate away) without losing previous turns.
  void _handleEdit(String messageId) {
    if (_sending) return;

    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;

    final originalContent = _messages[idx].content;

    setState(() {
      _editingMessageId = messageId;
      _sendError = null;
      _inputController.text = originalContent;
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
    });
  }

  /// Drops the staged edit target and everything after it from both the
  /// in-memory list and the database. Called from [_sendMessage] right
  /// before the new (edited) user turn is appended.
  Future<void> _truncateForEdit(String messageId) async {
    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;

    final idsToRemove = _messages.sublist(idx).map((m) => m.id).toList();

    setState(() {
      _messages.removeRange(idx, _messages.length);
    });

    for (final id in idsToRemove) {
      await MessageRepository.instance.deleteById(id);
    }
  }

  /// Handles the "Delete" action on a message bubble.
  ///
  /// Removes the selected message from the conversation history.
  Future<void> _handleDeleteMessage(String messageId) async {
    final idx = _messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;

    final conv = _conversation;
    if (conv == null) return;

    // Remove the message from the list
    setState(() {
      _messages.removeAt(idx);
      // If we were staging an edit on this message, drop the edit target.
      if (_editingMessageId == messageId) _editingMessageId = null;
    });

    // Remove the message from the database
    await MessageRepository.instance.deleteById(messageId);

    // Update the conversation's updated time
    await ConversationRepository.instance.touch(conv.id);

    // Refresh conversations in sidebar
    await MethodListener<Sidebar>().callMethod("refreshConversations");
  }

  String _autoTitleFrom(String firstMessage) {
    final cleaned = firstMessage.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 40) return cleaned;
    return '${cleaned.substring(0, 40)}...';
  }

  /// Defensive last-mile cleanup before persisting an assistant reply.
  /// Strips orchestrator wire-protocol artifacts (`__READY__` handshake,
  /// `{"response": "...", "trace": [...]}` envelope) that should normally be
  /// peeled off in OrchestratorManager but may slip through on edge cases
  /// (subprocess respawn, missing `__RESPONSE_END__`, legacy data path).
  String _sanitizeAssistantReply(String reply) {
    var text = reply;
    // Drop a stray leading handshake line.
    text = text.replaceFirst(RegExp(r'^\s*__READY__\s*\n?'), '');
    final trimmed = text.trim();
    if (trimmed.startsWith('{')) {
      try {
        final obj = jsonDecode(trimmed);
        if (obj is Map && obj['response'] is String) {
          return obj['response'] as String;
        }
      } catch (_) {
        // Not JSON — keep the trimmed text.
      }
    }
    return trimmed.isNotEmpty ? trimmed : reply;
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
          onCopyToClipboard: _copyChatToClipboard,
          onNewChatFromJson: _newChatFromJson,
          controller: _inputController,
        ),
        if (showServerPanel)
          QuickServerPanel(
            modelId: _conversation!.modelId ?? '',
            onServerStatusChanged: () => setState(() {}),
          ),
        if (showOrchestratorLog && _logVisible) ...[
          ResizeHandle(
            height: _logPanelHeight,
            onHeightChanged: (newHeight) => setState(() => _logPanelHeight = newHeight),
            minHeight: 40.0,
          ),
          OrchestratorLogPanel(height: _logPanelHeight),
        ],
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
            valueListenable: AgentRoleSettingsRepository.instance.enabledNotifier,
            builder: (ctx, multiAgent, _) {
              if (multiAgent) {
                // Multi-agent mode owns the per-role models in Settings,
                // so the per-conversation model picker is replaced by a
                // breadcrumb that shows the four roles + their models.
                return WorkflowBreadcrumb(sending: _sending);
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
                border: Border.all(color: AppTheme.accentMarrone, width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: IconButton(
                tooltip: OrchestratorManager.instance.isRunning ? "Stop orchestrator" : "Start orchestrator",
                icon: Icon(
                  OrchestratorManager.instance.isRunning ? Icons.stop_outlined : Icons.play_arrow_outlined,
                  size: 20,
                  color: OrchestratorManager.instance.isRunning ? AppTheme.accentMarrone : AppTheme.accent,
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
        NotificationHelper.showError(
          context,
          'No configuration found. Configure the server in Settings > Model > Configure Local Server',
        );
        return;
      }

      NotificationHelper.showInfo(context, 'Starting server...');

      final serverUrl = await LocalServerManager.instance.startServer(config);

      if (!mounted) return;

      NotificationHelper.showSuccess(context, '✓ Server running at $serverUrl');

      setState(() {});
    } catch (e) {
      if (!mounted) return;

      NotificationHelper.showError(context, 'Error: $e');
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
    await _startOrchestratorForActiveBackend();
  }

  /// When the multi-agent workflow is enabled, returns the title of the
  /// workflow group bound to [conv] (falling back to the currently active
  /// group when [conv] has no `groupId`). Returns null otherwise — single
  /// backend conversations don't carry a workflow.
  Future<String?> _resolveWorkflowTitle(Conversation conv) async {
    final repo = AgentRoleSettingsRepository.instance;
    if (!await repo.isEnabled()) return null;
    final groups = await repo.listGroups();
    if (groups.isEmpty) return null;
    final targetId = conv.groupId ?? await repo.getActiveGroupId();
    for (final g in groups) {
      if (g.id == targetId) return g.title;
    }
    return null;
  }

  Future<void> _downloadChatAsJson() async {
    final conv = _conversation;
    if (conv == null) return;

    final messages = await MessageRepository.instance.listByConversation(conv.id);
    final workflowTitle = await _resolveWorkflowTitle(conv);

    // Build an AI-model-friendly format: OpenAI chat-completion shape.
    // The top-level object contains metadata and a "messages" array where
    // each entry has "role" and "content" — exactly what most LLM APIs expect.
    final jsonData = {
      "conversation": {
        "id": conv.id,
        "title": conv.title,
        "modelId": conv.modelId,
        "backend": conv.backend,
        if (workflowTitle != null) "workflow": workflowTitle,
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

      NotificationHelper.showSuccess(context, 'Saved to $savePath');
    } catch (e) {
      if (!mounted) return;
      NotificationHelper.showError(context, 'Failed to save JSON: $e');
    }
  }

  Future<void> _copyChatToClipboard() async {
    final conv = _conversation;
    if (conv == null) return;

    final messages = await MessageRepository.instance.listByConversation(conv.id);
    final workflowTitle = await _resolveWorkflowTitle(conv);

    // Build the same JSON structure as _downloadChatAsJson
    final jsonData = {
      "conversation": {
        "id": conv.id,
        "title": conv.title,
        "modelId": conv.modelId,
        "backend": conv.backend,
        if (workflowTitle != null) "workflow": workflowTitle,
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

    try {
      await Clipboard.setData(ClipboardData(text: jsonString));
      if (!mounted) return;
      NotificationHelper.showSuccess(context, 'Chat JSON copied to clipboard');
    } catch (e) {
      if (!mounted) return;
      NotificationHelper.showError(context, 'Failed to copy to clipboard: $e');
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
    // Preserve groupId so the new chat appears in the same sidebar filter.
    final newConv = Conversation(
      id: const Uuid().v4(),
      title: 'New chat from JSON',
      modelId: conv.modelId,
      backend: conv.backend,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      groupId: conv.groupId,
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

    if (!mounted) return;

    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }

    // Navigate to the new conversation via HomeScreen. The openConversation
    // handler in HomeScreen also triggers a sidebar refresh, so the new
    // chat will appear in the sidebar list automatically.
    await MethodListener<HomeScreen>().callMethod(
      "openConversation",
      params: {"conversationId": newConv.id},
    );

    if (!mounted) return;
    NotificationHelper.showInfo(context, 'New chat created from JSON context');
  }

  Future<void> _stopOrchestrator() async {
    try {
      NotificationHelper.showInfo(context, 'Stopping orchestrator...');
      await OrchestratorManager.instance.stop();
      if (!mounted) return;
      NotificationHelper.showSuccess(context, 'Orchestrator stopped');
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      NotificationHelper.showError(context, 'Error: $e');
    }
  }

  Future<bool> _startOrchestratorForActiveBackend({bool silent = false}) async {
    try {
      final settings = BackendSettingsRepository.instance;
      final backend = await settings.getActiveBackend();
      if (mounted && _activeBackend != backend) {
        setState(() => _activeBackend = backend);
      }

      if (!_isOrchestratorBackend(backend)) return false;

      final desiredBackend = _desiredOrchestratorBackend(backend);
      final convModelId = _conversation?.modelId?.trim() ?? '';

      String? token;
      String? modelId;
      String? ollamaBaseUrl;
      int? ollamaNumCtx;
      String? ollamaApiKey;
      String? groqApiKey;
      String? geminiApiKey;
      String? openRouterApiKey;
      String? githubApiKey;
      double? temperature;
      int? maxTokens;
      int? tpmLimit;
      bool disableTools = false;

      switch (desiredBackend) {
        case OrchestratorBackend.ollama:
          ollamaBaseUrl = await settings.getOllamaBaseUrl();
          ollamaNumCtx = await settings.getOllamaNumCtx();
          ollamaApiKey = await settings.getOllamaApiKey();
          final savedOllamaModel = await settings.getOllamaModel();
          modelId = convModelId.isNotEmpty ? convModelId : savedOllamaModel;
          if ((modelId ?? '').isEmpty) {
            if (!silent && mounted) {
              NotificationHelper.showError(context, 'Select an Ollama model in Settings first');
            }
            return false;
          }
          break;
        case OrchestratorBackend.groq:
          groqApiKey = await settings.getGroqApiKey() ?? '';
          final savedGroqModel = await settings.getGroqModel() ?? '';
          modelId = (convModelId.isNotEmpty && !convModelId.contains(':')) ? convModelId : (savedGroqModel.isNotEmpty ? savedGroqModel : convModelId);
          temperature = await settings.getGroqTemperature();
          maxTokens = await settings.getGroqMaxTokens();
          tpmLimit = await settings.getGroqTpmLimit();
          if (groqApiKey.isEmpty) {
            if (!silent && mounted) {
              NotificationHelper.showError(context, 'Configure Groq API key in Settings first');
            }
            return false;
          }
          break;
        case OrchestratorBackend.gemini:
          geminiApiKey = await settings.getGeminiApiKey() ?? '';
          final savedGeminiModel = await settings.getGeminiModel() ?? '';
          modelId = resolveGeminiModel(convModelId, savedGeminiModel);
          temperature = await settings.getGeminiTemperature();
          maxTokens = await settings.getGeminiMaxTokens();
          tpmLimit = await settings.getGeminiTpmLimit();
          if (geminiApiKey.isEmpty) {
            if (!silent && mounted) {
              NotificationHelper.showError(context, 'Configure Gemini API key in Settings first');
            }
            return false;
          }
          break;
        case OrchestratorBackend.openrouter:
          openRouterApiKey = await settings.getOpenRouterApiKey() ?? '';
          final savedOpenRouterModel = await settings.getOpenRouterModel() ?? '';
          modelId = resolveOpenRouterModel(convModelId, savedOpenRouterModel);
          temperature = await settings.getOpenRouterTemperature();
          maxTokens = await settings.getOpenRouterMaxTokens();
          tpmLimit = await settings.getOpenRouterTpmLimit();
          if (openRouterApiKey.isEmpty) {
            if (!silent && mounted) {
              NotificationHelper.showError(context, 'Configure OpenRouter API key in Settings first');
            }
            return false;
          }
          break;
        case OrchestratorBackend.github:
          githubApiKey = await settings.getGithubApiKey() ?? '';
          final savedGithubModel = await settings.getGithubModel() ?? '';
          modelId = (convModelId.isNotEmpty && convModelId.contains('/')) ? convModelId : savedGithubModel;
          temperature = await settings.getGithubTemperature();
          maxTokens = await settings.getGithubMaxTokens();
          tpmLimit = await settings.getGithubTpmLimit();
          disableTools = await settings.getGithubDisableTools();
          if (githubApiKey.isEmpty) {
            if (!silent && mounted) {
              NotificationHelper.showError(context, 'Configure GitHub API token in Settings first');
            }
            return false;
          }
          break;
        case OrchestratorBackend.huggingface:
          final creds = await AgentCredentialsRepository.instance.getCredentials();
          token = creds?.hfToken ?? await SettingsRepository.instance.getHfToken();
          modelId = convModelId;
          if ((token ?? '').isEmpty) {
            if (!silent && mounted) {
              NotificationHelper.showError(context, 'Configure HF token in Settings first');
            }
            return false;
          }
          break;
      }

      // Already running on the desired backend -> nothing to do.
      if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend == desiredBackend) {
        return true;
      }

      // Stop existing orchestrator if backend changed.
      if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend != desiredBackend) {
        await OrchestratorManager.instance.stop();
      }

      // Rule: on any orchestrator start, open the output widget.
      if (mounted && !_logVisible) {
        setState(() => _logVisible = true);
      }

      if (!silent && mounted) {
        NotificationHelper.showInfo(
          context,
          switch (desiredBackend) {
            OrchestratorBackend.ollama => "Starting Ollama orchestrator...",
            OrchestratorBackend.groq => "Starting Groq orchestrator...",
            OrchestratorBackend.gemini => "Starting Gemini orchestrator...",
            OrchestratorBackend.openrouter => "Starting OpenRouter orchestrator...",
            OrchestratorBackend.github => "Starting GitHub orchestrator...",
            OrchestratorBackend.huggingface => "Starting orchestrator...",
          },
        );
      }

      final started = await OrchestratorManager.instance.start(
        hfToken: token,
        modelId: modelId,
        backend: desiredBackend,
        ollamaBaseUrl: ollamaBaseUrl,
        ollamaNumCtx: ollamaNumCtx,
        ollamaApiKey: ollamaApiKey,
        groqApiKey: groqApiKey,
        geminiApiKey: geminiApiKey,
        openRouterApiKey: openRouterApiKey,
        githubApiKey: githubApiKey,
        temperature: temperature,
        maxTokens: maxTokens,
        tpmLimit: tpmLimit,
        disableTools: disableTools,
      );

      if (!mounted) return started;

      if (!silent) {
        if (started) {
          NotificationHelper.showSuccess(
            context,
            switch (desiredBackend) {
              OrchestratorBackend.ollama => "Ollama orchestrator active",
              OrchestratorBackend.groq => "Groq orchestrator active",
              OrchestratorBackend.gemini => "Gemini orchestrator active",
              OrchestratorBackend.openrouter => "OpenRouter orchestrator active",
              OrchestratorBackend.github => "GitHub orchestrator active",
              OrchestratorBackend.huggingface => "Orchestrator active",
            },
          );
        } else {
          NotificationHelper.showError(
            context,
            switch (desiredBackend) {
              OrchestratorBackend.ollama => "Failed to start Ollama orchestrator",
              OrchestratorBackend.groq => "Failed to start Groq orchestrator",
              OrchestratorBackend.gemini => "Failed to start Gemini orchestrator",
              OrchestratorBackend.openrouter => "Failed to start OpenRouter orchestrator",
              OrchestratorBackend.github => "Failed to start GitHub orchestrator",
              OrchestratorBackend.huggingface => "Failed to start orchestrator",
            },
          );
        }
      }

      setState(() {});
      return started;
    } catch (e) {
      if (!silent && mounted) {
        NotificationHelper.showError(context, 'Error: $e');
      }
      return false;
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
              ValueListenableBuilder<bool>(
                valueListenable: AgentRoleSettingsRepository.instance.enabledNotifier,
                builder: (ctx, multiAgent, _) {
                  if (multiAgent) {
                    return ValueListenableBuilder<String?>(
                      valueListenable: AgentRoleSettingsRepository.instance.activeGroupNotifier,
                      builder: (ctx, activeId, _) {
                        return ValueListenableBuilder<int>(
                          valueListenable: AgentRoleSettingsRepository.instance.groupsChangedNotifier,
                          builder: (ctx, _, __) {
                            return FutureBuilder<List<WorkflowGroup>>(
                              future: AgentRoleSettingsRepository.instance.listGroups(),
                              builder: (ctx, snap) {
                                final groups = snap.data;
                                String title = '';
                                if (groups != null && groups.isNotEmpty) {
                                  final match = groups.firstWhere(
                                    (g) => g.id == activeId,
                                    orElse: () => groups.first,
                                  );
                                  title = match.title;
                                }
                                return Text(
                                  "Workflow: $title",
                                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  }
                  return Text(
                    "Model: ${_conversation?.modelId ?? ''}",
                    style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  );
                },
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
          message: m.content,
          timeInSeconds: (m.responseTimeMs ?? 0) / 1000.0,
          isUser: m.role == MessageRole.user,
          // Show resend only on user bubbles and only when not already sending.
          onResend: (m.role == MessageRole.user && !_sending) ? () => _handleResend(m.id) : null,
          onEdit: (m.role == MessageRole.user && !_sending) ? () => _handleEdit(m.id) : null,
          onDelete: () => _handleDeleteMessage(m.id),
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
                NotificationHelper.showInfo(context, "Error copied to clipboard");
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
    final position = _scrollController.position;
    if (!position.hasContentDimensions) {
      return const SizedBox.shrink();
    }

    final maxScroll = position.maxScrollExtent;
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
              border: Border.all(color: AppTheme.accentMarrone, width: 1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 30,
              color: AppTheme.accentMarrone,
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
              MethodListener<Sidebar>().callMethod("newConversation");
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
    _inputController.dispose();
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
                          color: AppTheme.accentMarrone,
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
            style: TextStyle(color: AppTheme.accentMarrone, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
