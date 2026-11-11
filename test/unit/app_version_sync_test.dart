import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/ui/screens/about_screen.dart';

/// Drift guard (v1.49.7): the About-screen version constant is the single
/// source the update checker reads (`di.dart` passes it as currentVersion)
/// — when it lagged pubspec (1.49.3 while 1.49.6 shipped) the app believed
/// it was outdated and nagged "update available" on every startup. This
/// test pins the constant to pubspec.yaml so the next release bump that
/// forgets the About screen goes red in CI instead of nagging users.
void main() {
  test('kAppVersion matches pubspec.yaml version', () {
    final File pubspec = File('pubspec.yaml');
    expect(
      pubspec.existsSync(),
      isTrue,
      reason: 'tests run from the package root; pubspec.yaml must exist',
    );
    final RegExpMatch? match = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync());
    expect(match, isNotNull, reason: 'pubspec.yaml carries a semver version');
    expect(kAppVersion, match!.group(1));
  });
}
