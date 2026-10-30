/// D-pad navigation for websites built for a mouse: arrow keys move a visible focus ring
/// between links and buttons, Return activates. Stays out of the way while a video fills
/// the screen (so arrows seek) and while typing in a text field.
enum SpatialNav {
    static let script = #"""
    (() => {
      if (window.__couchNav) return;
      window.__couchNav = true;

      const SELECTOR = 'a[href], button, input, select, textarea, summary, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="option"], [tabindex]:not([tabindex="-1"])';
      const FOCUS = '__couch-focus';
      const DIRS = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' };
      let current = null;

      const addStyle = () => {
        const style = document.createElement('style');
        style.textContent = `.${FOCUS}{outline:4px solid #fff!important;outline-offset:3px!important;box-shadow:0 0 0 9px rgba(122,162,255,.55)!important;border-radius:8px}`;
        (document.head || document.documentElement).appendChild(style);
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', addStyle);
      else addStyle();

      const shown = el => {
        const r = el.getBoundingClientRect();
        if (r.width < 8 || r.height < 8) return false;
        if (r.bottom < -innerHeight || r.top > innerHeight * 2) return false;
        const s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && Number(s.opacity) > 0.05;
      };
      const videoFillsScreen = () => [...document.querySelectorAll('video')].some(v => {
        const r = v.getBoundingClientRect();
        return r.width * r.height > innerWidth * innerHeight * 0.85;
      });
      const typing = () => {
        const a = document.activeElement;
        return !!a && (a.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName));
      };
      const center = r => ({ x: r.left + r.width / 2, y: r.top + r.height / 2 });

      function focusOn(el) {
        if (current) current.classList.remove(FOCUS);
        current = el;
        el.classList.add(FOCUS);
        el.focus({ preventScroll: true });
        el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
      }

      function move(dir) {
        const candidates = [...document.querySelectorAll(SELECTOR)].filter(shown);
        if (!candidates.length) return false;

        if (!current || !document.contains(current) || !shown(current)) {
          const inView = candidates.filter(el => { const r = el.getBoundingClientRect(); return r.top >= 0 && r.top < innerHeight; });
          const pool = inView.length ? inView : candidates;
          pool.sort((a, b) => { const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect(); return (ra.top - rb.top) || (ra.left - rb.left); });
          focusOn(pool[0]);
          return true;
        }

        const a = current.getBoundingClientRect(), ca = center(a);
        let best = null, bestScore = Infinity;
        for (const el of candidates) {
          if (el === current || el.contains(current) || current.contains(el)) continue;
          const b = el.getBoundingClientRect(), cb = center(b);
          let gap, offAxis;
          if (dir === 'right') { if (b.left < a.right - 4) continue; gap = b.left - a.right; offAxis = Math.abs(cb.y - ca.y); }
          if (dir === 'left')  { if (b.right > a.left + 4) continue; gap = a.left - b.right; offAxis = Math.abs(cb.y - ca.y); }
          if (dir === 'down')  { if (b.top < a.bottom - 4) continue; gap = b.top - a.bottom; offAxis = Math.abs(cb.x - ca.x); }
          if (dir === 'up')    { if (b.bottom > a.top + 4) continue; gap = a.top - b.bottom; offAxis = Math.abs(cb.x - ca.x); }
          const score = Math.max(gap, 0) + offAxis * 2;
          if (score < bestScore) { bestScore = score; best = el; }
        }
        if (best) { focusOn(best); return true; }
        if (dir === 'up' || dir === 'down') {
          window.scrollBy({ top: (dir === 'down' ? 1 : -1) * innerHeight * 0.6, behavior: 'smooth' });
          return true;
        }
        return false;
      }

      window.addEventListener('keydown', e => {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        const dir = DIRS[e.key];
        if (!dir && e.key !== 'Enter') return;
        if (videoFillsScreen()) return;
        if (typing() && dir !== 'up' && dir !== 'down') return;
        if (dir) {
          if (move(dir)) { e.preventDefault(); e.stopImmediatePropagation(); }
          return;
        }
        if (current && document.contains(current)) {
          e.preventDefault();
          e.stopImmediatePropagation();
          if (/^(INPUT|TEXTAREA|SELECT)$/.test(current.tagName)) current.focus();
          else current.click();
        }
      }, true);
    })();
    """#
}
