import AppKit
import DamsonSettings
import SwiftUI

/// Shared state of the Settings window: which page is showing, which setting a search
/// result pointed at, and a tick that re-renders the "modified" markers whenever
/// UserDefaults changes (they read defaults directly, which SwiftUI can't observe).
final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage = .appearance
    /// The row to scroll to and flash, set when a search result is chosen.
    @Published var highlightKey: String?
    @Published private(set) var defaultsTick = 0

    private var observer: NSObjectProtocol?
    private var clearHighlight: DispatchWorkItem?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.defaultsTick &+= 1 }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func isModified(_ key: String) -> Bool {
        _ = defaultsTick
        guard let item = SettingsCatalog.item(key) else { return false }
        return SettingsCatalog.isModified(item, in: .standard)
    }

    func modifiedCount(_ page: SettingsPage, _ section: String) -> Int {
        _ = defaultsTick
        return SettingsCatalog.modifiedItems(page: page, section: section, in: .standard).count
    }

    /// Open the setting's page, then scroll to and flash its row.
    func reveal(_ item: SettingItem) {
        page = item.page
        highlightKey = nil
        // Next runloop turn: the page has to exist before its row can be scrolled to.
        DispatchQueue.main.async { [weak self] in
            self?.highlightKey = item.key
            self?.clearHighlight?.cancel()
            let work = DispatchWorkItem { [weak self] in
                withAnimation(.easeOut(duration: 0.4)) { self?.highlightKey = nil }
            }
            self?.clearHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
    }

    /// Reset a section (or a whole page) and push the change to every open window.
    func reset(_ page: SettingsPage, section: String? = nil) {
        let items = SettingsCatalog.items(page: page, section: section)
        SettingsCatalog.reset(page: page, section: section, in: .standard)
        // Blobs owned by a store need the store to forget its in-memory copy too.
        if items.contains(where: { $0.key == "damson.keybindings" }) { KeyBindingStore.shared.resetAll() }
        SettingsModel.applySideEffects()
    }

    /// What `.onChange` handlers would do for settings changed behind SwiftUI's back
    /// (reset, import): hot-reload the panes and re-apply the two settings that live
    /// outside the config path.
    static func applySideEffects() {
        UserDefaults.standard.set(UserDefaults.standard.bool(forKey: "damson.pressAndHold"),
                                  forKey: "ApplePressAndHoldEnabled")
        DamsonUpdater.shared.applyAutomaticChecksSetting()
        NotificationCenter.default.post(name: .damsonSettingsChanged, object: nil)
    }
}

/// A Settings section whose header shows how many of its settings differ from the
/// default, with a button that resets just this section.
struct SettingsSection<Content: View>: View {
    let page: SettingsPage
    let title: String
    @ViewBuilder let content: Content
    @EnvironmentObject private var model: SettingsModel

    init(_ page: SettingsPage, _ title: String, @ViewBuilder content: () -> Content) {
        self.page = page
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                let changed = model.modifiedCount(page, title)
                if changed > 0 {
                    Text("\(changed) changed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Reset") { model.reset(page, section: title) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Reset the settings in \(title) to their defaults")
                }
            }
        }
    }
}

private struct SettingRowModifier: ViewModifier {
    let key: String
    @EnvironmentObject private var model: SettingsModel

    func body(content: Content) -> some View {
        let modified = model.isModified(key)
        content
            .id(key)
            // In the row's leading inset, so the control itself doesn't shift when the
            // marker appears.
            .overlay(alignment: .leading) {
                if modified {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: -9)
                        .help("Changed from the default")
                        .accessibilityLabel("Changed from the default")
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(model.highlightKey == key ? 0.22 : 0))
                    .padding(-5)
            )
    }
}

extension View {
    /// Tie a control row to its catalogue entry: scroll target for search, the
    /// "modified" marker, and the search-hit flash.
    func setting(_ key: String) -> some View {
        assert(SettingsCatalog.item(key) != nil, "\(key) is not in SettingsCatalog")
        return modifier(SettingRowModifier(key: key))
    }
}

/// Sidebar: the page list, or search results while the field has text.
struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel
    @State private var query = ""

    var body: some View {
        let results = SettingsCatalog.search(query)
        List(selection: Binding(get: { query.isEmpty ? model.page : nil },
                                set: { if let p = $0 { model.page = p } })) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                }
            } else if results.isEmpty {
                Text("No matching settings")
                    .foregroundColor(.secondary)
            } else {
                ForEach(results) { item in
                    Button { model.reveal(item) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text("\(item.page.title) › \(item.section)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }
}
