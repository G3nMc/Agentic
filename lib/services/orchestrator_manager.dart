import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:agentic/services/project_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:uuid/uuid.dart';

import '../data/models/conversation_task.dart';
import '../data/repositories/agent_role_settings_repository.dart';
import '../data/repositories/backend_settings_repository.dart';
import '../data/repositories/database_connections_repository.dart';
import '../data/repositories/dev_filters_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/task_repository.dart';
import 'openrouter_service.dart';

/// Structured event emitted by the Python orchestrator while it reports
/// task-checklist progress. Two concrete shapes:
///   - [OrchestratorTasksProposed]: a fresh plan was declared.
///   - [OrchestratorTaskStatusChanged]: one task moved to a new state.
sealed class OrchestratorTaskEvent {
  const OrchestratorTaskEvent({required this.conversationId});

  final String conversationId;
}

class OrchestratorTasksProposed extends OrchestratorTaskEvent {
  const OrchestratorTasksProposed({
    required super.conversationId,
    required this.tasks,
  });

  final List<ConversationTask> tasks;
}

class OrchestratorTaskStatusChanged extends OrchestratorTaskEvent {
  const OrchestratorTaskStatusChanged({
    required super.conversationId,
    required this.taskId,
    required this.status,
    this.note = '',
    this.description = '',
  });

  final int taskId;
  final TaskStatus status;
  final String note;

  /// Human-readable task description, mirrored from the plan so the UI can
  /// show what the model is working on without a separate DB lookup.
  final String description;
}

// Inactivity timeout: if the orchestrator emits no output on stdout OR
// stderr for this long, we assume it's wedged and give up. Activity
// (including per-chunk heartbeat lines from the Python streaming loops)
// resets it. 10 min gives slow local models (phi3:mini on CPU) enough
// headroom while still catching a truly wedged process.
const Duration _kOrchestratorInactivityTimeout = Duration(minutes: 60);

// Absolute ceiling: even if the orchestrator keeps heart-beating, refuse to
// wait longer than this for a single prompt. Prevents runaway tool chains.
// Set high enough to cover long multi-agent chains where each role may take
// multiple minutes (slow cloud reasoners, large file edits + repeated
// flutter_analyze cycles). The inactivity timeout above still catches a
// truly wedged process within 10 min of silence.
const Duration _kOrchestratorAbsoluteTimeout = Duration(minutes: 600);

/// Which model backend the orchestrator subprocess should use.
///
/// The orchestrator's tool protocol is backend-agnostic; this only decides
/// who actually runs inference. [huggingface] hits the HF router (needs a
/// token), [ollama] hits a local Ollama daemon (needs the daemon running),
/// [groq] hits Groq Cloud, [gemini] hits Google AI Studio / Gemini Cloud,
/// and [openrouter] routes to any supported provider via OpenRouter.
enum OrchestratorBackend { huggingface, ollama, groq, gemini, openrouter, github }

/// Why a session teardown was requested.
///
/// Only a genuine STOP affordance (or app shutdown / crash recovery) may
/// terminate a turn that is already in flight. Every other source describes a
/// *configuration change*: the running process is allowed to finish the
/// current answer first and be relaunched afterwards.
enum OrchestratorStopSource {
  /// User pressed STOP in the chat view.
  chatStopButton,

  /// User pressed STOP in Settings -> Orchestrator.
  orchestratorSettingsButton,

  /// The application is quitting.
  appShutdown,

  /// The caller did not declare an intent (legacy call sites).
  unspecified,

  /// The active LLM backend changed.
  backendSwitch,

  /// The model / temperature / token budget changed.
  modelSwitch,

  /// A different project folder was activated.
  projectSwitch,

  /// A different conversation was opened.
  conversationSwitch,

  /// Internal recovery after a crash.
  internalFailure,
}

extension OrchestratorStopSourceX on OrchestratorStopSource {
  /// Whether this source is allowed to kill a live turn immediately.
  bool get mayTerminateSession =>
      this == OrchestratorStopSource.chatStopButton ||
      this == OrchestratorStopSource.orchestratorSettingsButton ||
      this == OrchestratorStopSource.appShutdown ||
      this == OrchestratorStopSource.internalFailure;
}

/// Lifecycle of the orchestrator subprocess.
///
/// stopped -> starting -> idle -> busy -> idle ... -> stopped
/// A configuration change requested while [busy] is parked as a deferred
/// relaunch and applied once the turn has been delivered to the UI.
enum OrchestratorSessionState {
  stopped,
  starting,
  idle,
  busy,
  restarting,
  failed,
}

/// Raised into an awaiting [OrchestratorManager.sendPrompt] future when the
/// session is torn down underneath it, so the UI reports an abort instead of
/// waiting for the absolute timeout to expire.
class OrchestratorAborted implements Exception {
  OrchestratorAborted(this.source, this.reason);

  final String source;
  final String reason;

  @override
  String toString() => 'Orchestrator session aborted ($source): $reason';
}

/// A relaunch that had to wait until the in-flight turn was delivered.
class _PendingRestart {
  _PendingRestart(this.reason, this.source, this.argsFingerprint);

  final String reason;
  final OrchestratorStopSource source;
  final String argsFingerprint;
}

/// Visual activity of a conversation's orchestrator session, as rendered by
/// the sidebar: [working] shows a leading spinner and an amber dot,
/// [answered] shows a green dot, and [idle] shows neither.
enum SessionActivity {
  /// No session, or a session that has never delivered an answer.
  idle,

  /// A turn is in flight, or the MaM User model is evaluating the reply.
  working,

  /// The last turn delivered an assistant answer.
  answered,
}

/// One orchestrator subprocess, bound to exactly one conversation.
///
/// Protocol (must match `bin/orchestrator.py`):
///   - Orchestrator is launched with `--interactive`.
///   - When ready it prints a single line: `__READY__`
///   - Client writes ONE JSON line per request:
///       {"prompt": "...", "new_session": true|false}
///   - Orchestrator replies with exactly one JSON line:
///       {"response": "..."}
///     followed by a single line:
///       __RESPONSE_END__
///
/// This class used to be the application-wide singleton `OrchestratorManager`.
/// It is now an instance class: every conversation owns one session, so a turn
/// running in chat A is completely independent from a turn running in chat B.
/// The former singleton identity lives on in the [OrchestratorManager] facade
/// declared at the bottom of this file, which indexes sessions by chat GUID.
///
/// Nothing inside a session changed: the subprocess protocol, the deferred
/// relaunch, the stop authority and the log/status/trace streams are exactly as
/// they were, they are simply no longer shared between conversations.
class OrchestratorSession {
  OrchestratorSession(this.conversationId);

  /// The chat GUID this session belongs to.
  ///
  /// It is simultaneously the log file name (`logs/<guid>.log`), the value sent
  /// to Python as `session_key` / `conversation_id`, and the key the registry
  /// indexes this session by.
  final String conversationId;

  Process? _process;
  bool _isRunning = false;
  bool _isReady = false;

  /// Current lifecycle state of the subprocess. [_isRunning] is derived from
  /// it so every legacy `isRunning` guard keeps working unchanged.
  OrchestratorSessionState _state = OrchestratorSessionState.stopped;

  final StreamController<OrchestratorSessionState> _stateController =
      StreamController<OrchestratorSessionState>.broadcast();

  /// Relaunch parked because a turn was in flight when the configuration
  /// changed. Drained in the `finally` of [_sendPromptInternal].
  _PendingRestart? _pendingRestart;

  /// Fingerprint of the arguments the running subprocess was launched with.
  /// Used to drop restart requests that would not change anything.
  String _argsFingerprint = '';

  // Guards against concurrent start() calls before _isRunning flips true.
  // Holds the in-flight start() future so overlapping callers await the same
  // result instead of each spawning their own subprocess.
  Future<bool>? _startingFuture;
  OrchestratorBackend _currentBackend = OrchestratorBackend.huggingface;
  String? _currentModelId;
  double? _currentTemperature;
  final StringBuffer _stderrBuffer = StringBuffer();

  // â”€â”€ Live log stream â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // A broadcast StreamController so multiple widgets can subscribe
  // simultaneously without causing "already subscribed" errors.
  final StreamController<String> _logController = StreamController<String>.broadcast();

  // â”€â”€ Multi-agent execution-trace stream â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Each entry is one agent activation. Only fires when the orchestrator was
  // launched with `multiAgent: true` and Python actually returned a `trace`
  // array in its response payload. Single-agent mode leaves this idle.
  final StreamController<List<Map<String, Object?>>> _traceController = StreamController<List<Map<String, Object?>>>.broadcast();

  Stream<List<Map<String, Object?>>> get traceStream => _traceController.stream;
  List<Map<String, Object?>> _lastTrace = const [];

  List<Map<String, Object?>> get lastTrace => List.unmodifiable(_lastTrace);

  // â”€â”€ Human-friendly status stream â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Each event is a short label like "Reading file..." or "Analyzing Dart
  // code..." that the typing indicator displays instead of "Working...".
  final StreamController<String> _statusController = StreamController<String>.broadcast();

  /// Live stream of human-friendly status labels derived from orchestrator
  /// log lines. Use this to show what the model is doing right now.
  Stream<String> get statusStream => _statusController.stream;

  /// Notices raised by the AUTO INPUT loop that the user must see in the
  /// chat surface — currently the "no User agent configured" case, where the
  /// loop fails safe and waits for real input instead of letting the
  /// Assistant review its own work.
  final StreamController<String> _autoInputNoticeController =
      StreamController<String>.broadcast();

  /// Human-readable AUTO INPUT notices (empty when nothing to report).
  Stream<String> get autoInputNoticeStream => _autoInputNoticeController.stream;

  /// Intermediate Assistant answers produced while AUTO INPUT keeps working
  /// autonomously. Each round emits one entry so the chat can render the
  /// running output instead of jumping straight to the final answer.
  final StreamController<String> _autoInputReplyController =
      StreamController<String>.broadcast();

  /// Intermediate AUTO INPUT answers, in order.
  Stream<String> get autoInputReplyStream => _autoInputReplyController.stream;

  /// Intermediate AUTO INPUT answers already received for the current turn.
  /// Widgets that mount late read this to rebuild the running transcript.
  final List<String> _autoInputReplies = [];

  List<String> get autoInputReplies => List.unmodifiable(_autoInputReplies);

  /// Continuation prompts authored by the User agent (second Workflow Agents
  /// slot) while AUTO INPUT keeps working. Each one is fed back to the
  /// Assistant as the next user turn, so the chat renders it as a real
  /// user-side bubble instead of showing back-to-back assistant replies.
  final StreamController<String> _autoInputPromptController =
      StreamController<String>.broadcast();

  /// User-agent continuation prompts, in order.
  Stream<String> get autoInputPromptStream => _autoInputPromptController.stream;

  final List<String> _autoInputPrompts = [];

  List<String> get autoInputPrompts => List.unmodifiable(_autoInputPrompts);

  /// True while the User agent is reviewing the Assistant's reply and writing
  /// the next prompt. Drives a user-side indicator so the exchange reads as a
  /// continuing conversation rather than a stalled assistant.
  final StreamController<bool> _autoInputEvaluatingController =
      StreamController<bool>.broadcast();

  Stream<bool> get autoInputEvaluatingStream =>
      _autoInputEvaluatingController.stream;

  bool _autoInputEvaluating = false;

  bool get autoInputEvaluating => _autoInputEvaluating;

  void _setAutoInputEvaluating(bool value) {
    if (_autoInputEvaluating == value) return;
    _autoInputEvaluating = value;
    if (!_autoInputEvaluatingController.isClosed) {
      _autoInputEvaluatingController.add(value);
    }
    // While the User model reviews the Assistant's reply and writes the next
    // prompt the sidebar must keep showing `working` (amber), so the MaM
    // exchange is legible from the chat list without opening the chat.
    _refreshActivity();
  }

  // Thinking stream: carries the model's chain-of-thought, emitted by the
  // Python orchestrator as structured thinking envelopes on stdout. The chat
  // view subscribes to show the current reasoning live in the activity strip.
  final StreamController<String> _thinkingController = StreamController<String>.broadcast();

  /// Live stream of model chain-of-thought text (may be multi-line).
  Stream<String> get thinkingStream => _thinkingController.stream;

  String? _lastThinking;

  /// Most recent chain-of-thought text, or null if none has been emitted.
  String? get lastThinking => _lastThinking;

  /// Live stream of orchestrator log lines (stderr of the subprocess).
  /// Each event is a single trimmed line such as
  ///   "[orch] Groq streaming 'llama-3.3-70b-versatile' (42 chars)..."
  Stream<String> get logStream => _logController.stream;

  // ── Task-flow event stream ────────────────────────────────────────
  // Carries structured events emitted by the Python orchestrator while it
  // reports task-checklist progress: ``tasks_proposed`` (plan
  // declared), ``task_status`` (one task moved to a new state). The UI
  // subscribes via ``taskStream`` to update the checklist panel live
  // and the persistence layer subscribes to mirror changes into the
  // ``conversation_tasks`` SQLite table.
  final StreamController<OrchestratorTaskEvent> _taskController = StreamController<OrchestratorTaskEvent>.broadcast();

  /// Live stream of structured task-flow events.
  Stream<OrchestratorTaskEvent> get taskStream => _taskController.stream;

