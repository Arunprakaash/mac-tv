import AppKit

/// Explicit opt-in smoke check: opens a fresh owned Brave window, then closes just that window.
@MainActor enum BraveSessionProbe {
    private static func report(_ message: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }
    static func start(_ url: URL) {
        Task { @MainActor in
            let session = BraveSession()
            do {
                try await session.open(url)
                report("Brave window opened")
                try await session.fit(to: NSScreen.tvScreen)
                try session.activate()
                try await Task.sleep(for: .seconds(1))
                if AXIsProcessTrusted() {
                    try session.handle(.nextControl)
                    try session.handle(.previousControl)
                    let start = ContinuousClock.now
                    for _ in 0..<15 { try session.handle(.pointer(dx: 1, dy: 1)) }
                    report("15 pointer packets: \(start.duration(to: .now))")
                    report("Remote key and pointer events submitted")
                } else {
                    report("Input check skipped: Accessibility permission is not granted")
                }
                try await Task.sleep(for: .seconds(1))
                try session.close()
                report("Owned Brave window closed")
                exit(0)
            } catch {
                try? session.close()
                report("Brave smoke check failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
