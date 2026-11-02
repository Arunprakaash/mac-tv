const $ = s => document.querySelector(s);

// Haptics: Android vibrates; iPhone (iOS 18+) ticks when a switch toggles, so flip a hidden one.
const haptic = (() => {
  const vibrate = typeof navigator.vibrate === 'function';
  let iosSwitch = null;
  if (!vibrate) {
    iosSwitch = document.createElement('label');
    iosSwitch.style.display = 'none';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.setAttribute('switch', '');
    iosSwitch.appendChild(input);
    document.body.appendChild(iosSwitch);
  }
  // Short pulses feel like light ticks; longer ones buzz.
  const patterns = { tick: 6, tap: 10, repeat: 4, error: [10, 50, 10] };
  return kind => {
    try {
      if (vibrate) navigator.vibrate(patterns[kind] ?? 14);
      else if (kind !== 'repeat') {
        iosSwitch.click();
        if (kind === 'error') setTimeout(() => iosSwitch.click(), 140);
      }
    } catch {}
  };
})();

// Visible press feedback on every button (Android Chrome's :active is unreliable on touch).
document.addEventListener('pointerdown', e => {
  const b = e.target.closest('button');
  if (!b) return;
  b.classList.add('pressed');
  const release = () => { b.classList.remove('pressed'); ['pointerup', 'pointercancel', 'pointerleave'].forEach(t => b.removeEventListener(t, release)); };
  ['pointerup', 'pointercancel', 'pointerleave'].forEach(t => b.addEventListener(t, release));
});

const store = {
  get() { try { return localStorage.getItem('mactvKey') || localStorage.getItem('matineeKey') || localStorage.getItem('couchKey') || ''; } catch { return ''; } },
  set(v) {
    for (const old of ['matineeKey', 'couchKey']) { try { localStorage.removeItem(old); } catch {} }
    try { localStorage.setItem('mactvKey', v); } catch {}
  },
};
const qrCode = new URLSearchParams(location.search).get('k') || '';
// A remote that moved here from another of the Mac's addresses brings its key in the fragment,
// which browsers never send to the server.
const carriedKey = new URLSearchParams(location.hash.slice(1)).get('key') || '';
if (carriedKey) store.set(carriedKey);
if (qrCode || carriedKey) history.replaceState(null, '', location.pathname);
let key = store.get();

// Every address the Mac answers at (its name, IP and Tailscale), from its last state.
const addresses = {
  get() { try { const list = JSON.parse(localStorage.getItem('mactvAddresses') || '[]'); return Array.isArray(list) ? list : []; } catch { return []; } },
  set(list) { try { localStorage.setItem('mactvAddresses', JSON.stringify(list)); } catch {} },
};

// When this address stops answering (the Mac's IP changed while it slept, say), try its other
// addresses and move to the first one that still knows this phone, taking the key along.
let unanswered = 0, moving = false;
async function moveToAnotherAddress(fetcher = fetch, go = url => location.replace(url)) {
  if (moving || !key) return false;
  moving = true;
  try {
    for (const origin of addresses.get()) {
      if (typeof origin !== 'string' || origin === location.origin || !/^http:\/\/[^/]+$/.test(origin)) continue;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 2500);
      try {
        const res = await fetcher(origin + '/state', { headers: { 'X-Couch-Key': key }, signal: controller.signal });
        if (res.ok) { go(origin + '/#key=' + encodeURIComponent(key)); return true; }
      } catch {} finally { clearTimeout(timer); }
    }
    return false;
  } finally { moving = false; }
}

// Keep a reachable sleeping display distinct from an offline Mac.
function online(ok, sleeping = false) {
  $('.status').hidden = ok && !sleeping;
  $('#status').textContent = !ok ? 'Can’t reach the TV' : sleeping ? 'Screen asleep · controls wake it' : '';
}

