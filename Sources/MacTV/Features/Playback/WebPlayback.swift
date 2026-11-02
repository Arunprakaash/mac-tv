/// A per-frame bridge for controlling ordinary HTML video, including cross-origin embeds.
/// Inject at document start in every frame. The main frame probes visible descendants,
/// selects one video, and sends exactly one command to its frame. No media URLs are read.
enum WebPlayback {
    static let script = #"""
    (() => {
      if (window.__macTVPlaybackInstalled) return;
      window.__macTVPlaybackInstalled = true;
      const marker = '__macTVPlaybackV1';
      const seen = new Set();
      const pending = new Map();
      const visible = el => {
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        return r.width >= 8 && r.height >= 8 && r.right > 0 && r.bottom > 0 &&
          r.left < innerWidth && r.top < innerHeight && s.display !== 'none' &&
          s.visibility !== 'hidden' && Number(s.opacity) > 0.05;
      };
      function bestVideo() {
        let best = null, score = -1;
        for (const v of document.querySelectorAll('video')) {
          if (!visible(v) || v.readyState === 0 || v.ended) continue;
          const r = v.getBoundingClientRect();
          const area = Math.min(1, r.width * r.height / Math.max(1, innerWidth * innerHeight));
          const value = (!v.paused ? 2 : 0) + area;
          if (value > score) { score = value; best = v; }
        }
        return best && { video: best, score };
      }
      function reply(data) { window.top.postMessage({ marker, ...data }, '*'); }
      window.addEventListener('message', e => {
        const m = e.data;
        if (!m || m.marker !== marker || typeof m.id !== 'string') return;
        if (m.type === 'probe') {
          // Only the top frame may initiate a probe; descendants relay it downward.
          if (e.source !== window && e.source !== window.parent) return;
          if (seen.has(m.id) || !Number.isInteger(m.depth) || m.depth > 6) return;
          seen.add(m.id);
          setTimeout(() => seen.delete(m.id), 2000);
          const best = bestVideo();
          if (best) reply({ type: 'candidate', id: m.id, score: best.score });
          if (m.depth < 6) {
            for (const frame of [...document.querySelectorAll('iframe')].filter(visible).slice(0, 32)) {
              try { frame.contentWindow?.postMessage({ marker, type: 'probe', id: m.id, depth: m.depth + 1 }, '*'); } catch (_) {}
            }
          }
        } else if (m.type === 'candidate' && window === window.top) {
          const p = pending.get(m.id);
          if (p && typeof m.score === 'number' && Number.isFinite(m.score) && e.source &&
              (!p.best || m.score > p.best.score)) p.best = { source: e.source, score: m.score };
        } else if (m.type === 'execute' && e.source === window.top) {
          const best = bestVideo();
          if (!best) { reply({ type: 'result', id: m.id, result: 'none' }); return; }
          const v = best.video;
          try {
            if (m.command === 'toggle') {
              if (v.paused) {
                Promise.resolve(v.play()).then(() => reply({ type: 'result', id: m.id, result: 'playing' }),
                  () => reply({ type: 'result', id: m.id, result: 'unsupported' }));
              } else { v.pause(); reply({ type: 'result', id: m.id, result: 'paused' }); }
            } else if (m.command === 'backward' || m.command === 'forward') {
              if (!Number.isFinite(v.currentTime) || !v.seekable.length) throw Error('not seekable');
              const start = v.seekable.start(0), end = v.seekable.end(v.seekable.length - 1);
              v.currentTime = Math.max(start, Math.min(end, v.currentTime + (m.command === 'forward' ? 10 : -10)));
              reply({ type: 'result', id: m.id, result: 'seeked' });
            } else reply({ type: 'result', id: m.id, result: 'unsupported' });
          } catch (_) { reply({ type: 'result', id: m.id, result: 'unsupported' }); }
        } else if (m.type === 'result' && window === window.top) {
          const p = pending.get(m.id);
          if (p && p.best && e.source === p.best.source &&
              ['none', 'playing', 'paused', 'seeked', 'unsupported'].includes(m.result)) p.finish(m.result);
        }
      });
      if (window === window.top) {
        window.__macTVPlayback = command => {
          if (!['toggle', 'forward', 'backward'].includes(command)) return Promise.resolve('unsupported');
          const id = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
          return new Promise(resolve => {
            let done = false;
            const finish = result => { if (done) return; done = true; pending.delete(id); resolve(result); };
            const p = { best: null, finish };
            pending.set(id, p);
            window.postMessage({ marker, type: 'probe', id, depth: 0 }, '*');
            setTimeout(() => {
              if (!p.best) { finish('none'); return; }
              p.best.source.postMessage({ marker, type: 'execute', id, command }, '*');
              setTimeout(() => finish('unsupported'), 500);
            }, 160);
          });
        };
      }
    })();
    """#
}
