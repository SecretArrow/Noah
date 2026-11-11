import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/module_registry.dart';
import 'package:noah/ui/screens/home_shell.dart';
import 'package:noah/ui/widgets/module_setup_sheet.dart';

import '../support/test_doubles.dart';

/// Records submitModuleSetup calls; never touches the real controller
/// machinery (no runs, no storage) so widget tests stay deterministic.
class RecordingChatController extends ChatController {
  final List<({String name, Map<String, dynamic> values})> submissions =
      <({String name, Map<String, dynamic> values})>[];
  bool nextResult = true;
  ChatState initialState = const ChatState();

  @override
  ChatState build() => initialState;

  void push(ChatState next) => state = next;

  @override
  Future<bool> submitModuleSetup(
    String moduleName,
    Map<String, dynamic> values, {
    bool awaitRun = true,
  }) async {
    submissions.add((name: moduleName, values: values));
    return nextResult;
  }
}

ModuleSetupRequest _request({
  List<Map<String, dynamic>> extraFields = const <Map<String, dynamic>>[],
  Map<String, dynamic> values = const <String, dynamic>{},
}) {
  final ModuleSetup? setup = ModuleSetup.fromJson(<String, dynamic>{
    'title': 'OnHomeroom account',
    'description': 'Credentials for this chat.',
    'fields': <dynamic>[
      <String, dynamic>{
        'key': 'email',
        'label': 'Email',
        'type': 'text',
        'required': true,
        'placeholder': 'you@example.com',
      },
      <String, dynamic>{
        'key': 'password',
        'label': 'Password',
        'type': 'password',
        'required': true,
      },
      ...extraFields,
    ],
  });
  return ModuleSetupRequest(
    moduleName: 'onhomeroom-daily',
    moduleTitle: 'OnHomeroom Daily',
    setup: setup!,
    values: values,
  );
}

Widget _host(
  Widget child, {
  RecordingChatController? controller,
  Directory? dir,
}) {
  final Directory temp = dir ?? Directory.systemTemp;
  return ProviderScope(
    overrides: <Override>[
      ...testOverrides(dir: temp, writeScreenshots: false),
      if (controller != null)
        chatControllerProvider.overrideWith(() => controller),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        zLocalizationsDelegate,
      ],
      supportedLocales: const <Locale>[Locale('en'), Locale('id')],
      home: child,
    ),
  );
}

/// Host that opens the sheet from a button and displays the returned
/// values (JSON-ish) in a Text so tests can assert the result.
class _SheetHost extends StatefulWidget {
  const _SheetHost({required this.request});