  /// The underlying stream controller for task-flow events. Exposed so
  /// the UI can inject synthetic events (e.g. clearing the plan when
  /// the user sends a new prompt) without going through the Python side.
  StreamController<OrchestratorTaskEvent> get taskController => _taskController;

  /// Conversation id currently being processed. Set by
  /// [_sendPromptInternal] just before writing to stdin so the
  /// dispatcher can attach it to incoming task events (Python doesn't
  /// re-echo it on every event).
  String? _currentConversationId;

  /// Rolling in-memory buffer of the most recent [_kMaxLogLines] lines.
  /// Useful for widgets that appear after the process has already emitted
  /// output (they can populate themselves from this list on first build).
  static const int _kMaxLogLines = 2000;
  final List<String> _logLines = [];

  List<String> get logLines => List.unmodifiable(_logLines);
  String? _lastNonEmptyLogLine;

  void _appendLog(String line) {
    final trimmed = line.trim();
    // Empty lines are pure heartbeat signals from the Python streaming loop.
    // They still bump the inactivity watchdog (the listener calls
    // _bumpInactivityTimer unconditionally) but we don't show them in the
    // visible log so they don't scroll meaningful output off screen.
    if (trimmed.isEmpty) return;

    // Avoid repeated noise when the same startup/preflight error is emitted
    // multiple times in quick succession.
    if (_lastNonEmptyLogLine == trimmed) return;
    _lastNonEmptyLogLine = trimmed;

    _stderrBuffer.writeln(trimmed);
    _logLines.add(trimmed);
    if (_logLines.length > _kMaxLogLines) _logLines.removeAt(0);
    if (!_logController.isClosed) _logController.add(trimmed);

    // Persist to the per-chat log file so logs survive process restarts.
    _writeToLogFile(trimmed);

    // Derive a human-friendly status label from the raw log line and push
    // it onto the status stream so the typing indicator can show what the
    // model is doing right now instead of a generic "Working...".
    final status = _deriveStatus(trimmed);
    if (status != null) {
      _lastStatus = status;
      if (!_statusController.isClosed) _statusController.add(status);
    }
  }

  /// Append a single line to `<basePath>/logs/<sessionKey>.log`.
  ///
  /// Creates the `logs/` directory on first write. When a previous chat is
  /// reloaded the file already exists, so new lines naturally append after
  /// the previous session's output â€” no explicit prepend step needed.
  void _writeToLogFile(String line) {
    final base = _basePath;
    final key = conversationId;
    if (base == null || key.isEmpty) return;
    try {
      final dir = Directory('$base${Platform.pathSeparator}logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(
        '${dir.path}${Platform.pathSeparator}$key.log',
      );
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Best-effort: never let a disk write failure crash the orchestrator
      // or leak into the visible log stream.
    }
  }

