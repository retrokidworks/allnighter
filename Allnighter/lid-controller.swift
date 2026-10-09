import Foundation
import ServiceManagement

// 뚜껑을 닫아도 잠들지 않게 root 헬퍼에 요청한다. 직접 배포판에만 들어간다.
// 켜 둔 동안 XPC 연결을 붙잡고 있는다 — 앱이 죽어 연결이 끊기면 헬퍼가 스스로 끈다.
final class LidController {
    private let daemon = SMAppService.daemon(plistName: HelperContract.daemonPlistName)
    private var connection: NSXPCConnection?

    // 사용자가 시스템 설정에서 허용했는지. 허용은 알림이 오지 않아 부르는 쪽이 들여다본다.
    var isApproved: Bool { daemon.status == .enabled }

    // 헬퍼를 등록한다. 처음에는 사용자가 시스템 설정 > 로그인 항목에서 허용해야 한다.
    func ensureRegistered() throws {
        switch daemon.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw LidApprovalRequired()
        case .notRegistered, .notFound:
            // 사용자 승인 전이면 register() 가 EPERM 을 던지면서 상태는 requiresApproval 로 바뀐다.
            do {
                try daemon.register()
            } catch {
                guard daemon.status == .requiresApproval else { throw error }
            }
            if daemon.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw LidApprovalRequired()
            }
        @unknown default:
            throw AllnighterError("Unknown helper status: \(daemon.status.rawValue)")
        }
    }

    func enable() async throws {
        try ensureRegistered()
        do {
            try await send(true, over: currentConnection())
        } catch is HelperUnreachable {
            // 로그인 항목에는 허용(enabled)으로 남았는데 launchd 에 데몬이 없을 때가 있다 — 앱을 덮어쓰거나 옮긴 뒤
            // 백그라운드 작업 관리자가 앱 경로를 잃은 경우(backgroundtaskmanagementd "fullPath is nil").
            // 등록을 지우고 다시 하면 launchd 에 올라온다. 다시 해도 안 닿으면 그대로 오류를 낸다.
            try await daemon.unregister()
            try ensureRegistered()
            try await send(true, over: currentConnection())
        }
    }

    func disable() async throws {
        guard let connection else { return }
        defer {
            connection.invalidate()
            self.connection = nil
        }
        try await send(false, over: connection)
    }

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperContract.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()
        self.connection = connection
        return connection
    }

    // 응답·연결 오류·시간 초과 중 먼저 온 하나로 끝낸다. 실패하면 연결을 버린다 — 다음 요청은 새 연결로 간다.
    // launchd 가 헬퍼를 띄우지 못하면(로그인 항목 기록이 깨져 실행 경로를 못 찾을 때) 오류도 응답도 오지 않아,
    // 시간 제한이 없으면 세션 작업 줄이 영원히 막혀 메뉴도 종료도 듣지 않는다.
    private func send(_ on: Bool, over connection: NSXPCConnection) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.replyTimeout) {
                    once.resume(throwing: AllnighterError("Helper did not respond in time"))
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    once.resume(throwing: HelperUnreachable(underlying: error))
                }
                guard let helper = proxy as? HelperProtocol else {
                    return once.resume(throwing: AllnighterError("Helper proxy has the wrong type"))
                }
                helper.setLidAwake(on) { failure in
                    once.resume(throwing: failure.map { AllnighterError($0) })
                }
            }
        } catch {
            connection.invalidate()
            if self.connection === connection { self.connection = nil }
            throw error
        }
    }

    private static let replyTimeout: TimeInterval = 5
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    // error 가 nil 이면 성공으로 끝낸다. 두 번째부터는 무시한다.
    func resume(throwing error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}

struct LidApprovalRequired: LocalizedError {
    var errorDescription: String? { "Allow Allnighter in System Settings › Login Items" }
}

struct HelperUnreachable: LocalizedError {
    let underlying: Error

    var errorDescription: String? { "Helper is not reachable: \(underlying.localizedDescription)" }
}
