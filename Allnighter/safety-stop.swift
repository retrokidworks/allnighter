import Foundation
import IOKit.ps

// 세션을 이어 가면 안 되는 상황. 가방 속에서 뚜껑 닫기 모드로 둔 맥이 배터리로 5시간을 깨어 있다가
// 75분 만에 열 압박 heavy 에 올라 4시간을 그대로 버텼다(실측) — 그 길목마다 끊는다.
enum SafetyStop {
    case tooHot
    case inBag
    case batteryLow

    // 배터리로 돌 때 이 아래로 내려가면 끊는다 — 잠들기를 막은 채 바닥나면 작업을 잃고 꺼진다.
    static let lowBatteryPercent = 10

    // 지금 끊어야 하면 그 이유. 여럿이면 앞의 것.
    static func current() -> SafetyStop? {
        // heavy 가 thermalState 로는 .serious 다.
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return .tooHot }
        let power = PowerStatus.read()
        guard power.onBattery else { return nil }
        #if !APP_STORE
        // 뚜껑을 닫고 전원선을 뺐으면 들고 나간 것이다. App Store 판에는 뚜껑 닫기 모드가 없어 닫으면 그냥 잠든다.
        if LidController.isClosed { return .inBag }
        #endif
        guard let percent = power.batteryPercent else { fatalError("Running on battery power without a battery") }
        return percent <= lowBatteryPercent ? .batteryLow : nil
    }

    // 메뉴에 남기는 한 줄.
    var menuText: String {
        switch self {
        case .tooHot: "Stopped: your Mac got too hot"
        case .inBag: "Stopped: lid closed on battery"
        case .batteryLow: "Stopped: battery at \(Self.lowBatteryPercent)%"
        }
    }

    // 알림 본문 — 돌아온 사람이 왜 멈췄는지 알게 한다.
    var notificationBody: String {
        switch self {
        case .tooHot: "Your Mac got too hot, so Allnighter stopped keeping it awake."
        case .inBag: "The lid was closed on battery power, so Allnighter let your Mac sleep."
        case .batteryLow: "The battery dropped to \(Self.lowBatteryPercent)%, so Allnighter stopped keeping your Mac awake."
        }
    }
}

struct PowerStatus {
    let onBattery: Bool
    // 배터리가 없는 맥(데스크톱)은 nil.
    let batteryPercent: Int?

    static func read() -> PowerStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { fatalError("IOPSCopyPowerSourcesInfo failed") }
        guard let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            fatalError("IOPSGetProvidingPowerSourceType failed")
        }
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            fatalError("IOPSCopyPowerSourcesList failed")
        }
        var batteryPercent: Int?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                fatalError("Power source has no description")
            }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else {
                fatalError("Battery capacity is missing")
            }
            batteryPercent = current * 100 / max
        }
        return PowerStatus(onBattery: (providing as String) == kIOPMBatteryPowerKey, batteryPercent: batteryPercent)
    }
}
