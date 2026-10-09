import CoreGraphics
import Foundation
import Observation
import ServiceManagement

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
        lastError = nil
        do {
            try sleepBlocker.enable()
            #if !APP_STORE
            if lidAwake { try await enableLid() }
            #endif
            isActive = true
            schedule(minutes: minutes)
            updateIdleWatcher()
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
    private func updateIdleWatcher() {
        idleWatcher?.cancel()
        idleWatcher = nil
        guard isActive, let minutes = dimAfterMinutes else { return }
        guard let brightness else {
            lastError = "Display dimming is unavailable"
            return
        }
        let threshold = TimeInterval(minutes * 60)
        idleWatcher = Task { [weak self] in
            // App Store 판은 밝기 키를 보내 어둡게 하는데, 그 키도 입력으로 잡힌다. 어둡게 한 뒤 키를 다 보낼 때까지(settle)
            // 들어온 입력은 무시하고, 그 뒤에 들어온 입력만 사람이 돌아온 것으로 본다.
            let settle: TimeInterval = 2
            var dimmedAt: Date?
            while !Task.isCancelled {
                guard let self else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.anyInput)
                do {
                    if let since = dimmedAt.map({ Date().timeIntervalSince($0) }) {
                        if since > settle, idle < since - settle {
                            try brightness.restorePending()
                            dimmedAt = nil
                        }
                    } else if idle >= threshold {
                        try brightness.dim()
                        dimmedAt = Date()
                        self.lastError = nil
                    }
                } catch {
                    // 권한을 아직 안 줬을 수 있다 — 알리고 계속 본다(허용하면 다음 차례에 된다).
                    self.lastError = error.localizedDescription
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

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
