import AppKit
import CoreGraphics

// App Store 판의 화면 어둡게. 샌드박스라 백라이트를 직접 만질 수 없어 밝기 키를 보낸다.
// 키를 보내려면 사용자가 System Settings › Privacy & Security 에서 허용해야 한다(PostEvent 권한).
// 현재 밝기를 읽을 공개 API 가 없어 정확히 되돌리지 못한다 — 16번 내려 끄고, 돌아올 때는 메뉴에서 고른 밝기까지 올린다.
// 직접 배포판은 brightness-controller.swift(같은 이름·같은 사용법)를 쓴다.
final class BrightnessController {
    // 밝기 키 한 번이 1/16 이다.
    static let steps = 16
    private static let restoreStepsKey = "restoreBrightnessSteps"
    private static let brightnessUp = 2    // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown = 3  // NX_KEYTYPE_BRIGHTNESS_DOWN

    // 어둡게 한 상태를 디스크에 표시해 둔다 — 어둡게 한 채 앱이 죽어도 다음 실행 때 restorePending() 이 되돌린다.
    private let dimmedMarkURL: URL
    // 키는 보낸 순서대로 나가야 한다(내리는 중에 올리기가 끼면 안 된다).
    private let keys = DispatchQueue(label: "brightness-keys")

    // 돌아왔을 때 올릴 칸 수(0 에서부터).
    var restoreSteps: Int {
        get { UserDefaults.standard.integer(forKey: Self.restoreStepsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.restoreStepsKey) }
    }

    init() throws {
        UserDefaults.standard.register(defaults: [Self.restoreStepsKey: Self.steps / 2])
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Allnighter", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        dimmedMarkURL = support.appendingPathComponent("dimmed")
    }

    var isDimmed: Bool { FileManager.default.fileExists(atPath: dimmedMarkURL.path) }

    // macOS 는 이 권한을 앱이 켜질 때 한 번 읽어 둔다 — 허용한 뒤에도 앱을 다시 켜야 true 가 된다.
    var hasAccess: Bool { CGPreflightPostEventAccess() }

    // 어둡게 하기를 켤 때 부른다. 권한이 없으면 목록에 올리고 설정을 연다.
    func ensureAccess() throws {
        guard !CGPreflightPostEventAccess() else { return }
        CGRequestPostEventAccess()
        guard let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            fatalError("Invalid System Settings URL")
        }
        NSWorkspace.shared.open(settings)
        throw AllnighterError("Allow Allnighter in System Settings › Privacy & Security, then reopen Allnighter")
    }

    func dim() throws {
        guard !isDimmed else { return }
        guard hasAccess else {
            throw AllnighterError("Allow Allnighter in System Settings › Privacy & Security, then reopen Allnighter")
        }
        try Data().write(to: dimmedMarkURL, options: .atomic)
        press(Self.brightnessDown, times: Self.steps)
    }

    func restorePending() throws {
        guard isDimmed else { return }
        try FileManager.default.removeItem(at: dimmedMarkURL)
        press(Self.brightnessUp, times: restoreSteps)
    }

    private func press(_ key: Int, times: Int) {
        keys.async {
            for _ in 0..<times {
                for (flags, pause) in [(0xA00, 20_000), (0xB00, 40_000)] {  // 누름, 뗌
                    guard let event = NSEvent.otherEvent(
                        with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | flags, data2: -1
                    )?.cgEvent else { fatalError("Could not create brightness key event") }
                    event.post(tap: .cghidEventTap)
                    usleep(useconds_t(pause))
                }
            }
        }
    }
}
