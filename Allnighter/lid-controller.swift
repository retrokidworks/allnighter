import Foundation
import ServiceManagement

// 뚜껑을 닫아도 잠들지 않게 root 헬퍼에 요청한다. 직접 배포판에만 들어간다.
// 켜 둔 동안 XPC 연결을 붙잡고 있는다 — 앱이 죽어 연결이 끊기면 헬퍼가 스스로 끈다.
final class LidController {
    private let daemon = SMAppService.daemon(plistName: HelperContract.daemonPlistName)
    private var connection: NSXPCConnection?

    // 헬퍼를 등록한다. 처음에는 사용자가 시스템 설정 > 로그인 항목에서 허용해야 한다.
    func ensureRegistered() throws {
        switch daemon.status {
        case .enabled:
            return
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw AllnighterError("Allow Allnighter in System Settings › Login Items, then try again")
        case .notRegistered, .notFound:
            // 사용자 승인 전이면 register() 가 EPERM 을 던지면서 상태는 requiresApproval 로 바뀐다.
            do {
                try daemon.register()
            } catch {
                guard daemon.status == .requiresApproval else { throw error }
            }
            if daemon.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw AllnighterError("Allow Allnighter in System Settings › Login Items, then try again")
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
            connection?.invalidate()
            connection = nil
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

    private func send(_ on: Bool, over connection: NSXPCConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: HelperUnreachable(underlying: error))
            }
            guard let helper = proxy as? HelperProtocol else {
                return continuation.resume(throwing: AllnighterError("Helper proxy has the wrong type"))
            }
            helper.setLidAwake(on) { failure in
                if let failure {
                    continuation.resume(throwing: AllnighterError(failure))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

struct HelperUnreachable: LocalizedError {
    let underlying: Error

    var errorDescription: String? { "Helper is not reachable: \(underlying.localizedDescription)" }
}
