import SwiftUI

/// Apple TV's volume indicator: a glass capsule with the speaker and the level.
struct VolumeHUD: View {
    let volume: VolumeLevel

    private var symbol: String {
        guard let level = volume.level else { return "tv" }
        if volume.muted || level == 0 { return "speaker.slash.fill" }
        return level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40)
            if let level = volume.level {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * CGFloat(volume.muted ? 0 : level) / 100)
                    }
                }
                .frame(width: 260, height: 8)
            } else {
                Text("Volume is set on the TV").font(.tv(.caption2))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .frame(height: 72)
        .animation(.smooth(duration: 0.2), value: volume)
        .tvGlass(in: Capsule())
    }
}
