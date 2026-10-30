/// Presses the players' own "Skip Intro", "Skip Recap" and "Next Episode" buttons when they
/// appear (Netflix, Prime Video, JioHotstar and others label them plainly). Ad "Skip" buttons
/// are never touched: only the exact phrases below count.
enum AutoPlay {
    static func script(skip: Bool, next: Bool) -> String {
        "window.__matineeAuto = { skip: \(skip), next: \(next) };\n" + body
    }

    private static let body = #"""
    (() => {
      if (window.__matineeAutoInstalled) return;
      window.__matineeAutoInstalled = true;
      const settings = window.__matineeAuto || {};
      if (!settings.skip && !settings.next) return;

      const SKIP_LABEL = /\bskip\s+(the\s+)?(intro|introduction|recap|opening|opening credits|credits|summary)\b/i;
      const NEXT_LABEL = /^(next episode|play next episode|watch next episode)$/i;
      const pressed = new WeakSet();

      setInterval(() => {
        const candidates = document.querySelectorAll('button, [role="button"], [data-uia^="player-skip"], [data-uia^="next-episode"]');
        for (const el of candidates) {
          if (pressed.has(el)) continue;
          const box = el.getBoundingClientRect();
          if (!box.width || !box.height) continue;
          const label = (el.getAttribute('aria-label') || el.textContent || '').replace(/\s+/g, ' ').trim();
          if (label.length > 40) continue;
          const uia = el.getAttribute('data-uia') || '';
          const isSkip = /^player-skip-(intro|recap)/.test(uia) || SKIP_LABEL.test(label);
          const isNext = /^next-episode-seamless-button/.test(uia) || NEXT_LABEL.test(label);
          if ((isSkip && settings.skip) || (isNext && settings.next)) {
            pressed.add(el);
            el.click();
          }
        }
      }, 1000);
    })();
    """#
}
