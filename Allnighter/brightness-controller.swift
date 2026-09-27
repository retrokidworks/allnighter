import CoreGraphics
import Foundation

// 내장 화면 백라이트를 0 으로 내리고 되돌린다. DisplayServices 는 비공개 프레임워크라 직접 배포판에만 들어간다.
// 원래 밝기는 디스크에 먼저 적어 둔다 — 어둡게 한 채 앱이 죽어도 다음 실행 때 restorePending() 이 되돌린다.
final class BrightnessController {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightness: GetBrightness
    private let setBrightness: SetBrightness
    private let savedURL: URL
    // 마지막으로 되돌린 밝기. holdRestored() 가 다시 적용한다.
    private var restored: [CGDirectDisplayID: Float] = [:]

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness")
        else {
            throw AllnighterError("DisplayServices is not available on this macOS")
        }
        getBrightness = unsafeBitCast(get, to: GetBrightness.self)
        setBrightness = unsafeBitCast(set, to: SetBrightness.self)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Allnighter", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        savedURL = support.appendingPathComponent("saved-brightness.json")
    }

    var isDimmed: Bool { FileManager.default.fileExists(atPath: savedURL.path) }

    // App Store 판(brightness-keys-controller.swift)과 사용법을 맞춘다. 직접 배포판은 권한이 필요 없다.
    func ensureAccess() throws {}

    func dim() throws {
        guard !isDimmed else { return }
        restored = [:]
        var saved: [String: Float] = [:]
        for display in try builtInDisplays() {
            var value: Float = 0
            let result = getBrightness(display, &value)
            guard result == 0 else { throw AllnighterError("Could not read display brightness (\(result))") }
            saved[String(display)] = value
        }
        guard !saved.isEmpty else { throw AllnighterError("No built-in display to dim") }
        try JSONEncoder().encode(saved).write(to: savedURL, options: .atomic)
        for display in saved.keys.compactMap(CGDirectDisplayID.init) {
            let result = setBrightness(display, 0)
            guard result == 0 else { throw AllnighterError("Could not dim display (\(result))") }
        }
    }

    // 저장해 둔 밝기로 되돌리고 기록을 지운다. 기록이 없으면 할 일이 없다.
    func restorePending() throws {
        guard isDimmed else { return }
        let saved = try JSONDecoder().decode([String: Float].self, from: Data(contentsOf: savedURL))
        var values: [CGDirectDisplayID: Float] = [:]
        for (key, value) in saved {
            guard let display = CGDirectDisplayID(key) else { throw AllnighterError("Corrupt brightness record: \(key)") }
            let result = setBrightness(display, value)
            guard result == 0 else { throw AllnighterError("Could not restore display brightness (\(result))") }
            values[display] = value
        }
        try FileManager.default.removeItem(at: savedURL)
        restored = values
    }

    // 사용자가 오래 자리를 비웠다 돌아오면(UserIsActive 가 풀린 뒤 첫 입력) macOS 가 첫 입력 0.2초쯤 뒤에
    // 자기가 기억한 밝기(여기서 내린 0)를 한 번 다시 적용해 restorePending() 을 덮어쓴다.
    // 되돌린 직후 잠깐 이것을 불러, 아직 0 이면 되돌린 밝기를 다시 적용한다.
    func holdRestored() throws {
        for (display, value) in restored {
            var current: Float = 0
            let read = getBrightness(display, &current)
            guard read == 0 else { throw AllnighterError("Could not read display brightness (\(read))") }
            guard current == 0 else { continue }
            let result = setBrightness(display, value)
            guard result == 0 else { throw AllnighterError("Could not restore display brightness (\(result))") }
        }
    }

    private func builtInDisplays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw AllnighterError("Could not list displays") }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { throw AllnighterError("Could not list displays") }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    }
}
