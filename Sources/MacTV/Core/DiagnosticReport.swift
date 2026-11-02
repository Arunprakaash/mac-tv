import AppKit
import CoreAudio
import OSLog

/// A plain-text report to paste into a bug report: versions, the Mac, displays, sound, the remote,
/// power, recent crashes and this session's log.
///
/// It leaves out what's watched, titles, web and server addresses, file and folder names, profile
/// and device names: the facts below never include them, and the log keeps them private.
@MainActor
enum DiagnosticReport {
    /// Builds the report and puts it on the clipboard. Reading the log can take a moment, so it
    /// happens off the main thread.
    static func copy(from tv: TVController) {
        let facts = facts(tv)
        tv.showToast("Preparing the report…")
        Task.detached(priority: .userInitiated) {
            let report = facts + "\n\n## Log (this session)\n\n" + sessionLog()
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                tv.showToast("Report copied. Paste it into a GitHub issue.")
            }
            Log.app.notice("Diagnostics report copied")
        }
    }

    static func facts(_ tv: TVController) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let power = PowerStatus.current()
        var lines = ["# Mac TV diagnostics", ""]
        func add(_ name: String, _ value: String) { lines.append("- \(name): \(value)") }

        add("Mac TV", "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
        add("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        add("Mac", "\(sysctl("hw.model") ?? "?"), \(architecture), \(ProcessInfo.processInfo.physicalMemory >> 30) GB")
        add("Open for", duration(Date().timeIntervalSince(launched)))
        add("Showing", screenName(tv))
        add("Website player", tv.websitePlayerName)
        add("IINA installed", yesNo(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") != nil))
        add("Accessibility allowed", yesNo(AXIsProcessTrusted()))

        lines += ["", "## Displays", ""]
        for screen in NSScreen.screens {
            let size = screen.frame.size
            let kind = CGDisplayIsBuiltin(screen.displayID) != 0 ? "built-in" : "external"
            let hz = screen.maximumFramesPerSecond
            add(kind, "\(Int(size.width))×\(Int(size.height)) pt @\(Int(screen.backingScaleFactor))x, \(hz) Hz"
                + (screen == tv.window?.screen ? ", Mac TV is here" : ""))
        }
        add("Dedicated TV mode", tv.dedicatedTVMode ? "on" : "off")

        lines += ["", "## Sound", ""]
        add("Output", tv.currentAudioDevice.map { transportName($0.transport) } ?? "none")
        add("Outputs available", "\(tv.audioDevices.count)")
        add("Navigation sounds", Feedback.shared.enabled ? "on" : "off")

        lines += ["", "## Remote and power", ""]
        add("Remote page", RemotePage.available ? "found" : "missing")
        add("Phone paired", yesNo(tv.phonePaired))
        add("Tailscale running", yesNo(LAN.tailscaleIPv4() != nil))
        add("Game controller", tv.controller == nil ? "none" : "connected")
        add("Power", power.onAC ? "on power" : "on battery" + (power.battery.map { ", \($0)%" } ?? ""))
        add("Lid", power.lidClosed ? "closed" : "open")
        add("Keep Mac awake", tv.keepMacAwake ? "on" : "off")
        add("Stay awake with lid closed", tv.lidOverride ? "on" : "off")
        add("Automatic updates", Updater.shared.automatic ? "on" : "off")

        let crashes = recentCrashes()
        lines += ["", "## Crashes in the last 14 days", ""]
        lines += crashes.isEmpty ? ["None"] : crashes.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }

    /// When this process started, for "Open for".
    static let launched = Date()

    /// This session's log entries from Mac TV, newest last, at most `limit` of them.
    nonisolated static func sessionLog(limit: Int = 400) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", Log.subsystem))
            let time = DateFormatter()
            time.dateFormat = "HH:mm:ss.SSS"
            let lines = entries.compactMap { $0 as? OSLogEntryLog }.suffix(limit).map {
                "\(time.string(from: $0.date)) [\($0.category)] \(level($0.level)) \($0.composedMessage)"
            }
            return lines.isEmpty ? "Nothing logged yet." : lines.joined(separator: "\n")
        } catch {
            return "Couldn't read the log: \(error.localizedDescription)"
        }
    }

    private nonisolated static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .error: "error"
        case .fault: "fault"
        case .notice: "note"
        case .info: "info"
        case .debug: "debug"
        default: "-"
        }
    }

    private static func screenName(_ tv: TVController) -> String {
        switch tv.mode {
        case .launcher: "Home"
        case .player(let service): "\(service.kind) app"
        case .movie: "a movie"
        }
    }

    /// Crash reports macOS kept for Mac TV, by date only.
    private static func recentCrashes() -> [String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("MacTV") }
            .compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
            .filter { $0 > cutoff }
            .sorted(by: >)
            .map { $0.formatted(date: .abbreviated, time: .shortened) }
    }

    nonisolated static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "built-in speakers"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case 0x64707274: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: "virtual"
        default: "other"
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        translated ? "Intel build under Rosetta" : "Intel"
        #endif
    }

    #if !arch(arm64)
    /// Whether this Intel build is running on Apple silicon through Rosetta.
    private static var translated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }
    #endif

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