// A timed-out POST may already have reached the TV; never replay it automatically.
async function request(path, body, authenticated = true, cancelSignal = null) {
  if (cancelSignal?.aborted) throw new Error('cancelled');
  const controller = new AbortController();
  const credential = key;
  let timer, cancel;
  const interrupted = new Promise((_, reject) => {
    timer = setTimeout(() => { controller.abort(); reject(new Error('Request timed out.')); }, 9000);
    cancel = () => { controller.abort(); reject(new Error('cancelled')); };
    if (cancelSignal) {
      if (cancelSignal.aborted) cancel();
      else cancelSignal.addEventListener('abort', cancel, { once: true });
    }
  });
  try {
    return await Promise.race([interrupted, (async () => {
      const res = await fetch(path, {
        method: body ? 'POST' : 'GET',
        headers: authenticated ? { 'Content-Type': 'application/json', 'X-Couch-Key': credential } : { 'Content-Type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });
      if (authenticated && res.status === 401) {
        // A late response from an old request must not revoke a newly paired key.
        if (key === credential) { key = ''; store.set(''); showPair(); }
        throw new Error('unpaired');
      }
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || res.statusText);
      return data;
    })()]);
  } finally {
    clearTimeout(timer);
    if (cancelSignal) cancelSignal.removeEventListener('abort', cancel);
  }
}
function api(path, body, signal) { return request(path, body, true, signal); }

// Keep a small bounded queue: repeats are dropped under load and urgent actions jump ahead.
const commandQueue = [];
let activeCommand = null;
function pumpCommands() {
  if (activeCommand || !commandQueue.length) return;
  const item = commandQueue.shift();
  if (!key) { item.done(); pumpCommands(); return; }
  const controller = new AbortController();
  activeCommand = controller;
  api('/cmd', item.body, controller.signal).catch(e => {
    if (e.message !== 'unpaired' && e.message !== 'cancelled') { online(false); haptic('error'); }
  }).finally(() => { activeCommand = null; item.done(); pumpCommands(); });
}
function send(a, extra, kind = 'tick') {
  haptic(kind);
  return new Promise(resolve => {
    const urgent = a === 'home' || a === 'screenoff';
    if (urgent) {
      while (commandQueue.length) commandQueue.shift().done();
      if (activeCommand) activeCommand.abort();
      commandQueue.unshift({ body: { a, ...extra }, done: resolve });
    } else if ((kind === 'repeat' && (activeCommand || commandQueue.length)) || commandQueue.length >= 8) {
      resolve(); return;
    } else {
      commandQueue.push({ body: { a, ...extra }, done: resolve });
    }
    pumpCommands();
  });
}

// State: connection, the app list, settings.
let appsShown = '', apps = [], canRestore = false, currentLocalMovie = null, iinaInstalled = false;
let stateGeneration = 0, appMutationPending = false, displayChanging = false, availableDisplays = [];
let stateInFlight = null;
async function refresh(duringMutation = false) {
  if (appMutationPending && !duringMutation) return false;
  if (!key) { showPair(); return false; }
  if (stateInFlight) {
    if (!duringMutation) return stateInFlight;
    await stateInFlight; // The pre-edit snapshot must finish before the reconciliation read.
    if (!key) return false;
  }
  const pending = readState();
  stateInFlight = pending;
  try { return await pending; } finally { if (stateInFlight === pending) stateInFlight = null; }
}
async function readState() {
  const generation = ++stateGeneration;
  try {
    const s = await api('/state');
    // A newer refresh or an edit invalidates an older in-flight response.
    if (generation !== stateGeneration) return false;
    unanswered = 0;
    if (Array.isArray(s.addresses) && s.addresses.length) addresses.set(s.addresses);
    online(true, s.displaysSleeping === true);
    document.body.classList.toggle('guest', s.guest === true);
    if (s.guest === true) document.querySelectorAll('.scrim.show').forEach(sheet => sheet.classList.remove('show'));
    const focused = appFocus();
    apps = s.apps;
    canRestore = s.canRestore;
    currentLocalMovie = s.currentLocalMovie || null;
    iinaInstalled = !!s.iinaInstalled;
    updateMovieOptions();
    showSleep(s.sleepMinutes || 0);
    $('#auto-skip').checked = s.autoSkip;
    $('#auto-next').checked = s.autoNext;
    $('#keep-awake').checked = s.keepMacAwake;
    $('#lid-override').checked = s.lidOverride;
    $('#lid-status').textContent = s.lidStatus || '';
    if (!displayChanging) updateDisplays(s.displaySetup);
    $('#website-player').value = s.websitePlayer === 'brave' ? 'brave' : 'embedded';
    const player = s.externalPlayer && s.externalPlayer.name === 'IINA' ? s.externalPlayer : null;
    $('#iina-controls').hidden = !player;
    const iinaStatus = player && typeof player.status === 'string' ? player.status : '';
    const iinaError = player && typeof player.error === 'string' ? player.error : '';
    $('#iina-status').textContent = iinaStatus;
    $('#iina-status').hidden = !iinaStatus;
    $('#iina-error').textContent = iinaError;
    $('#iina-error').hidden = !iinaError;
    const browser = s.externalBrowser;
    $('#browser-controls').hidden = !browser;
    const browserError = browser && typeof browser.error === 'string' ? browser.error : '';
    $('#browser-error').textContent = browserError;
    $('#browser-error').hidden = !browserError;
    $('#browser-retry').hidden = !browserError;
    $('#browser-retry').disabled = !!(browser && browser.opening);
    $('#browser-control-note').textContent = browser && browser.accessibilityAllowed === false
      ? 'Allow Accessibility access for Mac TV to send input to Brave. Automation access is also needed to open and control its window.' : '';
    const sig = JSON.stringify([s.apps, s.canRestore]);
    if (sig !== appsShown) {
      appsShown = sig;
      if (!appMutationPending) renderApps(focused);
    }
    return true;
  } catch (e) {
    if (generation === stateGeneration && e.message !== 'unpaired') {
      online(false);
      // About nine seconds without an answer: look for the Mac at its other addresses.
      if (++unanswered >= 3) moveToAnotherAddress();
    }
    return false;
  }
}

function updateDisplays(setup) {
  const select = $('#display-select');
  availableDisplays = Array.isArray(setup?.displays) ? setup.displays : [];
  select.replaceChildren();
  if (!availableDisplays.length) {
    const option = document.createElement('option');
    option.textContent = 'No displays available';
    select.appendChild(option);
    select.disabled = true;
    return;
  }
  for (const display of availableDisplays) {
    const option = document.createElement('option');
    option.value = String(display.id);
    option.textContent = display.name + (display.current ? ' · current' : '');
    select.appendChild(option);
  }
  const selected = availableDisplays.find(display => display.preferred) || availableDisplays.find(display => display.current);
  if (selected) select.value = String(selected.id);
  select.disabled = false;
}

// Apps sheet: launch tiles, or accessible controls for arranging the same apps.
let editing = false;
function appFocus() {
  const active = document.activeElement;
  if (!$('#apps').contains(active) || !active.dataset.appId) return null;
  return { id: active.dataset.appId, action: active.dataset.action, element: active,
           index: apps.findIndex(app => app.id === active.dataset.appId) };
}
function appArt(app) {
  const art = document.createElement('span');
  art.className = 'art';
  if (app.icon) {
    const img = document.createElement('img');
    img.src = `/icon/${encodeURIComponent(app.id)}?v=${encodeURIComponent(appsShown.length)}`;
    img.alt = '';
    art.appendChild(img);
  } else {
    art.textContent = app.name.slice(0, 1).toUpperCase();
  }
  return art;
}
function favouriteBadge() {
  const badge = document.createElement('span');
  badge.className = 'favourite';
  badge.textContent = '★';
  badge.setAttribute('aria-hidden', 'true');
  return badge;
}
function appMessage(message, error = false) {
  const note = $('#apps-msg');
  note.textContent = message;
  note.className = error ? 'note err' : 'note ok';
  note.hidden = !message;
}
async function changeApp(path, body, message) {
  if (appMutationPending) return;
  const focused = appFocus();
  appMutationPending = true;
  ++stateGeneration;
  $('#apps').setAttribute('aria-busy', 'true');
  $('#apps').querySelectorAll('button').forEach(button => { button.disabled = true; });
  $('#edit-apps').disabled = true;
  $('#restore').disabled = true;
  appMessage('Saving…');
  haptic('tap');
  try {
    await api(path, body);
    const updated = await refresh(true);
    appMessage(updated ? message : 'Saved on the TV. Reconnect to refresh the app list.', !updated);
  } catch (e) {
    haptic('error');
    appMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true);
    // Another remote may have changed the app or its position.
    await refresh(true);
  } finally {
    appMutationPending = false;
    // Do not take focus back if the user moved to Done or another sheet while waiting.
    const canRestoreFocus = focused && (document.activeElement === focused.element || document.activeElement === document.body);
    renderApps(canRestoreFocus ? focused : null);
  }
}
function renderApps(focused = appFocus()) {
  const box = $('#apps');
  const sheet = $('#apps-sheet .sheet');
  const scrollTop = sheet.scrollTop;
  box.textContent = '';
  box.classList.toggle('editing', editing);
  box.setAttribute('aria-busy', String(appMutationPending));
  for (const app of apps) {
    if (editing) {
      const card = document.createElement('div');
      card.className = 'app-editor';
      const head = document.createElement('div');
      head.className = 'app-editor-head';
      const icon = document.createElement('span');
      icon.className = 'app';
      icon.appendChild(appArt(app));
      if (app.pinned) icon.appendChild(favouriteBadge());
      const name = document.createElement('span');
      name.className = 'app-editor-name';
      name.textContent = app.name;
      head.append(icon, name);
      const actions = document.createElement('div');
      actions.className = 'app-actions';
      const action = (kind, label, description, available, path, body, message) => {
        const button = document.createElement('button');
        button.className = kind;
        button.textContent = label;
        button.dataset.appId = app.id;
        button.dataset.action = kind;
        button.setAttribute('aria-label', description);
        button.disabled = appMutationPending || !available;
        button.onclick = () => changeApp(path, body, message);
        actions.appendChild(button);
        return button;
      };
      const pin = action('pin', app.pinned ? '★ Unpin' : '☆ Pin favourite',
        `${app.pinned ? 'Unpin' : 'Pin'} ${app.name}`, true, '/apps/pin', { id: app.id, pinned: !app.pinned },
        `${app.name} ${app.pinned ? 'unpinned' : 'pinned as a favourite'}.`);
      pin.setAttribute('aria-pressed', String(!!app.pinned));
      action('remove', 'Remove', `Remove ${app.name}`, true, '/apps/remove', { id: app.id }, `Removed ${app.name}.`);
      action('earlier', '↑ Earlier', `Move ${app.name} earlier`, !!app.canMoveEarlier,
        '/apps/move', { id: app.id, offset: -1 }, `Moved ${app.name} earlier.`);
      action('later', '↓ Later', `Move ${app.name} later`, !!app.canMoveLater,
        '/apps/move', { id: app.id, offset: 1 }, `Moved ${app.name} later.`);
      card.append(head, actions);
      box.appendChild(card);
      continue;
    }
    const b = document.createElement('button');
    b.className = 'app';
    b.dataset.appId = app.id;
    b.dataset.action = 'launch';
    const name = document.createElement('span');
    name.textContent = app.name;
    b.append(appArt(app), name);
    if (app.pinned) b.appendChild(favouriteBadge());
    b.setAttribute('aria-label', `Open ${app.name}${app.pinned ? ', favourite' : ''}`);
    b.onclick = () => {
      closeSheets();
      send('launch', { id: app.id }, 'tap');
    };
    box.appendChild(b);
  }
  const add = document.createElement('button');
  add.className = 'app add';
  add.innerHTML = '<span class="art">+</span><span>Add app</span>';
  add.onclick = () => { haptic('tick'); openAdd(); };
  box.appendChild(add);
  $('#edit-apps').textContent = editing ? 'Finish' : 'Edit';
  $('#edit-apps').classList.toggle('on', editing);
  $('#edit-apps').disabled = appMutationPending;
  $('#edit-note').hidden = !editing;
  $('#restore').hidden = !(editing && canRestore);
  $('#restore').disabled = appMutationPending;
  $('#apps-title').textContent = editing ? 'Edit apps' : 'Open on TV';
  if (focused && $('#apps-sheet').classList.contains('show') && !$('#pair').classList.contains('show')) {
    const buttons = [...box.querySelectorAll('button[data-app-id]')];
    const sameApp = buttons.filter(button => button.dataset.appId === focused.id && !button.disabled);
    const target = sameApp.find(button => button.dataset.action === focused.action) || sameApp[0]
      || buttons.find(button => button.dataset.appId === apps[Math.min(Math.max(focused.index, 0), apps.length - 1)]?.id && !button.disabled)
      || $('#edit-apps');
    target.focus({ preventScroll: true });
  }
  sheet.scrollTop = scrollTop;
}
$('#edit-apps').onclick = () => { haptic('tick'); editing = !editing; appMessage(''); renderApps(); };
$('#restore').onclick = () => changeApp('/apps/restore', {}, 'Restored built-in apps.');

// File IDs come from the server and remain opaque; names are always rendered as text.
let fileTrail = [], fileEntries = [], fileNext = null, selectedMovie = null, fileGeneration = 0;
function fileMessage(message, error = false) {
  $('#files-msg').textContent = message;
  $('#files-msg').className = error ? 'note err' : 'note';
}
function updateMovieOptions() {
  $('#play-iina').disabled = !iinaInstalled;
  $('#play-iina').textContent = iinaInstalled ? 'Play in IINA' : 'IINA not installed';
  $('#subtitle-search-iina').disabled = !iinaInstalled;
}
async function loadFiles(more = false) {
  const generation = ++fileGeneration;
  const folder = fileTrail[fileTrail.length - 1];
  const offset = more ? fileNext : 0;
  fileMessage('Loading…');
  try {
    const data = await api(folder ? `/files?folder=${encodeURIComponent(folder.id)}&offset=${encodeURIComponent(offset)}&limit=100` : '/files/roots');
    if (generation !== fileGeneration) return;
    const items = folder ? (data.entries || []) : (data.roots || []);
    fileEntries = more ? fileEntries.concat(items) : items;
    fileNext = folder && data.nextOffset != null ? data.nextOffset : null;
    fileMessage('');
    renderFiles();
  } catch (e) {
    if (generation !== fileGeneration) return;
    fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true);
  }
}
function renderFiles() {
  $('#files-path').textContent = ['Locations', ...fileTrail.map(item => item.name)].join(' › ');
  $('#files-back').disabled = !fileTrail.length;
  $('#files-more').hidden = fileNext == null;
  const list = $('#files-list'); list.textContent = '';
  const filter = $('#files-filter').value.trim().toLocaleLowerCase();
  const matches = fileEntries.filter(item => item.name.toLocaleLowerCase().includes(filter));
  for (const item of matches) {
    const button = document.createElement('button');
    const name = document.createElement('span'); name.textContent = item.name;
    const tag = document.createElement('span');
    tag.textContent = item.kind === 'directory' ? 'Folder ›' : item.kind === 'subtitle' ? 'Subtitle' : 'Video';
    button.append(name, tag);
    button.onclick = () => {
      if (item.kind === 'directory') {
        fileTrail.push({ id:item.id, name:item.name });
        $('#files-filter').value = ''; loadFiles();
      } else if (item.kind === 'video') {
        selectedMovie = { id:item.id, title:item.name };
        $('#movie-name').textContent = item.name;
        $('#movie-options').hidden = false;
        $('#subtitle-panel').hidden = true;
        fileMessage('Choose a player or subtitle option.');
      } else if (item.kind === 'subtitle' && selectedMovie) {
        applySubtitle(item.id);
      } else {
        fileMessage('Select a video first, then choose a subtitle.');
      }
    };
    list.appendChild(button);
  }
  if (!matches.length) {
    const empty = document.createElement('p'); empty.className = 'note';
    empty.textContent = filter ? 'No loaded filenames match.' : 'No playable files or folders here.';
    list.appendChild(empty);
  }
}
$('#open-files').onclick = () => {
  haptic('tick'); $('#apps-sheet').classList.remove('show'); $('#files-sheet').classList.add('show');
  fileTrail = []; fileEntries = []; fileNext = null; $('#files-filter').value = '';
  selectedMovie = currentLocalMovie;
  $('#movie-options').hidden = !selectedMovie; $('#subtitle-panel').hidden = true;
  if (selectedMovie) $('#movie-name').textContent = selectedMovie.title;
  updateMovieOptions(); loadFiles();
};
$('#files-back').onclick = () => { if (fileTrail.length) { fileTrail.pop(); $('#files-filter').value = ''; loadFiles(); } };
$('#files-filter').addEventListener('input', renderFiles);
$('#files-more').onclick = () => { if (fileNext != null) loadFiles(true); };
async function playFile(player) {
  if (!selectedMovie) return;
  try {
    fileMessage('Opening video…');
    await api('/files/play', { id:selectedMovie.id, player });
    fileMessage(player === 'iina' ? 'Playback requested in IINA on the Mac.' : 'Playback requested on Mac TV.');
    refresh();
  } catch (e) { fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true); }
}
$('#play-native').onclick = () => playFile('native');
$('#play-iina').onclick = () => playFile('iina');
async function applySubtitle(id) {
  if (!selectedMovie) return;
  try { await api('/files/subtitle', { movie:selectedMovie.id, subtitle:id }); fileMessage('Opening the video with subtitles in IINA.'); }
  catch (e) { fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true); }
}
$('#subtitle-options').onclick = async () => {
  if (!selectedMovie) return;
  $('#subtitle-panel').hidden = false;
  const list = $('#subtitle-list'); list.textContent = '';
  try {
    const data = await api(`/files/subtitles?movie=${encodeURIComponent(selectedMovie.id)}`);
    for (const item of data.entries || []) {
      const button = document.createElement('button'); button.textContent = item.name;
      button.onclick = () => applySubtitle(item.id); list.appendChild(button);
    }
    if (!list.childElementCount) { const note = document.createElement('p'); note.className = 'note'; note.textContent = 'No subtitles found beside this video.'; list.appendChild(note); }
  } catch (e) { fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true); }
};
$('#subtitle-upload').onchange = async e => {
  const input = e.target, file = input.files[0];
  if (!file || !selectedMovie) return;
  try {
    if (!/\.srt$/i.test(file.name) || !file.size || file.size > 256 * 1024) throw new Error('Choose a non-empty .srt file up to 256 KB.');
    const content = new TextDecoder('utf-8', { fatal:true }).decode(await file.arrayBuffer());
    await api('/files/subtitle-upload', { movie:selectedMovie.id, name:file.name, content });
    fileMessage('Subtitle uploaded; opening the video in IINA.');
  } catch (err) { fileMessage(err.message === 'unpaired' ? 'Pair with the TV first.' : err.message, true); }
  finally { input.value = ''; }
};
$('#subtitle-search-iina').onclick = async () => {
  if (!selectedMovie) return;
  try { await api('/files/subtitle-search', { movie:selectedMovie.id }); fileMessage('Requested subtitle search in IINA.'); }
  catch (e) { fileMessage(e.message === 'unpaired' ? 'Pair with the TV first.' : e.message, true); }
};
$('#subtitle-search-web').onclick = () => {
  if (!selectedMovie) return;
  window.open('https://www.opensubtitles.org/en/search/sublanguageid-all/moviename-' + encodeURIComponent(selectedMovie.title.replace(/\.(mp4|m4v|mov|mkv|webm|avi|wmv|flv|ts|m2ts|mts|mpg|mpeg|3gp)$/i, '')), '_blank', 'noopener,noreferrer');
  fileMessage('Download a subtitle on your phone, then upload the .srt here.');
};

