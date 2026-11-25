import SwiftUI

/// Shared launch session for web players, Steam games, and Mac apps.
struct LaunchCoverSession: Equatable {
    var service: Service
    var ready = false
    var canceling = false
}

/// Dock-sized tile zooms to a hero, waits, then either hands off or reverses on cancel.
/// Scale-only — no matchedGeometry (that was locking the UI).
struct LaunchCover: View {
    let service: Service
    let ready: Bool
    let canceling: Bool
    let onFinished: () -> Void
    let onCancelled: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    @State private var showTitle = false
    @State private var showStatus = false
    @State private var revealing = false
    @State private var cancelStarted = false

    private let heroSize = CGSize(width: 420, height: 252)
    private let dockWidth: CGFloat = 250

    var body: some View {
        let accentHex = TileArt.brandAccent(for: service)
        let deepHex = TileArt.brandDeep(fromAccent: accentHex)
        let accent = Color(hex: accentHex)
        ZStack {
            backdrop(accent: accent, deep: deepHex)
                .opacity(settled && !revealing ? 1 : 0)

            VStack(spacing: 36) {
                launchTile(deep: deepHex)
                    .scaleEffect(tileScale)
                    // Cancel: shrink and fade together so it doesn't pop away at dock size.
                    .opacity(revealing || (cancelStarted && !settled) ? 0 : 1)

                Text(service.name)
                    .font(.tv(.title2, emphasized: true))
                    .opacity(showTitle && !revealing ? 1 : 0)
                    .offset(y: showTitle && !revealing ? 0 : 12)

                VStack(spacing: 18) {
                    LaunchSpinner(accent: accent)
                        .opacity(showStatus && !revealing ? 1 : 0)
                        .scaleEffect(showStatus && !revealing ? 1 : 0.85)
                    Text("Starting…")
                        .font(.tv(.body))
                        .foregroundStyle(.white.opacity(0.7))
                        .opacity(showStatus && !revealing ? 1 : 0)
                        .offset(y: showStatus && !revealing ? 0 : 8)
                }
            }
            .padding(64)
        }
        .foregroundStyle(.white)
        .onAppear(perform: playEnter)
        .onChange(of: ready) { _, isReady in
            if isReady { playReveal() }
        }
        .onChange(of: canceling) { _, isCanceling in
            if isCanceling { playCancel() }
        }
    }

    private var tileScale: CGFloat {
        if reduceMotion { return 1 }
        return settled ? 1 : dockWidth / heroSize.width
    }

    private func launchTile(deep: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return Group {
            if let art = Icons.tile(for: service) {
                Image(nsImage: art).resizable().interpolation(.high)
            } else {
                ZStack {
                    Color(hex: deep)
                    Text(service.name).font(.tv(.title3, emphasized: true))
                }
            }
        }
        .frame(width: heroSize.width, height: heroSize.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(settled ? 0.55 : 0.3), radius: settled ? 36 : 20, y: settled ? 28 : 14)
    }

    private func backdrop(accent: Color, deep: String) -> some View {
        ZStack {
            Color(hex: deep)
            RadialGradient(colors: [accent.opacity(0.55), accent.opacity(0.12), .clear],
                           center: .center, startRadius: 40, endRadius: 900)
            RadialGradient(colors: [.black.opacity(0.15), .black.opacity(0.72)],
                           center: .center, startRadius: 200, endRadius: 1100)
        }
        .ignoresSafeArea()
    }

    private func playEnter() {
        if canceling { playCancel(); return }
        if ready { playReveal(); return }
        if reduceMotion {
            settled = true
            showTitle = true
            showStatus = true
            return
        }
        withAnimation(Motion.launch) { settled = true }
        withAnimation(Motion.launch.delay(0.14)) { showTitle = true }
        withAnimation(Motion.launch.delay(0.26)) { showStatus = true }
    }

    private func playReveal() {
        guard !revealing, !cancelStarted else { return }
        if reduceMotion {
            onFinished()
            return
        }
        withAnimation(Motion.launchExit) { revealing = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            onFinished()
        }
    }

    private func playCancel() {
        guard !cancelStarted, !revealing else { return }
        cancelStarted = true
        if reduceMotion {
            onCancelled()
            return
        }
        withAnimation(Motion.launch) {
            showStatus = false
            showTitle = false
            settled = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            onCancelled()
        }
    }
}

/// Quiet indeterminate wait — accent arc on a glass-thin track, not a system ProgressView.
private struct LaunchSpinner: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.14), lineWidth: 3)
            Circle()
                .trim(from: 0.04, to: 0.28)
                .stroke(
                    AngularGradient(colors: [accent.opacity(0.15), accent],
                                    center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: 42, height: 42)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.95).repeatForever(autoreverses: false)) {
                turning = true
            }
        }
    }
}
