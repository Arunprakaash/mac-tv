import CoreAudio
import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct AudioOutputTests {
    init() { AudioCoordinator.readVolume = { VolumeLevel(level: 50, muted: false) } }

    @Test
    func deviceSymbolMappingMatchesEndpointTypes() {
        let airPodsPro = AudioOutputDevice(id: 1, name: "Pratik’s AirPods Pro", transport: 0, isDefault: true)
        #expect(airPodsPro.symbol == "airpodspro")

        let airPodsMax = AudioOutputDevice(id: 2, name: "Living Room AirPods Max", transport: 0, isDefault: false)
        #expect(airPodsMax.symbol == "airpodsmax")

        let airPods = AudioOutputDevice(id: 3, name: "AirPods", transport: 0, isDefault: false)
        #expect(airPods.symbol == "airpods")

        let beats = AudioOutputDevice(id: 4, name: "Beats Solo", transport: 0, isDefault: false)
        #expect(beats.symbol == "headphones")

        let btHeadphones = AudioOutputDevice(id: 5, name: "WH-1000XM5", transport: kAudioDeviceTransportTypeBluetooth, isDefault: false)
        #expect(btHeadphones.symbol == "headphones")

        let hdmiTV = AudioOutputDevice(id: 6, name: "LG TV", transport: kAudioDeviceTransportTypeHDMI, isDefault: false)
        #expect(hdmiTV.symbol == "tv.fill")

        let dprtMonitor = AudioOutputDevice(id: 7, name: "DELL S2721DS", transport: 0x64707274, isDefault: false)
        #expect(dprtMonitor.symbol == "tv.fill")

        let airPlay = AudioOutputDevice(id: 8, name: "HomePod", transport: kAudioDeviceTransportTypeAirPlay, isDefault: false)
        #expect(airPlay.symbol == "airplayaudio")

        let builtIn = AudioOutputDevice(id: 9, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn, isDefault: true)
        #expect(builtIn.symbol == "speaker.wave.2.fill")
    }

    @Test
    func coordinatorDiscoversSystemOutputs() {
        // Build machines may have no sound output at all.
        let coordinator = AudioCoordinator()
        if let current = coordinator.currentDevice {
            #expect(coordinator.devices.contains(current))
        }
    }

    @Test
    func audioPickerNavigationAndSheetRouting() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("work/tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let tv = TVController(library: AppLibrary(folder: folder))
        #expect(tv.audioPicker == nil)
        #expect(tv.activeSheet == nil)

        tv.openAudioPicker()
        #expect(tv.audioPicker != nil)
        #expect(tv.activeSheet == .audioPicker)
        #expect(tv.isTopSheet(.audioPicker))

        // Deterministic navigation check
        tv.audioPicker?.row = 0
        if tv.audioDevices.count > 1 {
            tv.handleAudioPicker(.move(.down))
            #expect(tv.audioPicker?.row == 1)
            tv.handleAudioPicker(.move(.up))
            #expect(tv.audioPicker?.row == 0)
        }

        // Boundary clamp at top
        tv.handleAudioPicker(.move(.up))
        #expect(tv.audioPicker?.row == 0)

        // Volume slider navigation
        let sliderRow = tv.audioDevices.count
        tv.audioPicker?.row = sliderRow

        // ◀ ▶ here change the Mac's real volume, so the test only checks focus can reach it.
        #expect(tv.isTopSheet(.audioPicker))

        // Navigation sound slider
        let soundSliderRow = tv.audioDevices.count + 1
        tv.audioPicker?.row = soundSliderRow

        let (savedVolume, savedEnabled) = (Feedback.shared.volume, Feedback.shared.enabled)
        defer { Feedback.shared.volume = savedVolume; Feedback.shared.enabled = savedEnabled }
        Feedback.shared.volume = 0.50
        Feedback.shared.enabled = true
        tv.handleAudioPicker(.move(.left))
        #expect(abs(Feedback.shared.volume - 0.45) < 0.01)

        tv.handleAudioPicker(.move(.right))
        #expect(abs(Feedback.shared.volume - 0.50) < 0.01)

        tv.handleAudioPicker(.select)
        #expect(Feedback.shared.isMuted)
        tv.handleAudioPicker(.select)
        #expect(!Feedback.shared.isMuted)

        // Dismiss with Back
        tv.handleAudioPicker(.back)
        #expect(tv.audioPicker == nil)
        #expect(tv.activeSheet == nil)
    }

    @Test
    func controlCenterItemsExcludeSounds() {
        #expect(!ControlCenterPanel.Item.allCases.contains(where: { "\($0)" == "sounds" }))
        #expect(ControlCenterPanel.neighbour(of: .sleepTimer, .down) == .controller)
        #expect(ControlCenterPanel.neighbour(of: .controller, .up) == .sleepTimer)
    }
}
