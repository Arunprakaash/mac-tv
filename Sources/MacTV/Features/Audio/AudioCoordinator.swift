import AppKit
import CoreAudio
import SwiftUI

/// An audio output endpoint (AirPods, TV HDMI, built-in speakers, etc.).
struct AudioOutputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    let isDefault: Bool

    /// Maps transport type and device name to the appropriate tvOS SF Symbol.
    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") || lower.contains("headphone") { return "headphones" }

        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, 0x64707274 /* 'dprt' DisplayPort */:
            return "tv.fill"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

/// The TV's audio output picker sheet state.
struct AudioPickerPanel: Equatable {
    var row = 0
}

/// Manages system audio output endpoints and monitors device route changes via CoreAudio.
@MainActor
final class AudioCoordinator: ObservableObject {
    weak var tv: TVController?

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var currentDevice: AudioOutputDevice?

    nonisolated(unsafe) private var defaultListenerBlock: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var devicesListenerBlock: AudioObjectPropertyListenerBlock?

    nonisolated(unsafe) private var defaultAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    nonisolated(unsafe) private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(tv: TVController? = nil) {
        self.tv = tv
        refreshDevices()
        startListening()
    }

    deinit {
        stopListening()
    }

    // MARK: - CoreAudio Device Querying

    func refreshDevices() {
        let defaultID = defaultOutputDeviceID()
        var newDevices: [AudioOutputDevice] = []

        for id in allAudioDeviceIDs() {
            guard hasOutputStreams(id), !isHidden(id) else { continue }
            // Apps get a private "CADefaultDeviceAggregate-<pid>" device that isn't a real output.
            guard let name = deviceName(id), !name.hasPrefix("CADefaultDeviceAggregate") else { continue }
            let transport = transportType(id)
            let isCurrent = (id == defaultID)

            let device = AudioOutputDevice(
                id: id,
                name: name,
                transport: transport,
                isDefault: isCurrent
            )
            newDevices.append(device)
        }

        // The sliders sit under the devices: keep focus on the same slider as the list changes.
        if let row = tv?.audioPicker?.row {
            let moved = row >= devices.count ? row + newDevices.count - devices.count : row
            tv?.audioPicker?.row = max(0, min(moved, newDevices.count + 1))
        }
        self.devices = newDevices
        self.currentDevice = newDevices.first(where: { $0.id == defaultID })
        // Reading the volume runs AppleScript, so only while the picker shows it.
        if tv?.audioPicker != nil { refreshVolume() }
        tv?.objectWillChange.send()
    }

    // MARK: - Volume Controls

    @Published private(set) var currentVolume = VolumeLevel(level: nil, muted: false)

    /// Reads the Mac's volume. Tests swap it out: the AppleScript behind it ends a test run.
    static var readVolume: () -> VolumeLevel = SystemControl.volume

    func refreshVolume() {
        currentVolume = Self.readVolume()
        tv?.objectWillChange.send()
    }

    func setVolume(_ level: Int) {
        currentVolume = SystemControl.setVolume(to: level)
        tv?.showVolume(currentVolume)
        tv?.objectWillChange.send()
    }

    /// Setting the volume runs AppleScript, so a drag sets it only when the level changes,
    /// at most about twelve times a second.
    private var lastDragSet: TimeInterval = 0

    func dragVolume(to level: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard level != currentVolume.level || currentVolume.muted, now - lastDragSet >= 0.08 else { return }
        lastDragSet = now
        setVolume(level)
    }

    func stepVolume(by delta: Int) {
        currentVolume = SystemControl.changeVolume(by: delta)
        tv?.showVolume(currentVolume)
        tv?.objectWillChange.send()
    }

    func toggleMute() {
        currentVolume = SystemControl.toggleMute()
        tv?.showVolume(currentVolume)
        tv?.objectWillChange.send()
    }

