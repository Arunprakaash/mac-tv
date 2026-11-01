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
./scripts/make-dmg.sh            # builds build/MacTV-<version>.dmg
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

- **Phone remote:** a web page Mac TV serves on the local network. The PIN refreshes every five minutes and is exchanged for a per-device credential, stored hashed on the Mac. Guests expire after 24 hours and can't browse files or manage devices. It's plain HTTP, so use a trusted network or Tailscale, and never expose its port publicly.
- **Brave player:** Mac TV opens its own Brave window through Apple Events (values passed as descriptors, never as script text) and sends input only to that window. It needs Automation and Accessibility permission. Auto-skip, auto-next and the playback check apply only to the built-in player.
- **Tiles:** generated from any square app icon (`TileArt.swift`): the background is read, the logo found and sized, and the background extended to 5:3.
- **Top Shelf:** daily lists from [TVmaze](https://www.tvmaze.com) (CC BY-SA) and Apple's public music charts.
