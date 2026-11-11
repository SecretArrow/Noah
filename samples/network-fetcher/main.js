/**
 * Network Fetcher — ZAgents chat module (sample).
 *
 * Demonstrates: `zagents.http` (permission `network`) with a manifest
 * `allowedHosts` allowlist, plus `zagents.chat.emit` (permission
 * `chat`) for progressive output.
 *
 * The manifest allows ONLY api.github.com — any other host is rejected
 * by the native bridge even if the module code changes. Requests to a
 * non-allowed host fail with:
 *   "Host is not allowed by this module (allowedHosts)"
 */
const ENDPOINT = 'https://api.github.com/zen';

async function main() {
  // User-Agent integration: every module presents the identity the user
  // picked in Settings → User Agent. The same string is sent on every
  // zagents.http request and cannot be overridden by headers.
  const ua = zagents.info.userAgent || '(unknown)';
  await zagents.chat.emit('Fetching ' + ENDPOINT + ' …');
  zagents.log('User-Agent (from Settings):', ua);

  const res = await zagents.http.request(ENDPOINT, {
    method: 'GET',
    headers: { 'User-Agent': 'this header is dropped — Settings wins' },
  });
  zagents.log('HTTP status:', res.status);

  if (!res.ok) {
    await zagents.chat.emit('Request failed with status ' + res.status);
    return { ok: false, status: res.status };
  }

  const quote = await res.text();
  await zagents.chat.emit('“' + quote + '”');

  return { ok: true, status: res.status, quote: quote };
}

module.exports = main();
