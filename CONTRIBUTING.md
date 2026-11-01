# Contributing to Mac TV

Thanks for helping. Bug reports and ideas go to [GitHub issues](https://github.com/Arunprakaash/mac-tv/issues); security problems to [SECURITY.md](SECURITY.md).

## Pull requests

- Keep each pull request to one change, and describe what it does and how you checked it.
- `main` is protected: the **macos** check (Swift tests and the universal build) must pass.
- Match the surrounding code and the Apple TV look: Liquid Glass only over real content, a white platter for focus, the `Font.tv` type scale, and SF Symbols in one colour.
- Mac TV opens official services only. Don't add, suggest or document sites that host pirated content.
- Analytics events live only in `Analytics.swift`. Never send what anyone watches, titles, addresses, file names or profile names.

## Build from source

Needs the Swift toolchain (Command Line Tools is enough) on macOS 14 or later.

```bash
./build.sh                       # builds "build/Mac TV.app" (Apple silicon and Intel)
open "build/Mac TV.app"
./scripts/make-dmg.sh            # builds build/MacTV-<version>.dmg (asks once to let your terminal control Finder, to lay out its window)
swift scripts/make-dmg-background.swift   # redraws the DMG window's background (variants sheet.png shows all designs)
./scripts/make-signing-cert.sh   # once: a local signing certificate, so macOS keeps permissions across builds
swift scripts/make-icon.swift    # redraws Assets/AppIcon.png and .icns
```

- `MACTV_BUILD_DIR` keeps the build database off a cloud-synced drive; the app still lands in `build`.
- `MACTV_DATA_DIR` points Mac TV at a separate data folder for isolated UI checks. Normally sign-ins and apps live in `~/Library/Application Support/Mac TV`.
- `./scripts/notarize.sh` signs, notarizes and staples with `MACTV_DEVELOPER_ID` and `MACTV_NOTARY_PROFILE` (the publisher's Apple Developer credentials).

## Tests and checks

```bash
swift test --disable-xctest              # Swift tests (Swift 6 or newer)
node Tests/WebPlayback/bridge.test.cjs   # web player bridge
node Tests/WebPlayback/touchpad.test.cjs # phone touchpad transport
node Tests/WebPlayback/address.test.cjs  # phone website address entry
node Tests/WebPlayback/transport.test.cjs # phone request deadlines and queues
node Tests/WebPlayback/layout.test.cjs    # phone layout (needs Chrome or Brave, or BROWSER_BIN)
```

Some Swift 6.4 Command Line Tools installs have a [TestingMacros loading issue](https://github.com/swiftlang/swift-build/issues/1870). If the plugin is reported missing:

```bash
swift test --disable-xctest -Xswiftc -load-plugin-library \
  -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
```

Built-in checks, run on the app's binary:

- `--selftest-drm` prints the DRM systems available.
- `--selftest-brave <url>` opens and closes a test Brave window, and checks input if Accessibility is allowed.
- `--export-tiles <folder>` renders the dock tiles, and `--export-home <folder>` the home screen.
- `--export-remote <file.png> [apps|controls]` renders the phone remote. Needs Mac TV running and `MACTV_REMOTE_CODE` set to its current pairing PIN.

## How some parts work

- **Phone remote:** a web page Mac TV serves only to local and private-network phones (Tailscale included), with limits on connections, request size and time. Trusted and guest phones scan separate rotating codes, exchanged for a per-device credential stored hashed on the Mac. Guests get playback controls only and expire after 24 hours. It's plain HTTP, so use a trusted network or Tailscale, and never expose its port publicly.
- **IINA:** Mac TV starts its own IINA window on the TV display and controls it over a private mpv socket (in a 0700 temporary folder), so commands work whatever app is in front. Home and Quit close only that window. Placing the window needs Accessibility.
- **Screen wake:** "Wake screen" and other remote presses ask macOS to wake sleeping displays (a short user-activity assertion). It can't wake a Mac that is asleep or a TV that is switched off.
- **Brave player:** Mac TV opens its own Brave window through Apple Events (values passed as descriptors, never as script text) and sends input only to that window. It needs Automation and Accessibility permission. Auto-skip, auto-next and the playback check apply only to the built-in player.
- **Network shares:** `NetworkShares.swift` mounts SMB shares with NetFS (no macOS dialogs), keeps passwords in the Keychain under its own label, and reconnects at launch, after waking, when the network returns and every two minutes. Movies keeps an offline share's films (and where you stopped) in `offline.json` until it's back.
- **Jellyfin:** `Jellyfin.swift` signs in with `AuthenticateByName` and keeps only the token in the Keychain. Its movies and episodes join Movies with `jellyfin://<server>/<item>` paths. `PlaybackInfo` with a device profile picks direct play (MP4/MOV with H.264 or HEVC) or Jellyfin's HLS, which `AVPlayback` opens. Progress goes back through `/Sessions/Playing`, and a film that's also a file on this Mac shows once, as the file.
- **Updates:** `Updater.swift` reads the latest GitHub release, at launch and daily. With automatic updates on, it downloads straight away and installs only while Mac TV is idle (screen saver up, or screen off at home with nothing playing). Installing mounts the release's `.dmg`, checks the app inside satisfies the running app's designated requirement (same identifier and signing certificate), swaps it in and relaunches. So releases must be tagged `vX.Y`, carry a `.dmg`, and be signed with the same certificate as the builds people have, or the update is refused.
- **Tiles:** generated from any square app icon (`TileArt.swift`): the background is read, the logo found and sized, and the background extended to 5:3.
- **Top Shelf:** daily lists from [TVmaze](https://www.tvmaze.com) (CC BY-SA) and Apple's public music charts.