    func selectDevice(_ device: AudioOutputDevice) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var targetID = device.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &targetID
        )

        if status == noErr {
            refreshDevices()
            refreshVolume()
            tv?.showToast("Audio: \(device.name)")
        }
    }

    // MARK: - Real-Time CoreAudio Listeners

    private func startListening() {
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
        self.defaultListenerBlock = defaultBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            defaultBlock
        )

        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshDevices() }
        }
        self.devicesListenerBlock = devicesBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            devicesBlock
        )
    }

    nonisolated private func stopListening() {
        if let block = defaultListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                DispatchQueue.main,
                block
            )
        }
        if let block = devicesListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                block
            )
        }
    }

    // MARK: - Low-Level Helpers

    private func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return size > 0
    }

    /// Aggregate and helper devices macOS keeps out of its own sound menu.
    private func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden)
        return status == noErr && hidden != 0
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfName)
        guard status == noErr, let name = cfName?.takeRetainedValue() as String? else { return nil }
        return name
    }

    private func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return transport
    }
}

extension TVController {
    func openAudioPicker() {
        audioCoordinator.refreshVolume()
        let currentIndex = audioDevices.firstIndex(where: { $0.isDefault }) ?? 0
        audioPicker = AudioPickerPanel(row: currentIndex)
    }

    func handleAudioPicker(_ command: RemoteCommand) {
        guard var panel = audioPicker else { return }
        let masterSliderRow = audioDevices.count
        let soundSliderRow = audioDevices.count + 1
        let maxRow = soundSliderRow

        switch command {
        case .back:
            audioPicker = nil
            return
        case .move(.up):
            panel.row = max(0, panel.row - 1)
        case .move(.down):
            panel.row = min(maxRow, panel.row + 1)
        case .move(.left):
            if panel.row == masterSliderRow {
                audioCoordinator.stepVolume(by: -5)
                return
            } else if panel.row == soundSliderRow {
                Feedback.shared.stepVolume(by: -0.05)
                return
            }
        case .move(.right):
            if panel.row == masterSliderRow {
                audioCoordinator.stepVolume(by: 5)
                return
            } else if panel.row == soundSliderRow {
                Feedback.shared.stepVolume(by: 0.05)
                return
            }
        case .select:
            if panel.row == masterSliderRow {
                audioCoordinator.toggleMute()
                return
            } else if panel.row == soundSliderRow {
                Feedback.shared.toggleMute()
                return
            } else if audioDevices.indices.contains(panel.row) {
                audioCoordinator.selectDevice(audioDevices[panel.row])
                return
            }
        case .volume(let delta):
            audioCoordinator.stepVolume(by: delta)
            return
        case .mute:
            audioCoordinator.toggleMute()
            return
        default:
            break
        }
        audioPicker = panel
    }
}

// MARK: - Audio Picker Sheet

