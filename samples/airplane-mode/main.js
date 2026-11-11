/**
 * Airplane Mode — ZAgents chat module (v1.3: root AUTO + manual + IP cycle).
 *
 * Toggles Android airplane mode from the chat AND rotates the carrier IP.
 * Two modes, picked per device — no blind trust anywhere, the final report
 * is always the ACTUAL verified state:
 *
 *   ROOTED (su available)  → AUTO: the module toggles the radio itself
 *     (cmd connectivity → settings put + broadcast fallback, read-back
 *     verification after every step). `/airplane cycle` runs the
 *     one-command IP rotation via zagents.device.airplaneCycle:
 *     airplane ON (radio deregisters) → hold → airplane OFF (radio
 *     re-registers with a NEW IP) → settle — always ends OFF (online).
 *
 *   NOT ROOTED             → MANUAL: the module verifies the state with
 *     the world-readable native probe (zagents.device.airplane — works
 *     without root AND offline) and walks the user through the toggle:
 *     the user flips airplane mode from Quick Settings, the module
 *     verifies the real state on /airplane status.
 *
 * Commands (work from the very first message AND mid-chat; they run
 * app-side, so they keep working while airplane mode is ON and the AI
 * chat itself is unreachable):
 *
 *   /airplane cycle   ONE-command IP rotation (rooted, auto): airplane
 *                     ON → hold → OFF → settle; new carrier IP. Aliases:
 *                     /airplane ip and /airplane rotate. Non-rooted
 *                     devices get the guided-manual fallback.
 *   /airplane on      enable airplane mode (auto on root, guided manual otherwise)
 *   /airplane off     disable airplane mode (auto on root, guided manual otherwise)
 *   /airplane status  report the verified current state + active mode
 *
 * Offline note: while airplane mode is ON the AI chat cannot reach the
 * provider (no internet). These commands keep working because they run
 * locally. When the user turns airplane mode back OFF, auto-retry
 * (v1.30.0+) delivers the queued messages and the task continues
 * automatically — no retry budget is burned while the radio is off.
 *
 * Requirements:
 *   - ZAgents v1.32.0+ (zagents.device SDK with the airplane probe);
 *   - rooted phone ONLY for the AUTO toggle — manual mode works on any
 *     device;
 *   - for root toggles: Settings → Modules → "Device commands (root)"
 *     switched ON (the airplane STATE probe does not need this switch).
 */
