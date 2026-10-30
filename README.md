# Matinee

Turns a Mac into a TV box with an Apple TV-style home screen. Streaming services run in their official web players with Apple's FairPlay DRM, and your phone is the remote.

## Build and run

```bash
./build.sh
open build/Matinee.app
```

Matinee opens as a normal window on your external display, or the main display if none is connected. Use the green button or ⌃⌘F to go full screen. It remembers where you left the window.

The first time it runs after each build, macOS asks whether Matinee may accept incoming network connections. Choose **Allow**, or phones won't reach the remote.

## Home screen

- **Dock:** the top row, on frosted glass. Focusing an app fills the Top Shelf behind it with what you last watched there.
- **Top Shelf:** move up from the dock to expand it, with Resume and Open buttons.
- **App grid:** move down from the dock to see the rest of your apps.
- **Pairing:** Settings shows the QR codes for pairing a phone.

Keyboard: arrows, Return, and Escape to go back. ⌘⇧H goes home and ⌘Q quits.

## Phone remote

In Settings, scan the QR code with your phone's camera. The Tailscale code works when your Wi-Fi keeps devices apart or when you're away from home. Add the page to your home screen to keep the remote as an icon.

The remote has a Clickpad (swipe, tap edges, hold to repeat, tap the middle for OK) and a Touchpad (drag, tap, two-finger scroll). It also has media keys, volume, typing on the TV, an app launcher, and screen off and sleep. Every press gives haptic feedback: vibration on Android, and a light tick on iPhone with iOS 18 or later.

## Watching

- **Skip intros, recaps and play next episode:** Matinee presses the players' own Skip Intro, Skip Recap and Next Episode buttons when they appear (Netflix, Prime Video, JioHotstar and others). It never presses an ad's "Skip" button. Turn either one off in **TV controls** on the remote (the power button).
- **Sleep timer:** in **TV controls**, pick 15, 30, 60 or 90 minutes. When it ends, playback stops, Matinee goes home and the screen turns off.
- **Screensaver:** after 5 idle minutes on the home screen, a large clock appears at the top over Apple's aerial films, if the Mac has downloaded them in System Settings › Wallpaper or Screen Saver. Otherwise it shows drifting colour. Any key, click or remote press brings you back.
- **Privacy:** the home screen never shows pictures of what you watched; the Top Shelf uses each app's own colours.

## Adding and removing apps

On the phone remote, open **Apps** (the grid button):

- **Add app → Website:** type an address, such as `crunchyroll.com`. The name is optional. Matinee finds the official icon itself: first the matching App Store app's icon, otherwise the largest home-screen icon the site publishes. It also picks up the brand colour for the Top Shelf.
- **Add app → Mac app:** search the apps installed on the Mac and tap one. Its own icon is used.
- **Edit:** tap the red badge to remove an app. You can bring back built-in apps you removed with **Restore built-in apps**.

Added apps and their icons are kept in `~/Library/Application Support/Matinee/`.

## Apps and icons

The built-in apps are listed in `Sources/Matinee/Catalog.swift`, and their icons are in `Icons/`. These are each service's official App Store icons.

Tiles are generated from the icons automatically (`TileArt.swift`), so any square app icon works with no tuning. Matinee reads the icon's background, finds its logo, sizes the logo to a standard visual weight, and extends the background to the 5:3 tile.

To check all tiles side by side:

```bash
build/Matinee.app/Contents/MacOS/Matinee --export-tiles /path/to/folder
build/Matinee.app/Contents/MacOS/Matinee --export-home /path/to/folder
```

## Notes

- **Sign-ins:** each service needs signing in once inside Matinee. Matinee keeps its own sign-ins, separate from Safari or Chrome.
- **Top Shelf:** it fills in as you watch. Matinee notes the title, artwork and progress of what's playing.
- **DRM check:** `Matinee --selftest-drm` prints the DRM systems available. FairPlay is available, the same as in Safari.
- **Mac apps:** when a Mac app tile (such as IINA) is in front, the remote forwards arrows, OK, Back and Play. This needs Accessibility permission.
