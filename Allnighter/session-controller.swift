import CoreGraphics
import Foundation
import Observation
import ServiceManagement
import UserNotifications

// 세션 상태의 단일 진실 공급원. 모든 전환은 메인 액터에서 줄을 서서(queue) 하나씩 일어난다 —
// XPC 를 기다리는 동안 다른 전환이 끼어들지 않고, 들어온 요청은 버려지지 않는다.
@MainActor
@Observable
final class SessionController {
    private(set) var isActive = false
    private(set) var endsAt: Date?
    private(set) var isBusy = false
    private(set) var lastError: String?

    // 세션 중 이만큼 입력이 없으면 화면을 어둡게 한다. nil 이면 어둡게 하지 않는다.
    var dimAfterMinutes: Int? {
        didSet {
            if let dimAfterMinutes {
                UserDefaults.standard.set(dimAfterMinutes, forKey: Self.dimAfterMinutesKey)
            } else {
                UserDefaults.standard.set(Self.dimOff, forKey: Self.dimAfterMinutesKey)
            }
        }
    }
    var lidAwake: Bool {
        didSet { UserDefaults.standard.set(lidAwake, forKey: Self.lidAwakeKey) }
    }

    private static let dimAfterMinutesKey = "dimAfterMinutes"
    private static let lidAwakeKey = "lidAwake"
    // 끈 것은 0 으로 적는다 — 키를 지우면 기본값으로 돌아가 버린다.
    private static let dimOff = 0
    #if !APP_STORE
    // 고른 적이 없으면 5분 뒤 어둡게 한다. App Store 판은 키 권한을 먼저 받아야 해서 꺼진 채로 시작한다.
    private static let defaultDimAfterMinutes = 5
    #endif

    private let sleepBlocker = SleepBlocker()
    private var timer: Task<Void, Never>?
    private var queue: Task<Void, Never>?
    private let brightness: BrightnessController?
    private var idleWatcher: Task<Void, Never>?
    private var safetyWatcher: Task<Void, Never>?
    #if !APP_STORE
    private let lid = LidController()
    private var approvalWatcher: Task<Void, Never>?
    #endif

    init() {
        #if !APP_STORE
        UserDefaults.standard.register(defaults: [Self.dimAfterMinutesKey: Self.defaultDimAfterMinutes])
        #endif
        let storedDimAfter = UserDefaults.standard.integer(forKey: Self.dimAfterMinutesKey)
        dimAfterMinutes = storedDimAfter == Self.dimOff ? nil : storedDimAfter
        lidAwake = UserDefaults.standard.bool(forKey: Self.lidAwakeKey)
        do {
            let brightness = try BrightnessController()
            // 지난번에 어둡게 한 채 죽었다면 여기서 되돌린다.
            try brightness.restorePending()
            self.brightness = brightness
        } catch {
            brightness = nil
            lastError = error.localizedDescription
        }
        // 안전 때문에 끊으면 알린다 — 메뉴를 열어 보기 전엔 왜 멈췄는지 모른다. 거절하면 알리지 않는다.
        Task { [weak self] in
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    #if APP_STORE
    // App Store 판은 원래 밝기를 읽을 수 없어, 돌아왔을 때의 밝기(0~16칸)를 사용자가 고른다.
    var restoreBrightnessSteps: Int? {
        brightness?.restoreSteps
    }

    func setRestoreBrightness(steps: Int) {
        brightness?.restoreSteps = steps
    }

    // 어둡게 하기를 켰는데 키 권한이 아직 이 프로세스에 없다 — 허용했다면 다시 켜야 한다.
    var dimNeedsReopen: Bool {
        guard dimAfterMinutes != nil, let brightness else { return false }
        return !brightness.hasAccess
    }
    #endif

    // minutes 가 nil 이면 끌 때까지 계속.
    func start(minutes: Int?) {
        enqueue { await $0.performStart(minutes: minutes) }
    }

    func stop() {
        enqueue { await $0.performStop() }
    }

    // 세션 중에 옵션을 바꾸면 바로 적용한다.
    func setDimAfter(minutes: Int?) {
        enqueue { await $0.performSetDimAfter(minutes: minutes) }
    }

    func setLidAwake(_ on: Bool) {
        enqueue { await $0.performSetLidAwake(on) }
    }

    // 앱 종료 직전에 부른다. 줄에 선 작업이 끝난 뒤 되돌린다.
    func shutdown() async {
        stop()
        await queue?.value
    }

    private func enqueue(_ operation: @escaping @MainActor (SessionController) async -> Void) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            self.isBusy = true
            await operation(self)
            self.isBusy = false
        }
    }