function openAdd() {
  $('#apps-sheet').classList.remove('show');
  $('#add-sheet').classList.add('show');
  $('#add-msg').textContent = '';
  $('#add-msg').className = 'note';
  addTab('web');
}
function addTab(which) {
  $('#add-web-tab').classList.toggle('on', which === 'web');
  $('#add-mac-tab').classList.toggle('on', which === 'mac');
  $('#web-form').hidden = which !== 'web';
  $('#mac-form').hidden = which !== 'mac';
  if (which === 'mac') searchMac();
}
$('#add-web-tab').onclick = () => { haptic('tick'); addTab('web'); };
$('#add-mac-tab').onclick = () => { haptic('tick'); addTab('mac'); };

function added(result) {
  haptic('tap');
  const msg = $('#add-msg');
  msg.className = 'note ok';
  msg.textContent = `Added ${result.name}. It's on the TV now.`;
  refresh();
  setTimeout(() => { closeSheets(); }, 1400);
}
function failed(e) {
  haptic('error');
  const msg = $('#add-msg');
  msg.className = 'note err';
  msg.textContent = e.message === 'unpaired' ? 'Pair with the TV first.' : e.message;
}
$('#web-form').onsubmit = e => {
  e.preventDefault();
  const url = $('#web-url').value.trim();
  if (!url) { failed(new Error('Enter a website address.')); return; }
  $('#add-msg').className = 'note';
  $('#add-msg').textContent = 'Adding…';
  api('/apps/add', { url, name: $('#web-name').value.trim() }).then(r => {
    $('#web-url').value = ''; $('#web-name').value = '';
    added(r);
  }).catch(failed);
};

