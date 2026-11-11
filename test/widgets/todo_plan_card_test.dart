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
import 'package:noah/ui/widgets/composer.dart';
import 'package:noah/ui/widgets/message_bubble.dart';
import 'package:noah/ui/widgets/todo_plan_card.dart';
import 'package:noah/ui/widgets/tool_call_card.dart';

const List<TodoItem> kFooterTodos = <TodoItem>[
  TodoItem(content: 'research topic', status: TodoStatus.completed),
  TodoItem(content: 'draft report', status: TodoStatus.inProgress),
  TodoItem(content: 'review output', status: TodoStatus.pending),
];

ChatMessage _assistantWith(Map<String, dynamic> args) => ChatMessage.assistant(
  '',
  toolCalls: <ToolCall>[
    ToolCall(
      id: 'p1',
      name: 'todo_write',
      arguments: args,
      status: ToolStatus.success,
      resultText: '{"ok":true}',
    ),
  ],
);

/// A ChatController stub parked on a fixed state (running or not) — lets
/// a widget harness render BOTH the thinking footer and the composer
/// against the same state without booting the real app shell.
class _ParkedChatController extends ChatController {
  _ParkedChatController(this._initial);

  final ChatState _initial;

  @override
  ChatState build() => _initial;
}

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
      home: Scaffold(body: ListView(children: <Widget>[child])),
    ),
  );

  testWidgets('todo_write renders a plan card with progress and statuses', (
    WidgetTester tester,
  ) async {
    final ChatMessage message = _assistantWith(<String, dynamic>{
      'todos': <dynamic>[
        <String, dynamic>{'content': 'research topic', 'status': 'completed'},
        <String, dynamic>{'content': 'draft report', 'status': 'in_progress'},
        <String, dynamic>{'content': 'review output', 'status': 'pending'},
      ],
    });

    await tester.pumpWidget(wrap(MessageBubble(message: message)));

    expect(find.byType(TodoPlanCard), findsOneWidget);
    expect(find.byType(ToolCallCard), findsNothing);
    expect(find.byKey(const Key('todo-plan-card')), findsOneWidget);

    const AppStrings strings = AppStringsEn();
    expect(find.text(strings.planTitle), findsOneWidget);
    expect(find.text(strings.planProgress(1, 3)), findsOneWidget);
    expect(find.text('research topic'), findsOneWidget);
    expect(find.text('draft report'), findsOneWidget);
    expect(find.text('review output'), findsOneWidget);

    // Status icons: 1 completed check + 1 in-progress ring + 1 pending ring.
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsOneWidget);
  });

  testWidgets('v1.49: blocked todo shows reason line and depends-on row', (
    WidgetTester tester,
  ) async {
    final ChatMessage message = _assistantWith(<String, dynamic>{
      'todos': <dynamic>[
        <String, dynamic>{'content': 'setup env', 'status': 'completed'},
        <String, dynamic>{
          'content': 'deploy service',
          'status': 'blocked',
          'blocked_reason': 'API key missing — ask the user',
          'depends_on': <String>['1'],
        },
      ],
    });

    await tester.pumpWidget(wrap(MessageBubble(message: message)));

    expect(find.byType(TodoPlanCard), findsOneWidget);
    expect(find.byIcon(Icons.block_rounded), findsOneWidget);
    const AppStrings strings = AppStringsEn();
    expect(
      find.text('Blocked: API key missing — ask the user'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('todo-blocked-reason-1')), findsOneWidget);
    expect(find.text('Depends on 1'), findsOneWidget);
    expect(find.byKey(const Key('todo-depends-1')), findsOneWidget);
    expect(find.text(strings.todoBlocked), findsNothing);
  });

  testWidgets('v1.49: blocked step without reason renders no reason row', (
    WidgetTester tester,
  ) async {
    final ChatMessage message = _assistantWith(<String, dynamic>{
      'todos': <dynamic>[
        <String, dynamic>{'content': 'silent block', 'status': 'blocked'},
      ],
    });

    await tester.pumpWidget(wrap(MessageBubble(message: message)));

    expect(find.byType(TodoPlanCard), findsOneWidget);
    // Parser degrades a reasonless blocked todo to pending: no block icon.
    expect(find.byIcon(Icons.block_rounded), findsNothing);
    expect(find.byKey(const Key('todo-blocked-reason-0')), findsNothing);
    expect(find.byKey(const Key('todo-depends-0')), findsNothing);
  });

  testWidgets('todo_write with malformed args falls back to ToolCallCard', (
    WidgetTester tester,
  ) async {
    final ChatMessage message = _assistantWith(<String, dynamic>{
      'todos': 'not-a-list',
    });

    await tester.pumpWidget(wrap(MessageBubble(message: message)));

    expect(find.byType(TodoPlanCard), findsNothing);
    expect(find.byType(ToolCallCard), findsOneWidget);
    expect(find.text('todo_write'), findsOneWidget);
  });

  testWidgets('plan card reflects the latest state of its own call', (
    WidgetTester tester,
  ) async {
    // A later todo_write (completed plan) renders fully checked.
    final ChatMessage message = _assistantWith(<String, dynamic>{
      'todos': <dynamic>[
        <String, dynamic>{'content': 'step', 'status': 'completed'},
      ],
    });

    await tester.pumpWidget(wrap(MessageBubble(message: message)));

    expect(find.byType(TodoPlanCard), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
    expect(find.text(const AppStringsEn().planProgress(1, 1)), findsOneWidget);
  });

  group('live plan toggle (thinking indicator)', () {
    final List<TodoItem> todos = const <TodoItem>[
      TodoItem(content: 'research topic', status: TodoStatus.completed),
      TodoItem(content: 'draft report', status: TodoStatus.inProgress),
      TodoItem(content: 'review output', status: TodoStatus.pending),
    ];

    testWidgets('streaming message with a plan shows the right-aligned '
        'show/hide toggle that flips the GLOBAL panel open state', (
      WidgetTester tester,
    ) async {
      final ChatMessage message = ChatMessage.assistant(
        'Working on it…',
        isStreaming: true,
      );

      late WidgetRef capturedRef;
      await tester.pumpWidget(
        wrap(
          Consumer(
            builder: (_, WidgetRef ref, _) {
              capturedRef = ref;
              return MessageBubble(message: message, todos: todos);
            },
          ),
        ),
      );

      // Toggle exists, panel closed at first.
      expect(find.byKey(const Key('todo-toggle-button')), findsOneWidget);
      expect(find.text('thinking…'), findsOneWidget);
      expect(
        capturedRef.read(planPanelOpenProvider),
        isFalse,
        reason: 'panel starts closed',
      );

      // Show: the toggle flips the global state — the pinned panel
      // (rendered by ChatBody, covered by plan_panel_test) reacts to it.
      await tester.tap(find.byKey(const Key('todo-toggle-button')));
      await tester.pump();
      expect(capturedRef.read(planPanelOpenProvider), isTrue);
      // v1.41.6: with the plan open there are TWO "Hide plan" affordances
      // — the footer's eye toggle AND the inline panel's close (X) button.
      expect(
        find.byTooltip(const AppStringsEn().hidePlanTooltip),
        findsNWidgets(2),
      );

      // Hide again.
      await tester.tap(find.byKey(const Key('todo-toggle-button')));
      await tester.pump();
      expect(capturedRef.read(planPanelOpenProvider), isFalse);
    });

    testWidgets('v1.41.6: an OPEN plan renders INLINE directly ABOVE the '
        'thinking row (v1.36 placement)', (WidgetTester tester) async {
      final ChatMessage message = ChatMessage.assistant(
        'Working on it…',
        isStreaming: true,
      );
      await tester.pumpWidget(
        wrap(MessageBubble(message: message, todos: todos)),
      );

      // Closed at first: no inline plan anywhere.
      expect(find.byKey(const Key('live-todo-panel')), findsNothing);

      // Open via the footer toggle: the plan appears INSIDE the same
      // bubble, geometrically ABOVE the thinking row.
      await tester.tap(find.byKey(const Key('todo-toggle-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final Finder panel = find.byKey(const Key('live-todo-panel'));
      expect(panel, findsOneWidget);
      final double panelY = tester.getTopLeft(panel).dy;
      final double thinkingY = tester.getTopLeft(find.text('thinking…')).dy;
      expect(
        panelY,
        lessThan(thinkingY),
        reason: 'the live plan must sit ABOVE the thinking indicator',
      );
      // Plan rows are visible with live progress.
      expect(find.text('research topic'), findsOneWidget);
      expect(find.text('draft report'), findsOneWidget);
      expect(find.text('review output'), findsOneWidget);

      // Closing hides the inline plan again.
      await tester.tap(find.byKey(const Key('plan-panel-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(panel, findsNothing);
    });

    testWidgets('no plan yet: the toggle is not rendered', (
      WidgetTester tester,
    ) async {
      final ChatMessage message = ChatMessage.assistant('', isStreaming: true);

      await tester.pumpWidget(
        wrap(MessageBubble(message: message, todos: const <TodoItem>[])),
      );

      expect(find.text('thinking…'), findsOneWidget);
      expect(find.byKey(const Key('todo-toggle-button')), findsNothing);
    });

    testWidgets('tool execution phase: footer stays visible on the newest '
        'message while the agent works', (WidgetTester tester) async {
      // Not streaming (a finalized tool-call turn), but the agent loop is
      // still running — the thinking indicator must remain available.
      final ChatMessage message = _assistantWith(<String, dynamic>{
        'todos': <dynamic>[
          <String, dynamic>{'content': 'step', 'status': 'in_progress'},
        ],
      });

      await tester.pumpWidget(
        wrap(
          MessageBubble(
            message: message,
            todos: const <TodoItem>[
              TodoItem(content: 'step', status: TodoStatus.inProgress),
            ],
            agentWorking: true,
          ),
        ),
      );

      expect(find.text('thinking…'), findsOneWidget);
      expect(find.byKey(const Key('todo-toggle-button')), findsOneWidget);
    });

    testWidgets('a finished message without a running session shows no '
        'thinking footer', (WidgetTester tester) async {
      final ChatMessage message = ChatMessage.assistant('All done.');

      await tester.pumpWidget(
        wrap(MessageBubble(message: message, todos: todos)),
      );

      expect(find.text('thinking…'), findsNothing);
      expect(find.byKey(const Key('todo-toggle-button')), findsNothing);
    });
  });

  group('v1.48.0: the three tool icons live ON the thinking row', () {
    Finder footerIcon(String key) => find.byKey(Key(key));

    /// Center-x order assertions: attach < prompt < mic < eye — the eye
    /// stays the RIGHTMOST control of the row ("di samping kirinya icon
    /// show hide plan panel").
    void expectLeftOfEyeOrder(WidgetTester tester) {
      final double attachX = tester.getCenter(footerIcon('attach-button')).dx;
      final double promptX = tester
          .getCenter(footerIcon('prompt-insert-button'))
          .dx;
      final double micX = tester.getCenter(footerIcon('mic-button')).dx;
      final double eyeX = tester.getCenter(footerIcon('todo-toggle-button')).dx;
      expect(attachX, lessThan(promptX), reason: 'attach left of prompt');
      expect(promptX, lessThan(micX), reason: 'prompt left of mic');
      expect(micX, lessThan(eyeX), reason: 'mic immediately left of the eye');
    }

    void expectSameRowAsThinking(WidgetTester tester, Finder icon) {
      final double thinkingY = tester.getCenter(find.text('thinking…')).dy;
      expect(
        (tester.getCenter(icon).dy - thinkingY).abs(),
        lessThan(2.0),
        reason: 'the icon must be aligned with the thinking text',
      );
    }

    testWidgets('attach/prompt/mic render on the footer row, immediately '
        'LEFT of the plan eye and vertically aligned with "thinking…"', (
      WidgetTester tester,
    ) async {
      final ChatMessage message = ChatMessage.assistant(
        'Working on it…',
        isStreaming: true,
      );

      await tester.pumpWidget(
        wrap(MessageBubble(message: message, todos: kFooterTodos)),
      );

      expect(footerIcon('attach-button'), findsOneWidget);
      expect(footerIcon('prompt-insert-button'), findsOneWidget);
      expect(footerIcon('mic-button'), findsOneWidget);
      expect(footerIcon('todo-toggle-button'), findsOneWidget);

      expectLeftOfEyeOrder(tester);
      expectSameRowAsThinking(tester, footerIcon('attach-button'));
      expectSameRowAsThinking(tester, footerIcon('prompt-insert-button'));
      expectSameRowAsThinking(tester, footerIcon('mic-button'));
      expectSameRowAsThinking(tester, footerIcon('todo-toggle-button'));
    });

    testWidgets('no plan yet: the tool icons still render on the thinking '
        'row (only the eye is conditional)', (WidgetTester tester) async {
      final ChatMessage message = ChatMessage.assistant('', isStreaming: true);

      await tester.pumpWidget(
        wrap(MessageBubble(message: message, todos: const <TodoItem>[])),
      );

      expect(footerIcon('attach-button'), findsOneWidget);
      expect(footerIcon('prompt-insert-button'), findsOneWidget);
      expect(footerIcon('mic-button'), findsOneWidget);
      expect(footerIcon('todo-toggle-button'), findsNothing);
    });

    testWidgets('integration: while a run streams, the icons exist ONLY on '
        'the footer — the composer renders no toolbar copy and the plan '
        'eye is never duplicated', (WidgetTester tester) async {
      final ChatState parked = ChatState(
        sessionId: 'a',
        isRunning: true,
        messages: <ChatMessage>[
          ChatMessage.user('go'),
          ChatMessage.assistant('', isStreaming: true),
        ],
        todos: kFooterTodos,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            chatControllerProvider.overrideWith(
              () => _ParkedChatController(parked),
            ),
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
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  Expanded(
                    child: ListView(
                      children: <Widget>[
                        MessageBubble(
                          message: parked.messages.last,
                          todos: kFooterTodos,
                        ),
                      ],
                    ),
                  ),
                  const Composer(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Footer: all four controls, eye rightmost, same row as "thinking…".
      expect(footerIcon('attach-button'), findsOneWidget);
      expect(footerIcon('prompt-insert-button'), findsOneWidget);
      expect(footerIcon('mic-button'), findsOneWidget);
      expect(footerIcon('todo-toggle-button'), findsOneWidget);
      expectLeftOfEyeOrder(tester);

      // EXACTLY ONE attach icon in the whole app — the composer toolbar
      // row is gone while running.
      final Finder composerAttach = find.descendant(
        of: find.byType(Composer),
        matching: footerIcon('attach-button'),
      );
      expect(composerAttach, findsNothing);
      // The duplicate plan eye is deleted: no composer-side eye anywhere.
      expect(footerIcon('composer-plan-toggle'), findsNothing);
      // The input row stays.
      expect(footerIcon('composer-field'), findsOneWidget);
    });
  });
}
