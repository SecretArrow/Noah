import 'package:flutter_test/flutter_test.dart';

import '../../tool/agentrouter_standalone_check.dart' as standalone;

/// Wraps the standalone AgentRouter verification harness so the normal
/// `flutter test` gate (and CI) runs it too. The harness drives the REAL
/// [AgentRouterLlmClient] over a local mock gateway — see the tool header
/// for the case list.
void main() {
  test('agentrouter standalone check — full mock-gateway sweep', () async {
    await standalone.runChecks();
  });
}