let macTimer = 0;
$('#mac-q').addEventListener('input', () => { clearTimeout(macTimer); macTimer = setTimeout(searchMac, 200); });
async function searchMac() {
  try {
    const list = await api(`/macapps?q=${encodeURIComponent($('#mac-q').value)}`);
    const box = $('#mac-list');
    box.textContent = '';
    for (const app of list) {
      const b = document.createElement('button');
      const name = document.createElement('span');
      name.textContent = app.name;
      const tag = document.createElement('span');
      tag.textContent = app.added ? 'On TV' : 'Add';
      b.append(name, tag);
      b.disabled = app.added;
      b.onclick = () => api('/apps/add', { bundleID: app.bundleID }).then(added).catch(failed);
      box.appendChild(b);
    }
    if (!list.length) box.innerHTML = '<p class="note">No apps match.</p>';
  } catch (e) { failed(e); }
}

// A six-digit code is exchanged once for a separate device credential.
function showPair() { if ($('#pair').classList.contains('show')) return; $('#pair').classList.add('show'); setTimeout(() => $('#code').focus(), 50); }
async function pair(code, name) {
  const data = await request('/pair', { code, name }, false);
  key = data.token;
  store.set(key);
  $('#pair').classList.remove('show');
  $('#pair-err').textContent = '';
  $('#code').value = '';
  return refresh();
}
$('#pair-btn').onclick = async () => {
  try { await pair($('#code').value.trim(), $('#device-name').value.trim()); haptic('tap'); }
  catch (e) { haptic('error'); $('#pair-err').textContent = e.message; }
};
async function loadDevices() {
  const box = $('#devices'); box.textContent = '';
  try {
    const devices = await api('/devices');
    for (const device of devices) {
      const row = document.createElement('div');
      row.className = 'sheet-head';
      const label = document.createElement('span');
      label.textContent = device.name + (device.current ? ' (this device)' : '') +
        (device.guest ? ` · guest until ${new Date(device.expiresAt).toLocaleString()}` : '');
      const remove = document.createElement('button');
      remove.className = 'pill'; remove.textContent = 'Remove';
      remove.setAttribute('aria-label', `Remove ${device.name}`);
      remove.onclick = async () => {
        if (!confirm(`Remove ${device.name}?`)) return;
        try {
          await api('/devices/revoke', { id: device.id });
          if (device.current) { key = ''; store.set(''); closeSheets(); showPair(); }
          else await loadDevices();
        } catch (e) { $('#devices-msg').textContent = e.message; }
      };
      row.append(label, remove); box.appendChild(row);
    }
    $('#revoke-all').hidden = false;
    $('#devices-msg').textContent = '';
  } catch (e) {
    $('#revoke-all').hidden = true;
    $('#devices-msg').textContent = e.message === 'Guests cannot manage devices' ? 'Guest devices cannot manage pairing.' : e.message;
  }
}
let sharesPoll = 0;
async function loadShares() {
  const box = $('#shares');
  let list;
  try { list = await api('/shares'); } catch (e) { $('#shares-msg').textContent = e.message; return; }
  box.textContent = '';
  for (const share of list) {
    const row = document.createElement('div');
    row.className = 'sheet-head';
    const label = document.createElement('span');
    label.textContent = `${share.name} · ${share.status}`;
    label.title = share.address;
    const buttons = document.createElement('div');
    if (!share.connected && !share.connecting) {
      const retry = document.createElement('button');
      retry.className = 'pill'; retry.textContent = 'Connect';
      retry.onclick = async () => { try { await api('/shares/connect', { id: share.id }); } catch {} watchShares(); };
      buttons.appendChild(retry);
    }
    const remove = document.createElement('button');
    remove.className = 'pill'; remove.textContent = 'Remove';
    remove.setAttribute('aria-label', `Remove ${share.name}`);
    remove.onclick = async () => {
      if (!confirm(`Remove ${share.name} from Mac TV?`)) return;
      try { await api('/shares/remove', { id: share.id }); } catch (e) { $('#shares-msg').textContent = e.message; }
      loadShares();
    };
    buttons.appendChild(remove);
    row.append(label, buttons); box.appendChild(row);
  }
  return list;
}
// Connecting takes a few seconds: refresh the list until it settles.
function watchShares() {
  clearTimeout(sharesPoll);
  let tries = 0;
  const tick = async () => {
    const list = await loadShares();
    if (list && list.some(share => share.connecting) && ++tries < 50) sharesPoll = setTimeout(tick, 1500);
  };
  tick();
}
$('#share-form').onsubmit = async e => {
  e.preventDefault();
  const address = $('#share-address').value.trim();
  if (!address) { $('#shares-msg').textContent = 'Enter a shared folder, e.g. nas.local/Movies.'; return; }
  try {
    await api('/shares/add', { address, user: $('#share-user').value.trim(), password: $('#share-password').value });
    $('#share-address').value = ''; $('#share-password').value = '';
    $('#shares-msg').textContent = 'Its movies appear in Movies on the TV. The password stays in the Mac\'s Keychain.';
    haptic('tap');
  } catch (err) { $('#shares-msg').textContent = err.message; haptic('error'); }
  watchShares();
};
let jellyfinPoll = 0;
const jellyfinNote = 'Its movies appear in Movies on the TV. Only a sign-in key is kept, in the Mac\'s Keychain.';
async function loadJellyfin() {
  const box = $('#jellyfin');
  let reply;
  try { reply = await api('/jellyfin'); } catch (e) { $('#jellyfin-msg').textContent = e.message; return; }
  box.textContent = '';
  for (const server of reply.servers) {
    const row = document.createElement('div');
    row.className = 'sheet-head';
    const label = document.createElement('span');
    label.textContent = `${server.name} · ${server.status}`;
    label.title = `${server.user} on ${server.address}`;
    const remove = document.createElement('button');
    remove.className = 'pill'; remove.textContent = 'Remove';
    remove.setAttribute('aria-label', `Remove ${server.name}`);
    remove.onclick = async () => {
      if (!confirm(`Sign out of ${server.name} and remove it from Mac TV?`)) return;
      try { await api('/jellyfin/remove', { id: server.id }); } catch (e) { $('#jellyfin-msg').textContent = e.message; }
      loadJellyfin();
    };
    row.append(label, remove); box.appendChild(row);
  }
  if (reply.signingIn) $('#jellyfin-msg').textContent = 'Signing in…';
  return reply;
}
// Signing in takes a moment: check until it's done, then say how it went.
function watchJellyfin() {
  clearTimeout(jellyfinPoll);
  let tries = 0;
  const tick = async () => {
    const reply = await loadJellyfin();
    if (!reply) return;
    if (reply.signingIn && ++tries < 40) { jellyfinPoll = setTimeout(tick, 1000); return; }
    if (reply.error) { $('#jellyfin-msg').textContent = reply.error; haptic('error'); }
    else { $('#jellyfin-msg').textContent = jellyfinNote; $('#jellyfin-password').value = ''; }
  };
  tick();
}
$('#jellyfin-form').onsubmit = async e => {
  e.preventDefault();
  const address = $('#jellyfin-address').value.trim();
  const user = $('#jellyfin-user').value.trim();
  if (!address || !user) { $('#jellyfin-msg').textContent = 'Enter the server and your user name.'; return; }
  try {
    await api('/jellyfin/add', { address, user, password: $('#jellyfin-password').value });
    haptic('tap');
  } catch (err) { $('#jellyfin-msg').textContent = err.message; haptic('error'); return; }
  watchJellyfin();
};
$('#revoke-all').onclick = async () => {
  if (!confirm('Remove all paired devices, including this one?')) return;
  try { await api('/devices/revoke-all', {}); key = ''; store.set(''); closeSheets(); showPair(); }
  catch (e) { $('#devices-msg').textContent = e.message; }
};