  /// Push a synthetic line into the log buffer + stream + on-disk file.
  /// Used by the UI to surface client-side events (e.g. task_action
  /// envelopes leaving the Flutter side) in the same panel as the
  /// orchestrator-side stderr output, so a debugger can see the full
  /// model<->orchestrator<->UI exchange in chronological order.
  void _injectLogLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _logLines.add(trimmed);
    if (_logLines.length > _kMaxLogLines) _logLines.removeAt(0);
    if (!_logController.isClosed) _logController.add(trimmed);
    _writeToLogFile(trimmed);
  }

  /// Read the on-disk log file for [sessionKey] and push every line into the
  /// in-memory buffer and live stream so the log panel shows previous-session
  /// output immediately when a chat is reloaded.
  ///
  /// Safe to call before the orchestrator subprocess is running â€” only needs
  /// [_basePath] to be set (which happens during [start]).
  void loadLogFromDisk(String sessionKey) {
    final base = _basePath;
    if (base == null || sessionKey.isEmpty) return;
    try {
      final file = File(
        '$base${Platform.pathSeparator}logs${Platform.pathSeparator}$sessionKey.log',
      );
      if (!file.existsSync()) return;
      final lines = file.readAsLinesSync();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        _logLines.add(trimmed);
        if (_logLines.length > _kMaxLogLines) _logLines.removeAt(0);
        if (!_logController.isClosed) _logController.add(trimmed);
      }
    } catch (_) {
      // Best-effort: never let a disk read failure block the UI.
    }
  }

  /// Latest human-friendly status label, or null if nothing has been derived
  /// yet. Widgets that mount late can read this to show the current activity.
  String? _lastStatus;

  /// Current human-friendly status label (may be null).
  String? get lastStatus => _lastStatus;

  /// Map a raw orchestrator log line to a short, user-facing label.
  ///
  /// Returns null when the line doesn't carry a meaningful activity signal
  /// (e.g. pure heartbeat, token-budget trimming, circuit-breaker chatter).
  /// The returned string should be short enough to fit next to the three
  /// animated dots â€” aim for â‰¤ 40 characters.
  static String? _deriveStatus(String line) {
    final l = line.toLowerCase();

    // â”€â”€ Task-flow progress (show in typing indicator) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[task]') && l.contains('-> in_progress')) {
      final note = _extractAfter(line, ': ');
      if (note != null && note.isNotEmpty) return note;
      return 'Working on task...';
    }
    if (l.contains('[task] proposed plan')) return 'Planning...';

    // â”€â”€ Tool calls â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[orch] -> tool ')) {
      final tool = _extractAfter(line, '[orch] -> tool ');
      if (tool == null) return null;
      return _labelForTool(tool);
    }

    // â”€â”€ Model reply arrived â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[orch] model reply')) return null;

    // â”€â”€ Request dispatched â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    // Request-dispatch lines fire immediately on every send and are not real
    // progress — the strip must stay hidden until an actual tool call, task
    // status, or thinking event arrives.
    if (l.contains('[orch] request (tool-enabled)')) return null;
    if (l.contains('[orch] request (chat)')) return null;

    // â”€â”€ Multi-agent role transitions â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[agent:router')) return 'Routing task...';
    if (l.contains('[agent:shaper')) return 'Shaping plan...';
    if (l.contains('[agent:reasoner')) return 'Reasoning...';
    if (l.contains('[agent:executor')) return 'Executing tools...';

    // â”€â”€ Retry / recovery signals â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('retrying in tool mode')) return 'Switching to tools...';
    if (l.contains('malformed tool call detected')) return 'Correcting format...';
    if (l.contains('truncated tool call detected')) return 'Continuing tool call...';
    if (l.contains('truncated final answer detected')) return 'Continuing answer...';
    if (l.contains('refusal detected')) return 'Overcoming refusal...';
    if (l.contains('cliffhanger reply detected')) return 'Pushing to act...';

    // â”€â”€ Validation runs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('flutter_analyze')) return 'Analyzing Dart code...';
    if (l.contains('python_check')) return 'Checking Python syntax...';
    if (l.contains('python_lint')) return 'Linting Python...';
    if (l.contains('python_test')) return 'Running tests...';

    // â”€â”€ Synthesis / recap â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('synthesis succeeded')) return 'Summarizing...';
    if (l.contains('synthesis call failed')) return 'Summarizing...';
    if (l.contains('max iterations reached')) return 'Wrapping up...';
    if (l.contains('repeat-call cap reached')) return 'Wrapping up...';

    // â”€â”€ Progress / extension â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('progress detected')) return 'Making progress...';
    if (l.contains('complex multi-file')) return 'Working on multiple files...';

    // â”€â”€ Nudge / pressure â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[nudge]')) return 'Nudging to act...';
    if (l.contains('[final warning]')) return 'Final push to act...';

    // â”€â”€ History trimming (noise â€” don't show) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('history trimmed')) return null;
    if (l.contains('history over token budget')) return null;

    // â”€â”€ Rate-limit / circuit-breaker (noise) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('tpm limit')) return null;
    if (l.contains('transient error')) return null;
    if (l.contains('circuit breaker')) return null;

    return null;
  }

  static String? _extractAfter(String line, String prefix) {
    final idx = line.indexOf(prefix);
    if (idx == -1) return null;
    final after = line.substring(idx + prefix.length);
    // Tool calls look like: read_file(path='...', start_line=...)
    final paren = after.indexOf('(');
    if (paren == -1) return after.trim();
    return after.substring(0, paren).trim();
  }

  static String _labelForTool(String toolName) {
    switch (toolName) {
      case 'read_file':
        return 'Reading file...';
      case 'read_files':
        return 'Reading files...';
      case 'write_file':
        return 'Writing file...';
      case 'append_file':
        return 'Appending to file...';
      case 'patch_file':
        return 'Patching file...';
      case 'delete_file':
        return 'Deleting file...';
      case 'move_file':
        return 'Moving file...';
      case 'create_directory':
        return 'Creating directory...';
      case 'list_files':
        return 'Listing files...';
      case 'list_files_recursive':
        return 'Exploring project...';
      case 'search_in_files':
        return 'Searching code...';
      case 'find_files':
        return 'Finding files...';
      case 'run_command':
        return 'Running command...';
      case 'git_status':
        return 'Checking git status...';
      case 'git_diff':
        return 'Viewing git diff...';
      case 'git_log':
        return 'Reading git history...';
      case 'git_commit':
        return 'Committing changes...';
      case 'git_checkout':
        return 'Switching branch...';
      case 'git_branches':
        return 'Listing branches...';
      case 'flutter_analyze':
        return 'Analyzing Dart code...';
      case 'python_check':
        return 'Checking Python syntax...';
      case 'python_lint':
        return 'Linting Python...';
      case 'python_format':
        return 'Formatting Python...';
      case 'python_test':
        return 'Running tests...';
      case 'db_query':
        return 'Querying database...';
      default:
        return 'Working...';
    }
  }

  // Completes when the orchestrator prints `__READY__` on stdout.
  Completer<void>? _readyCompleter;

  // Queue of in-flight requests so sends are serialized on the stdin pipe.
  Future<String> _chain = Future.value('');

  // Per-request assembly state.
  Completer<String>? _activeCompleter;
  final List<String> _activeLines = [];

  /// Correlation id of the turn currently in flight. Echoed back by Python in
  /// the response envelope so an answer that belongs to a turn the user already
  /// stopped can be discarded instead of landing in the next turn.
  String? _activeRequestId;

  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  // Inactivity watchdog for the currently active request.
  Timer? _inactivityTimer;
  DateTime? _requestStartedAt;
  String? _basePath;

  /// The chat GUID this session serves.
  ///
  /// Kept under its historical name so existing readers (the Team Mode board
  /// viewer) keep working. The value is immutable for the session's lifetime:
  /// a session belongs to exactly one conversation, and switching chats never
  /// rebinds it.
  String? get currentSessionKey => conversationId;

  bool get isRunning => _isRunning;

  bool get isReady => _isReady;

  /// Live lifecycle transitions of the subprocess.
  Stream<OrchestratorSessionState> get sessionStateStream =>
      _stateController.stream;

  /// Current lifecycle state — widgets mounting late read this instead of
  /// waiting for the next stream event.
  OrchestratorSessionState get lastSessionState => _state;

  /// True while a prompt is being processed. Every destructive action checks
  /// this so a live turn is never killed by an unrelated affordance.
  bool get isBusy => _state == OrchestratorSessionState.busy;

  /// True when a configuration change is parked until the current turn ends.
  bool get hasPendingRestart => _pendingRestart != null;

  /// Fingerprint of the arguments the running subprocess was launched with.
  String get argsFingerprint => _argsFingerprint;

  /// Update the lifecycle state and mirror it onto [_isRunning] so all
  /// pre-existing `isRunning` guards keep working.
  void _setState(OrchestratorSessionState next) {
    if (_state == next) return;
    _state = next;
    _isRunning = next == OrchestratorSessionState.idle ||
        next == OrchestratorSessionState.starting ||
        next == OrchestratorSessionState.busy ||
        next == OrchestratorSessionState.restarting;
    if (!_stateController.isClosed) _stateController.add(next);
    _refreshActivity();
  }

  // ── Activity ─────────────────────────────────────────────────────────────
  // Single source of truth for the sidebar indicators: emitted on every
  // transition and readable synchronously, so a freshly mounted tile paints
  // immediately instead of waiting for a stream event.
  final StreamController<SessionActivity> _activityController =
      StreamController<SessionActivity>.broadcast();

  SessionActivity _activity = SessionActivity.idle;

  /// Current activity of this chat's session.
  SessionActivity get activity => _activity;

  /// Live activity transitions, consumed by this chat's sidebar tile.
  Stream<SessionActivity> get activityStream => _activityController.stream;

  void _setActivity(SessionActivity next) {
    if (_activity == next) return;
    _activity = next;
    if (!_activityController.isClosed) _activityController.add(next);
  }

  /// Re-derive [activity] from the lifecycle state and the AUTO INPUT flag.
  ///
  /// A session is [SessionActivity.working] whenever a turn is in flight *or*
  /// the MaM User model is evaluating the Assistant's reply, so the whole
  /// exchange stays amber. It becomes [SessionActivity.answered] only when the
  /// final assistant reply has been delivered, and returns to
  /// [SessionActivity.idle] once the subprocess stops.
  void _refreshActivity({bool answered = false}) {
    if (_state == OrchestratorSessionState.stopped ||
        _state == OrchestratorSessionState.failed) {
      _setActivity(SessionActivity.idle);
      return;
    }
    if (answered) {
      _setActivity(SessionActivity.answered);
      return;
    }
    if (_state == OrchestratorSessionState.starting ||
        _state == OrchestratorSessionState.restarting ||
        _state == OrchestratorSessionState.busy ||
        _autoInputEvaluating) {
      _setActivity(SessionActivity.working);
      return;
    }
    // Idle process: keep the last outcome so the green dot survives the end of
    // the turn instead of being erased the moment the process drains.
    if (_activity == SessionActivity.answered) return;
    _setActivity(SessionActivity.idle);
  }

  /// Every source passed to [stop] in this process, in call order.
  ///
  /// Widget tests assert that navigation and configuration affordances never
  /// request a teardown; recording the source is cheaper and far more precise
  /// than mocking the singleton. Cleared by [debugResetSession].
  @visibleForTesting
  static final List<OrchestratorStopSource> debugStopCalls =
      <OrchestratorStopSource>[];

  /// Every [requestRestart] reason recorded in this process, in call order.
  @visibleForTesting
  static final List<String> debugRestartReasons = <String>[];

  // ── Test seams ────────────────────────────────────────────────────────────
  // The stop-authority and deferred-restart rules are pure state-machine
  // decisions: they depend on the session state, the launch fingerprint and
  // the presence of an in-flight turn — never on a live subprocess. These
  // helpers let unit tests drive exactly those inputs, so no test has to spawn
  // Python, touch path_provider or open the SQLite database.

  /// Force the session into [state] and pretend the running process was
  /// launched with [argsFingerprint].
  @visibleForTesting
  void debugSetSessionState({
    required OrchestratorSessionState state,
    String argsFingerprint = '',
  }) {
    _argsFingerprint = argsFingerprint;
    _setState(state);
  }

  /// Force the MaM "User model is reviewing the reply" flag, so a widget test
  /// can verify that the sidebar keeps the chat amber across the exchange
  /// without spawning a subprocess or calling a provider.
  @visibleForTesting
  void debugSetAutoInputEvaluating(bool value) => _setAutoInputEvaluating(value);

  /// Record that this session delivered an answer, so its activity becomes
  /// [SessionActivity.answered] without running a real turn.
  @visibleForTesting
  void debugMarkAnswered() => _refreshActivity(answered: true);

  /// Install a fresh in-flight turn completer and return it, so a test can
  /// observe how a teardown resolves an awaiting [sendPrompt] future.
  @visibleForTesting
  Completer<String> debugArmTurn() {
    final completer = Completer<String>();
    _activeCompleter = completer;
    _activeLines.clear();
    return completer;
  }

  /// True while [debugArmTurn]'s completer is still registered as the active
  /// turn — i.e. a teardown failed to resolve it.
  @visibleForTesting
  bool get debugHasActiveTurn => _activeCompleter != null;

  /// Return the singleton to a pristine state between tests.
  @visibleForTesting
  void debugResetSession() {
    _activeCompleter = null;
    _activeLines.clear();
    _cancelInactivityTimer();
    _requestStartedAt = null;
    _pendingRestart = null;
    _argsFingerprint = '';
    _process = null;
    _isReady = false;
    _setState(OrchestratorSessionState.stopped);
  }

  /// Build the launch fingerprint for a would-be session.
  ///
  /// Two sessions with the same fingerprint behave identically, so a restart
  /// request that produces the same value can be dropped outright — this is
  /// what stops "open a dropdown and set it back" from killing a turn.
  static String fingerprintFor({
    required OrchestratorBackend backend,
    required String modelId,
    double? temperature,
    int? maxTokens,
    bool multiAgent = false,
    String? basePath,
  }) {
    final path = basePath ?? ProjectService().currentPath;
    return '${backend.name}|$modelId|${temperature ?? ''}|'
        '${maxTokens ?? ''}|$multiAgent|$path';
  }

  /// Whether the running subprocess was launched with [fingerprint].
  bool matchesFingerprint(String fingerprint) =>
      _isRunning && _argsFingerprint == fingerprint;

  OrchestratorBackend get currentBackend => _currentBackend;

  String? get currentModelId => _currentModelId;

  double? get currentTemperature => _currentTemperature;

  String get stderrLog => _stderrBuffer.toString();

  /// Platform-appropriate Python executable used as a fallback when the
  /// user has not configured an explicit interpreter in Settings â†’ Developer.
  static String get defaultPythonExecutable => Platform.isWindows ? 'python' : 'python3';

  /// Resolves the Python interpreter to launch the orchestrator with.
  /// Honours the user-configured override in SettingsRepository, otherwise
  /// falls back to the platform default (PATH lookup).
  static Future<String> resolvePythonExecutable() async {
    final configured = await SettingsRepository.instance.getPythonPath();
    if (configured != null && configured.trim().isNotEmpty) {
      return  configured.trim();
    }
    return defaultPythonExecutable;
  }

  /// Builds the environment map handed to the orchestrator subprocess.
  /// Always sets `PYTHONDONTWRITEBYTECODE=1` so the bundled Python sources
  /// don't leave `__pycache__` directories scattered through the install â€”
  /// has to be in the env (not just sys.dont_write_bytecode) because the
  /// flag must be active before Python parses the entry script itself.
  /// Prepends `<flutterSdkPath>/bin` to `PATH` when the user has configured
  /// a Flutter SDK location, so `subprocess.run(["flutter", ...])` inside
  /// the Python tools resolves without requiring system-wide PATH setup.
  static Future<Map<String, String>> resolveSubprocessEnvironment() async {
    final base = <String, String>{
      ...Platform.environment,
      'PYTHONDONTWRITEBYTECODE': '1',
    };
    final flutterSdk = (await SettingsRepository.instance.getFlutterSdkPath())?.trim();
    if (flutterSdk == null || flutterSdk.isEmpty) return base;
    final flutterBin = '$flutterSdk${Platform.pathSeparator}bin';
    final currentPath = base['PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    return {
      ...base,
      'PATH': '$flutterBin$sep$currentPath',
      'FLUTTER_ROOT': flutterSdk,
    };
  }

  /// Resolve the orchestrator script path based on whether multi-agent mode is
  /// active. Single-agent mode uses the legacy `orchestrator.py`; multi-agent
  /// mode uses the new `orchestrator_v2.py`.
  static File _resolveScriptPath(bool multiAgent) {
    final scriptName = multiAgent ? 'orchestrator_multi.py' : 'orchestrator.py';
    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/bin/$scriptName',
      '$cwd/$scriptName',
      '${Directory.current.parent.path}/bin/$scriptName',
    ];
    for (final p in candidates) {
      final f = File(p);
      if (f.existsSync()) return f;
    }
    // Fall back to the first candidate (caller will surface the error).
    return File(candidates.first);
  }

  /// Directory the orchestrator is allowed to touch (its --base-path).
  /// Defaults to the project root so tools operate on the current project.
  static Directory get baseDirectory => Directory(ProjectService.windowsToLinuxPath(ProjectService().currentPath));

  /// Install Python dependencies the orchestrator needs. Runs synchronously
  /// (streams output via [onLine] if provided) and returns true on success.
  Future<bool> installDependencies({void Function(String line)? onLine}) async {
    // Install deps for both the legacy single-agent orchestrator and the
    // new multi-agent orchestrator_v2, so the button works regardless of
    // which mode the user later switches to.
    final scripts = <File>[
      _resolveScriptPath(false),
      _resolveScriptPath(true),
    ];
    bool allOk = true;
    for (final script in scripts) {
      if (!script.existsSync()) {
        onLine?.call('Skipping ${script.path} (not found)');
        continue;
      }
      final python = await resolvePythonExecutable();
      onLine?.call('Running: $python ${script.path} --install-deps');
      try {
        final proc = await Process.start(
          python,
          [script.path, '--install-deps'],
          workingDirectory: script.parent.path,
        );
        final stdoutDone = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();
        final stderrDone = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();
        final exitCode = await proc.exitCode;
        await Future.wait([stdoutDone, stderrDone]);
        onLine?.call('Exit code: $exitCode');
        if (exitCode != 0) allOk = false;
      } catch (e) {
        onLine?.call('ERROR: $e');
        allOk = false;
      }
    }
    return allOk;
  }

  /// Install a single Python package via `python -m pip install <package>`.
  Future<bool> installPackage(
    String packageName, {
    void Function(String line)? onLine,
  }) async {
    final python = await resolvePythonExecutable();
    onLine?.call('Running: $python -m pip install --user $packageName');
    try {
      final proc = await Process.start(
        python,
        ['-m', 'pip', 'install', '--user', packageName],
      );

      final stdoutDone = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();
      final stderrDone = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();

      final exitCode = await proc.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      onLine?.call('Exit code: $exitCode');
      return exitCode == 0;
    } catch (e) {
      onLine?.call('ERROR: $e');
      return false;
    }
  }

  /// Start the orchestrator subprocess. Returns false if it was already
  /// running or if launch failed.
  ///
  /// For [OrchestratorBackend.huggingface] (default), [hfToken] is required.
  /// For [OrchestratorBackend.ollama], [hfToken] is ignored and [modelId]
  /// must be an Ollama tag (e.g. `qwen2.5-coder:7b`). For
  /// [OrchestratorBackend.gemini], pass a Gemini model (e.g.
  /// `gemini-2.5-flash`) and a Google AI Studio key. Optional
  /// [ollamaBaseUrl] / [ollamaNumCtx] / [ollamaAutoNumCtx] are forwarded to the Python side.
  Future<bool> start({
    String? hfToken,
    String? modelId,
    String? workingDirectory,
    OrchestratorBackend backend = OrchestratorBackend.huggingface,
    String? ollamaBaseUrl,
    int? ollamaNumCtx,
    bool? ollamaAutoNumCtx,
    double? temperature,
    int? maxTokens,
    String? ollamaApiKey,
    String? groqApiKey,
    String? geminiApiKey,
    String? openRouterApiKey,
    int? openRouterContextLimit,
    String? githubApiKey,
    int? tpmLimit,
    bool disableTools = false,
    bool? multiAgent,
  }) {
    if (_isRunning) {
      // The session is already alive: nothing to launch, and this is not a
      // failure. When a configuration change is pending it has been parked in
      // `_pendingRestart` and is applied as soon as the running turn drains.
      return Future.value(true);
    }
    // Coalesce: a second caller while the first is still awaiting __READY__
    // must NOT spawn a second subprocess. Return the in-flight future instead.
    final inflight = _startingFuture;
    if (inflight != null) return inflight;
    final fut = _startInternal(
      hfToken: hfToken,
      modelId: modelId,
      workingDirectory: workingDirectory,
      backend: backend,
      ollamaBaseUrl: ollamaBaseUrl,
      ollamaNumCtx: ollamaNumCtx,
      ollamaAutoNumCtx: ollamaAutoNumCtx,
      temperature: temperature,
      maxTokens: maxTokens,
      ollamaApiKey: ollamaApiKey,
      groqApiKey: groqApiKey,
      geminiApiKey: geminiApiKey,
      openRouterApiKey: openRouterApiKey,
      openRouterContextLimit: openRouterContextLimit,
      githubApiKey: githubApiKey,
      tpmLimit: tpmLimit,
      disableTools: disableTools,
      multiAgent: multiAgent,
    ).whenComplete(() => _startingFuture = null);
    _startingFuture = fut;
    return fut;
  }

  Future<bool> _startInternal({
    String? hfToken,
    String? modelId,
    String? workingDirectory,
    OrchestratorBackend backend = OrchestratorBackend.huggingface,
    String? ollamaBaseUrl,
    int? ollamaNumCtx,
    bool? ollamaAutoNumCtx,
    double? temperature,
    int? maxTokens,
    String? ollamaApiKey,
    String? groqApiKey,
    String? geminiApiKey,
    String? openRouterApiKey,
    int? openRouterContextLimit,
    String? githubApiKey,
    int? tpmLimit,
    bool disableTools = false,
    bool? multiAgent,
  }) async {
    // When the caller doesn't override, honour the toggle the user set in the
    // Workflow Agents settings panel. This way every existing start-button
    // wiring flips into multi-agent mode automatically once the user enables
    // it, without each caller having to thread the flag through.
    final effectiveMultiAgent = multiAgent ?? await AgentRoleSettingsRepository.instance.isEnabled();
    final backendSettings = BackendSettingsRepository.instance;

    // Ollama cloud requires a Bearer key when talking directly to ollama.com.
    // Fill from persisted settings if the caller didn't pass explicit values.
    if (backend == OrchestratorBackend.ollama) {
      if (ollamaBaseUrl == null || ollamaBaseUrl.isEmpty) {
        ollamaBaseUrl = await backendSettings.getOllamaBaseUrl();
      }
      if (ollamaApiKey == null || ollamaApiKey.isEmpty) {
        ollamaApiKey = await backendSettings.getOllamaApiKey();
      }
    }

    if (backend == OrchestratorBackend.openrouter) {
      if (openRouterApiKey == null || openRouterApiKey.isEmpty) {
        openRouterApiKey = await backendSettings.getOpenRouterApiKey();
      }
      if (openRouterContextLimit == null && openRouterApiKey != null && openRouterApiKey.isNotEmpty && modelId != null && modelId.isNotEmpty) {
        openRouterContextLimit = await OpenRouterService.instance.fetchContextLimit(openRouterApiKey, modelId);
      }
    }

    // In multi-agent mode the agent config can reference any backend
    // regardless of the primary `backend` parameter. Auto-fill any missing
    // key from persistent settings so the Python `SecretsResolver` doesn't
    // crash with `<X> backend requires --<x>-api-key` when a role uses a
    // different provider than the primary one.
    if (effectiveMultiAgent) {
      if (hfToken == null || hfToken.isEmpty) {
        hfToken = await SettingsRepository.instance.getHfToken();
      }
      if (groqApiKey == null || groqApiKey.isEmpty) {
        groqApiKey = await backendSettings.getGroqApiKey();
      }
      if (geminiApiKey == null || geminiApiKey.isEmpty) {
        geminiApiKey = await backendSettings.getGeminiApiKey();
      }
      if (openRouterApiKey == null || openRouterApiKey.isEmpty) {
        openRouterApiKey = await backendSettings.getOpenRouterApiKey();
      }
      if (githubApiKey == null || githubApiKey.isEmpty) {
        githubApiKey = await backendSettings.getGithubApiKey();
      }
      if (ollamaApiKey == null || ollamaApiKey.isEmpty) {
        ollamaApiKey = await backendSettings.getOllamaApiKey();
      }
    }

    final script = _resolveScriptPath(effectiveMultiAgent);
    if (!script.existsSync()) {
      _appendLog('orchestrator script not found at ${script.path}');
      return false;
    }

    // Backend-specific key checks are now handled by the Python side;
    // missing keys will result in a clear error message from the orchestrator.

    try {
      _stderrBuffer.clear();
      _logLines.clear();
      _lastNonEmptyLogLine = null;
      _readyCompleter = Completer<void>();

      final resolvedBasePath = workingDirectory ?? baseDirectory.path;
      _basePath = resolvedBasePath;
      _appendLog('[manager] --base-path -> $resolvedBasePath');
      if (!ProjectService().hasExplicitFolder && workingDirectory == null) {
        _appendLog(
          '[manager] WARNING: no project folder selected; falling back to '
          'Directory.current ($resolvedBasePath). Pick a project folder from '
          'the chat input so file tools resolve relative paths against your '
          'project, not the app install directory.',
        );
      }
      final args = <String>[
        script.path,
        '--interactive',
        '--base-path',
        resolvedBasePath,
      ];

      // Build the Assistant/User args from the multi-agent config.
      if (effectiveMultiAgent) {
        final agents = await WorkflowAgents.load();
        final reasonerCfg = agents.get('reasoner');

        final rProvider = _toProviderString(reasonerCfg.backend);
        final effectiveOpenRouterContextLimit = openRouterContextLimit ?? await backendSettings.getOpenRouterContextLimit();

        // Per-role Ollama endpoint resolution.
        //
        // The slot's own `ollama_base_url` (Settings -> Workflow Agents) is
        // authoritative: it is the endpoint the model picker in that panel
        // itself dials, and it is the only way to reach a cloud-only model
        // whose tag (e.g. `:1017`) does not match OllamaBackend's `-cloud`
        // auto-promotion heuristic. The global Ollama endpoint is only a
        // fallback for slots that leave the field blank.
        //
        // Emitting no flag is NOT equivalent to "use the default": Python then
        // builds OllamaBackend with an empty base_url, which resolves to
        // http://localhost:11434 and fails a cloud run with WinError 10061.
        String? ollamaUrlFor(AgentRoleConfig cfg) {
          final perRole = cfg.ollamaBaseUrl?.trim() ?? '';
          if (perRole.isNotEmpty) return perRole;
          final fallback = ollamaBaseUrl?.trim() ?? '';
          return fallback.isEmpty ? null : fallback;
        }

        args.addAll(['--reasoner-provider', rProvider]);
        args.addAll(['--reasoner-model', reasonerCfg.model]);
        // Context window: the per-slot value wins; OpenRouter falls back to the
        // limit resolved from the model catalogue. Python applies it to the
        // providers that support it (Ollama `num_ctx`, OpenRouter
        // `context_limit`) and logs a line for the ones that do not, so the
        // flag is always sent instead of being silently dropped here.
        int? rContextWindow = reasonerCfg.contextWindow;
        if ((rContextWindow == null || rContextWindow <= 0) &&
            rProvider == 'openrouter') {
          rContextWindow = effectiveOpenRouterContextLimit;
        }
        if (rContextWindow != null && rContextWindow > 0) {
          args.addAll(['--reasoner-context-window', rContextWindow.toString()]);
        }
        // Base URL override: honoured by Ollama, OpenRouter and Gemini.
        if (AgentRoleSettingsRepository.baseUrlBackends.contains(rProvider)) {
          final rBaseUrl = ollamaUrlFor(reasonerCfg);
          if (rBaseUrl != null) {
            args.addAll(['--reasoner-base-url', rBaseUrl]);
          }
        }
        args.addAll(['--temperature', reasonerCfg.temperature.toString()]);
        args.addAll(['--max-tokens', reasonerCfg.maxTokens.toString()]);
        final rKey = _apiKeyForProvider(rProvider,
            groqApiKey: groqApiKey, geminiApiKey: geminiApiKey, openRouterApiKey: openRouterApiKey, githubApiKey: githubApiKey, hfToken: hfToken, ollamaApiKey: ollamaApiKey);
        if (rKey != null && rKey.isNotEmpty) {
          args.addAll(['--reasoner-api-key', rKey]);
        }

        // Reasoning level: pass through to the Python orchestrator.
        // Defaults to 'max' if not set in the agent config.
        final rReasoningLevel = reasonerCfg.reasoningLevel.isNotEmpty ? reasonerCfg.reasoningLevel : 'max';
        args.addAll(['--reasoning-level', rReasoningLevel]);

        // Extended thinking is owned by the Assistant card while MaM is on, so
        // it must be seeded at launch: the chat-view toggle is hidden in this
        // mode and no longer sends `thinking` in the request envelope.
        args.add(reasonerCfg.thinking ? '--thinking' : '--no-thinking');

        // Optional per-slot tokens-per-minute cap (0 = unlimited).
        if (reasonerCfg.tpmLimit > 0) {
          args.addAll(['--reasoner-tpm-limit', reasonerCfg.tpmLimit.toString()]);
        }

        // AUTO INPUT round cap ("Maximum Auto Round Actions" in Settings ->
        // Workflow Agents MaM). Workflow-level, so it is read from the
        // repository rather than from a role config; the run loop uses it as
        // the Assistant <-> User exchange bound and as the progress total.
        final maxAutoRounds =
            await AgentRoleSettingsRepository.instance.getMaxAutoRounds();
        args.addAll(['--max-agent-rounds', maxAutoRounds.toString()]);

        // AUTO INPUT "User" agent: the second Workflow Agents slot. When it
        // has a model configured it is forwarded to the orchestrator, which
        // hands it the [INTERNAL: AUTO-INPUT MODE] evaluation so the
        // Assistant is reviewed by a genuinely separate model instead of
        // judging its own output. An empty model deliberately emits no
        // --user-* flags: Python then keeps the slot unset and the run loop
        // surfaces the "no User agent configured" notice and fails safe.
        _appendUserAgentArgs(
          args,
          agents.get('user'),
          ollamaBaseUrl: ollamaBaseUrl,
          apiKeyFor: (provider) => _apiKeyForProvider(
            provider,
            groqApiKey: groqApiKey,
            geminiApiKey: geminiApiKey,
            openRouterApiKey: openRouterApiKey,
            githubApiKey: githubApiKey,
            hfToken: hfToken,
            ollamaApiKey: ollamaApiKey,
          ),
        );

        // Team Mode is not yet supported by multi_mode; log a warning.
        if (await AgentRoleSettingsRepository.instance.isTeamModeEnabled()) {
          _appendLog('[manager] Team Mode is not supported by orchestrator_v2; ignoring.');
        }
      } else {
        // Single-agent mode: use the legacy orchestrator.py with its own flags.
        args.addAll(['--backend', _backendToString(backend)]);
        if (modelId != null && modelId.isNotEmpty) {
          args.addAll(['--model', modelId]);
        }
        // Fetch temperature from settings if not provided
        double effectiveTemperature = temperature ?? await _getDefaultTemperatureForBackend(backend);
        // Format temperature as a clean decimal (e.g., 0.30 instead of 0.30000000000000004)
        final formattedTemperature = double.parse(effectiveTemperature.toStringAsFixed(2));
        args.addAll(['--temperature', formattedTemperature.toString()]);
        if (maxTokens != null) {
          args.addAll(['--max-tokens', maxTokens.toString()]);
        }
        // Backend-specific keys
        switch (backend) {
          case OrchestratorBackend.huggingface:
            if (hfToken != null && hfToken.isNotEmpty) args.addAll(['--hf-token', hfToken]);
            break;
          case OrchestratorBackend.ollama:
            if (ollamaBaseUrl != null && ollamaBaseUrl.isNotEmpty) args.addAll(['--ollama-base-url', ollamaBaseUrl]);
            if (ollamaApiKey != null && ollamaApiKey.isNotEmpty) args.addAll(['--ollama-api-key', ollamaApiKey]);
            if (ollamaNumCtx != null) args.addAll(['--ollama-num-ctx', ollamaNumCtx.toString()]);
            if (ollamaAutoNumCtx == true) args.add('--auto-num-ctx');
            break;
          case OrchestratorBackend.groq:
            if (groqApiKey != null && groqApiKey.isNotEmpty) args.addAll(['--groq-api-key', groqApiKey]);
            break;
          case OrchestratorBackend.gemini:
            if (geminiApiKey != null && geminiApiKey.isNotEmpty) args.addAll(['--gemini-api-key', geminiApiKey]);
            break;
          case OrchestratorBackend.openrouter:
            if (openRouterApiKey != null && openRouterApiKey.isNotEmpty) args.addAll(['--openrouter-api-key', openRouterApiKey]);
            if (openRouterContextLimit != null) {
              args.addAll([
                '--openrouter-context-limit',
                openRouterContextLimit.toString(),
              ]);
            }
            break;
          case OrchestratorBackend.github:
            if (githubApiKey != null && githubApiKey.isNotEmpty) args.addAll(['--github-api-key', githubApiKey]);
            break;
        }
        if (tpmLimit != null) args.addAll(['--tpm-limit', tpmLimit.toString()]);

        // Forward the AUTO INPUT "User" agent (second Workflow Agents slot)
        // exactly as the multi-agent branch does: the single-agent run loop
        // implements AUTO INPUT too, so without these flags a User agent the
        // user did configure would be ignored and the loop would report it
        // missing while falling back to a single answer.
        final singleAgentUserCfg = (await WorkflowAgents.load()).get('user');
        _appendUserAgentArgs(
          args,
          singleAgentUserCfg,
          ollamaBaseUrl: ollamaBaseUrl,
          apiKeyFor: (provider) => _apiKeyForProvider(
            provider,
            groqApiKey: groqApiKey,
            geminiApiKey: geminiApiKey,
            openRouterApiKey: openRouterApiKey,
            githubApiKey: githubApiKey,
            hfToken: hfToken,
            ollamaApiKey: ollamaApiKey,
          ),
        );
      }

      if (disableTools) {
        args.add('--disable-tools');
      }

      // User-configured filesystem filters: list of dirs/files to hide
      // (or re-show) from the orchestrator's discovery tools. Written
      // alongside agents.json so the Python side can mmap a single file
      // at startup. Per-project: the lists are scoped to the current
      // working directory hash inside DevFiltersRepository.
      try {
        final tmp = await getTemporaryDirectory();
        final filtersPath = '${tmp.path}/agentic_filters.json';
        final filtersJson = await DevFiltersRepository.instance.toFiltersJson(resolvedBasePath);
        await File(filtersPath).writeAsString(filtersJson, flush: true);
        // Only attach the flag when the user has at least one rule
        // configured â€” empty config means "no filters" and Python's
        // default already covers that, no need for an extra arg.
        final hasAnyRule =
            !filtersJson.contains('"exclude_dirs":[]') || !filtersJson.contains('"include_dirs":[]') || !filtersJson.contains('"exclude_files":[]') || !filtersJson.contains('"include_files":[]');
        if (hasAnyRule) {
          args.addAll(['--filters-config', filtersPath]);
          _appendLog('[manager] Filesystem filters written -> $filtersPath');
        }
      } catch (e) {
        _appendLog('[manager] Failed to write filters config: $e (continuing without filters)');
      }

      // User-configured database connections (Settings â†’ Developer â†’
      // Database Connections). The Flutter UI persists these in the
      // app's SQLite settings table; we serialise the current snapshot
      // to a temp file and hand the path to Python so the db_query tool
      // can resolve a connection key the model passes in.
      try {
        final tmp = await getTemporaryDirectory();
        final dbConnPath = '${ProjectService.windowsToLinuxPath(tmp.path)}/agentic_db_connections.json';
        await DatabaseConnectionsRepository.instance.writeConfigJson(dbConnPath, workingDir: ProjectService.windowsToLinuxPath(ProjectService().currentPath));
        args.addAll(['--db-connections-config', dbConnPath]);
        _appendLog('[manager] DB connections written -> $dbConnPath');
      } catch (e) {
        _appendLog('[manager] Failed to write DB connections config: $e (continuing without DB tool)');
      }

      final python = await resolvePythonExecutable();
      // `AGENTIC_SESSION_ID` lets the Python side stamp every `[orch]` stderr
      // line (and every audit record) with this chat's GUID, so the logs of the
      // N concurrent sessions stay attributable when they land in one sink.
      final env = <String, String>{
        ...await resolveSubprocessEnvironment(),
        'AGENTIC_SESSION_ID': conversationId,
      };
      _appendLog('[manager] Python -> $python');
      final flutterRoot = env['FLUTTER_ROOT'];
      if (flutterRoot != null) {
        _appendLog('[manager] FLUTTER_ROOT -> $flutterRoot');
      }
      _process = await Process.start(
        python,
        args,
        workingDirectory: script.parent.path,
        environment: env,
      );

      _stdoutSub = _process!.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_onStdoutLine, onError: _onStreamError, onDone: _onProcessExited);

      _stderrSub = _process!.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
        _appendLog(line);
        // stderr activity (e.g. `[orch] Model reply (iter 0) â€¦`) counts as
        // a heartbeat â€” the subprocess is alive and making progress.
        _bumpInactivityTimer();
      });

      // Wait for the `__READY__` handshake. If the Python side is missing
      // dependencies it will exit with code 2 â€” we detect that via
      // _onProcessExited and complete the ready future with an error.
      // Multi-agent startup is heavier (loads + validates each role's
      // backend before signalling ready), so give it a longer budget.
      final readyTimeout = effectiveMultiAgent ? const Duration(seconds: 90) : const Duration(seconds: 30);
      await _readyCompleter!.future.timeout(readyTimeout);

      _isRunning = true;
      _isReady = true;
      _currentBackend = backend;
      _currentModelId = modelId;
      _currentTemperature = temperature;
      // Record what this session was launched with so a restart request that
      // would not change anything can be dropped instead of killing the turn.
      _argsFingerprint = fingerprintFor(
        backend: backend,
        modelId: modelId ?? '',
        temperature: temperature,
        maxTokens: maxTokens,
        multiAgent: effectiveMultiAgent,
        basePath: resolvedBasePath,
      );
      _setState(OrchestratorSessionState.idle);
      return true;
    } catch (e) {
      _appendLog('start() failed: $e');
      await _cleanup();
      _setState(OrchestratorSessionState.failed);
      return false;
    }
  }

  /// Send a prompt to the orchestrator and await the full response.
  ///
  /// [sessionKey] identifies the visible chat conversation. When it changes,
  /// or when [forceHistorySync] is true, the Python side is reset and
  /// re-seeded with [seedHistory] so hidden orchestrator memory cannot drift
  /// away from the visible chat history.
  Future<String> sendPrompt(
    String prompt, {
    bool newSession = false,
    String? sessionKey,
    List<Map<String, String>> seedHistory = const [],
    bool forceHistorySync = false,
    String taskMode = 'user_input',
    bool? thinking,
    String? effort,
  }) {
    // Serialize requests so multiple callers don't interleave on stdin.
    final next = _chain.then(
      (_) => _sendPromptInternal(
        prompt,
        newSession,
        sessionKey: sessionKey,
        seedHistory: seedHistory,
        forceHistorySync: forceHistorySync,
        taskMode: taskMode,
        thinking: thinking,
        effort: effort,
      ),
    );
    _chain = next.catchError((_) => '');
    return next;
  }

  Future<String> _sendPromptInternal(
    String prompt,
    bool newSession, {
    String? sessionKey,
    List<Map<String, String>> seedHistory = const [],
    bool forceHistorySync = false,
    String taskMode = 'user_input',
    bool? thinking,
    String? effort,
  }) async {
    if (!_isRunning || _process == null) {
      return 'Error: Orchestrator not running. Start it from Settings first.';
    }
    if (!_isReady) {
      return 'Error: Orchestrator not ready yet.';
    }
    // A configuration change is waiting for the live turn to drain. Sending now
    // would run the next prompt against the old backend/model, so refuse
    // explicitly instead of silently producing an answer from stale settings.
    if (_pendingRestart != null || _state == OrchestratorSessionState.restarting) {
      return 'Error: the orchestrator is being relaunched with the new '
          'configuration. Send the prompt again in a moment.';
    }

    // A session belongs to exactly one conversation, so a chat switch can no
    // longer invalidate it: only the caller's explicit request (a brand-new
    // chat, or a forced history resync) resets the hidden Python history.
    final shouldResetSession = forceHistorySync || newSession;

    _activeCompleter = Completer<String>();
    _activeLines.clear();
    // A new turn starts with a clean AUTO INPUT transcript; otherwise the
    // previous turn's intermediate answers would look like part of this one.
    _autoInputReplies.clear();
    _autoInputPrompts.clear();
    _setAutoInputEvaluating(false);
    // Trace the requested input mode in the orchestrator log so an inert
    // AUTO INPUT (e.g. missing User agent) is diagnosable from the UI. The
    // Python side logs the actual evaluation API call per round.
    if (taskMode == 'auto_input') {
      _injectLogLine(
        '[ui] task_mode=auto_input requested; AUTO INPUT loop enabled',
      );
    }
    _requestStartedAt = DateTime.now();
    _setState(OrchestratorSessionState.busy);
    // A fresh request invalidates the previous turn's activity labels and
    // chain-of-thought so the UI strip never shows stale "Planning..." or
    // leftover thinking while the new request is still warming up.
    _lastStatus = null;
    _lastThinking = null;
    // Stash the conversation id so the stdout dispatcher can attach it
    // to incoming task-flow events (Python doesn't re-echo it on every
    // event for the sake of payload size).
    _currentConversationId = sessionKey;
    _bumpInactivityTimer();

    // Correlation id: echoed back by Python. An envelope belonging to a turn
    // the user already aborted is then dropped instead of landing in the next
    // one (a real hazard while the process is killed and relaunched).
    final requestId = const Uuid().v4();
    _activeRequestId = requestId;
    final request = jsonEncode({
      'prompt': prompt,
      'new_session': shouldResetSession,
      'request_id': requestId,
      if (seedHistory.isNotEmpty) 'history': seedHistory,
      if (sessionKey != null && sessionKey.isNotEmpty) 'session_key': sessionKey,
      // Sent explicitly so Team Mode can isolate per-chat board/artifacts.
      // Same value as session_key — kept as a separate field so the
      // Python side has a stable contract independent of the legacy
      // session_key plumbing.
      if (sessionKey != null && sessionKey.isNotEmpty) 'conversation_id': sessionKey,
      // Mode dropdown selection (USER INPUT / AUTO INPUT). Python looks at
      // this on every request and switches the loop behaviour and task-event
      // emission accordingly.
      'task_mode': taskMode,
      // Thinking ON/OFF master switch + Effort level. Sent per-request so the
      // Flutter UI controls take effect immediately without restarting the
      // orchestrator subprocess — but ONLY when the caller owns them. In MaM
      // mode each Workflow Agents card owns its slot's thinking/effort and
      // they are seeded at launch; a per-request value would override the
      // slot configuration. Python treats an absent `thinking` as "keep the
      // launch-time value".
      if (thinking != null) 'thinking': thinking,
      if (effort != null && effort.isNotEmpty) 'effort': effort,
    });
    // Fix 10c: when the outgoing prompt is itself a <task_action>
    // envelope (sent by the TaskChecklistPanel buttons), inject a
    // synthetic log line so the orchestrator log panel shows the
    // user-driven action alongside the model-driven [task] lines.
    // Pattern: ``<task_action><id>N</id><action>value</action></task_action>``.
    final taskActionMatch = RegExp(
      r'<\s*task_action\s*>\s*(.*?)<\s*/\s*task_action\s*>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(prompt);
    if (taskActionMatch != null) {
      final body = taskActionMatch.group(1) ?? '';
      _injectLogLine('[task-action-ui] sent $body');
    }

    try {
      _process!.stdin.writeln(request);
      await _process!.stdin.flush();
    } catch (e) {
      return 'Error: Failed to write to orchestrator stdin: $e';
    }

    // Inactivity-based timeout: the request is only cancelled if neither
    // stdout nor stderr has produced a line for `_kOrchestratorInactivityTimeout`,
    // capped by `_kOrchestratorAbsoluteTimeout`. Long-but-progressing tool
    // chains keep extending the deadline via `_bumpInactivityTimer`.
    try {
      return await _activeCompleter!.future.timeout(
        _kOrchestratorAbsoluteTimeout,
        onTimeout: () => 'Timeout: orchestrator exceeded the absolute ceiling of '
            '${_kOrchestratorAbsoluteTimeout.inMinutes} minutes.',
      );
    } finally {
      _activeCompleter = null;
      _activeRequestId = null;
      _activeLines.clear();
      _cancelInactivityTimer();
      _requestStartedAt = null;
      // Fall back to idle only when the subprocess is still alive: a teardown
      // that landed mid-turn has already moved the state to stopped.
      if (_isRunning && _isReady) {
        _setState(OrchestratorSessionState.idle);
        // A configuration change requested while the turn was running is
        // applied now — after the answer has been extracted and returned to
        // the caller, so the reply is never discarded.
        final pending = _pendingRestart;
        _pendingRestart = null;
        if (pending != null) unawaited(_applyPendingRestart(pending));
      }
    }
  }

  void _bumpInactivityTimer() {
    if (_activeCompleter == null) return;
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(_kOrchestratorInactivityTimeout, () {
      if (_activeCompleter == null || _activeCompleter!.isCompleted) return;
      // If a complete JSON envelope already landed (sentinel just hadn't
      // arrived), recover the parsed reply instead of clobbering it with a
      // timeout string.
      final recovered = _extractResponseFromBuffer();
      if (recovered.isNotEmpty && recovered != _activeLines.join('\n').trim()) {
        _activeCompleter!.complete(recovered);
        return;
      }
      final waited = _requestStartedAt == null ? 'unknown' : '${DateTime.now().difference(_requestStartedAt!).inSeconds}s';
      _activeCompleter!.complete(
        'Timeout: orchestrator was silent for '
        '${_kOrchestratorInactivityTimeout.inMinutes} minutes '
        '(total wait $waited). Check the orchestrator log.',
      );
    });
  }

  void _cancelInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
  }

  void _onStdoutLine(String line) {
    // Handshake: Python prints `__READY__` once at startup. A second one
    // means the subprocess respawned (crash + restart, or stop+start while
    // a request was in flight) â€” never legitimate request payload, so drop
    // it unconditionally rather than letting it leak into _activeLines.
    if (line.trim() == '__READY__') {
      if (!_isReady) _readyCompleter?.complete();
      return;
    }

    if (_activeCompleter == null) return; // Stray line; ignore.

    // Any stdout line during an active request is progress â†’ reset watchdog.
    _bumpInactivityTimer();

    if (line.trim() == '__RESPONSE_END__') {
      final response = _extractResponseFromBuffer();
      if (!_activeCompleter!.isCompleted) {
        _activeCompleter!.complete(response);
      }
      // The turn is over: clear the activity label and chain-of-thought so
      // the UI strip empties out instead of spinning with stale content.
      // The AUTO INPUT user-side indicator is cleared too: when the last
      // evaluation declared the task done no continuation prompt follows, so
      // the flag would otherwise stay set and keep "User agent is writing..."
      // on screen after the reply landed.
      _setAutoInputEvaluating(false);
      _lastStatus = null;
      _lastThinking = null;
      if (!_statusController.isClosed) _statusController.add('');
      if (!_thinkingController.isClosed) _thinkingController.add('');
      return;
    }

    // Task-flow event interception: lines that parse as an XML envelope
    // carrying a ``type`` child (e.g. ``<event><type>tasks_proposed</type>...</event>``
    // or ``<event><type>task_status</type>...</event>``) are NOT the
    // response envelope -- they are intermediate structured events emitted
    // by Python while it reports task-checklist progress. Route them to
    // ``taskStream`` and mirror to SQLite via TaskRepository. The line is
    // then dropped from ``_activeLines`` so it never reaches the response
    // extractor.
    final maybeEvent = _tryParseTaskEvent(line);
    if (maybeEvent) {
      return;
    }

    _activeLines.add(line);
  }

  /// Reverse the XML character-reference escaping applied by Python's
  /// ``_escape_xml`` so the Flutter side sees the original text (newlines,
  /// ampersands, angle brackets) as the model intended.
  static String _unescapeXml(String value) {
    return value.replaceAll('&#10;', '\n').replaceAll('&#13;', '\r').replaceAll('&quot;', '"').replaceAll('&gt;', '>').replaceAll('&lt;', '<').replaceAll('&amp;', '&');
  }

  /// Attempt to parse ``line`` as a task-flow XML envelope. Returns ``true``
  /// when the line was an event (and was therefore consumed); ``false``
  /// otherwise so the caller falls back to the normal response buffer.
  bool _tryParseTaskEvent(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('<event>')) return false;

    // Extract the direct children of the <event> wrapper; we must not
    // match nested <task> tags at the same level or the outer <event>
    // tag itself would overwrite every key.
    final eventMatch = RegExp(
      r'<\s*event\s*>\s*(.*?)\s*<\s*/\s*event\s*>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmed);
    if (eventMatch == null) return false;
    final eventBody = eventMatch.group(1)!;

    // Same convention as the Python side: <tag>value</tag>, no attributes.
    final childTagRe = RegExp(
      r'<\s*(\w+)\s*>\s*(.*?)\s*<\s*/\s*\1\s*>',
      caseSensitive: false,
      dotAll: true,
    );
    final tags = <String, String>{};
    for (final m in childTagRe.allMatches(eventBody)) {
      tags[m.group(1)!.toLowerCase()] = _unescapeXml(m.group(2)!);
    }

    final eventType = tags['type'];
    if (eventType == null) return false;

    // AUTO INPUT events are conversation-independent (they describe the
    // autonomous loop itself, not task-plan rows), so handle them before the
    // conversation-id gate below.
    if (eventType == 'auto_input_reply') {
      _setAutoInputEvaluating(false);
      final text = tags['text'] ?? '';
      if (text.trim().isNotEmpty) {
        _autoInputReplies.add(text);
        if (!_autoInputReplyController.isClosed) {
          _autoInputReplyController.add(text);
        }
      }
      return true;
    }

    if (eventType == 'auto_input_evaluating') {
      // The User agent is now reviewing the Assistant's reply and writing the
      // next prompt: flip the user-side indicator on until the prompt or the
      // final answer arrives.
      _setAutoInputEvaluating(true);
      return true;
    }

    if (eventType == 'auto_input_prompt') {
      _setAutoInputEvaluating(false);
      final text = tags['text'] ?? '';
      if (text.trim().isNotEmpty) {
        _autoInputPrompts.add(text);
        if (!_autoInputPromptController.isClosed) {
          _autoInputPromptController.add(text);
        }
      }
      return true;
    }

    if (eventType == 'auto_input_user_missing') {
      final text = tags['text'] ?? '';
      if (text.trim().isNotEmpty) {
        if (!_autoInputNoticeController.isClosed) {
          _autoInputNoticeController.add(text);
        }
      }
      return true;
    }

    final convId = _currentConversationId;
    if (convId == null || convId.isEmpty) {
      // Without a conversation context we can't persist or attach the
      // event meaningfully. Treat as consumed to avoid leaking it into
      // the response buffer but skip the broadcast.
      return true;
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    if (eventType == 'tasks_proposed') {
      // The payload is nested inside <tasks>...</tasks>.
      final tasks = <ConversationTask>[];
      final tasksMatch = RegExp(
        r'<\s*tasks\s*>(.*?)<\s*/\s*tasks\s*>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(trimmed);
      if (tasksMatch != null) {
        final taskBlock = tasksMatch.group(1)!;
        final taskRe = RegExp(
          r'<\s*task\s*>(.*?)<\s*/\s*task\s*>',
          caseSensitive: false,
          dotAll: true,
        );
        for (final tm in taskRe.allMatches(taskBlock)) {
          final taskTags = <String, String>{};
          for (final m in childTagRe.allMatches(tm.group(1)!)) {
            taskTags[m.group(1)!.toLowerCase()] = m.group(2)!;
          }
          if (taskTags['id'] == null || taskTags['name'] == null) continue;
          final deps = <int>[];
          final dependsRaw = taskTags['depends_on'];
          if (dependsRaw != null && dependsRaw.trim().isNotEmpty) {
            for (final part in dependsRaw.split(',')) {
              final n = int.tryParse(part.trim());
              if (n != null) deps.add(n);
            }
          }
          tasks.add(
            ConversationTask(
              taskId: int.tryParse(taskTags['id']!) ?? 0,
              conversationId: convId,
              name: taskTags['name']!,
              description: taskTags['description'] ?? '',
              successCriteria: taskTags['success_criteria'] ?? '',
              dependsOn: deps,
              status: TaskStatusX.parse(taskTags['status']),
              createdAt: now,
              updatedAt: now,
            ),
          );
        }
      }
      // Persist + broadcast.
      TaskRepository.instance.replacePlan(convId, tasks);
      _taskController.add(
        OrchestratorTasksProposed(conversationId: convId, tasks: tasks),
      );
      return true;
    }

    if (eventType == 'thinking') {
      final text = tags['text'] ?? '';
      if (text.trim().isNotEmpty) {
        _lastThinking = text;
        if (!_thinkingController.isClosed) _thinkingController.add(text);
      }
      return true;
    }

    if (eventType == 'task_status') {
      final id = int.tryParse(tags['id'] ?? '');
      final statusRaw = tags['status'];
      if (id == null || statusRaw == null) return true;
      final status = TaskStatusX.parse(statusRaw);
      final note = tags['note'] ?? '';
      final description = tags['description'] ?? '';
      TaskRepository.instance.applyStatusUpdate(
        conversationId: convId,
        taskId: id,
        status: status,
        note: note,
        now: now,
      );
      _taskController.add(
        OrchestratorTaskStatusChanged(
          conversationId: convId,
          taskId: id,
          status: status,
          note: note,
          description: description,
        ),
      );
      return true;
    }

    // Unknown event types are silently consumed -- forwards
    // compatibility with future protocol extensions.
    return true;
  }

  /// Pull a clean user-facing reply out of `_activeLines`. Handles the normal
  /// case (`{"response": "...", "trace": [...]}`) and tolerates stray lines
  /// like a leftover `__READY__` from a respawn or stray Python prints that
  /// landed on stdout instead of stderr. Also publishes the trace when
  /// present.
  ///
  /// Strategy: scan from the end for the last line that parses as a JSON
  /// object containing a `"response"` key. That envelope is authoritative â€”
  /// anything before it is treated as noise and discarded. Falls back to the
  /// joined text only if no such envelope exists.
  String _extractResponseFromBuffer() {
    final cleaned = _activeLines.where((l) => l.trim() != '__READY__').toList();

    for (var i = cleaned.length - 1; i >= 0; i--) {
      final line = cleaned[i].trim();
      if (!line.startsWith('{') || !line.endsWith('}')) continue;
      try {
        final obj = jsonDecode(line);
        if (obj is! Map || obj['response'] is! String) continue;
        // Correlation check: drop an envelope belonging to a turn that has
        // already been aborted. Accepted whenever either side carries no id,
        // so an older Python build keeps working unchanged.
        final echoedId = obj['request_id'];
        final expectedId = _activeRequestId;
        if (echoedId is String &&
            expectedId != null &&
            echoedId.isNotEmpty &&
            echoedId != expectedId) {
          continue;
        }
        final rawTrace = obj['trace'];
        if (rawTrace is List) {
          final entries = <Map<String, Object?>>[];
          for (final e in rawTrace) {
            if (e is Map) {
              entries.add(e.map((k, v) => MapEntry(k.toString(), v)));
            }
          }
          _lastTrace = entries;
          if (!_traceController.isClosed) _traceController.add(entries);
        } else {
          _lastTrace = const [];
        }
        return obj['response'] as String;
      } catch (_) {
        // Not parseable â€” keep scanning earlier lines.
      }
    }

    _lastTrace = const [];
    return cleaned.join('\n').trim();
  }

  void _onStreamError(Object error) {
    _appendLog('stdout stream error: $error');
    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      _activeCompleter!.completeError(error);
    }
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(error);
    }
  }

  void _onProcessExited() {
    _isRunning = false;
    _isReady = false;
    _argsFingerprint = '';
    _cancelInactivityTimer();
    // A process that dies on its own (crash, missing dependency, OOM) is a
    // failure, not an orderly stop; the UI uses this to tell "the session
    // ended" apart from "a configuration change is pending".
    if (_state != OrchestratorSessionState.stopped) {
      _setState(OrchestratorSessionState.failed);
    }
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(
        StateError('Orchestrator process exited before signalling ready. '
            'stderr: ${_stderrBuffer.toString()}'),
      );
    }
    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      // If the JSON envelope already arrived before the process died, prefer
      // delivering the real reply over the generic "process exited" error.
      final recovered = _extractResponseFromBuffer();
      if (recovered.isNotEmpty && recovered.startsWith('{') == false) {
        _activeCompleter!.complete(recovered);
      } else {
        _activeCompleter!.complete(
          'Error: orchestrator process exited. stderr: ${_stderrBuffer.toString()}',
        );
      }
    }
  }

  /// Stop the orchestrator subprocess.
  ///
  /// Only a genuine STOP affordance, app shutdown, or crash recovery may
  /// terminate a turn that is already in flight. Every other source describes
  /// a *configuration change*: while [isBusy] the teardown is deferred until
  /// the running answer has been delivered, so in-app navigation can never
  /// kill a live session. When nothing is in flight the teardown happens
  /// immediately, which keeps the classic `stop(); start(...)` relaunch
  /// pattern intact.
  Future<void> stop({
    OrchestratorStopSource source = OrchestratorStopSource.unspecified,
    String reason = '',
  }) async {
    debugStopCalls.add(source);
    final suffix = reason.isEmpty ? '' : ': $reason';
    if (!source.mayTerminateSession && isBusy) {
      _parkRestart(
        reason.isEmpty ? 'configuration changed' : reason,
        source,
        '',
      );
      return;
    }
    _appendLog('[manager] stop requested by ${source.name}$suffix');
    _abortActiveTurn(source, reason);
    await _cleanup();
    _setState(OrchestratorSessionState.stopped);
  }

  /// Resolve any awaiting [sendPrompt] future with [OrchestratorAborted] so a
  /// teardown never leaves the caller waiting for the absolute timeout.
  void _abortActiveTurn(OrchestratorStopSource source, String reason) {
    final completer = _activeCompleter;
    _activeCompleter = null;
    _activeRequestId = null;
    _activeLines.clear();
    _cancelInactivityTimer();
    _requestStartedAt = null;
    _setAutoInputEvaluating(false);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        OrchestratorAborted(
          source.name,
          reason.isEmpty ? 'session torn down' : reason,
        ),
      );
    }
  }

  /// Ask for the subprocess to be relaunched with a different configuration.
  ///
  /// Identical fingerprints are dropped outright — that alone fixes the
  /// "open a dropdown, leave the value unchanged" case. While [isBusy] the
  /// request is parked and applied once the running turn has been delivered to
  /// the UI; otherwise it is simply noted, because the next launch picks the
  /// new configuration up anyway.
  void requestRestart({
    required String reason,
    required OrchestratorStopSource source,
    String argsFingerprint = '',
  }) {
    debugRestartReasons.add(reason);
    if (_isRunning &&
        argsFingerprint.isNotEmpty &&
        argsFingerprint == _argsFingerprint) {
      _appendLog(
        '[manager] restart request from ${source.name} ignored — '
        'configuration unchanged ($reason)',
      );
      return;
    }
    if (!isBusy) {
      _pendingRestart = null;
      if (!_isRunning) {
        _appendLog(
          '[manager] restart request from ${source.name} noted — '
          'applies on the next launch ($reason)',
        );
        return;
      }
      // Nothing is in flight, so the relaunch can happen straight away. This
      // is what makes a backend / project change effective before the next
      // prompt: leaving the old process alive would route that prompt to the
      // configuration the user just replaced.
      unawaited(
        _applyPendingRestart(
          _PendingRestart(reason, source, argsFingerprint),
        ),
      );
      return;
    }
    _parkRestart(reason, source, argsFingerprint);
  }

  void _parkRestart(
    String reason,
    OrchestratorStopSource source,
    String argsFingerprint,
  ) {
    _pendingRestart = _PendingRestart(reason, source, argsFingerprint);
    _appendLog(
      '[manager] deferred restart requested by ${source.name}: $reason',
    );
  }

  /// Apply the parked relaunch once the turn has been delivered.
  ///
  /// The process is torn down here (nothing is in flight any more) and the
  /// next prompt relaunches it with the configuration the user picked. This is
  /// what makes a mid-turn model/backend/project change effective without ever
  /// discarding the answer that was being produced.
  Future<void> _applyPendingRestart(_PendingRestart pending) async {
    _appendLog(
      '[manager] applying deferred restart (${pending.source.name}): '
      '${pending.reason}',
    );
    _setState(OrchestratorSessionState.restarting);
    _abortActiveTurn(pending.source, pending.reason);
    await _cleanup();
    _setState(OrchestratorSessionState.stopped);
  }

  Future<void> _cleanup() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;

    final process = _process;
    if (process != null) {
      // Graceful shutdown first: the Python side exits its read loop on
      // `{"action": "shutdown"}`, which lets it flush the audit log and the
      // per-chat log file before terminating. Fall back to kill() when the
      // process does not react within the grace window.
      try {
        process.stdin.writeln(jsonEncode({'action': 'shutdown'}));
        await process.stdin.flush();
      } catch (_) {
        // stdin already closed — fall through to kill().
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        try {
          process.kill();
        } catch (_) {}
      }
    }

    _process = null;
    _isRunning = false;
    _isReady = false;
    _argsFingerprint = '';
    _pendingRestart = null;
    _refreshActivity();
  }

  bool checkHealthy() => _isRunning && _isReady && _process != null;

  bool _disposed = false;

  /// True once this session has been released by the registry.
  ///
  /// A disposed session is never reused: the registry drops it and builds a
  /// fresh one for the same chat on the next acquisition.
  bool get isDisposed => _disposed;

  /// Tear the subprocess down and release every stream controller.
  ///
  /// Called by the registry on LRU eviction, idle-TTL reaping, conversation
  /// deletion and app shutdown. Safe to call twice.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    OrchestratorSession.debugStopCalls.add(OrchestratorStopSource.appShutdown);
    await _cleanup();
    _setState(OrchestratorSessionState.stopped);
    _setActivity(SessionActivity.idle);
    await _stateController.close();
    await _activityController.close();
    await _logController.close();
    await _traceController.close();
    await _statusController.close();
    await _autoInputNoticeController.close();
    await _autoInputReplyController.close();
    await _autoInputPromptController.close();
    await _autoInputEvaluatingController.close();
    await _thinkingController.close();
    await _taskController.close();
  }

  // ---------------------------------------------------------------------------
  // Helpers for building orchestrator_v2 CLI args
  // ---------------------------------------------------------------------------

  /// Map an [OrchestratorBackend] to the provider string expected by
  /// orchestrator_v2 (e.g. "openai", "anthropic", "ollama", "gemini",
  /// "openrouter", "github").
  static String _backendToString(OrchestratorBackend b) {
    switch (b) {
      case OrchestratorBackend.huggingface:
        return 'huggingface';
      case OrchestratorBackend.ollama:
        return 'ollama';
      case OrchestratorBackend.groq:
        return 'groq';
      case OrchestratorBackend.gemini:
        return 'gemini';
      case OrchestratorBackend.openrouter:
        return 'openrouter';
      case OrchestratorBackend.github:
        return 'github';
    }
  }

  /// Map a backend identifier from [AgentRoleConfig.backend] to the provider
  /// name orchestrator_multi passes to `build_backend`
  /// (see `bin/agent/backends/__init__.py`).
  ///
  /// This is intentionally the identity for every supported backend: the
  /// stored names are already the names the Python factory accepts, and an
  /// invented alias (the old `huggingface -> openai` remap) made startup fail
  /// with "Unknown backend: 'openai'". Unknown values are logged and passed
  /// through unchanged so the user's config is never silently rewritten.
  @visibleForTesting
  static String toProviderString(String backend) {
    final normalised = backend.trim().toLowerCase();
    if (!AgentRoleSettingsRepository.supportedBackends.contains(normalised)) {
      developer.log(
        '[manager] unsupported backend "$backend" is not accepted by '
        'bin/agent/backends/__init__.py::build_backend',
        name: 'orchestrator_manager',
      );
    }
    return normalised;
  }

  static String _toProviderString(String backend) => toProviderString(backend);

  /// Append the AUTO INPUT "User" agent CLI flags for [userCfg].
  ///
  /// The User agent is the second Workflow Agents slot: Python hands it the
  /// AUTO-INPUT evaluation so the Assistant is reviewed by a genuinely
  /// separate model instead of judging its own output. An empty model emits
  /// no flags at all — Python keeps the slot unset, the run loop surfaces the
  /// missing-agent notice, and AUTO INPUT fails safe waiting for real input.
  void _appendUserAgentArgs(
    List<String> args,
    AgentRoleConfig userCfg, {
    required String? ollamaBaseUrl,
    required String? Function(String provider) apiKeyFor,
  }) {
    final userModel = userCfg.model.trim();
    if (userModel.isEmpty) {
      _appendLog(
        '[manager] AUTO INPUT User agent not configured (empty model in '
        'Workflow Agents > User); AUTO INPUT will report it and wait for '
        'real input.',
      );
      return;
    }
    final provider = _toProviderString(userCfg.backend);
    args.addAll(['--user-provider', provider]);
    args.addAll(['--user-model', userModel]);
    final key = apiKeyFor(provider);
    if (key != null && key.isNotEmpty) {
      args.addAll(['--user-api-key', key]);
    }
    if (AgentRoleSettingsRepository.baseUrlBackends.contains(provider)) {
      final url = (userCfg.ollamaBaseUrl?.isNotEmpty ?? false)
          ? userCfg.ollamaBaseUrl!
          : ollamaBaseUrl;
      if (url != null && url.isNotEmpty) {
        args.addAll(['--user-base-url', url]);
      }
    }
    // Every generation setting configured on the User card is forwarded, so the
    // AUTO INPUT evaluation runs with the values the user actually picked.
    // `--user-num-ctx` is kept for older launchers; `--user-context-window` is
    // the canonical flag and takes precedence on the Python side.
    final userContextWindow = userCfg.contextWindow;
    if (userContextWindow != null && userContextWindow > 0) {
      args.addAll(['--user-context-window', userContextWindow.toString()]);
    }
    args.addAll(['--user-temperature', userCfg.temperature.toString()]);
    args.addAll(['--user-max-tokens', userCfg.maxTokens.toString()]);
    final userReasoningLevel =
        userCfg.reasoningLevel.isNotEmpty ? userCfg.reasoningLevel : 'max';
    args.addAll(['--user-reasoning-level', userReasoningLevel]);
    args.add(userCfg.thinking ? '--user-thinking' : '--user-no-thinking');
    if (userCfg.tpmLimit > 0) {
      args.addAll(['--user-tpm-limit', userCfg.tpmLimit.toString()]);
    }
    _appendLog('[manager] AUTO INPUT User agent -> $provider:$userModel '
        '(temp=${userCfg.temperature}, max_tokens=${userCfg.maxTokens}, '
        'effort=$userReasoningLevel, thinking=${userCfg.thinking})');
  }

  /// Return the API key for a given provider string, drawing from the
  /// appropriate parameter.
  static String? _apiKeyForProvider(
    String provider, {
    String? groqApiKey,
    String? geminiApiKey,
    String? openRouterApiKey,
    String? githubApiKey,
    String? hfToken,
    String? ollamaApiKey,
  }) {
    switch (provider) {
      case 'groq':
        return groqApiKey;
      case 'gemini':
        return geminiApiKey;
      case 'openrouter':
        return openRouterApiKey;
      case 'github':
        return githubApiKey;
      case 'openai':
      case 'huggingface':
        return hfToken;
      case 'ollama':
        return ollamaApiKey;
      default:
        return null;
    }
  }
}

