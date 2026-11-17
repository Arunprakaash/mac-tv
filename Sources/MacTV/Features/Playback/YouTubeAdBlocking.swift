import Foundation
import WebKit

/// YouTube-only ad filtering for the built-in website player (incl. `/tv` and Music).
/// Network rules are scoped to YouTube hosts; the page script no-ops elsewhere.
@MainActor
enum YouTubeAdBlocking {
    private static let storeID = "mactv.ytads.v1"
    private static var ruleList: WKContentRuleList?
    private static var preparing = false

    /// YouTube (and Music) pages where network rules may fire.
    static let ruleDomains = ["*youtube.com", "*youtu.be", "*youtube-nocookie.com"]

    /// Compile rules once at launch so the first stream already has them.
    static func prepare() {
        guard ruleList == nil, !preparing else { return }
        preparing = true
        let json = rulesJSON
        Task {
            do {
                if let store = WKContentRuleListStore.default() {
                    if let cached = try await store.contentRuleList(forIdentifier: storeID) {
                        ruleList = cached
                    } else {
                        ruleList = try await store.compileContentRuleList(
                            forIdentifier: storeID, encodedContentRuleList: json)
                    }
                }
            } catch {
                Log.playback.failure("YouTube ad blocking rules", error)
            }
            preparing = false
        }
    }