// Buttons
document.querySelectorAll('[data-a]').forEach(b => b.addEventListener('click', () => send(b.dataset.a, {}, b.dataset.h || 'tick')));
$('#browser-retry').onclick = () => send('retrybrowser', {}, 'tap').then(refresh);
let websiteOpening = false;
$('#open-website').onsubmit = async e => {
  e.preventDefault();
  if (websiteOpening) return;
  const input = $('#website-address'), note = $('#website-open-error');
  const url = input.value.trim();
  if (!url) { note.textContent = 'Enter a website address.'; note.hidden = false; return; }
  websiteOpening = true;
  $('#website-go').disabled = true;
  note.hidden = true;
  try {
    await api('/browser/open', { url });
    input.value = '';
    haptic('tap');
    await refresh();
  } catch (error) {
    if (error.message !== 'unpaired') {
      note.textContent = error.message || 'Could not open website.';
      note.hidden = false;
      haptic('error');
    }
  } finally {
    websiteOpening = false;
    $('#website-go').disabled = false;
  }
};
$('#type').onsubmit = e => {
  e.preventDefault();
  const t = $('#typed').value;
  if (t) send('text', { t }, 'tap');
  $('#typed').value = '';
};

// Sheets
const closeSheets = () => {
  const closingText = $('#text-sheet').classList.contains('show');
  document.querySelectorAll('.scrim').forEach(s => s.classList.remove('show'));
  if (closingText) $('#open-text').focus();
  if (editing) { editing = false; renderApps(); }
};
document.querySelectorAll('.scrim').forEach(s => s.addEventListener('click', e => { if (e.target === s) closeSheets(); }));
document.querySelectorAll('[data-close]').forEach(b => b.onclick = closeSheets);
$('#open-text').onclick = () => { haptic('tick'); $('#text-sheet').classList.add('show'); $('#text-sheet [data-close]').focus(); };
$('#open-apps').onclick = () => { haptic('tick'); refresh(); $('#apps-sheet').classList.add('show'); };
$('#open-power').onclick = () => { haptic('tick'); resetSleep(); refresh(); loadDevices(); loadShares(); loadJellyfin(); $('#power-sheet').classList.add('show'); };
document.querySelectorAll('#sleep-chips button').forEach(b => b.onclick = () => {
  const m = Number(b.dataset.m);
  send('sleeptimer', { m }, 'tap').then(refresh);
  showSleep(m);
});
$('#display-select').onchange = async e => {
  if (displayChanging) return;
  const display = availableDisplays.find(item => String(item.id) === e.target.value);
  if (!display) return;
  const note = $('#display-msg');
  displayChanging = true;
  e.target.disabled = true;
  note.hidden = true;
  try {
    await api('/display/select', { id: display.id });
    haptic('tap');
  } catch (error) {
    if (error.message !== 'unpaired') {
      note.textContent = error.message || 'Could not change display.';
      note.className = 'note err';
      note.hidden = false;
      haptic('error');
    }
  } finally {
    displayChanging = false;
    e.target.disabled = false;
    await refresh();
  }
};
$('#website-player').onchange = async e => {
  const note = $('#browser-msg');
  note.hidden = true;
  try {
    await api('/browser/preference', { player: e.target.value });
    haptic('tap');
  } catch (error) {
    if (error.message !== 'unpaired') {
      note.textContent = error.message || 'Could not change website player.';
      note.className = 'note err';
      note.hidden = false;
      haptic('error');
    }
  }
  await refresh();
};
$('#auto-skip').onchange = e => send('setting', { k: 'autoSkip', v: e.target.checked });
$('#auto-next').onchange = e => send('setting', { k: 'autoNext', v: e.target.checked });
$('#keep-awake').onchange = e => send('setting', { k: 'keepMacAwake', v: e.target.checked });
$('#lid-override').onchange = e => send('setting', { k: 'lidOverride', v: e.target.checked });
function showSleep(minutes) {
  document.querySelectorAll('#sleep-chips button').forEach(b => b.classList.toggle('on', Number(b.dataset.m) === (minutes ? -1 : 0)));
  $('#sleep-left').textContent = minutes
    ? `Turns off in ${minutes} min. Playback stops and the screen turns off.`
    : 'When it ends, playback stops and the screen turns off.';
  if (minutes) document.querySelectorAll('#sleep-chips button').forEach(b => b.classList.toggle('on', b.dataset.m !== '0' && Number(b.dataset.m) >= minutes && Number(b.dataset.m) - minutes < 15));
}
$('#screen-on').onclick = () => { closeSheets(); send('screenon', {}, 'tap'); };
$('#screen-off').onclick = () => { closeSheets(); send('screenoff', {}, 'tap'); };

