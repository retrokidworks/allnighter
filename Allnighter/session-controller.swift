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
        didSet { UserDefaults.standard.set(dimAfterMinutes, forKey: Self.dimAfterMinutesKey) }
    }
    var lidAwake: Bool {
        didSet { UserDefaults.standard.set(lidAwake, forKey: Self.lidAwakeKey) }
    }

    private static let dimAfterMinutesKey = "dimAfterMinutes"
    private static let lidAwakeKey = "lidAwake"

    private let sleepBlocker = SleepBlocker()
    private var timer: Task<Void, Never>?
    private var queue: Task<Void, Never>?
    #if !APP_STORE
    private let brightness: BrightnessController?
    private let lid = LidController()
    private var idleWatcher: Task<Void, Never>?
    #endif

    init() {
        dimAfterMinutes = UserDefaults.standard.object(forKey: Self.dimAfterMinutesKey) as? Int
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
            if lidAwake { try await lid.enable() }
            #endif
            isActive = true
            schedule(minutes: minutes)
            #if !APP_STORE
            updateIdleWatcher()
            #endif
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
        #if !APP_STORE
        do {
            try brightness?.restorePending()
        } catch {
            lastError = error.localizedDescription
        }
        updateIdleWatcher()
        #endif
    }

    #if !APP_STORE
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
            while !Task.isCancelled {
                guard let self else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.anyInput)
                do {
                    if idle >= threshold {
                        try brightness.dim()
                    } else if brightness.isDimmed {
                        try brightness.restorePending()
                    }
                } catch {
                    self.lastError = error.localizedDescription
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
    #endif

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
        idleWatcher?.cancel()
        idleWatcher = nil
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
