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
            guard hasOutputStreams(id) else { continue }
            guard let name = deviceName(id) else { continue }
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

        self.devices = newDevices
        self.currentDevice = newDevices.first(where: { $0.id == defaultID })
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
        let currentIndex = audioDevices.firstIndex(where: { $0.isDefault }) ?? 0
        audioPicker = AudioPickerPanel(row: currentIndex)
    }

    func handleAudioPicker(_ command: RemoteCommand) {
        guard var panel = audioPicker else { return }
        switch command {
        case .back:
            audioPicker = nil
            return
        case .move(.up):
            if !audioDevices.isEmpty {
                panel.row = max(0, panel.row - 1)
            }
        case .move(.down):
            if !audioDevices.isEmpty {
                panel.row = min(audioDevices.count - 1, panel.row + 1)
            }
        case .select:
            if audioDevices.indices.contains(panel.row) {
                audioCoordinator.selectDevice(audioDevices[panel.row])
                audioPicker = nil
                return
            }
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
        VStack(alignment: .leading, spacing: 26) {
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
                            tv.audioPicker = nil
                        }
                    }
                }
            }

            Text("Press Select to switch audio output. Esc or Back closes.")
                .font(.tv(.caption2))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(56)
        .frame(width: 820, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: panel)
    }
}