let sleepArmed = false;
function resetSleep() { sleepArmed = false; $('#sleep').classList.remove('danger'); $('#sleep').textContent = 'Sleep Mac'; }
$('#sleep').onclick = () => {
  if (!sleepArmed) { sleepArmed = true; haptic('tick'); $('#sleep').classList.add('danger'); $('#sleep').textContent = 'Tap again to sleep the Mac'; return; }
  closeSheets(); send('sleep', {}, 'tap');
};

// Tabs
function tab(which) {
  $('#tab-click').classList.toggle('on', which === 'click');
  $('#tab-touch').classList.toggle('on', which === 'touch');
  $('#clickpad').style.display = which === 'click' ? 'block' : 'none';
  $('#touchpad').style.display = which === 'touch' ? 'block' : 'none';
  try { localStorage.setItem('mactvTab', which); } catch {}
}
$('#tab-click').onclick = () => { haptic('tick'); tab('click'); };
$('#tab-touch').onclick = () => { haptic('tick'); tab('touch'); };
try { if (localStorage.getItem('mactvTab') === 'touch') tab('touch'); } catch {}

// Clickpad: tap an arrow on the ring or swipe anywhere; hold an arrow to repeat; tap the middle
// for OK. Taps outside the ring do nothing.
(() => {
  const pad = $('#clickpad');
  pad.querySelectorAll('button').forEach(button => button.addEventListener('click', e => {
    // Pointer gestures are handled below; keyboard/assistive activation produces detail=0.
    if (e.detail === 0) send(button.dataset.dir || 'ok', {}, 'tap');
  }));
  let start = null, timer = null, repeated = false;
  const zoneAt = (x, y) => {
    const r = pad.getBoundingClientRect();
    const cx = x - (r.left + r.width / 2), cy = y - (r.top + r.height / 2);
    const distance = Math.hypot(cx, cy);
    if (distance < $('#ok').getBoundingClientRect().width / 2 + 8) return 'ok';
    if (distance > pad.querySelector('.ring').getBoundingClientRect().width / 2 + 6) return null;
    return Math.abs(cx) > Math.abs(cy) ? (cx > 0 ? 'right' : 'left') : (cy > 0 ? 'down' : 'up');
  };
  const flash = zone => {
    const el = zone === 'ok' ? $('#ok') : pad.querySelector(`[data-dir="${zone}"]`);
    el.classList.add('hit');
    setTimeout(() => el.classList.remove('hit'), 140);
  };
  const stop = () => { clearTimeout(timer); clearInterval(timer); timer = null; };
  pad.addEventListener('pointerdown', e => {
    pad.setPointerCapture(e.pointerId);
    start = { x: e.clientX, y: e.clientY, zone: zoneAt(e.clientX, e.clientY) };
    repeated = false;
    if (start.zone && start.zone !== 'ok') {
      timer = setTimeout(() => {
        repeated = true;
        timer = setInterval(() => { flash(start.zone); send(start.zone, {}, 'repeat'); }, 130);
      }, 420);
    }
  });
  pad.addEventListener('pointermove', e => {
    if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 24) stop();
  });
  pad.addEventListener('pointerup', e => {
    if (!start) return;
    stop();
    const dx = e.clientX - start.x, dy = e.clientY - start.y;
    let zone = start.zone;
    start = null;
    if (Math.hypot(dx, dy) > 28) zone = Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 'right' : 'left') : (dy > 0 ? 'down' : 'up');
    else if (repeated || !zone) return;
    flash(zone);
    send(zone, {}, zone === 'ok' ? 'tap' : 'tick');
  });
  const cancelHold = () => { stop(); start = null; };
  pad.addEventListener('pointercancel', cancelHold);
  pad.addEventListener('lostpointercapture', cancelHold);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState !== 'visible') cancelHold(); });
})();