/// Marks the async scope that binds unkeyed facade calls to one conversation.
///
/// `LlmService.sendChat` establishes it once through
/// [OrchestratorManager.withConversation]; every continuation of that call
/// (including nested awaits) then resolves [OrchestratorManager]'s legacy
/// members against the chat it belongs to, even while a second chat is doing
/// exactly the same thing at the same time.
final Object _kConversationZoneKey = Object();

/// Soft cap on simultaneously live orchestrator subprocesses.
///
/// Beyond this the least-recently-used *idle* session is disposed to make
/// room. A busy session is never disposed: the cap is soft and the extra
/// process is allowed to live until it drains.
const int kMaxConcurrentSessions = 4;

/// A session that has been idle for longer than this is disposed lazily, on
/// the next acquisition. Keeps long-running apps from accumulating processes
/// for chats the user has not touched in a quarter of an hour.
const Duration kSessionIdleTtl = Duration(minutes: 15);

/// Keyed facade over one [OrchestratorSession] per conversation.
///
/// This class keeps its historical name and singleton identity so the existing
/// call sites keep compiling, but it no longer owns a subprocess: sessions are
/// indexed by the conversation GUID, created lazily on first use, and each one
/// runs its own Python process.
///
/// The primary goal of the split is that conversation identity is a *key we
/// index by*, not *a field we overwrite*. Opening chat B therefore cannot
/// invalidate chat A's hidden history or interrupt the turn it is running.
///
/// Members without an id argument are legacy shims. They resolve to:
///   1. the ambient conversation established by [withConversation], else
///   2. the conversation last opened through [setCurrentSession], else
///   3. the most recently used live session.
/// New code must use the explicit `*For(conversationId, …)` methods.
class OrchestratorManager {
  OrchestratorManager._internal();