    private func performStart(minutes: Int?) async {
        if let reason = SafetyStop.current() {
            lastError = reason.menuText
            return
        }
        lastError = nil
        do {
            try sleepBlocker.enable()
            #if !APP_STORE
            if lidAwake { try await enableLid() }
            #endif
            isActive = true
            schedule(minutes: minutes)
            updateIdleWatcher()
            watchSafety()
        } catch {
            lastError = error.localizedDescription
            await tearDown()
        }
    }

    private func performStop() async {
        guard isActive else { return }
        lastError = nil
        await tearDown()
    }

    // 세션 중 5초마다 끊어야 할 상황인지 본다. 판정은 줄에 선 작업 안에서 다시 한다 — 그새 바뀌었을 수 있다.
    private func watchSafety() {
        safetyWatcher?.cancel()
        safetyWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if SafetyStop.current() != nil { self.enqueue { await $0.performSafetyStop() } }
            }
        }
    }

    // 세션을 끄고 알린 뒤, 뚜껑이 닫혀 있으면 바로 재운다 — 잠들기 막기를 풀기만 해서는 닫힌 맥이 잠들지 않는다
    // (충전 중엔 화면 끄기가 꺼져 있고 caffeinate 등이 유휴 잠자기를 막는다). 상황이 풀려도 다시 켜지 않는다.
    private func performSafetyStop() async {
        guard isActive, let reason = SafetyStop.current() else { return }
        await tearDown()
        if lastError == nil { lastError = reason.menuText }
        await notify(reason)
        #if !APP_STORE
        if LidController.isClosed {
            do {
                try LidController.sleepNow()
            } catch {
                lastError = error.localizedDescription
            }
        }
        #endif
    }

    private func notify(_ reason: SafetyStop) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Allnighter stopped"
        content.body = reason.notificationBody
        do {
            try await center.add(UNNotificationRequest(identifier: "safety-stop", content: content, trigger: nil))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func performSetDimAfter(minutes: Int?) async {
        dimAfterMinutes = minutes
        lastError = nil
        do {
            try brightness?.restorePending()
            if minutes != nil { try brightness?.ensureAccess() }
        } catch {
            lastError = error.localizedDescription
        }
        updateIdleWatcher()
    }

    // 어느 입력이든(kCGAnyInputEventType) 마지막으로 들어온 뒤 지난 시간을 본다.
    private static let anyInput: CGEventType = {
        guard let type = CGEventType(rawValue: ~0) else { fatalError("kCGAnyInputEventType is unavailable") }
        return type
    }()

    // 세션이 켜져 있고 시간이 정해져 있으면, 입력이 그만큼 없을 때 어둡게 하고 입력이 들어오면 바로 되돌린다.
    // 뚜껑 닫기를 켰으면 닫힌 동안 화면을 끄고, 열면 어둡게 한 것까지 되돌린다(시간을 정하지 않았어도).
    private func updateIdleWatcher() {
        idleWatcher?.cancel()
        idleWatcher = nil
        // 이전 감시가 뚜껑이 닫힌 채 끝났으면 화면 유지가 내려가 있다 — 세션 중이면 다시 건다.
        if isActive {
            do {
                try sleepBlocker.enable()
            } catch {
                lastError = error.localizedDescription
            }
        }
        #if APP_STORE
        let watchesLid = false
        #else
        let watchesLid = lidAwake
        #endif
        guard isActive, dimAfterMinutes != nil || watchesLid else { return }
        guard let brightness else {
            lastError = "Display dimming is unavailable"
            return
        }
        let threshold = dimAfterMinutes.map { TimeInterval($0 * 60) }
        idleWatcher = Task { [weak self] in
            // App Store 판은 밝기 키를 보내 어둡게 하는데, 그 키도 입력으로 잡힌다. 어둡게 한 뒤 키를 다 보낼 때까지(settle)
            // 들어온 입력은 무시하고, 그 뒤에 들어온 입력만 사람이 돌아온 것으로 본다.
            let settle: TimeInterval = 2
            var dimmedAt: Date?
            var lidWasClosed = false
            #if !APP_STORE
            var displayOffRequestedAt: Date?
            #endif
            while !Task.isCancelled {
                guard let self else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.anyInput)
                #if APP_STORE
                let lidClosed = false
                #else
                let lidClosed = watchesLid && LidController.isClosed
                #endif
                let idleExpired: Bool
                if let threshold { idleExpired = idle >= threshold } else { idleExpired = false }
                do {
                    #if !APP_STORE
                    try self.holdDisplayOff(lidClosed: lidClosed, lidWasClosed: lidWasClosed, requestedAt: &displayOffRequestedAt)
                    #endif
                    if let since = dimmedAt.map({ Date().timeIntervalSince($0) }) {
                        if !lidClosed, lidWasClosed || (since > settle && idle < since - settle) {
                            try brightness.restorePending()
                            dimmedAt = nil
                        }
                    } else if !lidClosed, idleExpired {
                        try brightness.dim()
                        dimmedAt = Date()
                        self.lastError = nil
                    }
                } catch {
                    // 권한을 아직 안 줬을 수 있다 — 알리고 계속 본다(허용하면 다음 차례에 된다).
                    self.lastError = error.localizedDescription
                }
                lidWasClosed = lidClosed
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    #if !APP_STORE
    // 뚜껑이 닫힌 동안은 화면을 아예 끈다 — 밝기 0 이어도 켜져 있으면 계속 그려 열과 배터리를 쓴다.
    // 이 앱의 화면 유지가 걸려 있으면 끄자마자 다시 켜져(실측) 닫힌 동안은 내려놓는다. 시스템은 헬퍼가 깨워 둔다.
    // 다른 앱의 활동 신호에 화면이 다시 켜질 수 있어, 켜져 있으면 displayOffRetry 마다 다시 끈다.
    private func holdDisplayOff(lidClosed: Bool, lidWasClosed: Bool, requestedAt: inout Date?) throws {
        if lidClosed {
            if !lidWasClosed { sleepBlocker.disable() }
            guard LidController.isBuiltInDisplayAwake else { return }
            if let requestedAt, Date().timeIntervalSince(requestedAt) < Self.displayOffRetry { return }
            requestedAt = Date()
            try LidController.sleepDisplay()
        } else if lidWasClosed {
            requestedAt = nil
            try sleepBlocker.enable()
        }
    }

    private static let displayOffRetry: TimeInterval = 10
    #endif

    private func performSetLidAwake(_ on: Bool) async {
        lidAwake = on
        #if !APP_STORE
        approvalWatcher?.cancel()
        approvalWatcher = nil
        guard isActive else { return }
        do {
            if on { try await enableLid() } else { try await lid.disable() }
        } catch {
            lastError = error.localizedDescription
        }
        updateIdleWatcher()
        #endif
    }

    #if !APP_STORE
    // 헬퍼가 아직 허용 전이면 세션은 그대로 두고, 허용되는 즉시 다시 켠다 — 사용자가 메뉴를 다시 누를 필요가 없다.
    private func enableLid() async throws {
        approvalWatcher?.cancel()
        approvalWatcher = nil
        do {
            try await lid.enable()
        } catch let error as LidApprovalRequired {
            lastError = error.localizedDescription
            watchApproval()
        }
    }

    private func watchApproval() {
        approvalWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if self.lid.isApproved {
                    self.enqueue { await $0.performRetryLid() }
                    return
                }
            }
        }
    }

    private func performRetryLid() async {
        guard isActive, lidAwake else { return }
        lastError = nil
        do {
            try await enableLid()
        } catch {
            lastError = error.localizedDescription
        }
    }
    #endif

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func schedule(minutes: Int?) {
        timer?.cancel()
        guard let minutes else {
            endsAt = nil
            timer = nil
            return
        }
        endsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    // 켠 것을 모두 되돌린다. 하나가 실패해도 나머지는 계속 되돌리고, 첫 오류를 남긴다.
    private func tearDown() async {
        timer?.cancel()
        timer = nil
        endsAt = nil
        safetyWatcher?.cancel()
        safetyWatcher = nil
        sleepBlocker.disable()
        idleWatcher?.cancel()
        idleWatcher = nil
        do {
            try brightness?.restorePending()
        } catch {
            if lastError == nil { lastError = error.localizedDescription }
        }
        #if !APP_STORE
        approvalWatcher?.cancel()
        approvalWatcher = nil
        do {
            try await lid.disable()
        } catch {
            if lastError == nil { lastError = error.localizedDescription }
        }
        #endif
        isActive = false
    }
}
