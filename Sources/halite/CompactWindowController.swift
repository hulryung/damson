import AppKit
import Combine
import HaliteTerminal

/// Compact 모드 전용 윈도우 컨트롤러. 하나의 NSWindow가 N개 HaliteSession을
/// 멀티플렉스. NSWindow 네이티브 탭 비활성(`tabbingMode = .disallowed`) +
/// 커스텀 CompactTabBarView를 contentView 최상단에 둬서 신호등과 같은 row에 탭.
///
/// hiterm(`~/dev/hiterm`)의 MainWindowController 구조 차용.
final class CompactWindowController: NSWindowController, NSWindowDelegate {
    private(set) var sessions: [HaliteSession] = []
    private var surfaces: [HaliteSurfaceView] = []
    private(set) var currentIndex: Int = 0

    private var tabBar: CompactTabBarView!
    private var tabBarBackground: NSVisualEffectView!
    private var contentContainer: NSView!

    /// 각 세션의 $title을 구독해서 탭 이름 갱신.
    private var titleSubscriptions: [AnyCancellable] = []

    /// `gridChanged`를 구독해서 inactive 탭의 텍스트 update에도 반응
    /// (현재 visible 탭만 surface가 렌더되므로 그대로 작동).
    private var gridSubscriptions: [AnyCancellable] = []

    var hasTabs: Bool { !sessions.isEmpty }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "halite"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 480, height: 240)
        window.center()
        // 네이티브 탭 OFF — 우리가 직접 그리는 탭바 사용.
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)
        window.delegate = self

        setupViews()
        addNewTab()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        for s in sessions { s.terminate() }
    }

    private func setupViews() {
        guard let contentView = window?.contentView else { return }

        // titlebar 영역에 깔리는 vibrancy (신호등 + 탭 뒤 배경).
        tabBarBackground = NSVisualEffectView()
        tabBarBackground.material = .hudWindow
        tabBarBackground.blendingMode = .behindWindow
        tabBarBackground.state = .followsWindowActiveState
        tabBarBackground.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabBarBackground)

        // 커스텀 탭 바.
        tabBar = CompactTabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onTabSelected = { [weak self] idx in self?.selectTab(idx) }
        tabBar.onTabClosed = { [weak self] idx in self?.closeTab(idx) }
        tabBar.onNewTab = { [weak self] in self?.addNewTab() }
        contentView.addSubview(tabBar)

        // 세션 surface가 들어가는 컨테이너 — 탭 바 아래 채움.
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentContainer)

        // titlebar 높이 측정 (대략 28pt). styleMask + fullSizeContentView 상태에서
        // contentLayoutGuide의 top이 titlebar 아래임을 활용 가능하지만, 우리 탭바는
        // titlebar 자리에 그려야 하므로 0부터 시작.
        let tabBarHeight: CGFloat = 38

        NSLayoutConstraint.activate([
            tabBarBackground.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBarBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBarBackground.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarBackground.heightAnchor.constraint(equalToConstant: tabBarHeight),

            tabBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: tabBarHeight),

            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Tab management

    @discardableResult
    func addNewTab() -> HaliteSession {
        let session = HaliteSession(config: HaliteConfig.fromUserDefaults())
        let surface = HaliteSurfaceView(session: session)
        surface.translatesAutoresizingMaskIntoConstraints = false
        sessions.append(session)
        surfaces.append(surface)

        let titleSub = session.$title.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshTabBar()
        }
        titleSubscriptions.append(titleSub)

        selectTab(sessions.count - 1)
        refreshTabBar()
        return session
    }

    func selectTab(_ index: Int) {
        guard index >= 0, index < surfaces.count else { return }
        currentIndex = index
        for s in surfaces { s.removeFromSuperview() }
        let surface = surfaces[index]
        contentContainer.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            surface.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        window?.makeFirstResponder(surface)
        let title = sessions[index].title
        window?.title = title.isEmpty ? "halite" : title
        refreshTabBar()
    }

    func closeTab(_ index: Int) {
        guard index >= 0, index < sessions.count else { return }
        sessions[index].terminate()
        sessions.remove(at: index)
        surfaces.remove(at: index)
        titleSubscriptions.remove(at: index)

        if sessions.isEmpty {
            window?.performClose(nil)
            return
        }
        if currentIndex >= sessions.count { currentIndex = sessions.count - 1 }
        selectTab(currentIndex)
    }

    func closeCurrentTab() {
        closeTab(currentIndex)
    }

    /// HaliteSurfaceView가 Cmd+W를 responder chain에 보낼 때 받아서 활성 탭만 닫음.
    @objc func performCloseTab(_ sender: Any?) {
        closeCurrentTab()
    }

    private func refreshTabBar() {
        let titles = sessions.map { $0.title }
        tabBar.update(titles: titles, selectedIndex: currentIndex)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for s in sessions { s.terminate() }
    }
}
