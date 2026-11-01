import AppKit
import ApplicationServices
import CoreImage.CIFilterBuiltins
import IOKit.ps
import IOKit.pwr_mgt

enum SystemControl {
    /// Raising the volume also unmutes, like the volume keys. Returns the new level.
    static func changeVolume(by delta: Int) -> VolumeLevel {
        runAppleScript("set volume output volume ((output volume of (get volume settings)) + \(delta))"
                       + (delta > 0 ? "\nset volume output muted false" : ""))
        return volume()
    }

    static func toggleMute() -> VolumeLevel {
        runAppleScript("set volume output muted (not (output muted of (get volume settings)))")
        return volume()
    }

    /// The output's volume and mute state. Outputs macOS can't set the volume of, like most
    /// HDMI TVs, report no level.
    static func volume() -> VolumeLevel {
        var error: NSDictionary?
        let script = "set s to get volume settings\nreturn (output volume of s as text) & \",\" & (output muted of s as text)"
        let parts = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue?
            .split(separator: ",").map(String.init) ?? []
        return VolumeLevel(level: parts.first.flatMap { Int($0) }, muted: parts.count > 1 && parts[1] == "true")
    }

    /// Turns the displays off; playback and the remote keep working.
    static func displayOff() { pmset("displaysleepnow") }

    /// Ask macOS to wake sleeping displays. The return value reports request acceptance only.
    @discardableResult
    static func displayOn() -> Bool { DisplayPower.wake() }

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

struct VolumeLevel: Equatable {
    /// 0–100, or nil when the volume is set on the TV rather than the Mac.
    var level: Int?
    var muted: Bool
}

/// Holds one power assertion: the display awake while something plays, or the Mac awake while
/// Mac TV is open.
final class KeepAwake {
    private let type: String
    private var assertion: IOPMAssertionID = 0
    private var held = false

    init(_ type: String = kIOPMAssertionTypePreventUserIdleDisplaySleep) {
        self.type = type
    }

    deinit { release() }

    func hold(reason: String) {
        guard !held else { return }
        held = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion) == kIOReturnSuccess
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertion)
        held = false
    }
}

/// The lid, power and display facts that decide whether closing the lid sleeps the Mac.
struct PowerStatus: Equatable {
    var lidClosed = false
    var onAC = true
    /// Battery charge in percent; nil on a Mac without a battery.
    var battery: Int?
    var externalDisplay = false

    /// Apple's closed-lid mode: on power with an external display, closing the lid doesn't sleep the Mac.
    var closedLidModeReady: Bool { onAC && externalDisplay }

    static func current() -> PowerStatus {
        var status = PowerStatus()
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if root != 0 {
            status.lidClosed = (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, nil, 0)?
                .takeRetainedValue() as? Bool) ?? false
            IOObjectRelease(root)
        }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            status.onAC = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                status.battery = current * 100 / max
            }
        }
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetOnlineDisplayList(16, &displays, &count) == .success {
            status.externalDisplay = displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
        }
        return status
    }
}

/// Keeps the Mac running with the lid closed, even on battery or without an external display.
///
/// Normal power assertions don't stop lid-close sleep. This sets the kernel switch that powerd
/// itself sets for closed-lid mode (IOPMrootDomain's kPMSetClamshellSleepState, selector 12).
/// It needs no admin rights, but it's undocumented and shared with powerd, which rewrites it
/// when power or displays change, so Mac TV re-applies it while the option is on. A guard
/// process (`--lid-guard`) hands it back if Mac TV quits or crashes.
enum LidSleep {
    @discardableResult
    static func setPrevented(_ prevented: Bool) -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(root, mach_task_self_, 0, &connect) == kIOReturnSuccess else { return false }
        defer { IOServiceClose(connect) }
        var input: [UInt64] = [prevented ? 1 : 0]
        let setClamshellSleepState: UInt32 = 12
        return IOConnectCallScalarMethod(connect, setClamshellSleepState, &input, 1, nil, nil) == kIOReturnSuccess
    }

    /// Hands the switch back to macOS: on only where powerd would have it on (closed-lid mode).
    static func restore() {
        setPrevented(PowerStatus.current().closedLidModeReady)
    }

    /// Starts a guard that restores lid sleep once this process exits, however it exits.
    static func startGuard() -> Process? {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--lid-guard", String(getpid())]
        do { try process.run() } catch { return nil }
        return process
    }

    /// The guard's whole life: wait for Mac TV to exit, restore lid sleep, exit.
    static func runGuard(parent: pid_t) -> Never {
        let exited = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        exited.setEventHandler {
            restore()
            exit(0)
        }
        exited.resume()
        // SIGTERM means Mac TV turned the option off and restored lid sleep itself.
        signal(SIGTERM, SIG_IGN)
        let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        stop.setEventHandler { exit(0) }
        stop.resume()
        // The parent may have gone before the source was watching.
        if kill(parent, 0) != 0 { restore(); exit(0) }
        dispatchMain()
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
