import CoreAudio
import Foundation
import Testing
@testable import MacTV

@Suite @MainActor
struct AudioOutputTests {
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
        let coordinator = AudioCoordinator()
        #expect(!coordinator.devices.isEmpty)
        #expect(coordinator.currentDevice != nil)
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

        // Dismiss with Back
        tv.handleAudioPicker(.back)
        #expect(tv.audioPicker == nil)
        #expect(tv.activeSheet == nil)
    }
}
