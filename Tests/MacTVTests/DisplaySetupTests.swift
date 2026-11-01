import AppKit
import SwiftUI
import Foundation
import Testing
@testable import MacTV

@Suite @MainActor struct DisplaySetupTests {
    @Test func selectionMovesTheWindowOutsideDedicatedModeAndRejectsDisconnectedIDs() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/displays-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "MacTV.DisplayTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tv = TVController(library: AppLibrary(folder: folder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tv.window = window
        let mode = TVMode(window: window, tv: tv, defaults: defaults)
        #expect(!mode.enabled)
        let initial = window.frame
        #expect(!tv.selectTVDisplay(id: "disconnected-display"))
        #expect(window.frame == initial)
        #expect(mode.preferredID == nil)
        for display in tv.availableTVDisplays {
            #expect(tv.selectTVDisplay(id: display.id))
            try await Task.sleep(for: .milliseconds(350))
            #expect(mode.preferredID == display.id)
            #expect(tv.availableTVDisplays.contains { $0.id == display.id && $0.current && $0.preferred })
        }
        // Render the real panel, including the display choices, for native visual inspection.
        tv.remotePort = 18765
        tv.refreshRemoteURL()
        let output = root.appendingPathComponent("work/native-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in [NSSize(width: 1920, height: 1080), NSSize(width: 640, height: 360)] {
            let content = ZStack { Color.black; TVCanvas { PairSheet(tv: tv) } }
                .frame(width: size.width, height: size.height).environment(\.colorScheme, .dark)
            let view = NSHostingView(rootView: content)
            let renderWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
            renderWindow.isReleasedWhenClosed = false
            renderWindow.contentView = view
            renderWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            renderWindow.orderFront(nil)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            var highlights = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 12) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 12) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       max(color.redComponent, color.greenComponent, color.blueComponent) > 0.5 { highlights += 1 }
                }
            }
            #expect(highlights > 20, "Pairing panel must contain visible QR/text/controls")
            try png.write(to: output.appendingPathComponent("pairing-\(Int(size.width)).png"))
            renderWindow.close()
        }
    }

    @Test func pairingFocusIncludesDoneAndClampsAfterDisplayChanges() {
        #expect(TVMode.pairingIndex(0, count: 2, step: -1) == 0)
        #expect(TVMode.pairingIndex(1, count: 2, step: 1) == 2)
        #expect(TVMode.pairingIndex(2, count: 2, step: 1) == 3)
        #expect(TVMode.pairingIndex(3, count: 2, step: 1) == 3)
        #expect(TVMode.pairingIndex(2, count: 0, step: 0) == 1)
    }
}
