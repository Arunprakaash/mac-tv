// The phone remote finds the Mac at another of its addresses when the one it's on stops answering.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { script } = require('./page.cjs');
const start = script.indexOf('// Every address the Mac answers at');
const end = script.indexOf('// Keep a reachable sleeping display distinct');
assert.ok(start >= 0 && end > start);

function load(stored, here, { installed = false } = {}) {
  const storage = new Map([['mactvAddresses', JSON.stringify(stored)]]);
  const context = {
    key: 'secret-key', location: { origin: here, hostname: new URL(here).hostname }, AbortController, setTimeout, clearTimeout,
    JSON, Array, Number, encodeURIComponent,
    localStorage: { getItem: k => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v) },
  };
  if (installed) context.matchMedia = query => ({ matches: query === '(display-mode: standalone)' });
  vm.runInNewContext(script.slice(start, end).replace(/^let unanswered/m, 'var unanswered')
    + '\nthis.move = moveToAnotherAddress; this.settle = settleOnHome; this.addresses = addresses; this.base = () => base;', context);
  return context;
}

(async () => {
  const name = 'http://arun.local:8765', oldIP = 'http://192.168.1.5:8765', tailscale = 'http://100.92.2.111:8765';

  // The old IP is gone; the name answers: move there, key in the fragment.
  let page = load([name, oldIP, tailscale], oldIP);
  const asked = [];
  let went = null;
  const moved = await page.move(async (url, init) => {
    asked.push(url);
    assert.equal(init.headers['X-Couch-Key'], 'secret-key');
    return { ok: url.startsWith(name) };
  }, url => { went = url; });
  assert.equal(moved, true);
  assert.deepEqual(asked, [name + '/state'], 'tries other addresses in order, never the current one');
  assert.equal(went, name + '/#key=secret-key');

  // Nothing answers: stay put.
  page = load([name, oldIP, tailscale], name);
  went = null;
  assert.equal(await page.move(async () => { throw new Error('offline'); }, url => { went = url; }), false);
  assert.equal(went, null);

  // Only plain http origins of the Mac are tried.
  page = load(['javascript:alert(1)', 'http://evil.example/x', 42, tailscale], name);
  const tried = [];
  await page.move(async url => { tried.push(url); return { ok: false }; }, () => {});
  assert.deepEqual(tried, [tailscale + '/state']);

  // A remote saved to the home screen never leaves its own address: it asks the Mac at the other one.
  page = load([name, oldIP, tailscale], name, { installed: true });
  went = null;
  assert.equal(await page.move(async url => ({ ok: url.startsWith(oldIP) }), url => { went = url; }), true);
  assert.equal(went, null, 'an installed remote stays where it was saved');
  assert.equal(page.base(), oldIP);
  // When that address stops answering too, its own one is tried again first.
  const retried = [];
  assert.equal(await page.move(async url => { retried.push(url); return { ok: url.startsWith(name) }; }, () => {}), true);
  assert.deepEqual(retried, [name + '/state']);
  assert.equal(page.base(), '', 'back to asking its own address');

  // Opened at the home network IP, the remote moves to the Mac's name, which survives the IP changing.
  page = load([name, oldIP, tailscale], oldIP);
  went = null;
  assert.equal(await page.settle(name, async url => ({ ok: url === name + '/state' }), url => { went = url; }), true);
  assert.equal(went, name + '/#key=secret-key');
  // Only once per page, and not when the phone can't reach the name (some Android phones).
  went = null;
  assert.equal(await page.settle(name, async () => ({ ok: true }), url => { went = url; }), false);
  page = load([name, oldIP, tailscale], oldIP);
  assert.equal(await page.settle(name, async () => { throw new Error('no mDNS'); }, url => { went = url; }), false);
  assert.equal(went, null);

  // It stays put at the name, at Tailscale, on this Mac itself, when installed, and for a home address that isn't one.
  const never = async () => { throw new Error('should not ask'); };
  for (const [here, options, home] of [[name, {}, name], [tailscale, {}, name], ['http://127.0.0.1:8765', {}, name],
                                       [oldIP, { installed: true }, name],
                                       [oldIP, {}, 'javascript:alert(1)'], [oldIP, {}, '']]) {
    page = load([name, oldIP, tailscale], here, options);
    assert.equal(await page.settle(home, never, () => { throw new Error('should not move'); }), false, `stays at ${here}`);
  }
  console.log('reconnect ok');
})().catch(error => { console.error(error); process.exit(1); });
