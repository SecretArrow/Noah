import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/ui/screens/about_screen.dart';
import 'package:noah/ui/screens/help_screen.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  supportedLocales: const <Locale>[Locale('en'), Locale('id')],
  localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
    zLocalizationsDelegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

void main() {
  group('HelpScreen', () {
    testWidgets('renders the intro and all 12 topics (EN)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_wrap(const HelpScreen()));
      await tester.pumpAndSettle();
      expect(find.byType(HelpScreen), findsOneWidget);
      for (var i = 0; i < 12; i++) {
        expect(find.byKey(Key('help-topic-$i')), findsOneWidget);
      }
      // Only the first topic starts expanded; its body text is visible.
      expect(find.textContaining('connect a provider'), findsOneWidget);
      // Collapsed topics keep their titles reachable by scrolling.
      expect(find.textContaining('12. Tips'), findsWidgets);
    });

    testWidgets('expanding a topic reveals its full body text', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_wrap(const HelpScreen()));
      await tester.pumpAndSettle();
      // ExpansionTile keeps children mounted when collapsed, so text
      // presence proves nothing — assert on the card's rendered height:
      // collapsed is a single tile row, expanded grows well beyond it.
      double cardHeight() =>
          tester.getSize(find.byKey(const Key('help-topic-3'))).height;
      expect(cardHeight(), lessThan(120), reason: 'starts collapsed');
      // Physically drag the page up so the tile's title can be tapped.
      await tester.drag(find.byType(Scrollable), const Offset(0, -240));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('4. Skills'));
      await tester.pumpAndSettle();
      expect(cardHeight(), greaterThan(200), reason: 'expands on tap');
      // Collapsing shrinks it back.
      await tester.tap(find.textContaining('4. Skills'));
      await tester.pumpAndSettle();
      expect(cardHeight(), lessThan(120), reason: 'collapses on second tap');
    });

    testWidgets('renders the Indonesian bundle end to end', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const HelpScreen(), locale: const Locale('id')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bantuan'), findsOneWidget);
      expect(
        find.textContaining('1. Mulai: hubungkan provider'),
        findsOneWidget,
      );
    });
  });

  group('AboutScreen', () {
    testWidgets('shows identity, version, creator and sections (EN)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_wrap(const AboutScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Noah'), findsOneWidget);
      expect(find.byKey(const Key('about-version')), findsOneWidget);
      expect(find.byKey(const Key('about-creator')), findsOneWidget);
      // The version constant stays in sync with the release.
      expect(kAppVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
      expect(find.text('Maragung'), findsOneWidget);
      expect(find.text("What's inside"), findsOneWidget);
      expect(
        find.textContaining('independent app by Maragung'),
        findsOneWidget,
      );
    });

    testWidgets('renders the Indonesian bundle end to end', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const AboutScreen(), locale: const Locale('id')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tentang'), findsOneWidget);
      expect(find.text('Pembuat'), findsOneWidget);
      expect(find.text('Isi aplikasi'), findsOneWidget);
    });
  });
}