    static func apply(to controller: WKUserContentController) {
        prepare()
        if let ruleList { controller.add(ruleList) }
        controller.addUserScript(
            WKUserScript(source: pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    // MARK: - Network rules (hand-curated; not EasyList — keeps Mac TV MIT)

    /// Ad/tracker hosts blocked only while browsing YouTube.
    static let blockedHosts: [String] = [
        "doubleclick.net", "googleadservices.com", "googlesyndication.com", "googletagservices.com",
        "adservice.google.com", "pagead2.googlesyndication.com",
        "2mdn.net", "ad.doubleclick.net", "cm.g.doubleclick.net", "g.doubleclick.net",
        "amazon-adsystem.com", "aax.amazon-adsystem.com", "fls-na.amazon-adsystem.com",
        "adnxs.com", "adsrvr.org", "advertising.com", "adsafeprotected.com",
        "casalemedia.com", "criteo.com", "criteo.net", "outbrain.com", "taboola.com",
        "pubmatic.com", "rubiconproject.com", "openx.net", "moatads.com", "moatpixel.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com", "chartbeat.net",
        "ads-twitter.com", "static.ads-twitter.com", "bidswitch.net", "lijit.com",
        "media.net", "mgid.com", "seedtag.com", "teads.tv", "yieldmo.com",
        "smartadserver.com", "contextweb.com", "rlcdn.com", "bluekai.com",
        "exelator.com", "krxd.net", "mathtag.com", "tapad.com", "turn.com",
        "agkn.com", "demdex.net", "everesttech.net", "mookie1.com", "rfihub.com",
        "serving-sys.com", "w55c.net", "adform.net", "adition.com", "adscale.de",
        "spotxchange.com", "stickyadstv.com", "tremorhub.com", "innovid.com",
        // Not imasdk: blocking it mid-pod leaves YouTube on a black / first ad frame
        // with nothing to seek through. Skip + player hooks clear the pod instead.
    ]

    /// Extra path filters aimed at YouTube ad endpoints (not the video CDN).
    static let blockedURLFilters: [String] = [
        #"^https?://([^/]*\.)?youtube\.com/pagead"#,
        #"^https?://([^/]*\.)?youtube\.com/ptracking"#,
        #"^https?://([^/]*\.)?youtube\.com/api/stats/ads"#,
        #"^https?://([^/]*\.)?youtube\.com/api/stats/atr"#,
        #"^https?://([^/]*\.)?youtube\.com/get_midroll_"#,
        #"^https?://([^/]*\.)?youtube\.com/youtubei/v1/player/ad_"#,
        #"^https?://([^/]*\.)?youtu\.be/pagead"#,
        #"^https?://([^/]*\.)?music\.youtube\.com/api/stats/ads"#,
        #"^https?://([^/]*\.)?googleads\.g\.doubleclick\.net"#,
        #"^https?://([^/]*\.)?static\.doubleclick\.net"#,
        #"^https?://([^/]*\.)?ad\.youtube\.com"#,
        #"^https?://([^/]*\.)?ads\.youtube\.com"#,
        #"^https?://([^/]*\.)?s0\.2mdn\.net"#,
    ]

    static var rulesJSON: String {
        var rules: [[String: Any]] = []
        for host in blockedHosts {
            let escaped = NSRegularExpression.escapedPattern(for: host)
            rules.append([
                "trigger": [
                    "url-filter": "^https?://([^/]*\\.)?\(escaped)",
                    "if-domain": ruleDomains,
                ],
                "action": ["type": "block"],
            ])
        }
        for filter in blockedURLFilters {
            rules.append([
                "trigger": [
                    "url-filter": filter,
                    "if-domain": ruleDomains,
                ],
                "action": ["type": "block"],
            ])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Page script (YouTube desktop + /tv + Music)

    /// Prefer no ad pod at all (`isInlinePlaybackNoAd`); otherwise skip / break out of a stuck ad
    /// (black screen or single buffered frame).
    static let pageScript = #"""
    (() => {
      if (window.__macTVAdBlock) return;
      window.__macTVAdBlock = true;
      const host = location.hostname;
      if (!/(^|\.)youtube\.com$|(^|\.)youtu\.be$|(^|\.)youtube-nocookie\.com$/.test(host)) return;

      const SKIP = /\bskip\s*(ad|ads|advertisement)?s?\b/i;
      const AD_PLAYER = '.html5-video-player.ad-showing, .html5-video-player.ad-interrupting, .ad-showing, .ad-interrupting';
      const clicked = new WeakSet();
      let wasAd = false;
      let postSkipUntil = 0;
      let postSkipLastT = -1;
      let postSkipLastCheck = 0;
      let adStallT = -1;
      let adStallSince = 0;
      let lastForceLeave = 0;

      // C: ask InnerTube not to schedule ads (uBO / Brave approach).
      const patchAdBody = raw => {
        if (typeof raw !== 'string' || raw.includes('isInlinePlaybackNoAd')) return raw;
        if (!raw.includes('contentPlaybackContext')) return raw;
        return raw.replace(/"contentPlaybackContext"\s*:\s*\{/, '"contentPlaybackContext":{"isInlinePlaybackNoAd":true,');
      };
      try {
        const stringify = JSON.stringify.bind(JSON);
        JSON.stringify = function (value, ...rest) {
          const out = stringify(value, ...rest);
          return typeof value === 'object' && value ? patchAdBody(out) : out;
        };
      } catch (_) {}
      try {
        const assign = Object.assign.bind(Object);
        Object.assign = function (target, ...sources) {
          const out = assign(target, ...sources);
          if (out && typeof out.body === 'string') out.body = patchAdBody(out.body);
          return out;
        };
      } catch (_) {}
      try {
        const origFetch = window.fetch;
        if (typeof origFetch === 'function') {
          window.fetch = function (input, init) {
            try {
              if (init && typeof init.body === 'string') init = Object.assign({}, init, { body: patchAdBody(init.body) });
            } catch (_) {}
            return origFetch.call(this, input, init);
          };
        }
      } catch (_) {}

      const visible = el => {
        const r = el.getBoundingClientRect();
        return r.width > 2 && r.height > 2 && r.bottom > 0 && r.right > 0;
      };

      const adPlayers = () => document.querySelectorAll(AD_PLAYER);
      const isAd = () => adPlayers().length > 0
        || !!document.querySelector('.ytp-ad-player-overlay, .ytp-ad-module, ytw-ad, .ad-container');

      const mainVideo = () => {
        const ad = document.querySelector(AD_PLAYER);
        if (ad) {
          const v = ad.querySelector('video');
          if (v) return v;
        }
        return document.querySelector('video.html5-main-video, video');
      };

      const ytPlayer = () => document.querySelector('#movie_player, .html5-video-player');

      const clickSkips = () => {
        const nodes = document.querySelectorAll(
          'button, [role="button"], yt-button-shape button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-overlay-close-button, .ytp-ad-skip-button-slot button'
        );
        for (const el of nodes) {
          if (clicked.has(el) || !visible(el)) continue;
          const label = ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).replace(/\s+/g, ' ').trim();
          const looksSkip = SKIP.test(label) || /ytp-ad-skip|ytp-skip-ad|ad-overlay-close/i.test(el.className || '');
          if (!looksSkip) continue;
          clicked.add(el);
          try { el.click(); } catch (_) {}
        }
      };

      const safePlay = video => {
        try {
          const p = video.play();
          if (p && typeof p.catch === 'function') p.catch(() => {});
        } catch (_) {}
      };

      const bufferedEnd = video => {
        try {
          if (!video.buffered || !video.buffered.length) return 0;
          return video.buffered.end(video.buffered.length - 1);
        } catch (_) { return 0; }
      };

      // Leave a dead ad pod (blocked creative → one frame / black, nothing more buffers).
      const forceLeaveAd = video => {
        const now = Date.now();
        if (now - lastForceLeave < 700) return;
        lastForceLeave = now;
        clickSkips();
        try { video.dispatchEvent(new Event('ended')); } catch (_) {}
        const player = ytPlayer();
        if (player) {
          try { player.classList.remove('ad-showing', 'ad-interrupting'); } catch (_) {}
          try {
            if (typeof player.getVideoData === 'function' && typeof player.loadVideoById === 'function') {
              const id = player.getVideoData().video_id;
              const t = typeof player.getCurrentTime === 'function' ? player.getCurrentTime() : 0;
              if (id) player.loadVideoById(id, Math.max(0, t));
            } else if (typeof player.playVideo === 'function') {
              player.playVideo();
            }
          } catch (_) {}
        }
        try { video.playbackRate = 1; } catch (_) {}
        safePlay(video);
      };

      // A: finish the ad pod — seek when possible; break out when buffered wall / no duration.
      const endAdVideo = () => {
        for (const player of adPlayers()) {
          const video = player.querySelector('video') || document.querySelector('video');
          if (!video) continue;
          try { video.muted = true; } catch (_) {}
          const dur = video.duration;
          const buf = bufferedEnd(video);
          const t = video.currentTime;
          const noDur = !Number.isFinite(dur) || dur <= 0;
          const atWall = buf > 0 && t >= buf - 0.2 && (noDur || t < dur - 0.5);
          const stalled = Math.abs(t - adStallT) < 0.05;
          if (!stalled) {
            adStallT = t;
            adStallSince = Date.now();
          }
          const stallMs = Date.now() - adStallSince;

          if (atWall || (noDur && stallMs > 600) || (video.readyState < 2 && stallMs > 800)) {
            forceLeaveAd(video);
            continue;
          }
          if (noDur || video.readyState < 2) {
            try { video.playbackRate = 16; } catch (_) {}
            safePlay(video);
            continue;
          }
          try { video.playbackRate = 16; } catch (_) {}
          const nearEnd = Math.max(0, dur - 0.05);
          try {
            if (t >= nearEnd - 0.05) video.currentTime = Math.min(t + 0.5, dur);
            else video.currentTime = nearEnd;
          } catch (_) {}
          safePlay(video);
          clickSkips();
        }
      };

      // B: after ad-showing clears, unstick a black / frozen content frame.
      const recoverPostSkip = () => {
        const now = Date.now();
        if (now > postSkipUntil) return;
        const video = mainVideo();
        if (!video || isAd()) return;
        const t = video.currentTime;
        const moved = Math.abs(t - postSkipLastT) > 0.01;
        const since = now - postSkipLastCheck;
        if (!moved && since >= 600) {
          if (video.paused || video.readyState < 2 || bufferedEnd(video) <= t + 0.05) {
            try {
              video.pause();
              video.currentTime = t + 0.001;
            } catch (_) {}
            safePlay(video);
            const player = ytPlayer();
            try { if (player && typeof player.playVideo === 'function') player.playVideo(); } catch (_) {}
            setTimeout(() => {
              if (isAd() || Date.now() > postSkipUntil) return;
              const v = mainVideo();
              if (!v) return;
              if (v.paused || Math.abs(v.currentTime - (t + 0.001)) < 0.01) {
                try { v.currentTime = v.currentTime + 1; } catch (_) {}
                safePlay(v);
              }
            }, 700);
          }
          postSkipLastT = video.currentTime;
          postSkipLastCheck = now;
        } else if (moved) {
          postSkipLastT = t;
          postSkipLastCheck = now;
        }
      };

      const tick = () => {
        const ad = isAd();
        clickSkips();
        if (ad) endAdVideo();
        else {
          adStallT = -1;
          adStallSince = 0;
        }
        if (wasAd && !ad) {
          postSkipUntil = Date.now() + 1500;
          const v = mainVideo();
          postSkipLastT = v ? v.currentTime : -1;
          postSkipLastCheck = Date.now();
          if (v) {
            try { v.playbackRate = 1; v.muted = false; } catch (_) {}
            safePlay(v);
          }
        }
        wasAd = ad;
        recoverPostSkip();
      };

      setInterval(tick, 250);
      try {
        new MutationObserver(tick).observe(document.documentElement, {
          subtree: true, childList: true, attributes: true, attributeFilter: ['class']
        });
      } catch (_) {}
      document.addEventListener('yt-navigate-finish', tick, true);
    })();
    """#
}
