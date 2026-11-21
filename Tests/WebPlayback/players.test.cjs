// The phone remote lists the website players the Mac sends, or Built-in and Brave when an older Mac sends none.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { script } = require('./page.cjs');
const start = script.indexOf('// The browsers on this Mac, as the Mac lists them');
const end = script.indexOf('// Apps sheet: launch tiles');
assert.ok(start >= 0 && end > start);

function render(...args) {
  const value = { textContent: '' };
  const list = { rows: [], replaceChildren(...rows) { this.rows = rows; } };
  const picked = [];
  const context = {
    Array,
    $: selector => (selector === '#website-player-value' ? value : list),
    choiceRow: (title, detail, selected, disabled, onPick) => ({ title, detail, selected, disabled, onPick }),
    choosePlayer: id => picked.push(id),
  };
  vm.runInNewContext(script.slice(start, end) + '\nthis.render = renderPlayerChoices;', context);
  context.render(...args);
  return { value: value.textContent, rows: list.rows, picked };
}

const players = [{ id: 'embedded', name: 'Built-in' }, { id: 'brave', name: 'Brave' }, { id: 'com.apple.Safari', name: 'Safari' }];
let page = render('com.apple.Safari', true, players);
assert.equal(page.value, 'Safari');
assert.deepEqual(page.rows.map(row => [row.title, row.selected, row.disabled]),
  [['Built-in', false, false], ['Brave', false, false], ['Safari', true, false]]);
page.rows[2].onPick();
assert.deepEqual(page.picked, ['com.apple.Safari']);

// A saved browser that's gone shows as Built-in, which is what plays.
page = render('org.mozilla.firefox', false, players.slice(0, 1));
assert.equal(page.value, 'Built-in');
assert.equal(page.rows[0].selected, true);

// No list from an older Mac: today's two rows.
page = render('embedded', false, undefined);
assert.deepEqual(page.rows.map(row => [row.title, row.detail, row.selected, row.disabled]),
  [['Built-in', '', true, false], ['Brave', 'Not installed', false, true]]);
console.log('website players ok');
