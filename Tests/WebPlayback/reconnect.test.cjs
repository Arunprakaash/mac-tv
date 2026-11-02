// The phone remote finds the Mac at another of its addresses when the one it's on stops answering.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { script } = require('./page.cjs');
const start = script.indexOf('// Every address the Mac answers at');
const end = script.indexOf('// Keep a reachable sleeping display distinct');
assert.ok(start >= 0 && end > start);

function load(stored, here) {
  const storage = new Map([['mactvAddresses', JSON.stringify(stored)]]);
  const context = {
    key: 'secret-key', location: { origin: here }, AbortController, setTimeout, clearTimeout, JSON, Array, encodeURIComponent,
    localStorage: { getItem: k => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v) },
  };
  vm.runInNewContext(script.slice(start, end).replace(/^let unanswered/m, 'var unanswered')
    + '\nthis.move = moveToAnotherAddress; this.addresses = addresses;', context);
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
  console.log('reconnect ok');
})().catch(error => { console.error(error); process.exit(1); });
