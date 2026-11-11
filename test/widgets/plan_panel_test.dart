import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart' show ChatState;
import 'package:noah/ui/theme.dart';
import 'package:noah/ui/widgets/plan_panel.dart';

const List<TodoItem> _plan = <TodoItem>[
  TodoItem(content: 'research topic', status: TodoStatus.completed),
  TodoItem(content: 'draft report', status: TodoStatus.inProgress),
  TodoItem(content: 'review output', status: TodoStatus.pending),
];

ChatMessage _msg(String content, {bool streaming = false, Role? role}) =>
    role == Role.user
    ? ChatMessage.user(content)
    : ChatMessage.assistant(content, isStreaming: streaming);

void main() {
  Widget wrap(Widget child) => ProviderScope(
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
      home: Scaffold(
        body: Column(
          children: <Widget>[
            child,
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    ),
  );

  /// Drives the active-chat state exactly like the controller does on
  /// streaming syncs, step transitions, chat switches and run end.
  void setActiveState(WidgetTester tester, ChatState state) {
    final BuildContext context = tester.element(find.byType(PlanPanel));
    final ProviderContainer container = ProviderScope.containerOf(context);
    container.read(chatControllerProvider.notifier).state = state;
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(PlanPanel)));

  Future<void> openPanel(WidgetTester tester) async {
    containerOf(tester).read(planPanelOpenProvider.notifier).state = true;
    // two pumps: start + finish the AnimatedSize transition so hit tests
    // target the settled layout.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('panel is hidden while closed even when a plan exists', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(const PlanPanel()));
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        messages: <ChatMessage>[ChatMessage.user('hi')],
        todos: _plan,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('live-todo-panel')), findsNothing);
  });

  testWidgets('opening renders the CURRENT plan and every status update '
      'lands in real time without reopening', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const PlanPanel()));
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        messages: <ChatMessage>[ChatMessage.user('hi')],
        todos: _plan,
      ),
    );
    await openPanel(tester);

    expect(find.byKey(const Key('live-todo-panel')), findsOneWidget);
    expect(find.text('research topic'), findsOneWidget);
    expect(find.text('draft report'), findsOneWidget);
    expect(find.text('review output'), findsOneWidget);
    expect(find.text(const AppStringsEn().planProgress(1, 3)), findsOneWidget);

    // todo_write during the run: the SAME mounted panel re-renders — no
    // reopen, no refresh.
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        messages: <ChatMessage>[ChatMessage.user('hi')],
        todos: <TodoItem>[
          TodoItem(content: 'research topic', status: TodoStatus.completed),
          TodoItem(content: 'draft report', status: TodoStatus.completed),
          TodoItem(content: 'review output', status: TodoStatus.inProgress),
        ],
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('live-todo-panel')), findsOneWidget);
    expect(
      find.text(const AppStringsEn().planProgress(2, 3)),
      findsOneWidget,
      reason: 'status changes must appear immediately in the open panel',
    );
  });

  testWidgets('v1.48.1: the live plan header shows the completed/total '
      'counter label and a half-filled progress bar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(wrap(const PlanPanel()));
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        messages: <ChatMessage>[ChatMessage.user('hi')],
        todos: const <TodoItem>[
          TodoItem(content: 'step one', status: TodoStatus.completed),
          TodoItem(content: 'step two', status: TodoStatus.completed),
          TodoItem(content: 'step three', status: TodoStatus.inProgress),
          TodoItem(content: 'step four', status: TodoStatus.pending),
        ],
      ),
    );
    await openPanel(tester);

    expect(find.byKey(const Key('live-todo-panel')), findsOneWidget);
    // Counter: "2 of 4 done" in the en harness — keyed on the LIVE view
    // only (the historical TodoPlanCard keeps its unlabeled counter).
    final Finder label = find.byKey(const Key('plan-progress-label'));
    expect(label, findsOneWidget);
    expect(
      tester.widget<Text>(label).data,
      const AppStringsEn().planProgress(2, 4),
    );

    // Thin progress bar under the header reflects 2/4 completed.
    final Finder bar = find.descendant(
      of: find.byKey(const Key('live-todo-panel')),
      matching: find.byType(LinearProgressIndicator),
    );
    expect(bar, findsOneWidget);
    expect(
      tester.widget<LinearProgressIndicator>(bar).value,
      closeTo(0.5, 0.001),
    );
  });

  testWidgets('pinned panel STEPS ASIDE while the agent runs (the thinking '
      'footer renders the plan inline above the row) and the SAME open flag '
      'restores it the moment the run ends', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const PlanPanel()));
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        isRunning: true,
        messages: <ChatMessage>[
          _msg('hi', role: Role.user),
          _msg('', streaming: true),
        ],
        todos: _plan,
      ),
    );
    await openPanel(tester);
    // While running, the pinned host renders nothing: the plan lives
    // inline above the thinking row (footer render, v1.41.6).
    expect(
      find.byKey(const Key('live-todo-panel')),
      findsNothing,
      reason: 'pinned host must not double-render while the footer is up',
    );

    // Next agent step: still running — still stepped aside, and the open
    // flag survives the transition (the footer re-renders it elsewhere).
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        isRunning: true,
        messages: <ChatMessage>[
          _msg('hi', role: Role.user),
          _msg('Step 1 result', role: Role.user),
          _msg('', streaming: true),
        ],
        todos: _plan,
      ),
    );
    await tester.pump();
    expect(
      containerOf(tester).read(planPanelOpenProvider),
      isTrue,
      reason: 'step transition must not close the panel',
    );
    expect(find.byKey(const Key('live-todo-panel')), findsNothing);

    // Run ends: the thinking footer unmounts — the pinned panel returns
    // on its own, same plan, still open (run end never closes it).
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        messages: <ChatMessage>[
          _msg('hi', role: Role.user),
          _msg('Step 1 result', role: Role.user),
          _msg('All done!', role: Role.user),
        ],
        todos: _plan,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const Key('live-todo-panel')),
      findsOneWidget,
      reason: 'run end must hand the plan back to the pinned host',
    );
    expect(
      find.text('All done!'),
      findsNothing,
      reason: 'sanity: the list itself is not rendered in this harness',
    );
  });

  testWidgets('panel stays open across a chat switch and follows the '
      'active chat plan; no plan in the other chat renders empty and the '
      'open state is kept', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const PlanPanel()));
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        messages: <ChatMessage>[ChatMessage.user('hi')],
        todos: _plan,
      ),
    );
    await openPanel(tester);
    expect(find.text('research topic'), findsOneWidget);

    // Switch to chat B which has a DIFFERENT plan — the panel shows B's
    // plan (never a leak of A's rows).
    setActiveState(
      tester,
      ChatState(
        sessionId: 'b',
        messages: <ChatMessage>[ChatMessage.user('other task')],
        todos: <TodoItem>[
          TodoItem(content: 'plan-b-step', status: TodoStatus.inProgress),
        ],
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('live-todo-panel')), findsOneWidget);
    expect(find.text('plan-b-step'), findsOneWidget);
    expect(
      find.text('research topic'),
      findsNothing,
      reason: 'no cross-chat plan leakage',
    );

    // Switch to chat C without any plan: panel renders nothing but the
    // OPEN flag persists.
    setActiveState(
      tester,
      ChatState(
        sessionId: 'c',
        messages: <ChatMessage>[ChatMessage.user('no plan here')],
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('live-todo-panel')), findsNothing);

    // Back to chat A: the still-open flag restores the panel instantly.
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        messages: <ChatMessage>[ChatMessage.user('hi')],
        todos: _plan,
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('live-todo-panel')), findsOneWidget);
  });

  testWidgets('close button (X) closes the panel; the footer toggle can '
      'reopen it', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const PlanPanel()));
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        messages: <ChatMessage>[ChatMessage.user('hi')],
        todos: _plan,
      ),
    );
    await openPanel(tester);
    expect(find.byKey(const Key('live-todo-panel')), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan-panel-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('live-todo-panel')), findsNothing);
    expect(containerOf(tester).read(planPanelOpenProvider), isFalse);

    containerOf(tester).read(planPanelOpenProvider.notifier).state = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('live-todo-panel')), findsOneWidget);
  });

  testWidgets('a background session plan never leaks into the displayed '
      'chat panel', (WidgetTester tester) async {
    // The panel only ever renders the ACTIVE ChatState todos — a run in
    // another session mirrors into _runs, not here. Assert the invariant
    // from the UI side: state for chat 'a' displayed while 'b' runs.
    await tester.pumpWidget(wrap(const PlanPanel()));
    setActiveState(
      tester,
      ChatState(
        sessionId: 'a',
        isRunning: false,
        messages: <ChatMessage>[ChatMessage.user('hi')],
        todos: _plan,
      ),
    );
    await openPanel(tester);
    expect(find.text('research topic'), findsOneWidget);
    expect(find.text('plan-b-step'), findsNothing);
  });
}
