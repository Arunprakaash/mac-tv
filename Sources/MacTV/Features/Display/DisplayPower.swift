import Foundation
import IOKit.pwr_mgt

/// Reports nearby user activity to power management without injecting input into an app.
enum DisplayPower {
    typealias Declare = (inout IOPMAssertionID) -> IOReturn
    typealias Release = (IOPMAssertionID) -> Void
    typealias Schedule = (@escaping () -> Void) -> Void

    /// Success means macOS accepted the request, not that an external display powered on.
    /// The short-lived assertion is released after the wake request has had time to propagate.
    @discardableResult
    static func wake(
        declare: Declare = { assertion in
            IOPMAssertionDeclareUserActivity("Mac TV remote display wake" as CFString, kIOPMUserActiveLocal, &assertion)
        },
        release: @escaping Release = { _ = IOPMAssertionRelease($0) },
        schedule: Schedule = { action in DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: action) }
    ) -> Bool {
        var assertion: IOPMAssertionID = 0
        guard declare(&assertion) == kIOReturnSuccess else { return false }
        let acquired = assertion
        schedule { release(acquired) }
        return true
    }
}