struct AudioPickerSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let panel = tv.audioPicker ?? AudioPickerPanel()
        let masterSliderRow = tv.audioDevices.count
        let soundSliderRow = tv.audioDevices.count + 1

        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Audio Output").font(.tv(.title3, emphasized: true))
                Spacer()
                Button("Done") { tv.audioPicker = nil }
                    .buttonStyle(.plain)
                    .font(.tv(.caption1, emphasized: true))
                    .padding(.horizontal, 24)
                    .frame(height: 48)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            Text("Choose where sound plays from this Mac. Connect AirPods in System Settings › Bluetooth.")
                .font(.tv(.caption1))
                .foregroundStyle(.white.opacity(0.7))

            VStack(spacing: 12) {
                if tv.audioDevices.isEmpty {
                    Text("No audio output devices found")
                        .font(.tv(.callout))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ForEach(Array(tv.audioDevices.enumerated()), id: \.element.id) { index, device in
                        let focused = (panel.row == index)
                        HStack(spacing: 18) {
                            Image(systemName: device.symbol)
                                .font(.system(size: 30, weight: .medium))
                                .frame(width: 40)

                            Text(device.name)
                                .font(.tv(.callout, emphasized: device.isDefault))
                                .lineLimit(1)

                            Spacer(minLength: 12)

                            if device.isDefault {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 20, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 24)
                        .frame(height: 68)
                        .background(
                            focused ? Color.white : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                        .foregroundStyle(focused ? Color.black : Color.white)
                        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .scaleEffect(focused ? 1.02 : 1)
                        .onTapGesture {
                            tv.audioCoordinator.selectDevice(device)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Volume")
                    .font(.tv(.caption1, emphasized: true))
                    .foregroundStyle(.white.opacity(0.75))

                AudioVolumeSlider(tv: tv, focused: panel.row == masterSliderRow) {
                    tv.audioPicker?.row = masterSliderRow
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Navigation Sounds")
                    .font(.tv(.caption1, emphasized: true))
                    .foregroundStyle(.white.opacity(0.75))

                NavigationSoundSlider(focused: panel.row == soundSliderRow) {
                    tv.audioPicker?.row = soundSliderRow
                }
            }

            let hint: String = {
                if panel.row == masterSliderRow {
                    return "Use ◀ ▶ to change volume, Select to mute, Esc or Back closes."
                } else if panel.row == soundSliderRow {
                    return "Use ◀ ▶ to change sound effects volume, Select to mute, Esc or Back closes."
                } else {
                    return "Press Select to switch audio output. Esc or Back closes."
                }
            }()

            Text(hint)
                .font(.tv(.caption2))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(52)
        .frame(width: 820, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
    }
}

struct AudioVolumeSlider: View {
    @ObservedObject var tv: TVController
    let focused: Bool
    var onSelect: () -> Void = {}

    private var volume: VolumeLevel {
        tv.audioCoordinator.currentVolume
    }

    static func level(at x: CGFloat, width: CGFloat) -> Int {
        Int((max(0, min(1, x / width)) * 100).rounded())
    }

    private var symbol: String {
        guard let level = volume.level else { return "tv" }
        if volume.muted || level == 0 { return "speaker.slash.fill" }
        if level < 33 { return "speaker.wave.1.fill" }
        if level < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 16) {
            Button {
                tv.audioCoordinator.toggleMute()
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            if let level = volume.level {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(focused ? Color.white.opacity(0.35) : Color.white.opacity(0.18))

                        Capsule()
                            .fill(focused ? Color.white : Color.white.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(volume.muted ? 0 : level) / 100)
                    }
                    .frame(height: 12)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                tv.audioCoordinator.dragVolume(to: Self.level(at: value.location.x, width: geo.size.width))
                            }
                            .onEnded { value in
                                let level = Self.level(at: value.location.x, width: geo.size.width)
                                if level != volume.level || volume.muted { tv.audioCoordinator.setVolume(level) }
                            }
                    )
                }
                .frame(height: 36)

                Text(volume.muted ? "Muted" : "\(level)%")
                    .font(.tv(.caption1, emphasized: true))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 80, alignment: .trailing)
                    .foregroundStyle(focused ? .white : .white.opacity(0.75))
            } else {
                Text("Volume is set on the TV")
                    .font(.tv(.caption1))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(
            focused ? Color.white.opacity(0.16) : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(focused ? Color.white.opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .foregroundStyle(.white)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .scaleEffect(focused ? 1.02 : 1)
        .onTapGesture {
            onSelect()
        }
    }
}

struct NavigationSoundSlider: View {
    @ObservedObject private var feedback = Feedback.shared
    let focused: Bool
    var onSelect: () -> Void = {}

    private var percent: Int {
        Int((feedback.volume * 100).rounded())
    }

    private var symbol: String {
        if feedback.isMuted || percent == 0 { return "speaker.slash.fill" }
        if percent < 33 { return "speaker.wave.1.fill" }
        if percent < 66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 16) {
            Button {
                feedback.toggleMute()
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(focused ? Color.white.opacity(0.35) : Color.white.opacity(0.18))

                    Capsule()
                        .fill(focused ? Color.white : Color.white.opacity(0.85))
                        .frame(width: geo.size.width * CGFloat(feedback.isMuted ? 0 : percent) / 100)
                }
                .frame(height: 12)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            feedback.setVolumePercent(Int((fraction * 100).rounded()))
                        }
                )
            }
            .frame(height: 36)

            Text(feedback.isMuted ? "Muted" : "\(percent)%")
                .font(.tv(.caption1, emphasized: true))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 80, alignment: .trailing)
                .foregroundStyle(focused ? .white : .white.opacity(0.75))
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(
            focused ? Color.white.opacity(0.16) : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(focused ? Color.white.opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .foregroundStyle(.white)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .scaleEffect(focused ? 1.02 : 1)
        .onTapGesture {
            onSelect()
        }
    }
}
