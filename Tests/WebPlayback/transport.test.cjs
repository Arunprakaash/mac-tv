// Run with: node Tests/WebPlayback/transport.test.cjs
// Exercise the embedded transport and refresh scheduler with controlled slow responses.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Sources/MacTV/RemotePage.swift', 'utf8');
const transport = source.slice(source.indexOf('    // A timed-out POST'), source.indexOf('    // State: connection'));
const refresh = source.slice(source.indexOf('    let stateInFlight = null;'), source.indexOf('    async function readState()'));
assert.ok(transport.includes('function request') && refresh.includes('function refresh'));
const requests = [], calls = [], errors = [], storage = [];
let readCount = 0, finishRead, finishFetch;
const context = vm.createContext({
  AbortController, Promise, Error,
  setTimeout: (fn, ms) => setTimeout(fn, ms === 9000 ? 30 : ms), clearTimeout,
  fetch: (path, options) => {
    requests.push({ path, options });
    return new Promise((resolve, reject) => {
      finishFetch = resolve;
      options.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
    });
  },
  store: { set: value => storage.push(value) }, showPair: () => calls.push('pair'),
  haptic() {}, online: ok => errors.push(ok),
  readState: () => { readCount++; return new Promise(resolve => { finishRead = resolve; }); },
});
vm.runInContext("let key = 'original'; let appMutationPending = false;" + transport + refresh, context);
const run = code => vm.runInContext(code, context);
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
(async () => {
  const timeout = run("api('/files/play', {id:'video'})");
  await assert.rejects(timeout, /timed out|aborted/);
  assert.equal(requests.length, 1, 'timed-out POST is not replayed');
  assert.equal(requests[0].options.signal.aborted, true);

  const old = run('refresh()');
  const concurrent = run('refresh()');
  assert.equal(readCount, 1, 'concurrent polls share a single request');
  run('appMutationPending = true');
  const reconcile = run('refresh(true)');
  assert.equal(readCount, 1, 'edit waits for the older read');
  finishRead(false); await old; await concurrent; await wait(0);
  assert.equal(readCount, 2, 'edit gets a fresh reconciliation read');
  finishRead(true); assert.equal(await reconcile, true);
  run('appMutationPending = false');

  const a = run("send('up', {}, 'repeat')");
  for (let i = 0; i < 20; i++) run("send('up', {}, 'repeat')");
  await wait(0);
  assert.equal(requests.filter(r => r.path === '/cmd').length, 1, 'repeat traffic is dropped while busy');
  const urgent = run("send('home', {}, 'tap')");
  await wait(0);
  const cmd = requests.filter(r => r.path === '/cmd');
  assert.equal(cmd.length, 2);
  assert.equal(cmd[0].options.signal.aborted, true, 'urgent command cancels old request');
  assert.equal(JSON.parse(cmd[1].options.body).a, 'home');
  finishFetch({ status: 200, ok: true, json: async () => ({ ok: true }) });
  await Promise.all([a, urgent]);
  assert.deepEqual(errors, [], 'intentional cancellation is not an offline error');

  const expired = run("api('/state')");
  finishFetch({ status: 401, ok: false });
  await assert.rejects(expired, /unpaired/);
  assert.equal(run('key'), '');
  assert.deepEqual(storage, ['']);
  assert.deepEqual(calls, ['pair']);
  await run('refresh()');
  assert.equal(readCount, 2, 'unpaired polling never contacts state');
  const pairSource = source.slice(source.indexOf('    function showPair()'), source.indexOf('    async function pair(', source.indexOf('    function showPair()')));
  let shown = false, focuses = 0, scheduled = 0;
  const pairElements = { '#pair': { classList: { contains: () => shown, add: () => { shown = true; } } }, '#code': { focus: () => { focuses++; } } };
  const pairContext = vm.createContext({ $: s => pairElements[s], setTimeout: fn => { scheduled++; fn(); } });
  vm.runInContext(pairSource, pairContext);
  vm.runInContext('showPair(); showPair(); showPair()', pairContext);
  assert.equal(scheduled, 1, 'pairing focus is scheduled only on transition');
  assert.equal(focuses, 1);

  const start = source.indexOf('    // Clickpad:');
  const end = source.indexOf('    // Touchpad:', start);
  const listeners = {}, documentListeners = {}, repeats = [];
  let intervalCallback, intervalCleared = false;
  const pad = { querySelectorAll: () => [], setPointerCapture() {},
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 200, height: 200 }),
    querySelector: () => ({ getBoundingClientRect: () => ({ width: 160 }), classList: { add() {}, remove() {} } }),
    addEventListener: (type, fn) => { listeners[type] = fn; } };
  const doc = { visibilityState: 'visible', addEventListener: (type, fn) => { documentListeners[type] = fn; } };
  const padContext = vm.createContext({ document: doc, Math,
    $: selector => selector === '#clickpad' ? pad : { getBoundingClientRect: () => ({ width: 40 }) },
    send: action => repeats.push(action), setTimeout: (fn, ms) => { if (ms === 420) fn(); return 1; },
    clearTimeout() {}, setInterval: fn => { intervalCallback = fn; return 2; },
    clearInterval: () => { intervalCleared = true; }, });
  vm.runInContext(source.slice(start, end), padContext);
  listeners.pointerdown({ pointerId: 1, clientX: 150, clientY: 100 });
  intervalCallback(); assert.equal(repeats.length, 1);
  doc.visibilityState = 'hidden'; documentListeners.visibilitychange();
  assert.equal(intervalCleared, true, 'hiding the page stops held direction repeats');
  intervalCleared = false;
  listeners.pointerdown({ pointerId: 2, clientX: 150, clientY: 100 });
  listeners.lostpointercapture();
  assert.equal(intervalCleared, true, 'losing capture stops held direction repeats');
  console.log('Remote request deadlines, serialized refresh, bounded commands and pairing recovery passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
