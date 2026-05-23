import AppKit
import Combine
import HaliteTerminal
import SwiftUI

// 독립 halite.app의 최소 진입점.
// SwiftPM 실행: `swift run halite`
// 추후 정식 .app 배포는 별도 Xcode 프로젝트로 그래듀에이션.

final class HaliteAppDelegate: NSObject, NSApplicationDelegate {
    let session: HaliteSession
    private var titleSubscription: AnyCancellable?
    private weak var window: NSWindow?

    init(session: HaliteSession, window: NSWindow) {
        self.session = session
        self.window = window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // OSC 0/2 → window.title 동기화
        titleSubscription = session.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] newTitle in
                let display = newTitle.isEmpty ? "halite" : newTitle
                self?.window?.title = display
            }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.terminate()
    }
}

final class HaliteWindowDelegate: NSObject, NSWindowDelegate {
    let session: HaliteSession

    init(session: HaliteSession) {
        self.session = session
    }

    func windowWillClose(_ notification: Notification) {
        session.terminate()
        // SwiftPM 실행 시 applicationShouldTerminateAfterLastWindowClosed가
        // 항상 호출된다는 보장이 없어서 명시적으로 종료.
        NSApp.terminate(nil)
    }
}

// MARK: - 최소 메뉴바
// SwiftPM 실행 시 자동 메뉴바가 없어서 Cmd+Q / Cmd+W가 안 먹음 — 직접 설치.
func installMainMenu() {
    let mainMenu = NSMenu()

    // App menu (이름은 NSApplication이 자동 결정)
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(
        withTitle: "Quit halite",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )

    // File menu (Close Window)
    let fileItem = NSMenuItem()
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    fileItem.submenu = fileMenu
    fileMenu.addItem(
        withTitle: "Close Window",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    )

    // Edit menu (Copy/Paste — NSTextView 기본 셀렉터로)
    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editItem.submenu = editMenu
    editMenu.addItem(
        withTitle: "Copy",
        action: #selector(NSText.copy(_:)),
        keyEquivalent: "c"
    )
    editMenu.addItem(
        withTitle: "Paste",
        action: #selector(NSText.paste(_:)),
        keyEquivalent: "v"
    )

    NSApp.mainMenu = mainMenu
}

// MARK: - 부팅

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let session = HaliteSession(config: HaliteConfig())

let contentView = HaliteTerminalView(session: session)
    .frame(minWidth: 720, minHeight: 480)
let hostingController = NSHostingController(rootView: contentView)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled, .closable, .resizable, .miniaturizable],
    backing: .buffered,
    defer: false
)
window.title = "halite"
window.contentViewController = hostingController
window.center()

let windowDelegate = HaliteWindowDelegate(session: session)
window.delegate = windowDelegate

let appDelegate = HaliteAppDelegate(session: session, window: window)
app.delegate = appDelegate

installMainMenu()

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