  static final OrchestratorManager instance = OrchestratorManager._internal();

  /// Session key used when a caller genuinely has no conversation id.
  static const String fallbackSessionKey = 'app';

  final Map<String, OrchestratorSession> _sessions =
      <String, OrchestratorSession>{};

  /// Least-recently-used order, oldest first.
  final List<String> _mru = <String>[];

  final Map<String, DateTime> _lastUsed = <String, DateTime>{};

  final StreamController<OrchestratorSession> _addedController =
      StreamController<OrchestratorSession>.broadcast();

  String? _currentSessionKey;

  /// Live sessions, in creation order.
  List<OrchestratorSession> get sessions =>
      List<OrchestratorSession>.unmodifiable(_sessions.values);

  /// Emits a session the first time it is acquired, so a sidebar tile that
  /// mounted before its chat ever ran can promote itself to a live
  /// subscription.
  Stream<OrchestratorSession> get sessionAdded => _addedController.stream;

  /// The conversation last opened by the UI, if any.
  String? get currentSessionKey => _currentSessionKey;

  bool get anyRunning => _sessions.values.any((s) => s.isRunning);

  bool get anyBusy => _sessions.values.any((s) => s.isBusy);

  /// True when at least one live session was launched against [backend].
  ///
  /// The Settings → Orchestrator panel uses this instead of the old
  /// `isRunning && currentBackend == X` test: with several chats alive the
  /// question is "does any process already serve this backend?", not "is the
  /// one global process serving it?".
  bool anyRunningWithBackend(OrchestratorBackend backend) =>
      _sessions.values
          .any((s) => s.isRunning && s.currentBackend == backend);

