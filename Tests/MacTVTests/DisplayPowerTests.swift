import IOKit.pwr_mgt
import Testing
@testable import MacTV

@Suite struct DisplayPowerTests {
    @Test func successfulWakeReleasesTheAcquiredAssertion() {
        var released: IOPMAssertionID?
        var scheduled: (() -> Void)?
        let result = DisplayPower.wake(declare: { id in id = 73; return kIOReturnSuccess },
                                       release: { released = $0 }, schedule: { scheduled = $0 })
        #expect(result)
        #expect(released == nil)
        scheduled?()
        #expect(released == 73)
    }

    @Test func failedWakeDoesNotReleaseOrSchedule() {
        var scheduled = false
        var released = false
        let result = DisplayPower.wake(declare: { _ in IOReturn(-1) },
                                       release: { _ in released = true }, schedule: { _ in scheduled = true })
        #expect(!result)
        #expect(!scheduled)
        #expect(!released)
    }
}