// Touchpad: one finger moves the pointer, tap clicks, two fingers scroll.
(() => {
  const tp = $('#touchpad');
  const fingers = new Map();
  let travel = 0, downAt = 0, multi = false, timer = 0, inFlight = null;
  let acc = { dx: 0, dy: 0, sy: 0 };
  const flush = () => {
    clearTimeout(timer);
    timer = 0;
    if (inFlight) return inFlight;
    inFlight = (async () => {
      // Keep fractional remainders so frequent small movements are not rounded away.
      while (true) {
        const dx = Math.round(acc.dx), dy = Math.round(acc.dy), sy = Math.round(acc.sy * -3);
        if (!dx && !dy && !sy) break;
        acc.dx -= dx; acc.dy -= dy; acc.sy += sy / 3;
        // One request at a time, including when a gesture changes from moving to scrolling.
        if (dx || dy) await api('/cmd', { a: 'pointer', dx, dy }).catch(() => {});
        if (sy) await api('/cmd', { a: 'scroll', dy: sy }).catch(() => {});
      }
    })().finally(() => { inFlight = null; });
    return inFlight;
  };
  tp.addEventListener('pointerdown', e => {
    tp.setPointerCapture(e.pointerId);
    if (fingers.size === 0) { travel = 0; downAt = Date.now(); multi = false; }
    fingers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (fingers.size > 1) multi = true;
  });
  tp.addEventListener('pointermove', e => {
    const f = fingers.get(e.pointerId);
    if (!f) return;
    const dx = e.clientX - f.x, dy = e.clientY - f.y;
    f.x = e.clientX; f.y = e.clientY;
    travel += Math.abs(dx) + Math.abs(dy);
    if (fingers.size > 1) acc.sy += dy / fingers.size;
    else { const gain = 1.6 + Math.min(Math.hypot(dx, dy) / 6, 3); acc.dx += dx * gain; acc.dy += dy * gain; }
    if (!timer) timer = setTimeout(flush, 33);
  });
  const lift = e => {
    if (!fingers.delete(e.pointerId)) return;
    if (fingers.size === 0 && e.type === 'pointerup' && !multi && travel < 8 && Date.now() - downAt < 300) {
      // Deliver the last movement before the tap, even on a slow connection.
      flush().then(() => send('click', {}, 'tap'));
    }
  };
  tp.addEventListener('pointerup', lift);
  tp.addEventListener('pointercancel', lift);
})();

// Old installations stored the shared six-digit code; exchange it automatically during migration.
const initialCode = /^\d{6}$/.test(qrCode) ? qrCode : (/^\d{6}$/.test(key) ? key : '');
if (initialCode) {
  if (/^\d{6}$/.test(key)) { key = ''; store.set(''); }
  pair(initialCode, 'Phone').catch(() => { $('#code').value = ''; showPair(); });
} else { refresh(); }
setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, 3000);
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') refresh(); });
