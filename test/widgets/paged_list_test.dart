import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/ui/widgets/paged_list.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    zLocalizationsDelegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: const <Locale>[Locale('en'), Locale('id')],
  home: Scaffold(body: child),
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(_host(child));
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 10),
  );
}

List<String> letters(int n) => <String>[
  for (var i = 0; i < n; i++) 'item-${String.fromCharCode(97 + i)}',
];

void main() {
  testWidgets('shows at most 5 items per page with a pager', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      PagedList<String>(
        prefix: 'demo',
        items: letters(12),
        itemBuilder: (BuildContext context, String item) =>
            ListTile(title: Text(item)),
      ),
    );

    expect(find.byKey(const Key('demo-list-page-0')), findsOneWidget);
    expect(find.text('item-a'), findsOneWidget);
    expect(find.text('item-e'), findsOneWidget);
    expect(find.text('item-f'), findsNothing);
    expect(find.text('Page 1 of 3'), findsOneWidget);

    // Next / last navigation.
    await tester.tap(find.byKey(const Key('demo-page-next')));
    await tester.pumpAndSettle();
    expect(find.text('item-f'), findsOneWidget);
    expect(find.text('Page 2 of 3'), findsOneWidget);

    await tester.tap(find.byKey(const Key('demo-page-last')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('demo-list-page-2')), findsOneWidget);
    expect(find.text('item-l'), findsOneWidget);
    expect(find.text('Page 3 of 3'), findsOneWidget);

    // First returns to page 1.
    await tester.tap(find.byKey(const Key('demo-page-first')));
    await tester.pumpAndSettle();
    expect(find.text('Page 1 of 3'), findsOneWidget);
  });

  testWidgets('search filters items and resets the page', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      PagedList<String>(
        prefix: 'demo',
        items: letters(12),
        searchFieldKey: const Key('demo-search-field'),
        itemBuilder: (BuildContext context, String item) =>
            ListTile(title: Text(item)),
      ),
    );

    // Move to page 2 first so the reset is observable.
    await tester.tap(find.byKey(const Key('demo-page-next')));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 3'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('demo-search-field')),
      'ITEM-C',
    );
    await tester.pumpAndSettle();
    expect(find.text('item-c'), findsOneWidget);
    expect(find.text('item-a'), findsNothing);
    // One match = one page, pager disappears.
    expect(find.text('Page 1 of 1'), findsNothing);
    expect(find.byKey(const Key('demo-page-next')), findsNothing);
  });

  testWidgets('no match renders the empty builder', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      PagedList<String>(
        prefix: 'demo',
        items: letters(3),
        searchFieldKey: const Key('demo-search-field'),
        itemBuilder: (BuildContext context, String item) =>
            ListTile(title: Text(item)),
        emptyBuilder: (BuildContext context) => const Text('nothing here'),
      ),
    );
    await tester.enterText(find.byKey(const Key('demo-search-field')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('nothing here'), findsOneWidget);
  });

  testWidgets('empty items render the empty builder and no pager', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      PagedList<String>(
        prefix: 'demo',
        items: const <String>[],
        searchFieldKey: const Key('demo-search-field'),
        itemBuilder: (BuildContext context, String item) =>
            ListTile(title: Text(item)),
        emptyBuilder: (BuildContext context) => const Text('empty state'),
      ),
    );
    expect(find.text('empty state'), findsOneWidget);
    expect(find.byKey(const Key('demo-page-next')), findsNothing);
  });

  testWidgets('changing resetKey returns to page 1', (
    WidgetTester tester,
  ) async {
    final List<String> items = letters(12);
    await _pump(
      tester,
      PagedList<String>(
        prefix: 'demo',
        items: items,
        resetKey: items.length,
        searchFieldKey: const Key('demo-search-field'),
        itemBuilder: (BuildContext context, String item) =>
            ListTile(title: Text(item)),
      ),
    );
    await tester.tap(find.byKey(const Key('demo-page-next')));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 3'), findsOneWidget);

    // Simulate a data refresh: same widget position, new resetKey.
    await tester.pumpWidget(
      _host(
        PagedList<String>(
          key: const ValueKey<String>('same'),
          prefix: 'demo',
          items: items,
          resetKey: items.length + 1,
          searchFieldKey: const Key('demo-search-field'),
          itemBuilder: (BuildContext context, String item) =>
              ListTile(title: Text(item)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Page 1 of 3'), findsOneWidget);
  });

  testWidgets('no pager when everything fits on one page', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      PagedList<String>(
        prefix: 'demo',
        items: letters(5),
        itemBuilder: (BuildContext context, String item) =>
            ListTile(title: Text(item)),
      ),
    );
    expect(find.byKey(const Key('demo-list-page-0')), findsOneWidget);
    expect(find.byKey(const Key('demo-page-next')), findsNothing);
    expect(find.byKey(const Key('demo-page-prev')), findsNothing);
    expect(find.text('Page 1 of 1'), findsNothing);
  });

  testWidgets('localized Indonesian pager indicator', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('id'),
        localizationsDelegates: const <LocalizationsDelegate<Object>>[
          zLocalizationsDelegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const <Locale>[Locale('en'), Locale('id')],
        home: Scaffold(
          body: PagedList<String>(
            prefix: 'demo',
            items: letters(12),
            itemBuilder: (BuildContext context, String item) =>
                ListTile(title: Text(item)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Halaman 1 dari 3'), findsOneWidget);
  });
}
