import Foundation
import IOKit.ps
import IOKit.pwr_mgt

// root LaunchDaemon. `pmset -a disablesleep 1` 과 같은 설정(SleepDisabled)을 켜고 끈다.
// 이 설정은 프로세스가 죽어도 저절로 풀리지 않는다 — 그래서 켜 둔 연결이 끊기면 끄고,
// 헬퍼가 시작될 때(재부팅·재시작)도 먼저 끈다.
// IOPMSetSystemPowerSetting 과 SleepDisabled 키는 IOKit 이 내보내지만 공개 헤더에 없다(IOPMLibPrivate.h).
let sleepDisabledKey = "SleepDisabled" as CFString
typealias SetSystemPowerSetting = @convention(c) (CFString, CFTypeRef) -> IOReturn
let setSystemPowerSetting: SetSystemPowerSetting = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPMSetSystemPowerSetting") else {
        fatalError("IOPMSetSystemPowerSetting not found")
    }
    return unsafeBitCast(symbol, to: SetSystemPowerSetting.self)
}()

final class LidState {
    // setLidAwake(true) 를 보낸 연결들. 하나라도 있으면 켠다.
    private var holders = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "lid-state")

    func set(_ on: Bool, for connection: NSXPCConnection) -> String? {
        queue.sync {
            if on { holders.insert(ObjectIdentifier(connection)) } else { holders.remove(ObjectIdentifier(connection)) }
            return applyLocked()
        }
    }

    func release(_ connection: NSXPCConnection) {
        queue.sync {
            holders.remove(ObjectIdentifier(connection))
            _ = applyLocked()
        }
    }

    // 전원선을 꽂거나 뽑으면 Apple Silicon 맥북이 이 설정을 무시하고 잠드는 일이 있어 다시 적용한다.
    func reapply() {
        queue.sync { _ = applyLocked() }
    }

    private func applyLocked() -> String? {
        let value: CFBoolean = holders.isEmpty ? kCFBooleanFalse : kCFBooleanTrue
        let result = setSystemPowerSetting(sleepDisabledKey, value)
        return result == kIOReturnSuccess ? nil : "IOPMSetSystemPowerSetting failed: \(result)"
    }
}

final class HelperService: NSObject, HelperProtocol {
    private let state: LidState
    private weak var connection: NSXPCConnection?

    init(state: LidState, connection: NSXPCConnection) {
        self.state = state
        self.connection = connection
    }

    func setLidAwake(_ on: Bool, reply: @escaping (String?) -> Void) {
        guard let connection else { return reply("connection is gone") }
        reply(state.set(on, for: connection))
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let state: LidState

    init(state: LidState) {
        self.state = state
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(HelperContract.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService(state: state, connection: connection)
        connection.invalidationHandler = { [state, unowned connection] in state.release(connection) }
        connection.interruptionHandler = { [state, unowned connection] in state.release(connection) }
        connection.resume()
        return true
    }
}

let state = LidState()
state.reapply()

let powerSourceCallback: IOPowerSourceCallbackType = { _ in state.reapply() }
guard let powerSource = IOPSNotificationCreateRunLoopSource(powerSourceCallback, nil)?.takeRetainedValue() else {
    fatalError("IOPSNotificationCreateRunLoopSource failed")
}
CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode)

let delegate = ListenerDelegate(state: state)
let listener = NSXPCListener(machServiceName: HelperContract.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
