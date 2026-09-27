import AppKit
import Observation
import SwiftUI

@main
struct AllnighterApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    // 메뉴바 항목은 AppDelegate 의 NSStatusItem 이 그린다(좌클릭 메뉴·우클릭 켜기/끄기를 나누려면 AppKit 이 필요하다).
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let session = SessionController()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    // 소리는 켜짐/꺼짐이 실제로 바뀔 때만 낸다(첫 표시에는 내지 않는다).
    private var wasActive = false
    private static let playSoundsKey = "playSounds"

    override init() {
        UserDefaults.standard.register(defaults: [Self.playSoundsKey: true])
        super.init()
    }

    private var playSounds: Bool {
        get { UserDefaults.standard.bool(forKey: Self.playSoundsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.playSoundsKey) }
    }

    private static let durations = [15, 30, 60, 120, 240, 480]
    // 세션 중 입력이 없을 때 화면을 어둡게 하기까지 기다리는 시간(분)
    private static let dimDelays = [1, 2, 5, 10, 15, 30]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { fatalError("Status item has no button") }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        statusItem = item
        observeIcon()
    }

    // 종료 전에 밝기·뚜껑 설정을 되돌리고 나서 끝낸다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await session.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // 우클릭(또는 ⌃클릭)은 바로 켜기/끄기, 좌클릭은 메뉴.
    @objc private func statusItemClicked() {
        guard let item = statusItem else { return }
        // 접근성 도구(VoiceOver 등)로 누르면 마우스 이벤트가 없다 — 그때는 메뉴를 연다.
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            if session.isActive { session.stop() } else { session.start(minutes: nil) }
            return
        }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func observeIcon() {
        withObservationTracking {
            let isActive = session.isActive
            statusItem?.button?.image = EyeIcon.make(open: isActive)
            if isActive != wasActive, playSounds {
                NSSound(named: isActive ? "Glass" : "Bottle")?.play()
            }
            wasActive = isActive
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
    }

    // 메뉴는 열 때마다 현재 상태로 다시 만든다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if session.isActive {
            menu.addItem(disabledItem(statusText))
            menu.addItem(actionItem("Stop") { $0.session.stop() })
        } else {
            menu.addItem(actionItem("Start") { $0.session.start(minutes: nil) })
        }
        let durations = NSMenu()
        for minutes in Self.durations {
            durations.addItem(actionItem(Self.label(minutes: minutes)) { $0.session.start(minutes: minutes) })
        }
        let startFor = NSMenuItem(title: "Start for", action: nil, keyEquivalent: "")
        startFor.submenu = durations
        menu.addItem(startFor)
        menu.addItem(.separator())
        let dimAfter = NSMenu()
        dimAfter.addItem(toggleItem("Off", on: session.dimAfterMinutes == nil) { $0.session.setDimAfter(minutes: nil) })
        for minutes in Self.dimDelays {
            dimAfter.addItem(toggleItem(Self.label(minutes: minutes), on: session.dimAfterMinutes == minutes) { $0.session.setDimAfter(minutes: minutes) })
        }
        let dimItem = NSMenuItem(title: "Dim display after", action: nil, keyEquivalent: "")
        dimItem.submenu = dimAfter
        menu.addItem(dimItem)
        #if APP_STORE
        // App Store 판은 원래 밝기를 읽을 수 없어, 돌아왔을 때의 밝기를 고른다(16칸 중).
        if let current = session.restoreBrightnessSteps {
            let restore = NSMenu()
            for percent in [25, 50, 75, 100] {
                let steps = percent * 16 / 100
                restore.addItem(toggleItem("\(percent)%", on: current == steps) { $0.session.setRestoreBrightness(steps: steps) })
            }
            let restoreItem = NSMenuItem(title: "Brightness when you're back", action: nil, keyEquivalent: "")
            restoreItem.submenu = restore
            menu.addItem(restoreItem)
        }
        if session.dimNeedsReopen {
            menu.addItem(actionItem("Reopen Allnighter to finish setup") { $0.reopen() })
        }
        #else
        menu.addItem(toggleItem("Stay awake with lid closed", on: session.lidAwake) { $0.session.setLidAwake(!$0.session.lidAwake) })
        #endif
        menu.addItem(toggleItem("Launch at login", on: session.launchAtLogin) { $0.session.setLaunchAtLogin(!$0.session.launchAtLogin) })
        menu.addItem(toggleItem("Play sounds", on: playSounds) { $0.playSounds.toggle() })
        menu.addItem(disabledItem("Right-click the icon to start or stop"))
        if let error = session.lastError {
            menu.addItem(.separator())
            menu.addItem(disabledItem(error))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("About Allnighter") { $0.showAbout() })
        let quit = NSMenuItem(title: "Quit Allnighter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    #if APP_STORE
    // 새 인스턴스를 띄우고 이 인스턴스는 끝낸다(종료 처리는 applicationShouldTerminate 가 한다).
    private func reopen() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    NSAlert(error: error).runModal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
    #endif

    // 표준 About 창에 웹사이트 링크를 단다. 메뉴바 앱이라 먼저 앞으로 가져와야 창이 다른 앱 뒤에 숨지 않는다.
    private func showAbout() {
        let site = "allnighter.retrokidworks.com"
        guard let url = URL(string: "https://\(site)") else { fatalError("Invalid site URL") }
        let credits = NSMutableAttributedString(string: site, attributes: [
            .link: url,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private var statusText: String {
        guard let endsAt = session.endsAt else { return "Awake until you stop" }
        return "Awake until \(endsAt.formatted(date: .omitted, time: .shortened))"
    }

    private static func label(minutes: Int) -> String {
        if minutes == 1 { return "1 minute" }
        return minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes == 60 ? "" : "s")"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggleItem(_ title: String, on: Bool, perform: @escaping (AppDelegate) -> Void) -> NSMenuItem {
        let item = actionItem(title, perform: perform)
        item.state = on ? .on : .off
        return item
    }

    private func actionItem(_ title: String, perform: @escaping (AppDelegate) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title) { [weak self] in
            guard let self else { return }
            perform(self)
        }
        return item
    }
}

// NSMenuItem 은 target/selector 만 받는다. 항목마다 동작을 붙이려고 클로저를 들고 있게 한다.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is not decoded from a nib")
    }

    @objc private func run() {
        handler()
    }
}
