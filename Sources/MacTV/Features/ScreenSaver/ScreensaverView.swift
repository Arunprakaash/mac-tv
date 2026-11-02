import AVFoundation
import SwiftUI

/// Apple-style screensaver: Apple's own aerial films when the Mac has downloaded them
/// (System Settings › Wallpaper or Screen Saver), otherwise slow-drifting colour, under a large
/// lock-screen clock at the top centre.
struct Screensaver: View {
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        ZStack(alignment: .top) {
            ScreenSaverBackdrop(wallpaper: ScreenSaverSettings.wallpaper, pictures: ScreenSaverSettings.playing)
            if ScreenSaverSettings.showClock {
                // Keeps the clock legible over bright skies.
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .center)

                TimelineView(.everyMinute) { context in
                    VStack(spacing: 0) {
                        Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.tv(.callout))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                            .font(.system(size: 230, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.92))
                            .tracking(-4)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 6)
                    .padding(.top, 70)
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }
}

/// Plays aerial films one after another, muted and filling the screen.
struct AerialPlayer: NSViewRepresentable {
    let films: [URL]

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let player = AVQueuePlayer(items: (films + films).map { AVPlayerItem(url: $0) })
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        player.play()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView.layer as? AVPlayerLayer)?.player?.pause()
    }
}
