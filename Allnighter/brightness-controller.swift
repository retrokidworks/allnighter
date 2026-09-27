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
        for (key, value) in saved {
            guard let display = CGDirectDisplayID(key) else { throw AllnighterError("Corrupt brightness record: \(key)") }
            let result = setBrightness(display, value)
            guard result == 0 else { throw AllnighterError("Could not restore display brightness (\(result))") }
        }
        try FileManager.default.removeItem(at: savedURL)
    }

    private func builtInDisplays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw AllnighterError("Could not list displays") }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { throw AllnighterError("Could not list displays") }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    }
}
