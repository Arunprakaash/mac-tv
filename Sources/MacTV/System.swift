import AppKit
import ApplicationServices
import CoreImage.CIFilterBuiltins
import IOKit.pwr_mgt

enum SystemControl {
    static func changeVolume(by delta: Int) {
        runAppleScript("set volume output volume ((output volume of (get volume settings)) + \(delta))")
    }

    static func toggleMute() {
        runAppleScript("set volume output muted (not (output muted of (get volume settings)))")
    }

    /// Turns the displays off; playback and the remote keep working.
    static func displayOff() { pmset("displaysleepnow") }

    /// Full system sleep. The phone can't wake the Mac over Wi-Fi; its keyboard or lid can.
    static func sleepNow() { pmset("sleepnow") }

    /// Sends a key to whichever app is in front. Needs Accessibility permission, asked for once.
    static func postKeyToFrontApp(_ code: CGKeyCode) {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Mac TV: AppleScript failed: \(error)") }
    }

    private static func pmset(_ argument: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = [argument]
        try? process.run()
    }
}

/// Keeps the display awake while something is playing.
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    func hold(reason: String) {
        guard !held else { return }
        held = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion) == kIOReturnSuccess
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertion)
        held = false
    }
}

enum LAN {
    /// This Mac's IPv4 address on the local network, preferring Wi-Fi/Ethernet (en*).
    static func ipv4() -> String? {
        let local = addresses().filter { !isTailscale($0.address) }
        return (local.first { $0.interface == "en0" } ?? local.first { $0.interface.hasPrefix("en") } ?? local.first)?.address
    }

    /// This Mac's Tailscale address, when Tailscale is running. Reachable from phones on the same
    /// tailnet even where the router keeps Wi-Fi devices apart, and away from home.
    static func tailscaleIPv4() -> String? {
        addresses().first { $0.interface.hasPrefix("utun") && isTailscale($0.address) }?.address
    }

    /// Tailscale hands out addresses from 100.64.0.0/10.
    private static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func addresses() -> [(interface: String, address: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var found: [(interface: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if address.hasPrefix("169.254.") { continue }
            found.append((String(cString: entry.pointee.ifa_name), address))
        }
        return found
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