async function main() {
  const info = zagents.info || {};

  // Parse the command: "/airplane on" arrives as zagents.info.prompt on
  // the staged-module path AND on the mid-chat passthrough; a bare
  // activation (no message) defaults to a status report.
  const prompt = String(info.prompt || '').trim().toLowerCase();
  const parts = prompt.split(/\s+/).filter(Boolean);
  let arg = 'status';
  if (parts.length > 0) {
    if (parts[0] === '/airplane') {
      arg = parts[1] || 'status';
    } else if (
      parts[0] === 'on' || parts[0] === 'off' || parts[0] === 'status' ||
      parts[0] === 'cycle' || parts[0] === 'ip' || parts[0] === 'rotate'
    ) {
      arg = parts[0];
    }
  }

  // SDK availability (older host without the device slice).
  if (!zagents.device || typeof zagents.device.shell !== 'function') {
    zagents.log('This module needs ZAgents v1.31.0+ (zagents.device SDK).');
    return { ok: false, reason: 'sdk-missing' };
  }

  const su = (cmd) => zagents.device.shell(cmd, { root: true, timeoutMs: 20000 });

  // -- cycle (v1.3): one-command IP rotation -------------------------------
  // The phone's data IP changes when the radio RE-REGISTERS — i.e. when
  // airplane mode goes back OFF. The bridge runs the whole physics for us
  // (ensure ON → hold → OFF → settle, verified, always ends OFF); the
  // module only reports it. Rooted phones + master switch; everything
  // else gets the guided-manual fallback.
  if (arg === 'cycle' || arg === 'ip' || arg === 'rotate') {
    if (!zagents.device || typeof zagents.device.airplaneCycle !== 'function') {
      zagents.log('Airplane cycle needs ZAgents v1.34.0+ — update the app, or use /airplane on + /airplane off.');
      return { ok: false, action: 'cycle', reason: 'sdk-missing' };
    }
    try {
      const r = await zagents.device.airplaneCycle();
      const held = (r.heldMs / 1000).toString().replace(/\.0$/, '');
      const settle = (r.settleMs / 1000).toString().replace(/\.0$/, '');
      zagents.log(
        'Airplane cycled: ON ' + held + 's → OFF; new IP in ~' + settle + 's' +
        (r.verified ? ' (verified).' : '.'),
      );
      return { ok: true, action: 'cycle', wasOn: r.wasOn, verified: r.verified, heldMs: r.heldMs, settleMs: r.settleMs };
    } catch (e) {
      zagents.log('Airplane cycle failed: ' + ((e && e.message) ? e.message : e));
      zagents.log('Not rooted (or "Device commands" off)? Use /airplane on | off — guided MANUAL mode.');
      return { ok: false, action: 'cycle', reason: 'cycle-failed' };
    }
  }

  // -- Verified state (NO root needed) ------------------------------------
  // Prefer the native world-readable probe: it answers without root and
  // offline — exactly what manual mode needs. Rooted phones can also use
  // `settings get` but the probe is uniform everywhere.
  let available = false;
  let current = false;
  try {
    const probe = await zagents.device.airplane();
    available = probe.available === true;
    current = probe.on === true;
  } catch (_) {
    available = false;
  }
  if (!available) {
    // Probe missing (very old host / broken channel): rooted phones can
    // still fall back to `settings get`; non-rooted cannot verify at all.
    const r = await su('settings get global airplane_mode_on');
    if (r.ok) {
      available = true;
      current = r.stdout.trim() === '1';
    }
  }

  // -- Root probe (needed for the AUTO toggle; manual mode skips it) ------
  let rooted = false;
  let rootWhy = '';
  const id = await su('id -u');
  if (id.ok && id.stdout.trim().split(/\s+/).pop() === '0') {
    rooted = true;
  } else {
    rootWhy = id.error || id.stderr.trim() || 'su unavailable or denied';
  }

  // -- status --------------------------------------------------------------
  if (arg === 'status' || (arg !== 'on' && arg !== 'off')) {
    if (!available) {
      zagents.log('Cannot read the airplane state on this device (no probe, no root).');
      return { ok: false, reason: 'state-unknown' };
    }
    zagents.log('Airplane mode: ' + (current ? 'ON' : 'OFF'));
    zagents.log('Mode: ' + (rooted ? 'AUTO (root)' : 'MANUAL (no root)'));
    if (current) {
      zagents.log('While ON the AI chat is offline — these commands keep working.');
      zagents.log('Turn airplane OFF when done; auto-retry continues the task.');
    }
    zagents.log('(commands: /airplane cycle | on | off | status)');
    return { ok: true, action: 'status', on: current, auto: rooted };
  }

  const target = arg === 'on';

  // -- Already in the requested state --------------------------------------
  if (available && current === target) {
    zagents.log('Airplane mode already ' + (target ? 'ON' : 'OFF') + ' — nothing to do.');
    return { ok: true, action: arg, changed: false, on: current, auto: rooted };
  }

  // -- Rooted: AUTO toggle (verified) --------------------------------------
  if (rooted) {
    let method = 'cmd connectivity';
    await su('cmd connectivity airplane-mode ' + (target ? 'enable' : 'disable'));
    let now = await su('settings get global airplane_mode_on').then(
      (r) => r.ok && r.stdout.trim() === '1',
    );
    if (now !== target) {
      method = 'settings+broadcast';
      await su('settings put global airplane_mode_on ' + (target ? 1 : 0));
      await su(
        'am broadcast -a android.intent.action.AIRPLANE_MODE --ez state ' +
          (target ? 'true' : 'false'),
      );
      now = await su('settings get global airplane_mode_on').then(
        (r) => r.ok && r.stdout.trim() === '1',
      );
    }
    zagents.log('Airplane mode: ' + (now ? 'ON' : 'OFF') + ' (requested ' + arg.toUpperCase() + ')');
    zagents.log('Method: ' + method);
    zagents.log('Verified: settings get global airplane_mode_on → ' + (now ? 1 : 0));
    if (now !== target) {
      zagents.log('Warning: the device did not confirm the new state — some ROMs need a manual check.');
      return { ok: false, action: arg, on: now, method };
    }
    if (target) {
      zagents.log('Heads-up: the AI chat is offline while airplane mode is ON.');
    }
    return { ok: true, action: arg, changed: true, on: now, method, auto: true };
  }

  // -- Not rooted: MANUAL mode (guided, verified) ---------------------------
  // Never trust a bare "yes": the user flips the radio, the probe verifies
  // the REAL state on the next /airplane status (works offline).
  if (!available) {
    zagents.log('Not rooted and the airplane probe is unavailable — cannot toggle or verify.');
    zagents.log('Toggle airplane mode manually from Quick Settings.');
    return { ok: false, reason: 'no-root-no-probe', detail: rootWhy };
  }
  if (target) {
    zagents.log('Not rooted — MANUAL MODE. I cannot flip the radio for you.');
    zagents.log('Steps:');
    zagents.log('  1. Open Quick Settings and tap Airplane mode.');
    zagents.log('  2. Run:  /airplane status  — I verify the REAL state (works offline).');
    zagents.log('  3. The AI chat is offline while airplane is ON (expected).');
    zagents.log('  4. Do your offline task.');
    zagents.log('  5. Turn Airplane OFF from Quick Settings when done.');
    zagents.log('  6. The queued chat auto-continues via auto-retry — or run /airplane status to confirm restoration.');
    zagents.log('Airplane mode is currently OFF — waiting for you to enable it.');
    return { ok: true, action: 'on', mode: 'manual', on: current, guided: true };
  }
  zagents.log('Not rooted — MANUAL MODE. I cannot flip the radio for you.');
  zagents.log('Steps:');
  zagents.log('  1. Open Quick Settings and tap Airplane mode to turn it OFF.');
  zagents.log('  2. Run:  /airplane status  — I verify the connection is back (works offline).');
  zagents.log('  3. The task auto-continues the moment the connection returns.');
  zagents.log('Airplane mode is currently ON — waiting for you to disable it.');
  return { ok: true, action: 'off', mode: 'manual', on: current, guided: true };
}

module.exports = main();
