import DamsonTerminal
import Foundation

/// Stable identifiers for panes.
///
/// Everything else in the app addresses a pane by where it currently is — "the active tab's
/// active pane", an index into `tabs`. That is right for a keystroke and wrong for anything
/// that outlives the moment: an external driver that opens three agents and wants to talk to
/// the second one cannot say "index 1" and be right a minute later, because splitting,
/// closing, reordering, or dragging a pane to another window all renumber it.
///
/// So each pane gets a UUID when it is first seen and keeps it for life. The id survives
/// every structural change, including a move between windows, because it is keyed on the
/// session object's identity rather than on its position.
///
/// Process-wide (one terminal, one namespace) and main-thread only, like the pane tree it
/// shadows. Registration is lazy — `id(for:)` mints on first ask — so no creation site has
/// to remember to call in; a pane that is never addressed never costs anything.
public final class PaneRegistry {
    public static let shared = PaneRegistry()

    private var ids: [ObjectIdentifier: UUID] = [:]
    /// The reverse direction, for resolving an id back to its pane. Weak, so a closed pane's
    /// session deallocates normally and its entry can be swept.
    private var sessions: [UUID: WeakSession] = [:]

    private struct WeakSession { weak var session: DamsonSession? }

    private init() {}

    /// This pane's stable id, minted on first use.
    @discardableResult
    public func id(for session: DamsonSession) -> UUID {
        let key = ObjectIdentifier(session)
        // `ObjectIdentifier` is the object's ADDRESS, and a deallocated session's address is
        // reused by a later allocation — so a hit here may be a dead pane's entry sitting at
        // an address this brand-new pane now occupies. Returning it would hand the new pane
        // the old one's id, and a driver addressing "pane X" would silently talk to the
        // wrong terminal. Confirm the entry still points back at THIS object; a stale one is
        // treated as absent. (Sweeping cannot cover this: the collision exists from the
        // instant the address is reused, before any sweep could run.)
        if let existing = ids[key], sessions[existing]?.session === session { return existing }
        let id = UUID()
        ids[key] = id
        sessions[id] = WeakSession(session: session)
        return id
    }

    /// Adopt a pane under an id it already had — used when restoring a saved layout, so a
    /// driver's binding survives a restart (Stage 4). Ignored if the id is already live.
    public func adopt(_ session: DamsonSession, as id: UUID) {
        guard sessions[id]?.session == nil else { return }
        ids[ObjectIdentifier(session)] = id
        sessions[id] = WeakSession(session: session)
    }

    /// The pane with this id, if it is still open.
    public func session(for id: UUID) -> DamsonSession? {
        sweepIfNeeded()
        return sessions[id]?.session
    }

    /// The id of a pane that has one, without minting. Lets a read-only path (listing panes,
    /// serializing a layout) avoid creating ids for panes nobody has addressed.
    public func existingID(for session: DamsonSession) -> UUID? {
        ids[ObjectIdentifier(session)]
    }

    /// Drop entries whose session is gone. Called opportunistically rather than on a timer:
    /// the table holds one UUID and one weak box per addressed pane, so a late sweep costs
    /// bytes, not correctness — and `session(for:)` already returns nil for a dead pane.
    private func sweepIfNeeded() {
        guard sessions.count > lastSweepCount + 32 else { return }
        for (id, box) in sessions where box.session == nil {
            sessions.removeValue(forKey: id)
        }
        // ObjectIdentifier keys of deallocated sessions can collide with a later allocation
        // at the same address, so the forward map is rebuilt from what survived rather than
        // pruned in place — a stale key would otherwise hand a new pane an old pane's id.
        var rebuilt: [ObjectIdentifier: UUID] = [:]
        for (id, box) in sessions {
            if let s = box.session { rebuilt[ObjectIdentifier(s)] = id }
        }
        ids = rebuilt
        lastSweepCount = sessions.count
    }

    private var lastSweepCount = 0

    #if DEBUG
    /// Test hook: forget everything, so a test starts from an empty namespace.
    public func resetForTesting() {
        ids.removeAll()
        sessions.removeAll()
        lastSweepCount = 0
    }
    #endif
}