  /// Live sessions, most recently used first — the order the Settings panel
  /// renders them in.
  List<OrchestratorSession> get sessionsByRecency {
    final ordered = <OrchestratorSession>[];
    for (final key in _mru.reversed) {
      final session = _sessions[key];
      if (session != null) ordered.add(session);
    }
    for (final session in _sessions.values) {
      if (!ordered.contains(session)) ordered.add(session);
    }
    return List<OrchestratorSession>.unmodifiable(ordered);
  }

  /// Run [body] with [conversationId] bound as the ambient conversation.
  ///
  /// Every unkeyed facade member called from inside [body] — directly or from
  /// any of its async continuations — resolves to that conversation's session.
  Future<T> withConversation<T>(
    String? conversationId,
    Future<T> Function() body,
  ) {
    return runZoned(
      body,
      zoneValues: <Object, Object?>{
        _kConversationZoneKey: conversationId ?? fallbackSessionKey,
      },
    );
  }

  /// The session for [conversationId], creating it on first use.
  OrchestratorSession sessionFor(String? conversationId) {
    final key = (conversationId == null || conversationId.isEmpty)
        ? fallbackSessionKey
        : conversationId;
    _currentSessionKey = key;
    final existing = _sessions[key];
    if (existing != null && !existing.isDisposed) {
      _touch(key);
      return existing;
    }
    _reapIdle();
    final session = OrchestratorSession(key);
    _sessions[key] = session;
    _touch(key);
    if (!_addedController.isClosed) _addedController.add(session);
    _enforceCap(key);
    return session;
  }

