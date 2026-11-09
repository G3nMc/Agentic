import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/agent_context_template.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/notification_helper.dart';
import '../../data/models/conversation.dart';
import '../../data/models/conversation_turn.dart';
import '../../data/models/message.dart';
import '../../data/repositories/agent_credentials_repository.dart';
import '../../data/repositories/agent_role_settings_repository.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/conversation_turn_repository.dart';
import '../../data/repositories/dev_filters_repository.dart';
import '../../data/repositories/local_server_config_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/chat_processing_service.dart';
import '../../services/chat_turn_controller.dart';
import '../../services/context_summary_service.dart';
import '../../services/huggingface_service.dart';
import '../../services/llm_service.dart';
import '../../services/local_server_manager.dart';
import '../../services/orchestrator_manager.dart';
import '../../services/project_service.dart';
import '../../statemanagement/method_data.dart';
import '../../statemanagement/method_listener.dart';
import '../../statemanagement/state_manager.dart';
import '../screens/home_screen.dart';
import 'chat_input.dart';
import 'horizontal_resize_handle.dart';
import 'message_bubble.dart';
import 'model_switcher.dart';
import 'model_thinking_panel.dart';
import 'openrouter_usage_badge.dart';
import 'orchestrator_log_panel.dart';
import 'quick_server_panel.dart';
import 'resize_handle.dart';
import 'sidebar.dart';
import 'thinking_control.dart';
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

  /// AUTO INPUT notice surfaced by the orchestrator (e.g. "no Workflow Agent
  /// is configured as User"). Rendered as a dismissible banner above the
  /// input so the user knows why the autonomous loop stopped after one reply.
  String? _autoInputNotice;
  StreamSubscription<String>? _autoInputNoticeSub;

  /// Intermediate answers produced while AUTO INPUT keeps working on its own.
  /// Each one is a real assistant turn in the orchestrator's conversation
  /// history, so it is persisted and rendered instead of being dropped.
  StreamSubscription<String>? _autoInputReplySub;

  /// Continuation prompts authored by the AUTO INPUT User agent (second
  /// Workflow Agents slot). Rendered as user-side bubbles so the
  /// model-to-model exchange reads as a continuing conversation.
  StreamSubscription<String>? _autoInputPromptSub;

  /// True while the User agent is reviewing the last reply and writing the
  /// next prompt; drives the user-side typing indicator.
  StreamSubscription<bool>? _autoInputEvaluatingSub;
  bool _autoInputUserWriting = false;

  /// Active backend — loaded once and cached so build() never needs a
  /// FutureBuilder (which tears down child widgets on every setState).
  LlmBackend? _activeBackend;

  /// Input mode for this chat, selected from the dropdown in the input bar.
  ///   - 'user_input' : user-driven loop; the orchestrator waits for an
  ///                    explicit user message before every model call
  ///                    (the default, and what the retired 'open' alias
  ///                    always resolved to on the Python side).
  ///   - 'auto_input' : after each reply the orchestrator asks the model to
  ///                    self-evaluate; if the request isn't done it feeds
  ///                    its own follow-up prompt back in until completion.
  String _taskMode = 'user_input';

  /// Thinking ON/OFF master switch. When ON, the backend enables extended
  /// reasoning (Anthropic thinking, Gemini thinkingConfig, OpenAI reasoning_effort).
  /// When OFF, no reasoning params are sent to the provider API.
  bool _thinking = false;

  /// Effort level for reasoning budget. One of: minimal, low, medium, high, max.
  /// Only has effect when _thinking is ON. Maps to provider-specific budgets:
  ///   OpenAI: reasoning_effort (max→high), Anthropic: thinking.budget_tokens,
  ///   Gemini: thinkingConfig.thinkingBudget, Ollama: ignored.
  String _effort = 'medium';

  /// Whether the OrchestratorLogPanel is currently expanded under the input.
  /// Toggled by the log button in [ChatInput] and auto-set to true when the
  /// orchestrator successfully starts.
  bool _logVisible = false;

  /// Current height of the orchestrator log panel when visible.
  double _logPanelHeight = 220.0 - 123;

  /// Current width of the left (model thinking) panel when visible.
  double _thinkingPanelWidth = 260.0;

  static const String _thinkingPanelWidthKey = 'thinking_panel_width';

  /// Token for the currently in-flight send. Non-null only while [_sending].
  _CancelToken? _currentCancel;

  /// Subscription to the process-global turn journal. The reply of a turn that
  /// was dispatched from this conversation still arrives here after a remount
  /// (conversation switch, Settings tab), so the answer is never dropped.
  StreamSubscription<ChatTurnEvent>? _turnSub;

  /// Promotes this view from "no session yet" to a live subscription once the
  /// chat's orchestrator session is created by a send.
  StreamSubscription<OrchestratorSession>? _sessionAddedSub;

  /// Most recent persisted turn for this conversation. Used to flag a turn that
  /// never produced a delivered answer (crash, forced stop).
  ConversationTurn? _lastTurn;

  final ScrollController _scrollController = ScrollController();

  /// Controller for the chat input. Owned here so we can push text into it
  /// when the user taps the edit icon on a message bubble.
  final TextEditingController _inputController = TextEditingController();

  /// ID of the message currently staged for edit. Set when the user taps the
  /// edit icon; cleared after the next send (or if it disappears from the
  /// list). When non-null, [_sendMessage] truncates the conversation at this
  /// message before appending the new one.
  String? _editingMessageId;

  /// Text staged for auto-send after a new conversation is created and the
  /// orchestrator is up. Used by the auto-generate-agent-context flow so the
  /// prompt fires with zero prior history in a fresh conversation.
  static String? _pendingAutoSend;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadConversation();
    _refreshActiveBackend();
    _restoreThinkingPanelWidth();

    // Re-attach to the turn journal. A turn dispatched from this conversation
    // survives a widget remount (conversation switch, Settings tab) and its
    // reply is delivered to whichever view is mounted when it finishes.
    _turnSub = ChatTurnController.instance.events.listen(_onTurnEvent);
    final activeTurn = ChatTurnController.instance.active;
    if (activeTurn != null &&
        activeTurn.conversationId == widget.conversationId) {
      _sending = true;
    }

    // AUTO INPUT events belong to this chat's session only. Binding them here
    // (rather than to the global singleton) is what stops chat B from rendering
    // chat A's intermediate answers and user-agent prompts.
    _bindSessionStreams();

    // AUTO INPUT is MaM (Model against Model): it is the only task mode that
    // puts the two Workflow Agents slots to work together (Assistant answers,
    // User reviews and authors the next prompt). Enabling the master switch in
    // Settings -> Workflow Agents MaM therefore selects AUTO INPUT here —
    // immediately when the switch is flipped while this chat is open, and on
    // mount for a switch that was already ON.
    AgentRoleSettingsRepository.instance.enabledNotifier
        .addListener(_syncTaskModeWithWorkflow);
    // The notifier still holds its default (false) on a fresh mount, so read
    // the persisted switch before deciding the initial mode. The listener
    // above then covers a switch flipped while this chat stays open.
    AgentRoleSettingsRepository.instance.isEnabled().then((_) {
      if (mounted) _syncTaskModeWithWorkflow();
    });

    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      setState(() {
        _currentScroll = _scrollController.offset;
      });
    });
  }

  /// Keeps the input-bar task mode in sync with the Workflow Agents MaM
  /// master switch. MaM (Model against Model) only runs in AUTO INPUT, where
  /// the Assistant answers and the User agent reviews and authors the next
  /// prompt; AUTO INPUT likewise needs MaM on, otherwise no second agent is
  /// configured. Switching MaM ON therefore selects AUTO INPUT, switching it
  /// OFF falls back to USER INPUT so the chat stops advertising a model pair
  /// that is no longer configured.
  void _syncTaskModeWithWorkflow() {
    if (!mounted) return;
    final enabled = AgentRoleSettingsRepository.instance.enabledNotifier.value;
    if (enabled && _taskMode != 'auto_input') {
      setState(() => _taskMode = 'auto_input');
    } else if (!enabled && _taskMode == 'auto_input') {
      setState(() => _taskMode = 'user_input');
    }
  }

  Future<void> _restoreThinkingPanelWidth() async {
    final saved = await SettingsRepository.instance.get(_thinkingPanelWidthKey);
    final parsed = double.tryParse(saved ?? '');
    if (parsed != null && parsed >= 120.0) {
      if (mounted) setState(() => _thinkingPanelWidth = parsed);
    }
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
      // Only per-conversation UI state is reset here. The orchestrator session
      // is deliberately preserved: switching chats must never discard a turn
      // that is still being produced for the conversation being left.
      setState(() {
        _editingMessageId = null;
        _sendError = null;
        _autoInputNotice = null;
        _autoInputUserWriting = false;
        // Rehydrate the busy flag from *this* chat's turn journal. Without it
        // re-entering a chat whose answer is still being produced would show an
        // idle input bar and a Play button.
        _sending = ChatTurnController.instance.isBusyFor(widget.conversationId);
      });
      // Re-bind every per-session subscription: the streams belong to a
      // session, so chat B must never render chat A's log, status or AUTO
      // INPUT traffic.
      _bindSessionStreams();
      _loadConversation();
    }
  }

  /// (Re)subscribe to the streams of the current conversation's session and
  /// adopt its busy state.
  ///
  /// Sessions are created lazily, so nothing is subscribed until the chat's
  /// session actually exists; a session that appears later is promoted through
  /// [_pendingSessionBind]. Disposing the old subscriptions first is what keeps
  /// chat A's output out of chat B's widgets.
  void _bindSessionStreams() {
    _autoInputNoticeSub?.cancel();
    _autoInputReplySub?.cancel();
    _autoInputPromptSub?.cancel();
    _autoInputEvaluatingSub?.cancel();
    _autoInputNoticeSub = null;
    _autoInputReplySub = null;
    _autoInputPromptSub = null;
    _autoInputEvaluatingSub = null;

    _sending = ChatTurnController.instance.isBusyFor(widget.conversationId);

    final session = OrchestratorManager.instance.peek(widget.conversationId);
    if (session == null) {
      _autoInputUserWriting = false;
      // The session may be created by a send that is already on its way.
      _sessionAddedSub ??=
          OrchestratorManager.instance.sessionAdded.listen((added) {
        if (added.conversationId == widget.conversationId && mounted) {
          _bindSessionStreams();
        }
      });
      return;
    }

    // AUTO INPUT notices are emitted mid-request (e.g. "no Workflow Agent
    // configured as User"), so they must be wired before the reply returns.
    _autoInputNoticeSub = session.autoInputNoticeStream.listen((notice) {
      if (!mounted) return;
      // `_sending` is cleared by the normal completion path once the final
      // answer lands, otherwise the typing indicator flickers off early.
      setState(() => _autoInputNotice = notice);
    });

    _autoInputReplySub =
        session.autoInputReplyStream.listen(_handleAutoInputReply);

    _autoInputPromptSub =
        session.autoInputPromptStream.listen(_handleAutoInputPrompt);

    _autoInputEvaluatingSub =
        session.autoInputEvaluatingStream.listen((writing) {
      if (!mounted) return;
      setState(() => _autoInputUserWriting = writing);
    });
    _autoInputUserWriting = session.autoInputEvaluating;
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
      case "refreshActiveBackend":
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
      if (conv != null) {
        _thinking = conv.thinking;
        _effort = conv.effort.isNotEmpty ? conv.effort : 'medium';
      }
      _loading = false;
    });

    // Entering an existing chat should always ensure the orchestrator is up
    // for orchestrator-backed modes so the next action is instant.
    await _startOrchestratorForActiveBackend(silent: true);

    // Hydrate the log panel with the previous session's output from disk.
    OrchestratorManager.instance.loadLogFromDisk(id);

    // Surface an interrupted turn (crash, forced quit, STOP) on the last bubble.
    await _refreshLastTurn();

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    // If a pending-send text was staged (e.g. from auto-generate-agent-context),
    // fire it now that the conversation is loaded and the orchestrator is up.
    final pending = _pendingAutoSend;
    if (pending != null && pending.trim().isNotEmpty) {
      _pendingAutoSend = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sendMessage(pending);
      });
    }
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
  ///
  /// This is a genuine STOP: the shared turn is aborted so a late reply is
  /// discarded, the local token is cancelled, and the subprocess is terminated
  /// so the model stops burning tokens on an answer nobody will see.
  void _stopGeneration() {
    // Scope the STOP to the chat that owns this view: aborting its journal
    // entry and tearing down its session must leave every other running
    // conversation untouched.
    final id = widget.conversationId;
    if (id != null) {
      ChatTurnController.instance.abort(id, 'user stopped generation');
      OrchestratorManager.instance.stopFor(
        id,
        source: OrchestratorStopSource.chatStopButton,
        reason: 'user stopped generation from the chat view',
      );
    }
    _currentCancel?.cancel();
    _currentCancel = null;
    if (mounted) setState(() => _sending = false);
  }

  /// Builds the auto-generate-agent-context prompt, creates a fresh
  /// conversation, and stages the prompt so it fires with zero prior
  /// history once the orchestrator is up.
  Future<void> _autoGenerateAgentContext() async {
    if (_sending) return;

    final projectService = ProjectService();
    if (!projectService.hasExplicitFolder) return;

    final projectPath = projectService.currentPath;
    final agenticDirPath = '$projectPath${Platform.pathSeparator}$kAgentContextDirName';
    final agentMdPath = '$agenticDirPath${Platform.pathSeparator}$kAgentContextFileName';

    // Ensure .agentic/ directory exists.
    try {
      final agenticDir = Directory(agenticDirPath);
      if (!await agenticDir.exists()) {
        await agenticDir.create(recursive: true);
      }
    } catch (_) {
      // Ignore — can't create directory; agent will handle it.
    }

    // 1. Read existing .context.md if present (as current state of art).
    String existingContext = '';
    try {
      final agentFile = File(agentMdPath);
      if (await agentFile.exists()) {
        existingContext = await agentFile.readAsString();
      }
    } catch (_) {
      // Ignore — file doesn't exist or can't be read.
    }

    // 2. Build a directory tree snapshot (capped), respecting filesystem filters.
    String dirTree = '';
    try {
      final dir = Directory(projectPath);
      if (await dir.exists()) {
        // Load filesystem filters so we only pass what the user configured
        // in Settings → Developer → Filesystem Filters.
        final filters = await DevFiltersRepository.instance.getAll(projectPath);
        final includeDirs = filters[DevFiltersRepository.kIncludeDirs] ?? <String>[];
        final excludeDirs = filters[DevFiltersRepository.kExcludeDirs] ?? <String>[];
        final includeFiles = filters[DevFiltersRepository.kIncludeFiles] ?? <String>[];
        final excludeFiles = filters[DevFiltersRepository.kExcludeFiles] ?? <String>[];

        final dirWhitelist = includeDirs.isNotEmpty && excludeDirs.isEmpty;
        final fileWhitelist = includeFiles.isNotEmpty && excludeFiles.isEmpty;

        final entries = await dir.list(recursive: true).take(500).toList();
        final lines = <String>[];
        for (final e in entries) {
          final relPath = e.path.substring(projectPath.length + 1);
          final isDir = e is Directory;

          if (isDir) {
            if (!_filterAllowsDir(relPath, includeDirs, excludeDirs, dirWhitelist)) {
              continue;
            }
          } else {
            if (!_filterAllowsFile(relPath, includeFiles, excludeFiles, fileWhitelist)) {
              continue;
            }
            // Also check that the file's parent directory is visible.
            final parentRel = relPath.contains(Platform.pathSeparator)
                ? relPath.substring(0, relPath.lastIndexOf(Platform.pathSeparator))
                : '';
            if (parentRel.isNotEmpty && !_filterAllowsDir(parentRel, includeDirs, excludeDirs, dirWhitelist)) {
              continue;
            }
          }

          lines.add('${isDir ? '[DIR]' : '[FILE]'} $relPath');
        }
        dirTree = lines.join('\n');
      }
    } catch (_) {
      dirTree = '(could not list directory)';
    }

    // 3. Build the prompt.
    final hasExisting = existingContext.trim().isNotEmpty;
    final prompt = StringBuffer();
    prompt.writeln('## TASK');
    prompt.writeln();
    if (hasExisting) {
      prompt.writeln(
        'Below is the CURRENT `.agentic/.context.md` for this project. '
        'Read it, then analyse the project directory tree to see if '
        'anything has changed. Update the file to reflect the current '
        'state of the project. Use write_file to overwrite `.agentic/.context.md`. '
        'Ensure the `.agentic/` directory exists before writing.',
      );
      prompt.writeln();
      prompt.writeln('### CURRENT .agentic/.context.md');
      prompt.writeln('```markdown');
      prompt.writeln(existingContext);
      prompt.writeln('```');
    } else {
      prompt.writeln(
        'Analyse the project directory tree below and create a '
        '`.agentic/.context.md` file that describes this project for future '
        'coding agents. Use write_file to create `.agentic/.context.md`. '
        'First create the `.agentic/` directory if it does not exist.',
      );
    }
    prompt.writeln();
    prompt.writeln('### PROJECT DIRECTORY TREE');
    prompt.writeln('```');
    prompt.writeln(dirTree);
    prompt.writeln('```');
    prompt.writeln();
    prompt.writeln('### .agentic/.context.md TEMPLATE (use these sections)');
    prompt.writeln('```markdown');
    prompt.writeln(kAgentContextTemplate);
    prompt.writeln('```');
    prompt.writeln();
    prompt.writeln(
      'IMPORTANT: Only output the tool call to write_file. '
      'No explanation before or after.',
    );

    final promptText = prompt.toString();

    // 4. Create a fresh conversation and stage the prompt.
    // Use the model from the current conversation so the agent the user
    // is already chatting with performs the generation — no hardcoded fallback.
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = const Uuid().v4();
    final backend = await BackendSettingsRepository.instance.getActiveBackend();
    final selectedModel = _conversation?.modelId ?? '';

    final conversation = Conversation(
      id: id,
      title: 'Agent context generation',
      modelId: selectedModel,
      backend: backend.name,
      createdAt: now,
      updatedAt: now,
      projectPath: ProjectService().activeProjectKey,
    );
    await ConversationRepository.instance.insert(conversation);

    // Stage the prompt so it fires after the conversation loads.
    _pendingAutoSend = promptText;

    // Park a relaunch instead of killing the process: a turn may still be
    // running in the conversation we are leaving and its answer has to land
    // before the new session takes over.
    if (OrchestratorManager.instance.isRunning) {
      OrchestratorManager.instance.requestRestart(
        reason: 'agent-context generation opened a new conversation',
        source: OrchestratorStopSource.conversationSwitch,
      );
    }

    // Open the new conversation — _loadConversation will pick up
    // _pendingAutoSend and fire it.
    await MethodListener<HomeScreen>().callMethod(
      'openConversation',
      params: {'conversationId': id},
    );
  }

  // ---------------------------------------------------------------------------
  // Filesystem-filter helpers for auto-generate-agent-context
  // ---------------------------------------------------------------------------

  /// Hardcoded baseline of noise directories, matching Python's
  /// `_BASELINE_EXCLUDE_DIRS` in `agent/path_filter.py`.
  static const _baselineExcludeDirs = <String>{
    '.git',
    '.idea',
    '.claude',
    '.agent',
    '__pycache__',
    '.dart_tool',
    'build',
    'node_modules',
    '.gradle',
  };

  /// Returns `true` when [relPath] (a relative directory path) should be
  /// visible given the user's include/exclude lists.
  bool _filterAllowsDir(
    String relPath,
    List<String> includeDirs,
    List<String> excludeDirs,
    bool whitelistMode,
  ) {
    final name = relPath.split(Platform.pathSeparator).last;

    // Baseline noise: always excluded unless explicitly included.
    if (_baselineExcludeDirs.contains(name) && !includeDirs.contains(name)) {
      return false;
    }

    if (whitelistMode) {
      // Whitelist: only dirs matching an include (or ancestors of one) pass.
      return _matchesAnyDir(relPath, includeDirs) || _isAncestorOfAnyInclude(relPath, includeDirs);
    }

    // Blacklist / default-allow mode.
    if (_matchesAnyDir(relPath, excludeDirs)) {
      // Excluded — unless an include overrides.
      return _matchesAnyDir(relPath, includeDirs);
    }
    return true; // default-allow
  }

  /// Returns `true` when [relPath] (a relative file path) should be
  /// visible given the user's include/exclude lists.
  bool _filterAllowsFile(
    String relPath,
    List<String> includeFiles,
    List<String> excludeFiles,
    bool whitelistMode,
  ) {
    final name = relPath.split(Platform.pathSeparator).last;
    final ext = name.contains('.') ? '.${name.substring(name.lastIndexOf('.') + 1)}' : '';

    if (whitelistMode) {
      // Whitelist: only files matching an include pass.
      return _matchesAnyFile(relPath, name, ext, includeFiles);
    }

    // Blacklist / default-allow mode.
    if (_matchesAnyFile(relPath, name, ext, excludeFiles)) {
      // Excluded — unless an include overrides.
      return _matchesAnyFile(relPath, name, ext, includeFiles);
    }
    return true; // default-allow
  }

  /// True when [relPath] matches any entry in [patterns].
  bool _matchesAnyDir(String relPath, List<String> patterns) {
    final name = relPath.split(Platform.pathSeparator).last;
    for (final p in patterns) {
      if (p.isEmpty) continue;
      // Absolute path match
      if (Platform.isWindows ? p.toLowerCase() == relPath.toLowerCase() : p == relPath) {
        return true;
      }
      // Bare basename match
      if (p == name) return true;
      // Multi-segment relative match (e.g. "installer/Output")
      if (p.contains('/') || p.contains('\\')) {
        final normP = p.replaceAll('\\', '/');
        final normRel = relPath.replaceAll('\\', '/');
        if (normRel == normP || normRel.startsWith('$normP/')) return true;
      }
    }
    return false;
  }

  /// True when [relPath] is an ancestor of any include target (needed so
  /// recursive walks can descend through an excluded ancestor to reach a
  /// deeper include).
  bool _isAncestorOfAnyInclude(String relPath, List<String> includes) {
    final normRel = relPath.replaceAll('\\', '/');
    for (final inc in includes) {
      if (inc.isEmpty) continue;
      final normInc = inc.replaceAll('\\', '/');
      // Skip bare names and *.ext globs — they match anywhere.
      if (!normInc.contains('/')) continue;
      if (normInc.startsWith('$normRel/')) return true;
    }
    return false;
  }

  /// True when [relPath] (with [name] and [ext]) matches any entry in [patterns].
  bool _matchesAnyFile(String relPath, String name, String ext, List<String> patterns) {
    for (final p in patterns) {
      if (p.isEmpty) continue;
      // Absolute path match
      if (Platform.isWindows ? p.toLowerCase() == relPath.toLowerCase() : p == relPath) {
        return true;
      }
      // *.ext glob
      if (p.startsWith('*.') && ext.isNotEmpty) {
        final targetExt = p.substring(1).toLowerCase(); // ".ext"
        if (ext.toLowerCase() == targetExt) return true;
      }
      // Bare name match
      if (p == name) return true;
    }
    return false;
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
    } else if (backend == LlmBackend.ollama ||
        backend == LlmBackend.ollamaPython ||
        backend == LlmBackend.ollamaOrchestrator) {
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
      LlmBackend.ollama ||
      LlmBackend.ollamaPython ||
      LlmBackend.ollamaOrchestrator =>
        (conv.modelId != null && conv.modelId!.trim().isNotEmpty) ? conv.modelId! : (ollamaModel ?? ''),
      LlmBackend.openRouter => resolveOpenRouterModel(
          conv.modelId ?? '',
          openRouterModel ?? '',
        ),
      LlmBackend.geminiOrchestrator => (conv.modelId != null && conv.modelId!.startsWith('gemini'))
          ? conv.modelId!
          : (geminiModel ?? BackendSettingsRepository.defaultGeminiModel),
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

    // Take ownership of the turn in the process-global controller BEFORE
    // anything is persisted. Refusing after the insert would strand an
    // unanswered user message in the transcript: visible in the DB, invisible
    // in the UI, and never answered.
    final turn = ChatTurnController.instance.begin(
      conversationId: conv.id,
      prompt: safeText,
    );
    if (turn == null) {
      if (mounted) {
        setState(() {
          _sendError = 'A turn is already running in another conversation. '
              'Wait for it to finish before sending this prompt.';
        });
      }
      return;
    }

    await MessageRepository.instance.insert(userMsg);
    await ConversationRepository.instance.touch(conv.id);

    final cancelToken = _CancelToken();
    _currentCancel = cancelToken;

    // Journal the turn so an interruption (crash, forced quit, kill) stays
    // visible in the transcript as an "Interrupted" turn instead of vanishing.
    final turnRowId = await ConversationTurnRepository.instance.start(
      conversationId: conv.id,
      prompt: safeText,
      backend: backend.name,
      modelId: modelId,
    );

    // Capture the moment the request is dispatched so we can measure
    // how long the assistant takes to reply.
    final sendStartMs = DateTime.now().millisecondsSinceEpoch;

    setState(() {
      _messages.add(userMsg);
      _sending = true;
      _sendError = null;
      // Dismiss any stale AUTO INPUT notice: the user is driving again.
      _autoInputNotice = null;
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

    // AUTO INPUT is Model against Model: the Assistant that answers and the
    // User that reviews are both taken from Settings -> Workflow Agents MaM.
    // The mode therefore has to bring the multi-agent orchestrator up even
    // when the master switch is off — otherwise the chat would answer with
    // the Model Settings model and the configured User agent would never be
    // consulted.
    final workflowEnabled =
        AgentRoleSettingsRepository.instance.enabledNotifier.value;
    final multiAgentActive = workflowEnabled || _taskMode == 'auto_input';
    if (_isOrchestratorBackend(backend) || multiAgentActive) {
      await _startOrchestratorForActiveBackend(silent: true);
    }

    try {
      // Build the request via ChatProcessingService so the rolling
      // summary (if any) is injected as a system message and the history
      // is packed newest-first by char-budget rather than sent in full.
      // This is what keeps Q/A/Q context alive across turns without
      // exceeding the model's window.
      final prepared = await ChatProcessingService.instance.prepareRequest(
        conversationId: conv.id,
        userMessage: safeText,
        backend: backend,
        modelId: modelId,
        token: token,
        localServerUrl: serverUrl,
        ollamaBaseUrl: ollamaBaseUrl,
        ollamaModelId: modelId,
        ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
      );

      final historyForRequest = _isOrchestratorBackend(backend)
          ? history
          : (prepared.historyToSend.isNotEmpty ? prepared.historyToSend : history);
      // Determine temperature based on backend settings.
      double temperature = 0.2;
      switch (backend) {
        case LlmBackend.ollama:
        case LlmBackend.ollamaPython:
        case LlmBackend.ollamaOrchestrator:
          temperature = await BackendSettingsRepository.instance.getOllamaTemperature();
          break;
        case LlmBackend.groq:
        case LlmBackend.groqOrchestrator:
          temperature = await BackendSettingsRepository.instance.getGroqTemperature();
          break;
        case LlmBackend.geminiOrchestrator:
          temperature = await BackendSettingsRepository.instance.getGeminiTemperature();
          break;
        case LlmBackend.openRouter:
        case LlmBackend.openRouterOrchestrator:
          temperature = await BackendSettingsRepository.instance.getOpenRouterTemperature();
          break;
        case LlmBackend.githubOrchestrator:
          temperature = await BackendSettingsRepository.instance.getGithubTemperature();
          break;
        default:
          temperature = 0.2;
      }

      // With Workflow Agents MaM enabled each role card owns its slot's
      // thinking flag and effort level, and the launcher seeds them on the
      // orchestrator at start-up. Sending the per-conversation values here
      // would override the configured slots, so the keys are omitted (null =
      // "keep the launch-time value" on the Python side).
      final workflowOwnsThinking =
          AgentRoleSettingsRepository.instance.enabledNotifier.value;

      final reply = await LlmService.instance.sendChat(
        backend: backend,
        token: token ?? "",
        modelId: modelId,
        temperature: temperature,
        history: historyForRequest,
        conversationId: conv.id,
        localServerUrl: serverUrl,
        ollamaBaseUrl: ollamaBaseUrl,
        ollamaModelId: modelId,
        ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
        taskMode: _taskMode,
        thinking: workflowOwnsThinking ? null : _thinking,
        effort: workflowOwnsThinking ? null : _effort,
      );

      if (cancelToken.isCancelled || turn.cancelled) {
        await ConversationTurnRepository.instance.finish(
          turnRowId,
          status: ConversationTurnStatus.aborted,
          error: 'stopped by the user',
        );
        if (mounted) {
          setState(() {
            _sending = false;
            _currentCancel = null;
          });
        }
        return;
      }

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
      await ConversationTurnRepository.instance.finish(
        turnRowId,
        status: ConversationTurnStatus.completed,
      );

      // Hand the reply to the controller so any mounted view for this
      // conversation renders it — including a view that mounted after the
      // prompt was dispatched.
      ChatTurnController.instance.complete(turn, assistantMsg, responseTimeMs);

      if (mounted) {
        setState(() {
          _messages.add(assistantMsg);
          _sending = false;
          _currentCancel = null;
        });
      }

      await MethodListener<Sidebar>().callMethod("refreshConversations");

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
      });
    } on HuggingFaceException catch (e) {
      // A STOP surfaces as an exception because the subprocess is torn down
      // underneath the awaiting future. That is an abort, not a failure: the
      // chip must read "Turn interrupted" instead of "Turn failed".
      final aborted = turn.cancelled || cancelToken.isCancelled;
      await ConversationTurnRepository.instance.finish(
        turnRowId,
        status: aborted
            ? ConversationTurnStatus.aborted
            : ConversationTurnStatus.failed,
        error: aborted ? 'stopped by the user' : e.message,
      );
      ChatTurnController.instance.fail(turn, e.message);
      if (!mounted) return;

      setState(() {
        _sending = false;
        _currentCancel = null;
        if (!aborted) _sendError = e.message;
      });
    } catch (e) {
      final aborted = turn.cancelled || cancelToken.isCancelled;
      await ConversationTurnRepository.instance.finish(
        turnRowId,
        status: aborted
            ? ConversationTurnStatus.aborted
            : ConversationTurnStatus.failed,
        error: aborted ? 'stopped by the user' : e.toString(),
      );
      ChatTurnController.instance.fail(turn, e.toString());
      if (!mounted) return;

      setState(() {
        _sending = false;
        _currentCancel = null;
        if (!aborted) _sendError = e.toString();
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
    await ContextSummaryService.instance.deleteContextSummary(conv.id);

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
    final conv = _conversation;
    if (conv != null) {
      await ContextSummaryService.instance.deleteContextSummary(conv.id);
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
    await ContextSummaryService.instance.deleteContextSummary(conv.id);

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

  /// Persist and render one intermediate AUTO INPUT answer.
  ///
  /// While AUTO INPUT runs, every non-final answer is a real assistant turn in
  /// the orchestrator's conversation, so it is stored as soon as it arrives
  /// instead of being discarded: the user sees the running transcript and the
  /// persisted chat stays consistent with what the models actually exchanged.
  Future<void> _handleAutoInputReply(String reply) async {
    final conv = _conversation;
    if (conv == null) return;
    final cleaned = _sanitizeAssistantReply(reply);
    if (cleaned.trim().isEmpty) return;

    final msg = ChatMessage(
      id: const Uuid().v4(),
      conversationId: conv.id,
      role: MessageRole.assistant,
      content: cleaned,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    await MessageRepository.instance.insert(msg);
    await ConversationRepository.instance.touch(conv.id);
    if (!mounted) return;
    setState(() => _messages.add(msg));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  /// Persist and render a User-agent continuation prompt.
  ///
  /// In AUTO INPUT the second Workflow Agents slot authors the next user turn
  /// while the loop keeps running. Rendering it as a user bubble tagged with
  /// the `user` agent makes the exchange read as a continuing conversation
  /// instead of back-to-back assistant answers.
  Future<void> _handleAutoInputPrompt(String prompt) async {
    final conv = _conversation;
    if (conv == null) return;
    final cleaned = prompt.trim();
    if (cleaned.isEmpty) return;

    final msg = ChatMessage(
      id: const Uuid().v4(),
      conversationId: conv.id,
      role: MessageRole.user,
      content: cleaned,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      agent: 'user',
    );

    await MessageRepository.instance.insert(msg);
    await ConversationRepository.instance.touch(conv.id);
    if (!mounted) return;
    setState(() => _messages.add(msg));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
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

    final backend = _activeBackend;
    final showServerPanel = backend == LlmBackend.local;
    final multiAgentActive = AgentRoleSettingsRepository.instance.enabledNotifier.value;
    final showOrchestratorLog = backend == LlmBackend.orchestrator ||
        backend == LlmBackend.ollamaOrchestrator ||
        backend == LlmBackend.groqOrchestrator ||
        backend == LlmBackend.geminiOrchestrator ||
        backend == LlmBackend.openRouterOrchestrator ||
        backend == LlmBackend.githubOrchestrator ||
        multiAgentActive;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        // Cap the log panel to 45% of available height so the fixed-height
        // non-Expanded children never crowd out the message list and overflow
        // the parent Column.
        final clampedLogHeight = _logPanelHeight.clamp(40.0, constraints.maxHeight * 0.3);

        return Column(
          children: [
            _buildHeader(_conversation!),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildMessagesList()),
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: _buildScrollToBottomButton(),
                  ),
                ],
              ),
            ),
            if (_autoInputNotice != null) _buildAutoInputNoticeBar(),
            if (_sendError != null) _buildErrorBar(),
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
              onDownloadAsMarkdown: _downloadChatAsMarkdown,
              onCopyToClipboardAsMarkdown: _copyChatToClipboardAsMarkdown,
              onNewChatFromJson: _newChatFromJson,
              controller: _inputController,
              onAutoGenerateAgentContext: _autoGenerateAgentContext,
              taskMode: _taskMode,
              onTaskModeChanged: (v) {
                if (v == _taskMode) return;
                setState(() => _taskMode = v);
              },
            ),
            if (showServerPanel)
              QuickServerPanel(
                modelId: _conversation!.modelId ?? '',
                onServerStatusChanged: () => setState(() {}),
              ),
            if (showOrchestratorLog && _logVisible) ...[
              ResizeHandle(
                height: clampedLogHeight,
                onHeightChanged: (h) => setState(() => _logPanelHeight = h),
                minHeight: 40.0,
                inverted: true,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 10, 0),
                child: SizedBox(
                  height: clampedLogHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: _thinkingPanelWidth,
                        child: ModelThinkingPanel(
                          height: clampedLogHeight,
                          conversationId: widget.conversationId,
                        ),
                      ),
                      HorizontalResizeHandle(
                        width: _thinkingPanelWidth,
                        onWidthChanged: (w) {
                          setState(() => _thinkingPanelWidth = w);
                          SettingsRepository.instance
                              .set(_thinkingPanelWidthKey, w.toStringAsFixed(1));
                        },
                        minWidth: 120.0,
                        maxWidth: constraints.maxWidth * 0.7,
                      ),
                      Expanded(
                        child: OrchestratorLogPanel(
                          height: clampedLogHeight,
                          conversationId: widget.conversationId,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildHeader(Conversation conv) {
    return Container(
      padding: const EdgeInsets.only(left: 20, top: 8, bottom: 8),
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
          // Thinking ON/OFF + effort. Hidden while Workflow Agents MaM is
          // enabled: in that mode each role card in Settings owns its own
          // thinking flag and effort level, and the launcher seeds both on the
          // orchestrator at start-up, so a second per-conversation control here
          // would silently override the configured slots.
          ValueListenableBuilder<bool>(
            valueListenable: AgentRoleSettingsRepository.instance.enabledNotifier,
            builder: (ctx, multiAgent, _) {
              if (multiAgent) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ThinkingControl(
                  condense: true,
                  thinking: _thinking,
                  effort: _effort,
                  onThinkingChanged: (newValue) {
                    setState(() => _thinking = newValue);
                    final conv = _conversation;
                    if (conv != null) {
                      ConversationRepository.instance
                          .updateThinking(conv.id, newValue);
                      _conversation = conv.copyWith(thinking: newValue);
                    }
                  },
                  onEffortChanged: (v) {
                    setState(() => _effort = v);
                    final conv = _conversation;
                    if (conv != null) {
                      ConversationRepository.instance.updateEffort(conv.id, v);
                      _conversation = conv.copyWith(effort: v);
                    }
                  },
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<bool>(
            valueListenable: AgentRoleSettingsRepository.instance.enabledNotifier,
            builder: (ctx, multiAgent, _) {
              if (multiAgent) {
                // Multi-agent mode owns the per-role models in Settings,
                // so the per-conversation model picker is replaced by a
                // breadcrumb that shows the configured roles + their models.
                return WorkflowBreadcrumb(sending: _sending);
              }
              // AUTO INPUT is Model against Model (MaM): the reply comes from
              // the Assistant model while the review and the next user prompt
              // come from the User model, both configured in
              // Settings -> Workflow Agents MaM. Showing the single-model
              // picker here would advertise a model that is not actually
              // driving the exchange, so the header surfaces the two agents.
              if (_taskMode == 'auto_input') {
                return WorkflowBreadcrumb(
                  sending: _sending,
                  roleFilter: const ['reasoner', 'user'],
                );
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
          const SizedBox(width: 8),
          Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                border: Border.all(color: AppTheme.accentSecondary, width: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              // Start/Stop is bound to *this chat's* session only. The
              // StreamBuilder flips the icon without a manual setState, and
              // pressing it can never touch another conversation's process.
              child: StreamBuilder<OrchestratorSessionState>(
                stream: OrchestratorManager.instance
                    .peek(conv.id)
                    ?.sessionStateStream,
                initialData: OrchestratorManager.instance
                    .peek(conv.id)
                    ?.lastSessionState,
                builder: (context, snapshot) {
                  final running =
                      OrchestratorManager.instance.peek(conv.id)?.isRunning ??
                          false;
                  return IconButton(
                    tooltip: running
                        ? "Stop this chat's orchestrator"
                        : "Start this chat's orchestrator",
                    icon: Icon(
                      running ? Icons.stop_outlined : Icons.play_arrow_outlined,
                      size: 20,
                      color: running
                          ? AppTheme.accentSecondary
                          : AppTheme.accent,
                    ),
                    onPressed: () =>
                        running ? _stopOrchestrator() : _startOrchestrator(),
                  );
                },
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
                    color: isRunning ? AppTheme.accentSecondary : AppTheme.textSecondary,
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

  Future<void> _downloadChatAsMarkdown() async {
    final conv = _conversation;
    if (conv == null) return;

    final messages = await MessageRepository.instance.listByConversation(conv.id);
    final workflowTitle = await _resolveWorkflowTitle(conv);

    // Build Markdown content
    final markdownContent = StringBuffer();
    markdownContent.writeln("# ${conv.title}");
    markdownContent.writeln();
    if (workflowTitle != null) {
      markdownContent.writeln("_Workflow: $workflowTitle");
      markdownContent.writeln();
    }
    markdownContent.writeln("_Model: ${conv.modelId ?? 'unknown'} | Backend: ${conv.backend}_");
    markdownContent.writeln();
    markdownContent.writeln("---");
    markdownContent.writeln();

    for (final msg in messages) {
      final rolePrefix = msg.role == MessageRole.user ? "**User**" : "**Assistant**";
      if (msg.agent != null) {
        markdownContent.writeln("$rolePrefix (${msg.agent})");
      } else {
        markdownContent.writeln(rolePrefix);
      }
      markdownContent.writeln();
      markdownContent.writeln(msg.content);
      markdownContent.writeln();
      markdownContent.writeln("---");
      markdownContent.writeln();
    }

    final safeName = conv.title.replaceAll(RegExp(r'[\/:*?"<>|]'), '_');

    try {
      // Prefer a save dialog on platforms that support it (desktop).
      String? savePath = await FilePicker.saveFile(
        dialogTitle: 'Save chat as Markdown',
        fileName: '$safeName.md',
        type: FileType.custom,
        allowedExtensions: ['md'],
      );

      if (savePath == null && mounted) {
        // User cancelled the save dialog.
        return;
      }

      // If saveFile returned null (mobile / web fallback), write to a
      // well-known directory so the user can retrieve it.
      if (savePath == null) {
        final dir = await getApplicationDocumentsDirectory();
        savePath = '${dir.path}${Platform.pathSeparator}$safeName.md';
      }

      final file = File(savePath);
      await file.writeAsString(markdownContent.toString(), flush: true);

      if (!mounted) return;

      NotificationHelper.showSuccess(context, 'Saved to $savePath');
    } catch (e) {
      if (!mounted) return;
      NotificationHelper.showError(context, 'Failed to save Markdown: $e');
    }
  }

  Future<void> _copyChatToClipboardAsMarkdown() async {
    final conv = _conversation;
    if (conv == null) return;

    final messages = await MessageRepository.instance.listByConversation(conv.id);
    final workflowTitle = await _resolveWorkflowTitle(conv);

    // Build Markdown content
    final markdownContent = StringBuffer();
    markdownContent.writeln("# ${conv.title}");
    markdownContent.writeln();
    if (workflowTitle != null) {
      markdownContent.writeln("_Workflow: $workflowTitle");
      markdownContent.writeln();
    }
    markdownContent.writeln("_Model: ${conv.modelId ?? 'unknown'} | Backend: ${conv.backend}_");
    markdownContent.writeln();
    markdownContent.writeln("---");
    markdownContent.writeln();

    for (final msg in messages) {
      final rolePrefix = msg.role == MessageRole.user ? "**User**" : "**Assistant**";
      if (msg.agent != null) {
        markdownContent.writeln("$rolePrefix (${msg.agent})");
      } else {
        markdownContent.writeln(rolePrefix);
      }
      markdownContent.writeln();
      markdownContent.writeln(msg.content);
      markdownContent.writeln();
      markdownContent.writeln("---");
      markdownContent.writeln();
    }

    try {
      await Clipboard.setData(ClipboardData(text: markdownContent.toString()));
      if (!mounted) return;
      NotificationHelper.showSuccess(context, 'Chat Markdown copied to clipboard');
    } catch (e) {
      if (!mounted) return;
      NotificationHelper.showError(context, 'Failed to copy to clipboard: $e');
    }
  }

  Future<void> _newChatFromJson(String jsonContent) async {
    final jsonData = jsonDecode(jsonContent) as Map<String, dynamic>;

    // Create a new conversation
    final newConv = Conversation(
      id: const Uuid().v4(),
      title: 'New chat from JSON',
      modelId: _conversation?.modelId,
      backend: _conversation?.backend,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      groupId: _conversation?.groupId,
      projectPath: ProjectService().activeProjectKey,
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

    // Navigation only — a running turn is never killed here. The orchestrator
    // relaunch, if one is needed, is parked until that turn drains.
    if (OrchestratorManager.instance.isBusy) {
      OrchestratorManager.instance.requestRestart(
        reason: 'new chat created from JSON while a turn was running',
        source: OrchestratorStopSource.conversationSwitch,
      );
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
      // Explicit user STOP, scoped to this chat: the only affordance in the
      // chat surface allowed to terminate a turn that is still in flight, and
      // it must never reach another conversation's process.
      final id = widget.conversationId;
      if (id != null) {
        await OrchestratorManager.instance.stopFor(
          id,
          source: OrchestratorStopSource.chatStopButton,
          reason: 'user pressed STOP in the chat view',
        );
      }
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

      // AUTO INPUT is Model against Model: the Assistant (first slot) and the
      // User (second slot) are the models configured in Settings -> Workflow
      // Agents MaM. Selecting AUTO INPUT therefore has to bring up the
      // multi-agent orchestrator even when the master switch is off, otherwise
      // the chat would answer with the Model Settings model and the configured
      // User agent would never be consulted.
      final workflowEnabled =
          AgentRoleSettingsRepository.instance.enabledNotifier.value;
      final autoInputRequested = _taskMode == 'auto_input';
      final multiAgentEnabled = workflowEnabled || autoInputRequested;
      if (!_isOrchestratorBackend(backend) && !multiAgentEnabled) return false;

      // Multi-agent mode: start orchestrator with multi-agent flag, ignoring
      // the conversation's backend/model selection (agent config drives models).
      if (multiAgentEnabled) {
        // Already running the MaM session: reuse it. The models are owned by
        // the Workflow Agents slots, so the session only needs replacing when a
        // relaunch is explicitly pending.
        if (OrchestratorManager.instance.isRunning) {
          if (mounted && !_logVisible) {
            setState(() => _logVisible = true);
          }
          if (!OrchestratorManager.instance.hasPendingRestart) return true;
          if (OrchestratorManager.instance.isBusy) {
            // A turn is in flight: let it finish and apply the relaunch after.
            OrchestratorManager.instance.requestRestart(
              reason: 'multi-agent session requested while a turn was running',
              source: OrchestratorStopSource.modelSwitch,
            );
            return true;
          }
          await OrchestratorManager.instance.stop(
            source: OrchestratorStopSource.internalFailure,
            reason: 'relaunching the multi-agent session',
          );
        }
        if (mounted && !_logVisible) {
          setState(() => _logVisible = true);
        }
        final started = await OrchestratorManager.instance.start(multiAgent: true);
        if (mounted) {
          if (!silent) {
            if (started) {
              NotificationHelper.showSuccess(context, 'Multi-agent orchestrator active');
            } else {
              NotificationHelper.showError(context, 'Failed to start multi-agent orchestrator');
            }
          }
          setState(() {});
        }
        return started;
      }

      final desiredBackend = _desiredOrchestratorBackend(backend);
      final convModelId = _conversation?.modelId?.trim() ?? '';

      String? token;
      String? modelId;
      String? ollamaBaseUrl;
      int? ollamaNumCtx;
      bool? ollamaAutoNumCtx;
      String? ollamaApiKey;
      String? groqApiKey;
      String? geminiApiKey;
      String? openRouterApiKey;
      int? openRouterContextLimit;
      String? githubApiKey;
      double? temperature;
      int? maxTokens;
      int? tpmLimit;
      bool disableTools = false;

      switch (desiredBackend) {
        case OrchestratorBackend.ollama:
          ollamaBaseUrl = await settings.getOllamaBaseUrl();
          ollamaNumCtx = await settings.getOllamaNumCtx();
          ollamaAutoNumCtx = await settings.getOllamaAutoNumCtx();
          ollamaApiKey = await settings.getOllamaApiKey();
          temperature = await settings.getOllamaTemperature();
          maxTokens = await settings.getOllamaNumPredict();
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
          modelId = (convModelId.isNotEmpty && !convModelId.contains(':'))
              ? convModelId
              : (savedGroqModel.isNotEmpty ? savedGroqModel : convModelId);
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
          openRouterContextLimit = await settings.getOpenRouterContextLimit();
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

      // Already running on the desired backend/model/temp -> nothing to do.
      if (OrchestratorManager.instance.isRunning &&
          OrchestratorManager.instance.currentBackend == desiredBackend &&
          OrchestratorManager.instance.currentModelId == modelId &&
          OrchestratorManager.instance.currentTemperature == temperature) {
        if (mounted && !_logVisible) {
          setState(() => _logVisible = true);
        }
        return true;
      }

      // Backend / model / temperature changed: relaunch — but never while a
      // turn is mid-flight. In that case the new configuration is parked and
      // applied as soon as the running answer has reached the chat.
      if (OrchestratorManager.instance.isRunning) {
        final currentBackend = OrchestratorManager.instance.currentBackend;
        final currentModel = OrchestratorManager.instance.currentModelId;
        final currentTemp = OrchestratorManager.instance.currentTemperature;

        if (currentBackend != desiredBackend ||
            currentModel != modelId ||
            currentTemp != temperature) {
          if (OrchestratorManager.instance.isBusy) {
            OrchestratorManager.instance.requestRestart(
              reason: 'backend/model/temperature changed while a turn was running',
              source: OrchestratorStopSource.modelSwitch,
              argsFingerprint: OrchestratorManager.fingerprintFor(
                backend: desiredBackend,
                modelId: modelId ?? '',
                temperature: temperature,
                maxTokens: maxTokens,
              ),
            );
            return true;
          }
          await OrchestratorManager.instance.stop(
            source: OrchestratorStopSource.internalFailure,
            reason: 'relaunching with a different backend/model/temperature',
          );
        }
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
        ollamaAutoNumCtx: ollamaAutoNumCtx,
        ollamaApiKey: ollamaApiKey,
        groqApiKey: groqApiKey,
        geminiApiKey: geminiApiKey,
        openRouterApiKey: openRouterApiKey,
        openRouterContextLimit: openRouterContextLimit,
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
            mainAxisAlignment: MainAxisAlignment.center,
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

    // While the User agent is reviewing / writing the next prompt the Assistant
    // is idle, so the user-side indicator replaces the assistant one: the
    // transcript then reads as a turn-by-turn exchange instead of a stalled
    // assistant that keeps typing forever.
    final showAssistantTyping = _sending && !_autoInputUserWriting;
    final trailingRows =
        (showAssistantTyping ? 1 : 0) + (_autoInputUserWriting ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      itemCount: _messages.length + trailingRows,
      itemBuilder: (ctx, i) {
        if (i >= _messages.length) {
          if (showAssistantTyping && i == _messages.length) {
            return const _TypingIndicator();
          }
          return const _UserAgentTypingIndicator();
        }
        final m = _messages[i];
        final isUserAgentTurn = m.agent == 'user';
        final isLastRow = i == _messages.length - 1;
        final bubble = MessageBubble(
          message: m.content,
          timeInSeconds: (m.responseTimeMs ?? 0) / 1000.0,
          isUser: m.role == MessageRole.user,
          isStatus: m.hidden,
          roleLabel: isUserAgentTurn ? 'User agent' : null,
          // Resend / edit only apply to turns the human actually authored: the
          // User agent's prompts are generated, not typed, so they must not be
          // re-sent or edited as if they were the operator's own messages.
          onResend: (m.role == MessageRole.user &&
                  !_sending &&
                  !m.hidden &&
                  !isUserAgentTurn)
              ? () => _handleResend(m.id)
              : null,
          onEdit: (m.role == MessageRole.user &&
                  !_sending &&
                  !m.hidden &&
                  !isUserAgentTurn)
              ? () => _handleEdit(m.id)
              : null,
          onDelete: !m.hidden ? () => _handleDeleteMessage(m.id) : null,
        );

        // Flag a turn that never produced a delivered answer: the subprocess
        // died, the app was force-quit, or the user stopped it mid-flight. The
        // chip is attached to the last row so it reads as the tail of the
        // transcript rather than a detached banner.
        final interrupted = isLastRow &&
            _lastTurn != null &&
            _lastTurn!.isInterrupted &&
            !_sending;
        if (!interrupted) return bubble;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [bubble, _buildInterruptedChip(_lastTurn!)],
        );
      },
    );
  }

  /// Small inline chip marking the last turn as never delivered.
  Widget _buildInterruptedChip(ConversationTurn turn) {
    final label = turn.status == ConversationTurnStatus.aborted
        ? 'Turn interrupted'
        : 'Turn failed';
    final detail = (turn.error ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
      child: Tooltip(
        message: detail.isEmpty ? label : '$label — $detail',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppTheme.danger.withAlpha(28),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.danger.withAlpha(90)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.report_problem_outlined,
                size: 13,
                color: AppTheme.danger,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.danger,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  

  /// Banner shown when the orchestrator reports that AUTO INPUT cannot
  /// continue autonomously — currently the "no Workflow Agent configured as
  /// User" case. Styled as a warning (not an error) because no request failed:
  /// the loop simply handed control back to the user.
  Widget _buildAutoInputNoticeBar() {
    return Container(
      width: double.infinity,
      color: AppTheme.accent.withAlpha(38),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _autoInputNotice ?? '',
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => _autoInputNotice = null),
            color: AppTheme.textMuted,
            splashRadius: 14,
            tooltip: 'Dismiss',
          ),
        ],
      ),
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

    return Material(
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
            border: Border.all(color: AppTheme.accentSecondary, width: 1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 30,
            color: AppTheme.accentSecondary,
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

  /// Deliver a turn result to whichever view is mounted when it lands.
  ///
  /// The transaction that owns the turn persists the assistant message, so the
  /// handler re-reads the conversation instead of duplicating it. That is what
  /// makes a reply survive a remount: the view is disposable, the turn is not.
  Future<void> _onTurnEvent(ChatTurnEvent event) async {
    if (event.conversationId != widget.conversationId) return;
    switch (event) {
      case ChatTurnStarted():
        if (mounted) setState(() => _sending = true);
        break;
      case ChatTurnCompleted():
        await _reloadMessages();
        if (!mounted) return;
        setState(() {
          _sending = false;
          _sendError = null;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToBottom();
        });
        break;
      case ChatTurnFailed(:final error):
        if (!mounted) return;
        setState(() {
          _sending = false;
          _sendError = error;
        });
        break;
      case ChatTurnAborted():
        if (!mounted) return;
        setState(() {
          _sending = false;
          _sendError = null;
        });
        break;
    }
    await _refreshLastTurn();
  }

  /// Re-read the conversation transcript from SQLite. Used when a turn
  /// completes elsewhere so the visible history matches what was persisted.
  Future<void> _reloadMessages() async {
    final id = widget.conversationId;
    if (id == null) return;
    final msgs = await MessageRepository.instance.listByConversation(id);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(msgs);
    });
  }

  /// Refresh [_lastTurn] so an interrupted turn (crash, forced stop, app quit)
  /// is visible in the transcript instead of vanishing silently.
  Future<void> _refreshLastTurn() async {
    final id = widget.conversationId;
    if (id == null) return;
    final turn = await ConversationTurnRepository.instance
        .latestForConversation(id);
    if (!mounted) return;
    if (turn?.id == _lastTurn?.id && turn?.status == _lastTurn?.status) return;
    setState(() => _lastTurn = turn);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AgentRoleSettingsRepository.instance.enabledNotifier
        .removeListener(_syncTaskModeWithWorkflow);
    _turnSub?.cancel();
    _sessionAddedSub?.cancel();
    _autoInputNoticeSub?.cancel();
    _autoInputReplySub?.cancel();
    _autoInputPromptSub?.cancel();
    _autoInputEvaluatingSub?.cancel();
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
  StreamSubscription<String>? _statusSub;
  String _label = 'Working...';

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();

    // Seed from the last known status so late-mounted indicators show the
    // current activity instead of the generic fallback.
    final last = OrchestratorManager.instance.lastStatus;
    if (last != null && last.isNotEmpty) _label = last;

    _statusSub = OrchestratorManager.instance.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _label = status);
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
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
                          color: AppTheme.accentSecondary,
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
          Text(
            _label,
            style: const TextStyle(color: AppTheme.accentSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// User-side counterpart of [_TypingIndicator].
///
/// Shown while the AUTO INPUT User agent (second Workflow Agents slot) reviews
/// the Assistant's reply and writes the next prompt. Without it the transcript
/// would look like a single assistant typing forever with no visible
/// counterpart, because the User agent's turn happens between two assistant
/// answers.
class _UserAgentTypingIndicator extends StatefulWidget {
  const _UserAgentTypingIndicator();

  @override
  State<_UserAgentTypingIndicator> createState() =>
      _UserAgentTypingIndicatorState();
}

class _UserAgentTypingIndicatorState extends State<_UserAgentTypingIndicator>
    with SingleTickerProviderStateMixin {
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
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16, left: 16),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: AppTheme.userBubble,
          border: Border.all(width: 0.5, color: AppTheme.aiBubble),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                return Row(
                  children: List.generate(3, (i) {
                    final phase = (_c.value + i * 0.2) % 1.0;
                    final opacity =
                        0.3 + 0.7 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Opacity(
                        opacity: opacity.clamp(0.2, 1.0),
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: AppTheme.accent,
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
              'User agent is writing...',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
