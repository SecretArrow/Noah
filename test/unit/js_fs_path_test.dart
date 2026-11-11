import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/js_runtime.dart';

void main() {
  group('zResolveFsPath (module fs bridge, v1.29.0)', () {
    const String state = '/docs/sessions/s1/modules/counter/state';

    test('relative paths anchor to the working dir (first sandbox root)', () {
      expect(zResolveFsPath('data.json', <String>[state]), '$state/data.json');
      expect(
        zResolveFsPath('sub/data.json', <String>[state]),
        '$state/sub/data.json',
      );
      // The documented readdir('.') usage resolves to the state dir itself.
      expect(zResolveFsPath('.', <String>[state]), state);
      expect(zResolveFsPath('', <String>[state]), state);
    });

    test('dot segments normalize so the sandbox check sees the truth', () {
      expect(
        zResolveFsPath('./sub/../data.json', <String>[state]),
        '$state/data.json',
      );
    });

    test('traversal normalizes — and then lands outside, where the '
        'sandbox check rejects it', () {
      expect(
        zResolveFsPath('../../steal.json', <String>[state]),
        '/docs/sessions/s1/modules/steal.json',
      );
      // Deeper escape: the result is NOT under [state] anymore.
      final String resolved = zResolveFsPath('../../../../etc.json', <String>[
        state,
      ]);
      expect(resolved.startsWith('$state/'), isFalse);
    });

    test('absolute paths pass through (normalized)', () {
      expect(zResolveFsPath('/etc/passwd', <String>[state]), '/etc/passwd');
      expect(
        zResolveFsPath('$state/inner/../x.json', <String>[state]),
        '$state/x.json',
      );
    });

    test('without sandbox roots it falls back to the process CWD', () {
      final String cwd = Directory.current.path;
      expect(zResolveFsPath('x.txt', const <String>[]), '$cwd/x.txt');
    });
  });

  group('zIsUnderRoot (module fs write scope, v1.43.1)', () {
    const String state = '/docs/sessions/s1/modules/counter/state';
    const String moduleCode = '/docs/modules/counter';

    test('accepts the root itself and paths inside it', () {
      expect(zIsUnderRoot(state, state), isTrue);
      expect(zIsUnderRoot('$state/data.json', state), isTrue);
      expect(zIsUnderRoot('$state/sub/data.json', state), isTrue);
      expect(zIsUnderRoot('$state/inner/../x.json', state), isTrue);
    });

    test('rejects siblings sharing only a text prefix', () {
      // '/docs/sessions/s1/modules/counter-old' shares the counter
      // prefix but is NOT under [state] — naive startsWith would pass it.
      expect(zIsUnderRoot('$state-old/x.json', state), isFalse);
      expect(zIsUnderRoot('${state}base/x.json', state), isFalse);
    });

    test('rejects parents, the global module dir and unrelated trees', () {
      expect(zIsUnderRoot('/docs/sessions/s1/modules', state), isFalse);
      expect(zIsUnderRoot(moduleCode, state), isFalse);
      expect(zIsUnderRoot('/etc', state), isFalse);
      expect(zIsUnderRoot('/', state), isFalse);
    });

    test('the resolved escape from zResolveFsPath never passes', () {
      // Bridge order: resolve first, then check — so a `..` escape that
      // lands back in the session tree is still rejected as a write
      // target because it is not under the module state dir.
      final String resolved = zResolveFsPath(
        '../../../modules/counter/leak.json',
        <String>[state, moduleCode],
      );
      expect(resolved, '/docs/sessions/s1/modules/counter/leak.json');
      expect(zIsUnderRoot(resolved, state), isFalse);
    });

    test('absolute write into the global module dir is rejected', () {
      final String resolved = zResolveFsPath('$moduleCode/leak.json', <String>[
        state,
        moduleCode,
      ]);
      expect(zIsUnderRoot(resolved, moduleCode), isTrue); // sandbox: pass
      expect(zIsUnderRoot(resolved, state), isFalse); // write scope: reject
    });
  });
}