  /// The live session for [conversationId], or null when it never ran.
  ///
  /// Never creates a session, so it is safe to call from a build method.
  OrchestratorSession? peek(String? conversationId) {
    if (conversationId == null || conversationId.isEmpty) return null;
    final session = _sessions[conversationId];
    if (session == null || session.isDisposed) return null;
    return session;
  }

  /// Record [conversationId] as the chat currently on screen.
  ///
  /// Used only to resolve the legacy shims; it never rebinds or restarts a
  /// session, which is what makes navigation non-destructive.
  void setCurrentSession(String? conversationId) {
    if (conversationId == null || conversationId.isEmpty) return;
    _currentSessionKey = conversationId;
    if (_sessions.containsKey(conversationId)) _touch(conversationId);
  }

  /// Dispose the session of [conversationId] (deleting a chat).
  Future<void> disposeSession(String conversationId) async {
    final session = _sessions.remove(conversationId);
    _mru.remove(conversationId);
    _lastUsed.remove(conversationId);
    if (_currentSessionKey == conversationId) _currentSessionKey = null;
    await session?.dispose();
  }

  /// Dispose every session. Called on app shutdown.
  Future<void> disposeAll() async {
    final all = _sessions.values.toList(growable: false);
    _sessions.clear();
    _mru.clear();
    _lastUsed.clear();
    _currentSessionKey = null;
    await Future.wait(all.map((s) => s.dispose()));
  }

  /// Ask every session to relaunch with the new configuration.
  ///
  /// A backend / model / project change is genuinely global, so each live
  /// chat must pick it up — but each one still finishes the answer it is
  /// producing first, because [OrchestratorSession.requestRestart] parks the
  /// relaunch while a turn is in flight.
  void requestRestartAll({
    required String reason,
    required OrchestratorStopSource source,
  }) {
    for (final session in _sessions.values) {
      session.requestRestart(reason: reason, source: source);
    }
  }

  void _touch(String key) {
    _lastUsed[key] = DateTime.now();
    _mru.remove(key);
    _mru.add(key);
  }

  void _reapIdle() {
    final now = DateTime.now();
    final stale = _lastUsed.entries
        .where((e) =>
            now.difference(e.value) > kSessionIdleTtl &&
            e.key != _currentSessionKey)
        .map((e) => e.key)
        .toList(growable: false);
    for (final key in stale) {
      final session = _sessions[key];
      if (session == null || session.isBusy) continue;
      _sessions.remove(key);
      _mru.remove(key);
      _lastUsed.remove(key);
      unawaited(session.dispose());
    }
  }

  /// Keep the live-process count near [kMaxConcurrentSessions].
  ///
  /// Only idle sessions are evicted, oldest first; the newly acquired [keep]
  /// session and the chat on screen are always spared.
  void _enforceCap(String keep) {
    while (_sessions.length > kMaxConcurrentSessions) {
      String? victim;
      for (final key in _mru) {
        if (key == keep || key == _currentSessionKey) continue;
        final session = _sessions[key];
        if (session == null || session.isBusy) continue;
        victim = key;
        break;
      }
      if (victim == null) return;
      final session = _sessions.remove(victim);
      _mru.remove(victim);
      _lastUsed.remove(victim);
      if (session != null) unawaited(session.dispose());
    }
  }

