import AppKit
import SwiftUI
import Testing
@testable import MacTV

@Suite @MainActor struct PresentationTests {
    @Test func recoverySelectionStaysWithinActions() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.playerFailure = PlayerFailure(message: "Connection lost")
        for _ in 0..<5 { tv.handlePlayerFailure(.move(.right)) }
        #expect(tv.playerFailure?.selected == 2)
        for _ in 0..<5 { tv.handlePlayerFailure(.move(.left)) }
        #expect(tv.playerFailure?.selected == 0)
        tv.performPlayerRecovery(0)
        #expect(tv.playerFailure == nil)
    }

    @Test func nativeSheetsRender() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tv = TVController(library: AppLibrary(folder: folder))
        tv.settings = SettingsPanel()
        tv.openOrganizer()
        tv.topShelfPreferences = TopShelfPreferencesPanel()
        tv.playerFailure = PlayerFailure(message: "The streaming page couldn't load. Check the connection, then try again.")
        tv.playbackCheck = PlaybackDiagnostics()
        tv.openAudioPicker()
        let views: [(String, AnyView)] = [
            ("organizer", AnyView(AppOrganizerSheet(tv: tv))),
            ("top-shelf", AnyView(TopShelfPreferencesSheet(tv: tv))),
            ("recovery", AnyView(PlaybackFailureView(tv: tv))),
            ("diagnostics", AnyView(PlaybackCheckSheet(tv: tv))),
            ("settings", AnyView(SettingsSheet(tv: tv))),
            ("audio-picker", AnyView(AudioPickerSheet(tv: tv)))
        ]
        let output = root.appendingPathComponent("work/native-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, view) in views {
            let host = NSHostingView(rootView: ZStack { Color.black; TVCanvas { view } }.frame(width: 1280, height: 720))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            #expect(rep.pixelsWide >= 1280 && rep.pixelsHigh >= 720)
            var highlights = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 12) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 12) {
                    if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       max(color.redComponent, color.greenComponent, color.blueComponent) > 0.5 { highlights += 1 }
                }
            }
            #expect(highlights > 20, "Native sheet must contain visible text and controls, not a blank capture")
            try #require(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            window.close()
        }
    }
}
