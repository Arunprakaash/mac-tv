// Run with: node Tests/WebPlayback/stillmouse.test.cjs
// Executes the injected StillMouse script against a minimal window and checks which mouse events
// reach the page.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Sources/MacTV/Features/Playback/StillMouse.swift', 'utf8').split('static let script = #"""')[1].split('"""#')[0];

const listeners = {};
const window = { addEventListener(type, fn, capture) { assert.equal(capture, true); (listeners[type] ||= []).push(fn); } };
vm.runInContext(source, vm.createContext({ window, Math }));

// Whether the page would see the event.
function reaches(type, x, y, timeStamp, pointerType) {
  let stopped = false;
  const event = { type, screenX: x, screenY: y, timeStamp, pointerType, stopImmediatePropagation() { stopped = true; } };
  for (const fn of listeners[type] || []) fn(event);
  return !stopped;
}

// The page appears under a resting mouse: nothing moved, so nothing reaches it.
assert.equal(reaches('pointerover', 541.64, 618.35, 200), false);
assert.equal(reaches('mouseover', 541, 618, 200), false);
assert.equal(reaches('mousemove', 541, 618, 300), false);

// Minutes later a subtitle appears under it: WebKit reports hover changes at the same spot.
for (const type of ['pointerout', 'mouseout', 'pointerover', 'mouseover', 'mouseenter', 'pointerleave'])
  assert.equal(reaches(type, type.startsWith('pointer') ? 541.64 : 541, 618, 180_000), false, type);

// Moving the mouse reaches the page, as do the hover changes right after it.
assert.equal(reaches('pointermove', 600.2, 620.9, 181_000), true);
assert.equal(reaches('mousemove', 600, 620, 181_000), true);
assert.equal(reaches('mouseover', 600, 620, 181_100), true);
// Once it has rested again, the page's own changes are dropped again.
assert.equal(reaches('mouseover', 600, 620, 184_000), false);

// Touch and pen are never held back.
assert.equal(reaches('pointerover', 600, 620, 300_000, 'touch'), true);
assert.equal(reaches('pointermove', 600, 620, 300_000, 'pen'), true);
// Clicks aren't filtered at all.
assert.equal(listeners.mousedown, undefined);
assert.equal(listeners.click, undefined);

// Injected twice (a page that reruns scripts): one filter.
vm.runInContext(source, vm.createContext({ window, Math }));
assert.equal(listeners.mousemove.length, 1);
console.log('still mouse: ok');
