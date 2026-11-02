/// D-pad navigation for websites built for a mouse: arrow keys move focus between links and
/// buttons, Return activates. Focus is shown by a ring drawn over the page, not by restyling
/// the page's own elements, so it looks the same on every site and slides from item to item
/// like Apple TV's focus. Stays out of the way while a video fills the screen (so arrows seek)
/// and while typing in a text field.
enum SpatialNav {
    static let script = #"""
    (() => {
      if (window.__couchNav) return;
      window.__couchNav = true;

      const SELECTOR = 'a[href], button, input, select, textarea, summary, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="option"], [tabindex]:not([tabindex="-1"])';
      const DIRS = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' };
      const PAD = 6;
      let current = null;
      let ring = null;

      // The ring: one fixed element above the page, following the focused item's box.
      function ensureRing() {
        if (ring && document.contains(ring)) return ring;
        ring = document.createElement('div');
        ring.setAttribute('aria-hidden', 'true');
        ring.style.cssText = [
          'position:fixed', 'left:0', 'top:0', 'width:0', 'height:0', 'z-index:2147483647', 'pointer-events:none',
          'box-sizing:border-box', 'border:3px solid #0A84FF', 'border-radius:12px', 'background:rgba(10,132,255,.07)',
          'box-shadow:0 0 0 4px rgba(10,132,255,.22), 0 10px 28px rgba(0,0,0,.18)', 'opacity:0',
          'transition:transform .22s cubic-bezier(.2,.8,.2,1), width .22s cubic-bezier(.2,.8,.2,1), height .22s cubic-bezier(.2,.8,.2,1), opacity .15s, border-radius .22s',
        ].join(';');
        (document.body || document.documentElement).appendChild(ring);
        return ring;
      }

      // Keep the ring on its item while the page scrolls or the item moves.
      function place() {
        if (!current || !document.contains(current) || !shown(current)) {
          if (ring) ring.style.opacity = '0';
          return;
        }
        const r = current.getBoundingClientRect();
        const el = ensureRing();
        const radius = parseFloat(getComputedStyle(current).borderTopLeftRadius) || 0;
        el.style.transform = `translate(${r.left - PAD}px, ${r.top - PAD}px)`;
        el.style.width = `${r.width + PAD * 2}px`;
        el.style.height = `${r.height + PAD * 2}px`;
        el.style.borderRadius = `${Math.min(Math.max(radius + PAD, 10), (r.height + PAD * 2) / 2)}px`;
        el.style.opacity = '1';
      }
      (function follow() { place(); requestAnimationFrame(follow); })();

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
        current = el;
        // Keep the browser's own focus outline away; the ring is the indicator.
        el.focus({ preventScroll: true, focusVisible: false });
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

      // The mouse takes over: hide the ring until the D-pad is used again.
      window.addEventListener('mousedown', () => { current = null; }, true);
    })();
    """#
}
