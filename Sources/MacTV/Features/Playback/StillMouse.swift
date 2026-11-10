/// While the mouse rests over a website, WebKit tells the page the mouse is "over" whatever is under
/// it each time that changes: a subtitle, an "Up next" card, the player's own overlay. Players such
/// as HBO Max take that as someone moving the mouse and bring up their controls, every few minutes,
/// with nobody touching anything (issue #16). This drops mouse and pointer events that arrive
/// without the mouse moving, once it has been still for a moment. Real movement, clicks, touch and
/// the phone's trackpad (which moves the mouse) are untouched.
enum StillMouse {
    static let script = #"""
    (() => {
      if (window.__mactvStillMouse) return;
      window.__mactvStillMouse = true;
      // How long the mouse must rest before events at its spot count as the page's doing.
      const SETTLE_MS = 2000;
      let x = null, y = null, movedAt = -Infinity;
      const types = ['mousemove', 'mouseover', 'mouseout', 'mouseenter', 'mouseleave',
                     'pointermove', 'pointerover', 'pointerout', 'pointerenter', 'pointerleave'];
      const filter = event => {
        if (event.pointerType && event.pointerType !== 'mouse') return;
        // Pointer events carry fractions of a pixel and mouse events don't: compare whole pixels.
        const ex = Math.trunc(event.screenX), ey = Math.trunc(event.screenY);
        if (ex !== x || ey !== y) {
          const first = x === null;
          x = ex;
          y = ey;
          // The first event only says where the mouse already rests; anything after it is movement.
          if (!first) { movedAt = event.timeStamp; return; }
        }
        if (event.timeStamp - movedAt > SETTLE_MS) event.stopImmediatePropagation();
      };
      for (const type of types) window.addEventListener(type, filter, true);
    })();
    """#
}
