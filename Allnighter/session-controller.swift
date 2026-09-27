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

    var dimDisplay: Bool {
        didSet { UserDefaults.standard.set(dimDisplay, forKey: Self.dimDisplayKey) }
    }
    var lidAwake: Bool {
        didSet { UserDefaults.standard.set(lidAwake, forKey: Self.lidAwakeKey) }
    }

    private static let dimDisplayKey = "dimDisplay"
    private static let lidAwakeKey = "lidAwake"

    private let sleepBlocker = SleepBlocker()
    private var timer: Task<Void, Never>?
    private var queue: Task<Void, Never>?
    #if !APP_STORE
    private let brightness: BrightnessController?
    private let lid = LidController()
    #endif

    init() {
        dimDisplay = UserDefaults.standard.bool(forKey: Self.dimDisplayKey)
        lidAwake = UserDefaults.standard.bool(forKey: Self.lidAwakeKey)
        #if !APP_STORE
        do {
            let brightness = try BrightnessController()
            // 지난번에 어둡게 한 채 죽었다면 여기서 되돌린다.
            try brightness.restorePending()
            self.brightness = brightness
        } catch {
            brightness = nil
            lastError = error.localizedDescription
        }
        #endif
    }

    // minutes 가 nil 이면 끌 때까지 계속.
    func start(minutes: Int?) {
        enqueue { await $0.performStart(minutes: minutes) }
    }

    func stop() {
        enqueue { await $0.performStop() }
    }

    // 세션 중에 옵션을 바꾸면 바로 적용한다.
    func setDimDisplay(_ on: Bool) {
        enqueue { await $0.performSetDimDisplay(on) }
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
            if dimDisplay {
                guard let brightness else { throw AllnighterError("Display dimming is unavailable") }
                try brightness.dim()
            }
            if lidAwake { try await lid.enable() }
            #endif
            isActive = true
            schedule(minutes: minutes)
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

    private func performSetDimDisplay(_ on: Bool) async {
        dimDisplay = on
        #if !APP_STORE
        guard isActive else { return }
        do {
            guard let brightness else { throw AllnighterError("Display dimming is unavailable") }
            if on { try brightness.dim() } else { try brightness.restorePending() }
        } catch {
            lastError = error.localizedDescription
        }
        #endif
    }

    private func performSetLidAwake(_ on: Bool) async {
        lidAwake = on
        #if !APP_STORE
        guard isActive else { return }
        do {
            if on { try await lid.enable() } else { try await lid.disable() }
        } catch {
            lastError = error.localizedDescription
        }
        #endif
    }

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
        #if !APP_STORE
        do {
            try brightness?.restorePending()
        } catch {
            if lastError == nil { lastError = error.localizedDescription }
        }
        do {
            try await lid.disable()
        } catch {
            if lastError == nil { lastError = error.localizedDescription }
        }
        #endif
        isActive = false
    }
}
