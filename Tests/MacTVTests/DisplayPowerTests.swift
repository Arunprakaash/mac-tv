import IOKit.pwr_mgt
import Testing
@testable import MacTV

/// Holds what a test's closures record. They run on the test's own thread, one at a time.
private final class Record<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@Suite struct DisplayPowerTests {
    @Test func successfulWakeReleasesTheAcquiredAssertion() {
        let released = Record<IOPMAssertionID?>(nil)
        var scheduled: (@Sendable () -> Void)?
        let result = DisplayPower.wake(declare: { id in id = 73; return kIOReturnSuccess },
                                       release: { released.value = $0 }, schedule: { scheduled = $0 })
        #expect(result)
        #expect(released.value == nil)
        scheduled?()
        #expect(released.value == 73)
    }

    @Test func failedWakeDoesNotReleaseOrSchedule() {
        var scheduled = false
        let released = Record(false)
        let result = DisplayPower.wake(declare: { _ in IOReturn(-1) },
                                       release: { _ in released.value = true }, schedule: { _ in scheduled = true })
        #expect(!result)
        #expect(!scheduled)
        #expect(!released.value)
    }
}
