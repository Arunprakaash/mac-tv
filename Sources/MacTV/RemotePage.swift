/// The phone remote. Any phone browser opens it; "Add to Home Screen" makes it feel like an app.
enum RemotePage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Mac TV">
    <meta name="theme-color" content="#0a0b0e">
    <title>Mac TV Remote</title>
    <link rel="apple-touch-icon" href="/appicon.png">
    <link rel="icon" type="image/png" href="/appicon.png">
    <link rel="manifest" href="/manifest.webmanifest">
    <style>
      :root {
        --bg:#07080b; --glass:rgba(255,255,255,.09); --line:rgba(255,255,255,.14);
        /* Apple TV's Liquid Glass: blur and saturate what's behind, with a bright top edge. */
        --blur:blur(28px) saturate(170%); --sheen:inset 0 1px 0 rgba(255,255,255,.28), inset 0 -1px 1px rgba(255,255,255,.05);
        /* Soft colour behind everything, so the glass has something to show. */
        --ambient:radial-gradient(70vmax 60vmax at 10% 0%, rgba(70,110,255,.30), transparent 70%),
                  radial-gradient(60vmax 60vmax at 100% 55%, rgba(170,80,255,.20), transparent 70%),
                  radial-gradient(60vmax 50vmax at 20% 100%, rgba(0,190,170,.14), transparent 70%), #07080b;
        --fg:#fff; --dim:rgba(255,255,255,.62); --ok:#3ddc84; --warn:#ff6b6b;
        /* Controls size with the phone: round keys from 52 to 68px, spacing from the screen height. */
        --key:clamp(52px, 16vw, 68px); --gap:clamp(10px, 1.7dvh, 16px);
      }
      * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; -webkit-user-select:none; user-select:none; }
      html, body { margin:0; height:100%; color:var(--fg); font:16px/1.3 -apple-system, system-ui, Roboto, sans-serif; background:var(--bg); overscroll-behavior:none; }
      body { background:var(--ambient); background-attachment:fixed; }
      main { width:100%; max-width:460px; min-height:100dvh; margin:0 auto; padding:calc(env(safe-area-inset-top) + 14px) clamp(14px, 5vw, 22px) calc(env(safe-area-inset-bottom) + 18px); display:flex; flex-direction:column; gap:var(--gap); touch-action:manipulation; }
      button { font:inherit; color:inherit; cursor:pointer; transition:transform .08s, background-color .08s; }
      .pressed { transform:scale(.93); }
      .round { width:44px; height:44px; border-radius:50%; border:1px solid var(--line); background:var(--glass); -webkit-backdrop-filter:var(--blur); backdrop-filter:var(--blur); box-shadow:var(--sheen); display:grid; place-items:center; }
      /* tvOS focus: a press lights the control up as a white platter. */
      .round.pressed, .key.pressed, .pill.pressed, .row-btn.pressed { background:#fff; color:#000; }
      header { display:flex; align-items:center; justify-content:space-between; gap:12px; }
      header h1 { margin:0; font-size:20px; font-weight:800; letter-spacing:-.02em; line-height:0; }
      /* The app icon stands in for the name at the top of the remote. */
      header h1 img { width:44px; height:44px; display:block; filter:drop-shadow(0 4px 8px rgba(0,0,0,.35)); }
      .status[hidden] { display:none; }
      .status { display:flex; align-items:center; gap:6px; font-size:12px; font-weight:500; color:var(--dim); margin-top:2px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      .dot { width:7px; height:7px; border-radius:50%; background:var(--warn); flex:none; }
      .actions { display:flex; gap:10px; flex:none; }
      /* A segmented pill: the selected pill sits inside the track with the same inset on every side. */
      .tabs { display:grid; grid-template-columns:1fr 1fr; gap:4px; padding:4px; height:46px; flex:none; border-radius:999px; background:var(--glass); border:1px solid var(--line); -webkit-backdrop-filter:var(--blur); backdrop-filter:var(--blur); box-shadow:var(--sheen); }
      .tabs button { height:100%; padding:0; border:0; border-radius:999px; background:transparent; color:rgba(255,255,255,.75); font-size:14px; font-weight:600; transition:background-color .2s, color .2s; }
      .tabs button.on { background:#fff; color:#000; box-shadow:0 1px 3px rgba(0,0,0,.3); }
      /* The touch surface takes whatever height is left, so the remote fills any phone. */
      .surface { position:relative; flex:1 1 auto; min-height:210px; max-height:440px; border-radius:34px; background:rgba(255,255,255,.06); border:1px solid var(--line); -webkit-backdrop-filter:var(--blur); backdrop-filter:var(--blur); box-shadow:var(--sheen); overflow:hidden; touch-action:none; }
      /* The ring is centred and sized to fit the surface; arrows and OK sit on it. */
      #clickpad .ring { position:absolute; left:50%; top:50%; width:min(260px, 70vw); max-height:86%; aspect-ratio:1; transform:translate(-50%, -50%); border-radius:50%; border:1.5px solid rgba(255,255,255,.14); pointer-events:none; }
      #clickpad .chev { background:none; border:0; padding:0; min-width:44px; min-height:44px; position:absolute; width:40px; height:40px; display:grid; place-items:center; color:rgba(255,255,255,.55); transition:color .12s, scale .12s; }
      #clickpad .chev.hit { color:#fff; scale:1.25; }
      #clickpad .up { left:50%; top:4%; translate:-50% 0; } #clickpad .down { left:50%; bottom:4%; translate:-50% 0; }
      #clickpad .left { top:50%; left:4%; translate:0 -50%; } #clickpad .right { top:50%; right:4%; translate:0 -50%; }
      #clickpad .ok { position:absolute; left:50%; top:50%; width:38%; aspect-ratio:1; translate:-50% -50%; border-radius:50%; border:1px solid rgba(255,255,255,.16); background:rgba(255,255,255,.1); box-shadow:inset 0 1px 0 rgba(255,255,255,.18), 0 10px 24px rgba(0,0,0,.35); display:grid; place-items:center; font-weight:700; font-size:15px; transition:background .12s, scale .12s; }
      #clickpad .ok.hit { background:#fff; color:#000; scale:.94; }
      #touchpad { display:none; }
      #touchpad .hint { position:absolute; left:0; right:0; bottom:18px; text-align:center; font-size:13px; font-weight:500; color:rgba(255,255,255,.55); pointer-events:none; padding:0 16px; }
      .keys { display:grid; grid-template-columns:repeat(4, 1fr); gap:var(--gap) 8px; justify-items:center; flex:none; }
      .key { width:var(--key); height:var(--key); border-radius:50%; border:1px solid var(--line); background:var(--glass); -webkit-backdrop-filter:var(--blur); backdrop-filter:var(--blur); display:grid; place-items:center; box-shadow:var(--sheen); }
      .key.primary { background:#fff; color:#000; }
      .key.primary.pressed { background:#d9d9d9; }
      .key svg, .round svg { width:22px; height:22px; }
      .type { display:flex; align-items:center; gap:8px; height:52px; flex:none; padding:0 6px 0 16px; border-radius:999px; background:var(--glass); border:1px solid var(--line); -webkit-backdrop-filter:var(--blur); backdrop-filter:var(--blur); box-shadow:var(--sheen); color:var(--dim); }
      .type input { flex:1; min-width:0; border:0; outline:0; background:transparent; color:#fff; font:500 16px -apple-system, system-ui, sans-serif; -webkit-user-select:text; user-select:text; }
      .type button { width:40px; height:40px; border:0; border-radius:12px; background:transparent; display:grid; place-items:center; color:#fff; }
      /* Short phones: a smaller touch surface so the controls fit without scrolling. */
      @media (max-height: 640px) { .surface { min-height:180px; } }

      .scrim { position:fixed; inset:0; background:rgba(0,0,0,.5); -webkit-backdrop-filter:blur(6px); backdrop-filter:blur(6px); display:none; flex-direction:column; justify-content:flex-end; z-index:5; }
      .scrim.show { display:flex; }
      .sheet { max-width:460px; width:100%; max-height:88dvh; overflow-y:auto; margin:0 auto; padding:20px 18px calc(env(safe-area-inset-bottom) + 24px); border-radius:28px 28px 0 0; background:rgba(28,30,40,.86); -webkit-backdrop-filter:blur(40px) saturate(180%); backdrop-filter:blur(40px) saturate(180%); border-top:1px solid rgba(255,255,255,.18); box-shadow:var(--sheen); display:flex; flex-direction:column; gap:14px; }
      .sheet > * { flex-shrink:0; }
      .sheet-head { display:flex; align-items:center; justify-content:space-between; gap:10px; }
      .sheet-head > span { font-size:18px; font-weight:800; }
      .sheet-head > div { display:flex; gap:8px; }
      .pill { height:36px; padding:0 14px; border:0; border-radius:999px; background:rgba(255,255,255,.12); font-size:14px; font-weight:600; }
      .pill.on { background:#fff; color:#000; }
      .apps { display:grid; grid-template-columns:repeat(auto-fill, minmax(72px, 1fr)); gap:16px 12px; }
      .app { position:relative; border:0; background:none; padding:0; display:flex; flex-direction:column; gap:6px; align-items:center; font-size:12px; font-weight:600; color:var(--dim); text-align:center; }
      .app .art { width:100%; aspect-ratio:1; border-radius:23%; background:#2a2d36; display:grid; place-items:center; font-size:26px; font-weight:800; color:#fff; overflow:hidden; box-shadow:0 0 0 1px rgba(255,255,255,.08); }
      .app .art img { width:100%; height:100%; display:block; }
      .app .favourite { position:absolute; top:-6px; right:-6px; width:24px; height:24px; border-radius:50%; background:#ffd60a; color:#241d00; display:grid; place-items:center; font-size:15px; line-height:1; box-shadow:0 2px 6px rgba(0,0,0,.4); }
      .apps.editing { grid-template-columns:1fr; gap:12px; }
      .app-editor { padding:12px; border:1px solid var(--line); border-radius:20px; background:rgba(255,255,255,.05); }
      .app-editor-head { display:flex; align-items:center; gap:12px; margin-bottom:12px; min-width:0; }
      .app-editor-head .app { width:48px; flex:none; }
      .app-editor-name { font-size:16px; font-weight:650; overflow-wrap:anywhere; }
      .app-actions { display:grid; grid-template-columns:repeat(2, minmax(0, 1fr)); gap:8px; }
      .app-actions button { min-height:44px; min-width:44px; padding:10px 8px; border:0; border-radius:12px; background:rgba(255,255,255,.1); font-size:14px; font-weight:600; }
      .app-actions .pin[aria-pressed="true"] { color:#ffe991; background:rgba(255,214,10,.13); }
      .app-actions .remove { color:#ffd0d0; background:rgba(255,107,107,.13); }
      .app-actions button:disabled, #edit-apps:disabled, #restore:disabled { opacity:.4; cursor:default; }
      #apps-sheet button:focus-visible { outline:3px solid #8ec7ff; outline-offset:3px; }
      #apps-sheet .pill { min-height:44px; }
      .app.add .art { background:transparent; border:2px dashed rgba(255,255,255,.25); box-shadow:none; color:var(--dim); font-weight:400; font-size:34px; }
      .editing .app.add { display:none; }
      .row-btn { height:52px; border:0; border-radius:16px; background:rgba(255,255,255,.1); font-size:16px; font-weight:600; text-align:left; padding:0 18px; }
      .row-btn.danger { background:rgba(255,107,107,.22); color:#ffd0d0; }
      .note { font-size:13px; color:var(--dim); line-height:1.4; margin:0; padding:0 4px; }
      .note.ok { color:var(--ok); } .note.err { color:var(--warn); }
      .group-label { font-size:12px; font-weight:700; letter-spacing:.07em; text-transform:uppercase; color:var(--dim); margin:6px 4px -4px; }
      .chips { display:flex; flex-wrap:wrap; gap:8px; }
      .chips button { height:40px; padding:0 16px; border:0; border-radius:999px; background:rgba(255,255,255,.1); font-size:14px; font-weight:600; }
      .chips button.on { background:#fff; color:#000; }
      .toggle { display:flex; align-items:center; justify-content:space-between; gap:12px; min-height:54px; padding:0 14px 0 16px; border-radius:16px; background:rgba(255,255,255,.07); font-size:15px; font-weight:600; }
      .toggle input { appearance:none; -webkit-appearance:none; flex:none; position:relative; width:48px; height:28px; margin:0; border-radius:999px; background:rgba(255,255,255,.22); transition:background .15s; cursor:pointer; }
      .toggle input::before { content:""; position:absolute; top:3px; left:3px; width:22px; height:22px; border-radius:50%; background:#fff; transition:transform .15s; box-shadow:0 1px 3px rgba(0,0,0,.4); }
      .toggle input:checked { background:var(--ok); }
      .toggle input:checked::before { transform:translateX(20px); }
      .cancel { height:50px; border:0; border-radius:999px; background:#fff; color:#000; font-weight:700; }
      .field { width:100%; height:50px; border-radius:14px; border:1px solid rgba(255,255,255,.14); background:rgba(255,255,255,.06); color:#fff; padding:0 14px; font:500 16px -apple-system, system-ui, sans-serif; -webkit-user-select:text; user-select:text; outline:0; }
      .field:focus { border-color:rgba(255,255,255,.4); }
      .sheet form { display:flex; flex-direction:column; gap:10px; margin:0; }
      .list { display:flex; flex-direction:column; gap:6px; }
      .list button { display:flex; align-items:center; justify-content:space-between; gap:10px; height:50px; border:0; border-radius:14px; background:rgba(255,255,255,.07); padding:0 16px; font-size:15px; font-weight:600; text-align:left; }
      .list button span:last-child { font-size:12px; color:var(--dim); font-weight:600; }
      .list button[disabled] { opacity:.5; }
      .file-path { color:var(--dim); font-size:13px; overflow-wrap:anywhere; }
      .file-list button { min-height:50px; height:auto; padding:12px 16px; }
      .file-list button span:first-child { overflow-wrap:anywhere; min-width:0; }
      .file-actions { display:grid; gap:8px; }
      .file-actions button { min-height:48px; }
      #files-sheet button:focus-visible { outline:3px solid #8ec7ff; outline-offset:3px; }
      #pair { position:fixed; inset:0; background:var(--ambient); display:none; flex-direction:column; justify-content:center; gap:14px; padding:24px; text-align:center; z-index:9; }
      #pair.show { display:flex; }
      #pair h1 { margin:0; font-size:26px; }
      #pair p { margin:0; color:var(--dim); }
      #pair input:not([type="checkbox"]) { font:600 30px -apple-system, system-ui, Roboto, sans-serif; font-variant-numeric:tabular-nums; letter-spacing:.3em; text-align:center; background:var(--glass); color:#fff; border:1px solid rgba(255,255,255,.2); border-radius:14px; height:64px; -webkit-user-select:text; user-select:text; }
      #pair #device-name { font-size:16px; letter-spacing:normal; height:48px; }
      #pair label { color:var(--dim); font-size:14px; }
      #pair button { height:52px; border:0; border-radius:999px; background:#fff; color:#000; font-weight:700; }
    </style>
    </head>
    <body>
    <main>
      <header>
        <div style="min-width:0">
          <h1><img src="/appicon.png" alt="Mac TV"></h1>
          <div class="status" hidden><span class="dot" id="dot"></span><span id="status"></span></div>
        </div>
        <div class="actions">
          <button class="round" id="open-apps" aria-label="Apps"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/></svg></button>
          <button class="round" id="open-power" aria-label="Power"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v9"/><path d="M6.3 7.3a8 8 0 1 0 11.4 0"/></svg></button>
        </div>
      </header>

      <div class="tabs" role="tablist" aria-label="Remote mode">
        <button role="tab" id="tab-click" class="on">Clickpad</button>
        <button role="tab" id="tab-touch">Touchpad</button>
      </div>

      <div class="surface" id="clickpad" aria-label="Swipe or tap an arrow to move, tap the middle to select">
        <div class="ring">
        <button type="button" class="chev up" data-dir="up" aria-label="Move up"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6 15l6-6 6 6"/></svg></button>
        <button type="button" class="chev down" data-dir="down" aria-label="Move down"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg></button>
        <button type="button" class="chev left" data-dir="left" aria-label="Move left"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M15 6l-6 6 6 6"/></svg></button>
        <button type="button" class="chev right" data-dir="right" aria-label="Move right"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg></button>
        <button type="button" class="ok" id="ok" aria-label="Select">OK</button>
        </div>
      </div>
      <div class="surface" id="touchpad"><div class="hint">Drag to move · tap to click · two fingers to scroll</div></div>

      <div class="keys">
        <button class="key" data-a="back" aria-label="Back"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 6l-6 6 6 6"/></svg></button>
        <button class="key" data-a="home" aria-label="Home"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 10.5L12 3l9 7.5"/><path d="M5 9.5V21h14V9.5"/></svg></button>
        <button class="key primary" data-a="playpause" data-h="tap" aria-label="Play or pause"><svg viewBox="0 0 24 24" fill="#000"><path d="M3 5v14l8-7z"/><rect x="14" y="5" width="3" height="14" rx="1"/><rect x="19" y="5" width="3" height="14" rx="1"/></svg></button>
        <button class="key" data-a="mute" aria-label="Mute"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5L6 9H3v6h3l5 4z"/><path d="M22 9l-6 6M16 9l6 6"/></svg></button>
        <button class="key" data-a="rewind" aria-label="Back 10 seconds"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 6v12l-8-6z"/><path d="M21 6v12l-8-6z"/></svg></button>
        <button class="key" data-a="voldown" aria-label="Volume down"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5L6 9H3v6h3l5 4z"/><path d="M16 12h5"/></svg></button>
        <button class="key" data-a="volup" aria-label="Volume up"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5L6 9H3v6h3l5 4z"/><path d="M16 12h5M18.5 9.5v5"/></svg></button>
        <button class="key" data-a="forward" aria-label="Forward 10 seconds"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 6v12l8-6z"/><path d="M3 6v12l8-6z"/></svg></button>
      </div>

      <form class="type" id="type" autocomplete="off">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/></svg>
        <input id="typed" placeholder="Type on the TV…" aria-label="Type on the TV" enterkeyhint="send" autocapitalize="off" autocorrect="off" spellcheck="false">
        <button type="button" data-a="backspace" aria-label="Delete"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 5H8l-6 7 6 7h13z"/><path d="M17 9l-6 6M11 9l6 6"/></svg></button>
      </form>
    </main>

    <div class="scrim" id="apps-sheet">
      <div class="sheet" role="dialog" aria-label="Apps">
        <div class="sheet-head"><span id="apps-title">Open on TV</span><div><button class="pill" id="edit-apps">Edit</button><button class="pill" data-close>Done</button></div></div>
        <button class="row-btn" id="open-files">📁  Files on Mac</button>
        <div class="apps" id="apps"></div>
        <p class="note" id="edit-note" hidden>Pinned favourites appear first. Move apps within favourites or other apps. Removed built-in apps can be restored.</p>
        <p class="note" id="apps-msg" role="status" aria-live="polite" hidden></p>
        <button class="row-btn" id="restore" hidden>Restore built-in apps</button>
      </div>
    </div>

    <div class="scrim" id="files-sheet">
      <div class="sheet" role="dialog" aria-label="Files on Mac">
        <div class="sheet-head"><span>Files on Mac</span><div><button class="pill" id="files-back">Back</button><button class="pill" data-close>Done</button></div></div>
        <div class="file-path" id="files-path"></div>
        <input class="field" id="files-filter" placeholder="Filter filenames" aria-label="Filter filenames" autocapitalize="off" autocorrect="off" spellcheck="false">
        <p class="note" id="files-msg" role="status" aria-live="polite"></p>
        <div class="list file-list" id="files-list"></div>
        <button class="row-btn" id="files-more" hidden>Load more</button>
        <div id="movie-options" hidden>
          <div class="group-label">Selected video</div>
          <p id="movie-name"></p>
          <div class="file-actions">
            <button class="row-btn" id="play-native">Play on Mac TV</button>
            <button class="row-btn" id="play-iina">Play in IINA</button>
            <button class="row-btn" id="subtitle-options">Subtitle options</button>
          </div>
        </div>
        <div id="subtitle-panel" hidden>
          <div class="group-label">Subtitles</div>
          <p class="note">Choose a subtitle from this folder or upload a UTF-8 .srt file from your phone (up to 256 KB). Applying a subtitle opens the video in IINA.</p>
          <div class="list file-list" id="subtitle-list"></div>
          <input id="subtitle-upload" type="file" accept=".srt,text/plain" aria-label="Upload subtitle file">
          <div class="file-actions">
            <button class="row-btn" id="subtitle-search-iina">Search in IINA</button>
            <button class="row-btn" id="subtitle-search-web">Search subtitles on phone</button>
          </div>
        </div>
      </div>
    </div>

    <div class="scrim" id="add-sheet">
      <div class="sheet" role="dialog" aria-label="Add an app">
        <div class="sheet-head"><span>Add an app</span><div><button class="pill" data-close>Cancel</button></div></div>
        <div class="tabs" role="tablist">
          <button role="tab" id="add-web-tab" class="on">Website</button>
          <button role="tab" id="add-mac-tab">Mac app</button>
        </div>
        <form id="web-form" autocomplete="off">
          <input class="field" id="web-url" inputmode="url" placeholder="Website, e.g. crunchyroll.com" aria-label="Website address" autocapitalize="off" autocorrect="off" spellcheck="false">
          <input class="field" id="web-name" placeholder="Name (optional)" aria-label="Name">
          <button class="cancel" type="submit">Add to TV</button>
          <p class="note">Mac TV looks up the app's official icon for you.</p>
        </form>
        <div id="mac-form" hidden>
          <input class="field" id="mac-q" placeholder="Search apps on the Mac" aria-label="Search apps on the Mac" autocapitalize="off" autocorrect="off" spellcheck="false">
          <div class="list" id="mac-list" style="margin-top:10px"></div>
        </div>
        <p class="note" id="add-msg"></p>
      </div>
    </div>

    <div class="scrim" id="power-sheet">
      <div class="sheet" role="dialog" aria-label="TV controls">
        <div class="sheet-head"><span>TV controls</span><div><button class="pill" data-close>Done</button></div></div>
        <div class="group-label">Sleep timer</div>
        <div class="chips" id="sleep-chips">
          <button data-m="0">Off</button><button data-m="15">15 min</button><button data-m="30">30 min</button><button data-m="60">1 hour</button><button data-m="90">1½ hours</button>
        </div>
        <p class="note" id="sleep-left">When it ends, playback stops and the screen turns off.</p>
        <div class="group-label">Playback</div>
        <label class="toggle"><span>Skip intros and recaps</span><input type="checkbox" id="auto-skip"></label>
        <label class="toggle"><span>Play next episode automatically</span><input type="checkbox" id="auto-next"></label>
        <p class="note">Applies the next time you open an app.</p>
        <div class="group-label">Power</div>
        <p class="note" id="lid-status"></p>
        <label class="toggle"><span>Keep Mac awake while Mac TV is open</span><input type="checkbox" id="keep-awake"></label>
        <label class="toggle"><span>Stay awake with lid closed</span><input type="checkbox" id="lid-override"></label>
        <p class="note">Works on battery and without the TV connected. Turns off by itself when the battery is low or the Mac gets hot.</p>
        <div class="group-label">Paired devices</div>
        <div id="devices"></div>
        <button class="row-btn danger" id="revoke-all">Remove all paired devices</button>
        <p class="note" id="devices-msg"></p>
        <button class="row-btn" id="screen-off">Turn screen off</button>
        <button class="row-btn" id="sleep">Sleep Mac</button>
        <p class="note">After sleep, wake the Mac with its keyboard or by opening the lid.</p>
      </div>
    </div>

    <div id="pair">
      <h1>Pair with your TV</h1>
      <p>Enter the 6-digit code from Settings on the TV.</p>
      <input id="code" inputmode="numeric" maxlength="6" autocomplete="one-time-code" aria-label="Pairing code">
      <input id="device-name" maxlength="60" placeholder="Device name (optional)" aria-label="Device name">
      <label><input type="checkbox" id="guest"> Guest access (expires in 24 hours)</label>
      <button id="pair-btn">Pair</button>
      <p id="pair-err"></p>
    </div>

    <script>
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
    if (qrCode) history.replaceState(null, '', location.pathname);
    let key = store.get();

    // The status line only shows when something's wrong.
    function online(ok) {
      $('.status').hidden = ok;
      $('#status').textContent = ok ? '' : 'Can’t reach the TV';
    }

    async function api(path, body) {
      const res = await fetch(path, {
        method: body ? 'POST' : 'GET',
        headers: { 'Content-Type': 'application/json', 'X-Couch-Key': key },
        body: body ? JSON.stringify(body) : undefined,
      });
      if (res.status === 401) { showPair(); throw new Error('unpaired'); }
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || res.statusText);
      return data;
    }

    function send(a, extra, kind = 'tick') {
      haptic(kind);
      return api('/cmd', { a, ...extra }).catch(e => {
        if (e.message !== 'unpaired') { online(false); haptic('error'); }
      });
    }

    // State: connection, the app list, settings.
    let appsShown = '', apps = [], canRestore = false, currentLocalMovie = null, iinaInstalled = false;
    let stateGeneration = 0, appMutationPending = false;
    async function refresh(duringMutation = false) {
      if (appMutationPending && !duringMutation) return false;
      if (!key) return showPair();
      const generation = ++stateGeneration;
      try {
        const s = await api('/state');
        // A newer refresh or an edit invalidates an older in-flight response.
        if (generation !== stateGeneration) return false;
        online(true);
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
        const sig = JSON.stringify([s.apps, s.canRestore]);
        if (sig !== appsShown) {
          appsShown = sig;
          if (!appMutationPending) renderApps(focused);
        }
        return true;
      } catch (e) {
        if (generation === stateGeneration && e.message !== 'unpaired') online(false);
        return false;
      }
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
    function showPair() { $('#pair').classList.add('show'); setTimeout(() => $('#code').focus(), 50); }
    async function pair(code, name, guest) {
      const res = await fetch('/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code, name, guest }) });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || res.statusText);
      key = data.token;
      store.set(key);
      $('#pair').classList.remove('show');
      $('#pair-err').textContent = '';
      $('#code').value = '';
      return refresh();
    }
    $('#pair-btn').onclick = async () => {
      try { await pair($('#code').value.trim(), $('#device-name').value.trim(), $('#guest').checked); haptic('tap'); }
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
    $('#revoke-all').onclick = async () => {
      if (!confirm('Remove all paired devices, including this one?')) return;
      try { await api('/devices/revoke-all', {}); key = ''; store.set(''); closeSheets(); showPair(); }
      catch (e) { $('#devices-msg').textContent = e.message; }
    };

    // Buttons
    document.querySelectorAll('[data-a]').forEach(b => b.addEventListener('click', () => send(b.dataset.a, {}, b.dataset.h || 'tick')));
    $('#type').onsubmit = e => {
      e.preventDefault();
      const t = $('#typed').value;
      if (t) send('text', { t }, 'tap');
      $('#typed').value = '';
    };

    // Sheets
    const closeSheets = () => {
      document.querySelectorAll('.scrim').forEach(s => s.classList.remove('show'));
      if (editing) { editing = false; renderApps(); }
    };
    document.querySelectorAll('.scrim').forEach(s => s.addEventListener('click', e => { if (e.target === s) closeSheets(); }));
    document.querySelectorAll('[data-close]').forEach(b => b.onclick = closeSheets);
    $('#open-apps').onclick = () => { haptic('tick'); refresh(); $('#apps-sheet').classList.add('show'); };
    $('#open-power').onclick = () => { haptic('tick'); resetSleep(); refresh(); loadDevices(); $('#power-sheet').classList.add('show'); };
    document.querySelectorAll('#sleep-chips button').forEach(b => b.onclick = () => {
      const m = Number(b.dataset.m);
      send('sleeptimer', { m }, 'tap').then(refresh);
      showSleep(m);
    });
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
      pad.addEventListener('pointercancel', () => { stop(); start = null; });
    })();

    // Touchpad: one finger moves the pointer, tap clicks, two fingers scroll.
    (() => {
      const tp = $('#touchpad');
      const fingers = new Map();
      let travel = 0, downAt = 0, multi = false, timer = 0;
      let acc = { dx: 0, dy: 0, sy: 0 };
      const flush = () => {
        timer = 0;
        const { dx, dy, sy } = acc;
        acc = { dx: 0, dy: 0, sy: 0 };
        if (dx || dy) api('/cmd', { a: 'pointer', dx: Math.round(dx), dy: Math.round(dy) }).catch(() => {});
        if (sy) api('/cmd', { a: 'scroll', dy: Math.round(-sy * 3) }).catch(() => {});
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
        if (fingers.size === 0 && !multi && travel < 8 && Date.now() - downAt < 300) send('click', {}, 'tap');
      };
      tp.addEventListener('pointerup', lift);
      tp.addEventListener('pointercancel', lift);
    })();

    // Old installations stored the shared six-digit code; exchange it automatically during migration.
    const initialCode = /^\d{6}$/.test(qrCode) ? qrCode : (/^\d{6}$/.test(key) ? key : '');
    if (initialCode) {
      if (/^\d{6}$/.test(key)) { key = ''; store.set(''); }
      pair(initialCode, 'Phone', false).catch(() => { $('#code').value = ''; showPair(); });
    } else { refresh(); }
    setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, 3000);
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') refresh(); });
    </script>
    </body>
    </html>
    """#
}
