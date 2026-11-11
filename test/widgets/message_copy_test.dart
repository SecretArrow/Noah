import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/models.dart';
import 'package:noah/ui/theme.dart';
import 'package:noah/ui/widgets/message_bubble.dart';

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

  // Captures Clipboard.setData calls so tests can assert the copied text.
  String? clipboardText;
  setUp(() {
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('assistant bubbles', () {
    testWidgets('finished answer shows a copy button that puts the raw '
        'markdown on the clipboard', (WidgetTester tester) async {
      const String markdown =
          '# Heading\n\nA **bold** idea.\n\n'
          '```dart\nvoid main() {}\n```';
      final ChatMessage message = ChatMessage.assistant(markdown);

      await tester.pumpWidget(wrap(MessageBubble(message: message)));

      final Finder button = find.byKey(const Key('copy-message-button'));
      expect(button, findsOneWidget);
      expect(find.byTooltip(const AppStringsEn().copyMessage), findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(clipboardText, markdown);
      // Icon flips to a check mark + tooltip says Copied.
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsNothing);
      expect(find.byTooltip(const AppStringsEn().copied), findsOneWidget);

      // Confirmation state resets after two seconds (and no timer is
      // left pending when the test ends).
      await tester.pump(const Duration(seconds: 2, milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
    });

    testWidgets('streaming answers have no copy button yet', (
      WidgetTester tester,
    ) async {
      final ChatMessage message = ChatMessage.assistant(
        'partial answer…',
        isStreaming: true,
      );

      await tester.pumpWidget(wrap(MessageBubble(message: message)));

      expect(find.byKey(const Key('copy-message-button')), findsNothing);
    });

    testWidgets('tool-only bubbles (no text) have no copy button', (
      WidgetTester tester,
    ) async {
      final ChatMessage message = ChatMessage.assistant(
        '',
        toolCalls: <ToolCall>[
          ToolCall(
            id: 't1',
            name: 'read_file',
            arguments: <String, dynamic>{'path': 'a.txt'},
            status: ToolStatus.success,
            resultText: 'hello',
          ),
        ],
      );

      await tester.pumpWidget(wrap(MessageBubble(message: message)));

      expect(find.byKey(const Key('copy-message-button')), findsNothing);
    });
  });

  group('user bubbles', () {
    testWidgets('sent message shows a copy button that copies its text', (
      WidgetTester tester,
    ) async {
      final ChatMessage message = ChatMessage.user('catatan penting 123');

      await tester.pumpWidget(wrap(MessageBubble(message: message)));

      final Finder button = find.byKey(const Key('copy-message-button'));
      expect(button, findsOneWidget);
      // The copy control sits under the bubble, right-aligned.
      final Finder bubbleText = find.text('catatan penting 123');
      expect(bubbleText, findsOneWidget);
      expect(
        tester.getTopLeft(button).dy,
        greaterThan(tester.getTopLeft(bubbleText).dy),
      );

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(clipboardText, 'catatan penting 123');
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('attachment-only messages (no text) have no copy button', (
      WidgetTester tester,
    ) async {
      final ChatMessage message = ChatMessage.user(
        '',
        attachments: const <ChatAttachment>[
          ChatAttachment(
            path: '/tmp/pic.png',
            name: 'pic.png',
            sizeBytes: 12,
            kind: AttachmentKind.image,
          ),
        ],
      );

      await tester.pumpWidget(wrap(MessageBubble(message: message)));

      expect(find.byKey(const Key('copy-message-button')), findsNothing);
    });
  });
}