  final ModuleSetupRequest request;

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  String? result;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FilledButton(
              key: const Key('open-sheet'),
              onPressed: () async {
                final Map<String, dynamic>? values = await showModuleSetupSheet(
                  context,
                  widget.request,
                );
                if (mounted) {
                  setState(() => result = values?.toString());
                }
              },
              child: const Text('open'),
            ),
            if (result != null) Text(result!, key: const Key('sheet-result')),
          ],
        ),
      ),
    );
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('module_setup_widget');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('setup sheet renders fields, masks the password and gates '
      'the save button until required values are valid', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _SheetHost(
          request: _request(
            extraFields: <Map<String, dynamic>>[
              <String, dynamic>{
                'key': 'retries',
                'label': 'Retries',
                'type': 'number',
                'required': true,
              },
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();

    // Save starts disabled — required fields are empty.
    FilledButton save = tester.widget<FilledButton>(
      find.byKey(const Key('module-setup-save')),
    );
    expect(save.onPressed, isNull);

    // Password field is obscured and has a visibility toggle.
    final TextField password = tester.widget<TextField>(
      find.byKey(const Key('module-setup-field-password')),
    );
    expect(password.obscureText, isTrue);
    await tester.tap(find.byKey(const Key('module-setup-eye-password')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('module-setup-field-password')),
          )
          .obscureText,
      isFalse,
    );

    // Filling text fields is not enough while the number is invalid.
    await tester.enterText(
      find.byKey(const Key('module-setup-field-email')),
      'me@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('module-setup-field-password')),
      'hunter2',
    );
    await tester.enterText(
      find.byKey(const Key('module-setup-field-retries')),
      'abc',
    );
    await tester.pumpAndSettle();
    save = tester.widget<FilledButton>(
      find.byKey(const Key('module-setup-save')),
    );
    expect(save.onPressed, isNull);

    // A valid number unlocks "Save and run".
    await tester.enterText(
      find.byKey(const Key('module-setup-field-retries')),
      '3',
    );
    await tester.pumpAndSettle();
    save = tester.widget<FilledButton>(
      find.byKey(const Key('module-setup-save')),
    );
    expect(save.onPressed, isNotNull);
  });

  testWidgets('submitting hands the values to the controller and closes '
      'the sheet with them', (WidgetTester tester) async {
    final RecordingChatController controller = RecordingChatController();
    await tester.pumpWidget(
      _host(_SheetHost(request: _request()), controller: controller),
    );
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('module-setup-field-email')),
      'me@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('module-setup-field-password')),
      'hunter2',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('module-setup-save')));
    await tester.pumpAndSettle();

    expect(controller.submissions, hasLength(1));
    expect(controller.submissions.single.name, 'onhomeroom-daily');
    expect(controller.submissions.single.values, <String, dynamic>{
      'email': 'me@example.com',
      'password': 'hunter2',
    });
    // The sheet closed and returned the values to the opener.
    expect(
      tester.widget<Text>(find.byKey(const Key('sheet-result'))).data,
      contains('me@example.com'),
    );
    expect(find.byKey(const Key('module-setup-sheet')), findsNothing);
  });

  testWidgets('a failed submission keeps the sheet open for a retry', (
    WidgetTester tester,
  ) async {
    final RecordingChatController controller = RecordingChatController()
      ..nextResult = false;
    await tester.pumpWidget(
      _host(_SheetHost(request: _request()), controller: controller),
    );
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('module-setup-field-email')),
      'me@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('module-setup-field-password')),
      'hunter2',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('module-setup-save')));
    await tester.pumpAndSettle();

    expect(controller.submissions, hasLength(1));
    // Still open — the user can retry.
    expect(find.byKey(const Key('module-setup-sheet')), findsOneWidget);
  });

  testWidgets('home shell shows the setup banner while a request is '
      'pending and the banner button opens the form', (
    WidgetTester tester,
  ) async {
    final RecordingChatController controller = RecordingChatController()
      ..initialState = ChatState(setupRequest: _request());
    await tester.pumpWidget(
      _host(const HomeShell(), controller: controller, dir: tempDir),
    );
    await tester.pump();

    expect(find.byKey(const Key('module-setup-banner')), findsOneWidget);
    // The sheet is NOT auto-opened for the initial state (ref.listen
    // only fires on changes).
    expect(find.byKey(const Key('module-setup-sheet')), findsNothing);

    await tester.tap(find.byKey(const Key('module-setup-banner-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('module-setup-sheet')), findsOneWidget);
    expect(find.text('OnHomeroom account'), findsOneWidget);
  });

  testWidgets('a setup request appearing mid-session auto-opens the form '
      'once', (WidgetTester tester) async {
    final RecordingChatController controller = RecordingChatController();
    await tester.pumpWidget(
      _host(const HomeShell(), controller: controller, dir: tempDir),
    );
    await tester.pump();

    // The gate fires during a run: the controller surfaces the request.
    controller.push(ChatState(setupRequest: _request()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('module-setup-sheet')), findsOneWidget);
    expect(find.byKey(const Key('module-setup-banner')), findsOneWidget);
  });

  testWidgets('the banner says the queued message waits when '
      'waitingForSetup is on (v1.29.0)', (WidgetTester tester) async {
    final RecordingChatController controller = RecordingChatController()
      ..initialState = ChatState(
        setupRequest: _request(),
        waitingForSetup: true,
      );
    await tester.pumpWidget(
      _host(const HomeShell(), controller: controller, dir: tempDir),
    );
    await tester.pump();

    expect(find.byKey(const Key('module-setup-banner')), findsOneWidget);
    expect(find.textContaining('queued'), findsOneWidget);
  });
}
