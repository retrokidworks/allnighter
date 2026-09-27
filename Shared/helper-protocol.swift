import Foundation

// 앱과 root 헬퍼가 같이 쓰는 XPC 계약. 헬퍼 LaunchDaemon plist 의 Label·MachServices 와 같은 이름이어야 한다.
enum HelperContract {
    static let machServiceName = "com.retrokidworks.allnighter.helper"
    static let daemonPlistName = "com.retrokidworks.allnighter.helper.plist"
    // 헬퍼는 이 요구사항을 만족하는 앱의 연결만 받는다(같은 팀이 서명한 Allnighter).
    static let clientRequirement =
        "identifier \"com.retrokidworks.allnighter\" and anchor apple generic and certificate leaf[subject.OU] = \"6P57Y84B45\""
}

@objc protocol HelperProtocol {
    // 켜진 동안 뚜껑을 닫아도 잠들지 않는다. 이 요청을 보낸 연결이 끊기면 헬퍼가 스스로 끈다.
    func setLidAwake(_ on: Bool, reply: @escaping (String?) -> Void)
}
