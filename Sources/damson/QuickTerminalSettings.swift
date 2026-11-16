import DamsonSettings
import SwiftUI

/// Settings → Window → Quick Terminal: the shortcut recorder. Writing the defaults key is
/// all it does; the app delegate watches defaults, registers the chord, and on failure
/// (another app owns it) rolls back and says so.
struct QuickTerminalShortcutRow: View {
    @AppStorage(QuickTerminalShortcut.storageKey) private var stored: Data?
    @State private var problem: String?

    var body: some View {
        // Reading `stored` makes the row redraw when the shortcut changes (or is rolled back).
        let current = stored.map { _ in QuickTerminalShortcut.load(from: .standard) } ?? .default
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Shortcut")
                Spacer()
                KeyRecorderField(chord: nil, isDisabled: false, onRecord: { _ in },
                                 onRecordKeyCode: { chord, keyCode in record(chord, keyCode) },
                                 displayText: current.display)
                    .frame(width: 130, height: 22)
                Button {
                    problem = nil
                    stored = nil
                } label: { Image(systemName: "arrow.uturn.backward.circle") }
                .buttonStyle(.borderless)
                .help("Reset to default (\(QuickTerminalShortcut.default.display))")
                .disabled(stored == nil)
            }
            if let problem {
                Text(problem).font(.caption).foregroundColor(.orange)
            }
        }
    }

    private func record(_ chord: KeyChord, _ keyCode: UInt16) {
        let shortcut = QuickTerminalShortcut(keyCode: keyCode, modifiers: chord.mods, display: chord.display)
        if let why = shortcut.problem { problem = why; return }
        // A global hotkey wins over Damson's own menus, so it would silently disable the
        // in-app shortcut bound to the same chord.
        let clashes = AppAction.all.filter { KeyBindingStore.shared.chord(for: $0.id) == chord }
        if !clashes.isEmpty {
            problem = "\(chord.display) is already Damson's shortcut for "
                + clashes.map(\.title).joined(separator: ", ") + ". Rebind it in Keys first, or pick another."
            return
        }
        problem = nil
        shortcut.save(to: .standard)
    }
}
