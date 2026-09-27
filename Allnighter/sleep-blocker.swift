import Foundation
import IOKit.pwr_mgt

// 사용자 입력이 없어도 시스템과 화면이 잠들지 않게 하는 전원 assertion.
// 앱이 죽으면 OS 가 assertion 을 풀어 준다.
final class SleepBlocker {
    private var assertionID: IOPMAssertionID?

    func enable() throws {
        guard assertionID == nil else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Allnighter session" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            throw AllnighterError("Could not prevent sleep (IOPMAssertionCreateWithName \(result))")
        }
        assertionID = id
    }

    func disable() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
    }
}

struct AllnighterError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