  String? get _ambientConversationId {
    final value = Zone.current[_kConversationZoneKey];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Resolution order for the legacy, id-less members.
  OrchestratorSession? get _currentSession {
    final ambient = _ambientConversationId;
    if (ambient != null) {
      final session = _sessions[ambient];
      if (session != null) return session;
    }
    final key = _currentSessionKey;
    if (key != null) {
      final session = _sessions[key];
      if (session != null) return session;
    }
    if (_mru.isEmpty) return null;
    return _sessions[_mru.last];
  }

  /// [_currentSession], acquiring the fallback session when nothing exists yet
  /// (a fresh app where Settings opened the orchestrator panel first).
  OrchestratorSession get _requireSession =>
      _currentSession ?? sessionFor(fallbackSessionKey);

  // ── Test seams ───────────────────────────────────────────────────────────
  // Every source passed to [stop] in this process, in call order. Widget tests
  // assert that navigation and configuration affordances never request a
  // teardown.
  @visibleForTesting
  static List<OrchestratorStopSource> get debugStopCalls =>
      OrchestratorSession.debugStopCalls;

  @visibleForTesting
  static List<String> get debugRestartReasons =>
      OrchestratorSession.debugRestartReasons;

  /// Drive the current session into [state] (see
  /// [OrchestratorSession.debugSetSessionState]).
  @visibleForTesting
  void debugSetSessionState({
    required OrchestratorSessionState state,
    String argsFingerprint = '',
  }) {
    _requireSession.debugSetSessionState(
      state: state,
      argsFingerprint: argsFingerprint,
    );
  }

  /// Install an in-flight turn completer on the current session.
  @visibleForTesting
  Completer<String> debugArmTurn() => _requireSession.debugArmTurn();

  @visibleForTesting
  bool get debugHasActiveTurn => _currentSession?.debugHasActiveTurn ?? false;

  /// Reset the current session to a pristine state between tests.
  @visibleForTesting
  void debugResetSession() {
    _currentSession?.debugResetSession();
  }

  /// Drop every session and forget the recorded debug calls.
  @visibleForTesting
  Future<void> debugResetAll() async {
    await disposeAll();
    OrchestratorSession.debugStopCalls.clear();
    OrchestratorSession.debugRestartReasons.clear();
  }

  // ── Legacy shims ─────────────────────────────────────────────────────────

  bool get isRunning => _currentSession?.isRunning ?? false;

  bool get isReady => _currentSession?.isReady ?? false;

  bool get isBusy => _currentSession?.isBusy ?? false;

  bool get hasPendingRestart => _currentSession?.hasPendingRestart ?? false;

  String get argsFingerprint => _currentSession?.argsFingerprint ?? '';

  OrchestratorSessionState get lastSessionState =>
      _currentSession?.lastSessionState ?? OrchestratorSessionState.stopped;

  Stream<OrchestratorSessionState> get sessionStateStream =>
      _currentSession?.sessionStateStream ?? const Stream.empty();

  OrchestratorBackend get currentBackend => _requireSession.currentBackend;

  String? get currentModelId => _currentSession?.currentModelId;

  double? get currentTemperature => _currentSession?.currentTemperature;

  String get stderrLog => _currentSession?.stderrLog ?? '';

  bool checkHealthy() => _currentSession?.checkHealthy() ?? false;

  bool matchesFingerprint(String fingerprint) =>
      _currentSession?.matchesFingerprint(fingerprint) ?? false;

  Stream<String> get logStream =>
      _currentSession?.logStream ?? const Stream.empty();

  List<String> get logLines => _currentSession?.logLines ?? const <String>[];

  String? get lastStatus => _currentSession?.lastStatus;

  Stream<String> get statusStream =>
      _currentSession?.statusStream ?? const Stream.empty();

  Stream<String> get thinkingStream =>
      _currentSession?.thinkingStream ?? const Stream.empty();

  String? get lastThinking => _currentSession?.lastThinking;

  Stream<List<Map<String, Object?>>> get traceStream =>
      _currentSession?.traceStream ?? const Stream.empty();

  List<Map<String, Object?>> get lastTrace =>
      _currentSession?.lastTrace ?? const <Map<String, Object?>>[];

  Stream<OrchestratorTaskEvent> get taskStream =>
      _currentSession?.taskStream ?? const Stream.empty();

  StreamController<OrchestratorTaskEvent> get taskController =>
      _requireSession.taskController;

  Stream<String> get autoInputNoticeStream =>
      _currentSession?.autoInputNoticeStream ?? const Stream.empty();

  Stream<String> get autoInputReplyStream =>
      _currentSession?.autoInputReplyStream ?? const Stream.empty();

  Stream<String> get autoInputPromptStream =>
      _currentSession?.autoInputPromptStream ?? const Stream.empty();

  Stream<bool> get autoInputEvaluatingStream =>
      _currentSession?.autoInputEvaluatingStream ?? const Stream.empty();

  bool get autoInputEvaluating =>
      _currentSession?.autoInputEvaluating ?? false;

  List<String> get autoInputReplies =>
      _currentSession?.autoInputReplies ?? const <String>[];

  List<String> get autoInputPrompts =>
      _currentSession?.autoInputPrompts ?? const <String>[];

  /// Start (or reuse) the session of [conversationId].
  Future<bool> startFor(
    String? conversationId, {
    String? hfToken,
    String? modelId,
    String? workingDirectory,
    OrchestratorBackend backend = OrchestratorBackend.huggingface,
    String? ollamaBaseUrl,
    int? ollamaNumCtx,
    bool? ollamaAutoNumCtx,
    double? temperature,
    int? maxTokens,
    String? ollamaApiKey,
    String? groqApiKey,
    String? geminiApiKey,
    String? openRouterApiKey,
    int? openRouterContextLimit,
    String? githubApiKey,
    int? tpmLimit,
    bool disableTools = false,
    bool? multiAgent,
  }) {
    return sessionFor(conversationId).start(
      hfToken: hfToken,
      modelId: modelId,
      workingDirectory: workingDirectory,
      backend: backend,
      ollamaBaseUrl: ollamaBaseUrl,
      ollamaNumCtx: ollamaNumCtx,
      ollamaAutoNumCtx: ollamaAutoNumCtx,
      temperature: temperature,
      maxTokens: maxTokens,
      ollamaApiKey: ollamaApiKey,
      groqApiKey: groqApiKey,
      geminiApiKey: geminiApiKey,
      openRouterApiKey: openRouterApiKey,
      openRouterContextLimit: openRouterContextLimit,
      githubApiKey: githubApiKey,
      tpmLimit: tpmLimit,
      disableTools: disableTools,
      multiAgent: multiAgent,
    );
  }

  /// Legacy: start the session of the ambient / current conversation.
  Future<bool> start({
    String? hfToken,
    String? modelId,
    String? workingDirectory,
    OrchestratorBackend backend = OrchestratorBackend.huggingface,
    String? ollamaBaseUrl,
    int? ollamaNumCtx,
    bool? ollamaAutoNumCtx,
    double? temperature,
    int? maxTokens,
    String? ollamaApiKey,
    String? groqApiKey,
    String? geminiApiKey,
    String? openRouterApiKey,
    int? openRouterContextLimit,
    String? githubApiKey,
    int? tpmLimit,
    bool disableTools = false,
    bool? multiAgent,
  }) {
    return _requireSession.start(
      hfToken: hfToken,
      modelId: modelId,
      workingDirectory: workingDirectory,
      backend: backend,
      ollamaBaseUrl: ollamaBaseUrl,
      ollamaNumCtx: ollamaNumCtx,
      ollamaAutoNumCtx: ollamaAutoNumCtx,
      temperature: temperature,
      maxTokens: maxTokens,
      ollamaApiKey: ollamaApiKey,
      groqApiKey: groqApiKey,
      geminiApiKey: geminiApiKey,
      openRouterApiKey: openRouterApiKey,
      openRouterContextLimit: openRouterContextLimit,
      githubApiKey: githubApiKey,
      tpmLimit: tpmLimit,
      disableTools: disableTools,
      multiAgent: multiAgent,
    );
  }

  /// Send a prompt to the session of [sessionKey] (or the ambient one).
  Future<String> sendPrompt(
    String prompt, {
    bool newSession = false,
    String? sessionKey,
    List<Map<String, String>> seedHistory = const [],
    bool forceHistorySync = false,
    String taskMode = 'user_input',
    bool? thinking,
    String? effort,
  }) {
    final resolvedKey = sessionKey ?? _ambientConversationId;
    final session = sessionFor(resolvedKey);
    return session.sendPrompt(
      prompt,
      newSession: newSession,
      sessionKey: session.conversationId,
      seedHistory: seedHistory,
      forceHistorySync: forceHistorySync,
      taskMode: taskMode,
      thinking: thinking,
      effort: effort,
    );
  }

  /// Stop the session of [conversationId]; other chats are untouched.
  Future<void> stopFor(
    String? conversationId, {
    OrchestratorStopSource source = OrchestratorStopSource.unspecified,
    String reason = '',
  }) async {
    final session = conversationId == null
        ? _currentSession
        : _sessions[conversationId];
    if (session == null) return;
    await session.stop(source: source, reason: reason);
  }

  /// Stop every live session.
  ///
  /// Used by the Settings → Orchestrator panel: Start/Stop there is a global
  /// affordance (it prepares the *configuration* the next launch will use), so
  /// it must reach every chat that owns a process. Each session still applies
  /// its own stop-authority rules, so a busy session only dies when [source]
  /// [mayTerminateSession] — otherwise its relaunch is parked until the answer
  /// lands.
  Future<void> stopAll({
    OrchestratorStopSource source = OrchestratorStopSource.unspecified,
    String reason = '',
  }) async {
    final all = _sessions.values.toList(growable: false);
    await Future.wait(
      all.map((s) => s.stop(source: source, reason: reason)),
    );
  }

  /// Legacy: stop the session of the ambient / current conversation.
  Future<void> stop({
    OrchestratorStopSource source = OrchestratorStopSource.unspecified,
    String reason = '',
  }) async {
    final session = _currentSession;
    if (session == null) {
      if (source.mayTerminateSession) {
        OrchestratorSession.debugStopCalls.add(source);
      }
      return;
    }
    await session.stop(source: source, reason: reason);
  }

  /// Park (or apply) a relaunch for the session of [conversationId].
  void requestRestartFor(
    String? conversationId, {
    required String reason,
    required OrchestratorStopSource source,
    String argsFingerprint = '',
  }) {
    sessionFor(conversationId).requestRestart(
      reason: reason,
      source: source,
      argsFingerprint: argsFingerprint,
    );
  }

  /// Legacy: park a relaunch on the ambient / current conversation's session.
  void requestRestart({
    required String reason,
    required OrchestratorStopSource source,
    String argsFingerprint = '',
  }) {
    _requireSession.requestRestart(
      reason: reason,
      source: source,
      argsFingerprint: argsFingerprint,
    );
  }

  /// Read the on-disk log of [conversationId] into that session's buffer.
  void loadLogFromDisk(String conversationId) {
    sessionFor(conversationId).loadLogFromDisk(conversationId);
  }

  Future<bool> installDependencies({void Function(String line)? onLine}) =>
      _requireSession.installDependencies(onLine: onLine);

  Future<bool> installPackage(
    String packageName, {
    void Function(String line)? onLine,
  }) =>
      _requireSession.installPackage(packageName, onLine: onLine);

  // ── Static helpers, re-exported for existing call sites ───────────────────

  static String get defaultPythonExecutable =>
      OrchestratorSession.defaultPythonExecutable;

  static Future<String> resolvePythonExecutable() =>
      OrchestratorSession.resolvePythonExecutable();

  static Future<Map<String, String>> resolveSubprocessEnvironment() =>
      OrchestratorSession.resolveSubprocessEnvironment();

  static Directory get baseDirectory => OrchestratorSession.baseDirectory;

  static String fingerprintFor({
    required OrchestratorBackend backend,
    required String modelId,
    double? temperature,
    int? maxTokens,
    bool multiAgent = false,
    String? basePath,
  }) =>
      OrchestratorSession.fingerprintFor(
        backend: backend,
        modelId: modelId,
        temperature: temperature,
        maxTokens: maxTokens,
        multiAgent: multiAgent,
        basePath: basePath,
      );

  static String toProviderString(String backend) =>
      OrchestratorSession.toProviderString(backend);
}

/// Returns the default temperature for the given backend from BackendSettingsRepository.
Future<double> _getDefaultTemperatureForBackend(OrchestratorBackend backend) async {
  final backendSettings = BackendSettingsRepository.instance;
  switch (backend) {
    case OrchestratorBackend.huggingface:
      return await backendSettings.getHuggingFaceTemperature();
    case OrchestratorBackend.ollama:
      return await backendSettings.getOllamaTemperature();
    case OrchestratorBackend.groq:
      return await backendSettings.getGroqTemperature();
    case OrchestratorBackend.gemini:
      return await backendSettings.getGeminiTemperature();
    case OrchestratorBackend.openrouter:
      return await backendSettings.getOpenRouterTemperature();
    case OrchestratorBackend.github:
      return await backendSettings.getGitHubTemperature();
    // Fallback for unknown backends
  }
}
