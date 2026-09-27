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
        let connection = self.connection ?? makeConnection()
        self.connection = connection
        try await send(true, over: connection)
    }

    func disable() async throws {
        guard let connection else { return }
        defer {
            connection.invalidate()
            self.connection = nil
        }
        try await send(false, over: connection)
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperContract.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()
        return connection
    }

    private func send(_ on: Bool, over connection: NSXPCConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: AllnighterError("Helper is not reachable: \(error.localizedDescription)"))
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
