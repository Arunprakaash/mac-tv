import Testing
@testable import MacTV

@Suite
struct ControllerHapticsTests {
    @Test @MainActor func cuesRankByRole() {
        let move = Feedback.controllerPulse(for: .move, rotatingMotors: true)
        let select = Feedback.controllerPulse(for: .select, rotatingMotors: true)
        let back = Feedback.controllerPulse(for: .back, rotatingMotors: true)
        #expect(move.duration >= 0.2)
        #expect(select.intensity > move.intensity)
        #expect(move.sharpness > select.sharpness)
        #expect(select.sharpness > back.sharpness)
        #expect(back.duration >= select.duration)
        #expect(move.intensity < 0.35)
        #expect(select.intensity < 0.55)
    }

    @Test @MainActor func dualSensePulsesStayShort() {
        let move = Feedback.controllerPulse(for: .move, rotatingMotors: false)
        #expect(move.duration < 0.12)
        #expect(move.intensity < 0.35)
    }

    @Test @MainActor func envelopesMatchCueShapes() {
        let move = Feedback.intensityEnvelope(for: .move, duration: 0.22)
        let select = Feedback.intensityEnvelope(for: .select, duration: 0.28)
        let back = Feedback.intensityEnvelope(for: .back, duration: 0.30)
        #expect(move.controlPoints.map(\.value).max() == 1.0)
        #expect(select.controlPoints.map(\.value).max() == 1.0)
        // Back stays a single dull wave (no second peak at 1.0).
        #expect((back.controlPoints.map(\.value).max() ?? 0) < 1.0)
        #expect(back.controlPoints.last?.value == 0)
        #expect((move.controlPoints.first?.value ?? 0) >= 0.3)
    }

    @Test @MainActor func volumeStepRampsThenCaps() {
        #expect(ControllerInput.volumeStep(heldFor: 0) == 1)
        #expect(ControllerInput.volumeStep(heldFor: 0.5) == 2)
        #expect(ControllerInput.volumeStep(heldFor: 1.2) == 3)
        #expect(ControllerInput.volumeStep(heldFor: 10) == 3)
        // At ten ticks a second, a one-second squeeze stays under a quarter of the range.
        let firstSecond = (0..<10).map { ControllerInput.volumeStep(heldFor: Double($0) * 0.1) }.reduce(0, +)
        #expect(firstSecond <= 25)
    }
}
