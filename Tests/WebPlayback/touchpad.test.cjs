// Run with: node Tests/WebPlayback/touchpad.test.cjs
// Execute the real touchpad handler with a deliberately slow mock transport.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Sources/MacTV/RemotePage.swift', 'utf8');
const start = source.indexOf('    // Touchpad: one finger moves');
const end = source.indexOf('    // Old installations stored', start);
assert.ok(start >= 0 && end > start);
const listeners = {};
const pad = { addEventListener: (name, fn) => { listeners[name] = fn; }, setPointerCapture() {} };
const requests = [], pending = [];
let active = 0, maximum = 0;
const api = (_path, body) => {
  requests.push(body); active++; maximum = Math.max(maximum, active);
  return new Promise((resolve, reject) => pending.push({ resolve: () => { active--; resolve({}); }, reject: () => { active--; reject(new Error('offline')); } }));
};
const send = action => { requests.push({ a: action }); return Promise.resolve(); };
vm.runInNewContext(source.slice(start, end), { $: () => pad, api, send, setTimeout, clearTimeout, Date, Math, Map, Promise });
const event = (type, id, x, y) => listeners[type]({ type, pointerId: id, clientX: x, clientY: y });
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
(async () => {
  event('pointerdown', 1, 0, 0);
  event('pointermove', 1, 1, 0);
  await wait(40);
  assert.equal(pending.length, 1);
  event('pointermove', 1, 2, 0);
  event('pointerup', 1, 2, 0);
  await wait(40);
  assert.equal(requests.length, 1, 'no overlapping request or early click');
  pending.shift().resolve();
  await wait(0);
  assert.equal(requests.length, 2, 'movement accumulated while waiting is sent');
  assert.equal(requests[1].a, 'pointer');
  pending.shift().reject(); // A failed request must not prevent the click or reject unhandled.
  await wait(0);
  assert.deepEqual(requests.map(x => x.a), ['pointer', 'pointer', 'click']);
  event('pointerdown', 1, 0, 0);
  event('pointerdown', 2, 0, 0);
  event('pointermove', 1, 0, 4);
  await wait(40);
  assert.equal(requests.at(-1).a, 'scroll');
  event('pointermove', 1, 0, 8);
  pending.shift().resolve();
  await wait(0);
  assert.equal(requests.at(-1).a, 'scroll', 'scroll accumulated during request is sent');
  pending.shift().resolve();
  await wait(0);
  event('pointerup', 1, 0, 8);
  event('pointerup', 2, 0, 0);
  assert.equal(requests.filter(x => x.a === 'scroll').reduce((n, x) => n + x.dy, 0), -12);
  assert.equal(maximum, 1);
  console.log('Touchpad serial transport and tap ordering passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
