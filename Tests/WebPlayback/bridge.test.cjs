// Run with: node Tests/WebPlayback/bridge.test.cjs
// A small multi-frame browser model executes the actual injected script.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('Sources/MacTV/WebPlayback.swift', 'utf8').split('static let script = #"""')[1].split('"""#')[0];
let current;
const style = { display: 'block', visibility: 'visible', opacity: '1' };
const rect = { left: 0, top: 0, right: 800, bottom: 600, width: 800, height: 600 };
function video(paused) {
  return { paused, ended: false, readyState: 4, currentTime: 20, seekable: { length: 1, start: () => 0, end: () => 100 },
    getBoundingClientRect: () => rect, play() { this.paused = false; return Promise.resolve(); }, pause() { this.paused = true; } };
}
function frame(parent, videos = []) {
  const listeners = {}, children = [];
  const w = { parent: parent || null, top: parent ? parent.top : null,
    addEventListener(type, fn) { listeners[type] = fn; },
    postMessage(data) { const sender = current; setImmediate(() => run(w, () => listeners.message?.({ data, source: sender }))); } };
  if (!parent) w.parent = w.top = w;
  const context = vm.createContext({ window: w, document: { querySelectorAll: s => s === 'video' ? videos : children },
    getComputedStyle: el => el.style || style, innerWidth: 800, innerHeight: 600, setTimeout: (fn, ms) => setTimeout(() => run(w, fn), ms),
    Promise, Math, Date, Number, Error });
  w.context = context;
  w.addFrame = (child, hidden = false) => children.push({ contentWindow: child, getBoundingClientRect: () => rect,
    style: hidden ? { ...style, display: 'none' } : style });
  run(w, () => vm.runInContext(source, context));
  return w;
}
function run(w, fn) { const previous = current; current = w; try { return fn(); } finally { current = previous; } }
(async () => {
  const mainVideo = video(true), nestedVideo = video(false), hiddenVideo = video(false);
  const top = frame(null, [mainVideo]), child = frame(top), nested = frame(child, [nestedVideo]), hidden = frame(top, [hiddenVideo]);
  top.addFrame(child); child.addFrame(nested); top.addFrame(hidden, true);
  assert.equal(await run(top, () => top.__macTVPlayback('toggle')), 'paused');
  assert.equal(nestedVideo.paused, true);
  assert.equal(mainVideo.paused, true);
  assert.equal(hiddenVideo.paused, false);
  nestedVideo.paused = false;
  assert.equal(await run(top, () => top.__macTVPlayback('forward')), 'seeked');
  assert.equal(nestedVideo.currentTime, 30);
  assert.equal(mainVideo.currentTime, 20);
  const empty = frame(null);
  assert.equal(await run(empty, () => empty.__macTVPlayback('toggle')), 'none');
  assert.equal(await run(empty, () => empty.__macTVPlayback('invalid')), 'unsupported');
  console.log('Web playback bridge tests passed');
})().catch(e => { console.error(e); process.exitCode = 1; });
