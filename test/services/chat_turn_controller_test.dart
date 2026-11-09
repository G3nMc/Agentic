import 'package:agentic/data/models/message.dart';
import 'package:agentic/services/chat_turn_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Turn ownership lives outside the widget tree so a remount (conversation
/// switch, Settings tab) cannot lose an answer that is still being produced.
///
/// Ownership is *keyed* by conversation: one live turn per chat, and any number
/// of chats in parallel. These tests pin that contract.
void main() {
  final controller = ChatTurnController.instance;

  tearDown(() {
    // Leave the singleton idle for the next test.
    controller.abortAll('test teardown');
  });

  ChatMessage assistant(String conversationId, String content) => ChatMessage(
        id: 'm-$content',
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: content,
        createdAt: 0,
      );

  test('begin takes ownership and emits ChatTurnStarted', () async {
    final events = <ChatTurnEvent>[];
    final sub = controller.events.listen(events.add);
    addTearDown(sub.cancel);

    final turn = controller.begin(conversationId: 'c1', prompt: 'hello');
    await Future<void>.delayed(Duration.zero);

    expect(turn, isNotNull);
    expect(controller.isBusyFor('c1'), isTrue);
    expect(controller.activeFor('c1')?.prompt, 'hello');
    expect(events.single, isA<ChatTurnStarted>());
    expect((events.single as ChatTurnStarted).prompt, 'hello');
  });

  test('two conversations run their own turn concurrently', () async {
    final events = <ChatTurnEvent>[];
    final sub = controller.events.listen(events.add);
    addTearDown(sub.cancel);

    final a = controller.begin(conversationId: 'c1', prompt: 'one');
    final b = controller.begin(conversationId: 'c2', prompt: 'two');
    await Future<void>.delayed(Duration.zero);

    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(controller.isBusyFor('c1'), isTrue);
    expect(controller.isBusyFor('c2'), isTrue);
    expect(controller.activeTurns.keys, unorderedEquals(['c1', 'c2']));
    expect(events.whereType<ChatTurnStarted>(), hasLength(2));
  });

  test('a second begin on the same conversation is refused', () async {
    final first = controller.begin(conversationId: 'c1', prompt: 'one');
    final second = controller.begin(conversationId: 'c1', prompt: 'two');

    expect(first, isNotNull);
    expect(second, isNull);
    // The original owner is still in charge — one stdin pipe, one turn.
    expect(controller.activeFor('c1')?.prompt, 'one');
  });

  test('begin refuses an empty conversation id', () {
    expect(controller.begin(conversationId: '', prompt: 'x'), isNull);
  });

  test('complete emits ChatTurnCompleted and clears only its own entry',
      () async {
    final events = <ChatTurnEvent>[];
    final sub = controller.events.listen(events.add);
    addTearDown(sub.cancel);

    final a = controller.begin(conversationId: 'c1', prompt: 'hi')!;
    final b = controller.begin(conversationId: 'c2', prompt: 'yo')!;
    controller.complete(a, assistant('c1', 'reply'), 1234);
    await Future<void>.delayed(Duration.zero);

    expect(controller.isBusyFor('c1'), isFalse);
    expect(controller.isBusyFor('c2'), isTrue);

    final completed = events.whereType<ChatTurnCompleted>().single;
    expect(completed.conversationId, 'c1');
    expect(completed.message.content, 'reply');
    expect(completed.responseTimeMs, 1234);

    controller.complete(b, assistant('c2', 'other'), 10);
  });

  test('fail emits ChatTurnFailed and clears the active turn', () async {
    final events = <ChatTurnEvent>[];
    final sub = controller.events.listen(events.add);
    addTearDown(sub.cancel);

    final turn = controller.begin(conversationId: 'c1', prompt: 'hi')!;
    controller.fail(turn, 'boom');
    await Future<void>.delayed(Duration.zero);

    expect(controller.isBusyFor('c1'), isFalse);
    final failed = events.whereType<ChatTurnFailed>().single;
    expect(failed.error, 'boom');
  });

  test('abort emits ChatTurnAborted, clears the turn and marks it cancelled',
      () async {
    final events = <ChatTurnEvent>[];
    final sub = controller.events.listen(events.add);
    addTearDown(sub.cancel);

    final turn = controller.begin(conversationId: 'c1', prompt: 'hi')!;
    controller.abort('c1', 'user stopped generation');
    await Future<void>.delayed(Duration.zero);

    expect(turn.cancelled, isTrue);
    expect(controller.isBusyFor('c1'), isFalse);

    final aborted = events.whereType<ChatTurnAborted>().single;
    expect(aborted.conversationId, 'c1');
    expect(aborted.reason, 'user stopped generation');
  });

  test('aborting one conversation leaves the other untouched', () async {
    final a = controller.begin(conversationId: 'c1', prompt: 'hi')!;
    final b = controller.begin(conversationId: 'c2', prompt: 'yo')!;

    controller.abort('c2', 'stop c2');

    expect(a.cancelled, isFalse);
    expect(b.cancelled, isTrue);
    expect(controller.isBusyFor('c1'), isTrue);
    expect(controller.isBusyFor('c2'), isFalse);

    controller.abort('c1', 'cleanup');
  });

  test('completing a cancelled turn reports an abort, not a completion',
      () async {
    final events = <ChatTurnEvent>[];
    final sub = controller.events.listen(events.add);
    addTearDown(sub.cancel);

    final turn = controller.begin(conversationId: 'c1', prompt: 'hi')!;
    controller.abort('c1', 'stop');
    // The transaction still finishes; its result must be discarded.
    controller.complete(turn, assistant('c1', 'late reply'), 42);
    await Future<void>.delayed(Duration.zero);

    expect(events.whereType<ChatTurnCompleted>(), isEmpty);
    expect(events.whereType<ChatTurnAborted>(), hasLength(2));
  });

  test('a late subscriber rehydrates from activeFor', () async {
    controller.begin(conversationId: 'c1', prompt: 'hi');

    final events = <ChatTurnEvent>[];
    final sub = controller.events.listen(events.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);
    // Nothing was buffered for the late subscriber: that is what `activeFor`
    // is for, and it is checked below.
    expect(events, isEmpty);
    expect(controller.isBusyFor('c1'), isTrue);
    expect(controller.isBusyFor('c2'), isFalse);

    final turn = controller.activeFor('c1')!;
    controller.complete(turn, assistant('c1', 'reply'), 10);
    await Future<void>.delayed(Duration.zero);

    expect(events.whereType<ChatTurnCompleted>(), hasLength(1));
  });

  test('abort is a no-op when nothing is running', () async {
    final events = <ChatTurnEvent>[];
    final sub = controller.events.listen(events.add);
    addTearDown(sub.cancel);

    controller.abort('c1', 'nothing to abort');
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    expect(controller.isBusy, isFalse);
    expect(controller.anyBusy, isFalse);
  });

  test('abortAll clears every conversation', () async {
    controller.begin(conversationId: 'c1', prompt: 'hi');
    controller.begin(conversationId: 'c2', prompt: 'yo');

    controller.abortAll('shutdown');

    expect(controller.activeTurns, isEmpty);
    expect(controller.isBusy, isFalse);
  });
}