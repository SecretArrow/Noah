import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart'
    show ChatController, ChatState;
import 'package:noah/ui/theme.dart';
import 'package:noah/ui/widgets/chat_body.dart';

/// v1.48.1 — the user must SEE plan progress: [ChatBody] auto-reveals the
/// live Plan panel the moment a run's FIRST `todo_write` lands (todos
/// empty → non-empty while running). These tests pin the guards: idle
/// plan loads (opening a saved chat) never open it, and closing the panel
/// mid-run is respected for the rest of that run.

const List<TodoItem> kPlan = <TodoItem>[
  TodoItem(content: 'research topic', status: TodoStatus.completed),
  TodoItem(content: 'draft report', status: TodoStatus.inProgress),
  TodoItem(content: 'review output', status: TodoStatus.pending),
];

/// A ChatController stub parked on a fixed state — same trick as
/// todo_plan_card_test: lets the harness drive state manually without
/// booting the real controller (which touches disk and network).
class _ParkedChatController extends ChatController {
  _ParkedChatController(this._initial);

  final ChatState _initial;

  @override
  ChatState build() => _initial;
}

/// State for the on-screen chat: a user message plus a streaming tail
/// assistant bubble while running (idle runs show the finished bubble).
ChatState chatState({required List<TodoItem> todos, required bool running}) =>
    ChatState(
      sessionId: 'a',
      isRunning: running,
      messages: <ChatMessage>[
        ChatMessage.user('go'),
        ChatMessage.assistant(running ? '' : 'All done!', isStreaming: running),
      ],
      todos: todos,
    );

void main() {
  Widget wrap(ChatState initial) => ProviderScope(
    overrides: <Override>[
      chatControllerProvider.overrideWith(() => _ParkedChatController(initial)),
    ],
    child: MaterialApp(
      theme: buildDarkTheme(),
      locale: const Locale('en'),
      supportedLocales: const <Locale>[Locale('en'), Locale('id')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        zLocalizationsDelegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(body: ChatBody()),
    ),
  );

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(ChatBody)));

  testWidgets('the FIRST todo_write of a run auto-opens the plan panel and '
      'the live plan renders through the thinking footer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      wrap(chatState(todos: const <TodoItem>[], running: true)),
    );
    await tester.pump();
    final ProviderContainer container = containerOf(tester);
    expect(find.text('thinking…'), findsOneWidget);
    expect(
      container.read(planPanelOpenProvider),
      isFalse,
      reason: 'no plan yet — panel starts closed',
    );

    // First plan of the run lands while the agent is working.
    container.read(chatControllerProvider.notifier).state = chatState(
      todos: kPlan,
      running: true,
    );
    await tester.pump();
    expect(
      container.read(planPanelOpenProvider),
      isTrue,
      reason: 'first plan write of a run must auto-reveal the panel',
    );

    // The inline footer picks it up on the next frame batch.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('live-todo-panel')), findsOneWidget);
    expect(find.byKey(const Key('plan-progress-label')), findsOneWidget);
  });

  testWidgets('todos appearing while IDLE (opening a saved chat from disk) '
      'never auto-open the panel', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(chatState(todos: const <TodoItem>[], running: false)),
    );
    await tester.pump();

    containerOf(tester).read(chatControllerProvider.notifier).state = chatState(
      todos: kPlan,
      running: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      containerOf(tester).read(planPanelOpenProvider),
      isFalse,
      reason: 'disk-load path must not yank the panel open',
    );
    expect(find.byKey(const Key('live-todo-panel')), findsNothing);
  });

  testWidgets('closing the panel mid-run stays closed for later plan '
      'writes of the SAME run (no new empty→non-empty transition)', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      wrap(chatState(todos: const <TodoItem>[], running: true)),
    );
    await tester.pump();
    final ProviderContainer container = containerOf(tester);

    container.read(chatControllerProvider.notifier).state = chatState(
      todos: kPlan,
      running: true,
    );
    await tester.pump();
    expect(container.read(planPanelOpenProvider), isTrue);

    // User closes it (X button path) while the run continues.
    container.read(planPanelOpenProvider.notifier).state = false;
    await tester.pump();

    // Next todo_write: the plan stays non-empty → must not re-open.
    container.read(chatControllerProvider.notifier).state = chatState(
      todos: const <TodoItem>[
        TodoItem(content: 'research topic', status: TodoStatus.completed),
        TodoItem(content: 'draft report', status: TodoStatus.completed),
      ],
      running: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      container.read(planPanelOpenProvider),
      isFalse,
      reason: 'a mid-run close must be respected within the same run',
    );
    expect(find.byKey(const Key('live-todo-panel')), findsNothing);
  });
}
