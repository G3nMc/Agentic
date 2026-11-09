import 'dart:async';

import '../data/models/message.dart';

/// Lifecycle events of the chat turn that is currently in flight.
///
/// A turn is the whole `prompt -> orchestrator -> reply -> persist`
/// transaction. Ownership lives here rather than in [_ChatViewState] so that a
/// widget remount (conversation switch, settings tab, any navigation) cannot
/// lose an answer that is still being produced.
sealed class ChatTurnEvent {
  const ChatTurnEvent(this.conversationId);

  final String conversationId;
}

class ChatTurnStarted extends ChatTurnEvent {
  const ChatTurnStarted(super.conversationId, this.prompt);

  final String prompt;
}

class ChatTurnCompleted extends ChatTurnEvent {
  const ChatTurnCompleted(
    super.conversationId,
    this.message,
    this.responseTimeMs,
  );

  final ChatMessage message;
  final int responseTimeMs;
}

class ChatTurnFailed extends ChatTurnEvent {
  const ChatTurnFailed(super.conversationId, this.error);

  final String error;
}

class ChatTurnAborted extends ChatTurnEvent {
  const ChatTurnAborted(super.conversationId, this.reason);

  final String reason;
}

/// One in-flight prompt. [cancelled] is flipped by [ChatTurnController.abort]
/// so a late reply is discarded instead of being appended to the chat.
class ChatTurn {
  ChatTurn({
    required this.conversationId,
    required this.prompt,
    required this.startedAtMs,
  });

  final String conversationId;
  final String prompt;
  final int startedAtMs;
  bool cancelled = false;
}

/// Process-global owner of the running chat turn.
///
/// The chat view subscribes to [events] and rehydrates from [active] when it
/// mounts, so navigating away and back re-attaches to the same transaction
/// instead of dropping it.
class ChatTurnController {
  ChatTurnController._();

  static final ChatTurnController instance = ChatTurnController._();

  /// One live turn per conversation, keyed by the conversation GUID.
  ///
  /// This map is the whole multi-session contract: chat A and chat B each own
  /// an independent turn, so starting a prompt in B can never be refused
  /// because A is still answering.
  final Map<String, ChatTurn> _turns = <String, ChatTurn>{};

  /// The turn in flight for [conversationId], or null when that chat is idle.
  ChatTurn? activeFor(String? conversationId) {
    if (conversationId == null || conversationId.isEmpty) return null;
    return _turns[conversationId];
  }

  /// True when [conversationId] has a turn in flight.
  ///
  /// The chat view rehydrates its `_sending` flag from this, so re-entering a
  /// chat whose answer is still being produced restores the Stop affordance
  /// instead of rendering an idle input bar.
  bool isBusyFor(String? conversationId) => activeFor(conversationId) != null;

  /// Read-only snapshot of every in-flight turn, keyed by conversation id.
  Map<String, ChatTurn> get activeTurns => Map.unmodifiable(_turns);

  /// The single in-flight turn, or null.
  ///
  /// Legacy single-session view of the registry: returns the first live turn.
  /// Call sites that know their conversation must use [activeFor] instead.
  ChatTurn? get active => _turns.isEmpty ? null : _turns.values.first;

  /// True when at least one conversation has a turn in flight.
  bool get isBusy => _turns.isNotEmpty;

  /// True when at least one conversation has a turn in flight.
  bool get anyBusy => _turns.isNotEmpty;

  final StreamController<ChatTurnEvent> _events =
      StreamController<ChatTurnEvent>.broadcast();

  /// Live turn transitions. Broadcast so a re-mounting view can subscribe
  /// without contending with the previous subscription.
  ///
  /// Every event carries its [ChatTurnEvent.conversationId]; subscribers must
  /// filter on the chat they render.
  Stream<ChatTurnEvent> get events => _events.stream;

  /// Open a turn for [conversationId] and emit [ChatTurnStarted].
  ///
  /// Returns null only when *that same* conversation already has a turn in
  /// flight: two prompts on one chat still serialise, because a single
  /// orchestrator session owns a single stdin pipe. Other conversations are
  /// unaffected.
  ChatTurn? begin({required String conversationId, required String prompt}) {
    if (conversationId.isEmpty) return null;
    if (_turns.containsKey(conversationId)) return null;
    final turn = ChatTurn(
      conversationId: conversationId,
      prompt: prompt,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _turns[conversationId] = turn;
    _emit(ChatTurnStarted(conversationId, prompt));
    return turn;
  }

  /// Close [turn] with a delivered answer.
  ///
  /// The event is what makes the reply reach the UI: the chat view that is
  /// mounted when it fires renders it, even if that is a different view
  /// instance from the one that dispatched the prompt.
  void complete(ChatTurn turn, ChatMessage message, int responseTimeMs) {
    if (turn.cancelled) {
      _emit(ChatTurnAborted(turn.conversationId, 'cancelled by the user'));
    } else {
      _emit(ChatTurnCompleted(turn.conversationId, message, responseTimeMs));
    }
    _release(turn);
  }

  /// Close [turn] with an error.
  void fail(ChatTurn turn, String error) {
    if (turn.cancelled) {
      _emit(ChatTurnAborted(turn.conversationId, 'cancelled by the user'));
    } else {
      _emit(ChatTurnFailed(turn.conversationId, error));
    }
    _release(turn);
  }

  /// Mark the running turn of [conversationId] cancelled and emit
  /// [ChatTurnAborted].
  ///
  /// The transaction that owns the turn keeps running to completion, but it
  /// checks [ChatTurn.cancelled] before persisting and discards its result.
  /// Only that conversation is touched: a Stop pressed in chat B leaves chat
  /// A's turn running.
  void abort(String conversationId, String reason) {
    final turn = _turns.remove(conversationId);
    if (turn == null) return;
    turn.cancelled = true;
    _emit(ChatTurnAborted(conversationId, reason));
  }

  /// Abort every in-flight turn. Used on app shutdown only.
  void abortAll(String reason) {
    for (final id in _turns.keys.toList(growable: false)) {
      abort(id, reason);
    }
  }

  /// Remove [turn] from the registry, leaving every other conversation's
  /// entry in place.
  void _release(ChatTurn turn) {
    final existing = _turns[turn.conversationId];
    if (identical(existing, turn)) _turns.remove(turn.conversationId);
  }

  void _emit(ChatTurnEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}