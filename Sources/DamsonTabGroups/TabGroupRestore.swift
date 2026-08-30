import Foundation

/// The serialized form of a window's groups.
///
/// **Why this is optional everywhere it appears.** `SessionRestore.load()` decodes the whole
/// restoration state under a *single* `try?`. A required field, or a new enum case, means a
/// build that cannot read it loses **every window's layout** — not just the groups. So this
/// is carried as optional fields on the existing `RestorableWindow`, written with
/// `encodeIfPresent`, exactly as `tabTitles` was.
public struct RestorableTabGroups: Codable, Equatable, Sendable {
    /// The groups themselves.
    public var groups: [TabGroup]
    /// One entry per tab, same order and length as the window's `tabs`. nil = ungrouped.
    /// Strings rather than UUIDs so a malformed id degrades to "ungrouped" instead of
    /// failing the decode — and taking every window's layout with it.
    public var membership: [String?]

    public init(groups: [TabGroup], membership: [String?]) {
        self.groups = groups
        self.membership = membership
    }
}

public extension TabGroupLayout {

    /// Serialize, or nil when there is nothing to say. Returning nil for the no-groups case
    /// is what keeps an ordinary window's blob byte-identical to what shipped before groups
    /// existed.
    func restorable() -> RestorableTabGroups? {
        guard !groups.isEmpty else { return nil }
        return RestorableTabGroups(groups: orderedGroups(),
                                   membership: membership.map { $0?.uuidString })
    }

    /// Rebuild from saved data, repairing anything that does not hold up.
    ///
    /// Everything here is a *repair*, never a failure: this runs while restoring a user's
    /// windows, and refusing to decode would cost them their layout. Losing a group is
    /// recoverable in seconds; losing the windows is not. So:
    ///
    ///  - membership of the wrong length is dropped entirely — it cannot be aligned with the
    ///    tabs, and guessing an alignment would put tabs in groups they were never in
    ///  - an id that is not a valid UUID, or names no saved group, restores as ungrouped
    ///  - a group nothing points at is dropped
    ///  - membership that is not contiguous is reordered until it is, and the permutation is
    ///    returned so the caller can move the real tabs to match
    ///
    /// `order` is the permutation to apply to the window's parallel arrays (tabs, titles).
    /// It is the identity whenever nothing needed moving, which is the ordinary case.
    static func restore(_ saved: RestorableTabGroups?,
                        tabCount: Int) -> (layout: TabGroupLayout, order: [Int]) {
        var layout = TabGroupLayout()
        let identity = Array(0..<tabCount)
        for _ in 0..<tabCount { layout.membership.append(nil) }

        guard let saved, saved.membership.count == tabCount else {
            return (layout, identity)
        }

        let defined = Dictionary(uniqueKeysWithValues: saved.groups.map { ($0.id, $0) })
        let ids: [UUID?] = saved.membership.map { raw in
            guard let raw, let id = UUID(uuidString: raw), defined[id] != nil else { return nil }
            return id
        }

        let order = normalizedOrder(ids)
        layout.membership = order.map { ids[$0] }
        let live = Set(layout.membership.compactMap { $0 })
        layout.groups = defined.filter { live.contains($0.key) }
        return (layout, order)
    }

    /// The permutation that makes every group contiguous: each group is anchored where it
    /// first appears and its remaining tabs are pulled up behind it. Stable, so a layout
    /// that was already contiguous comes back untouched.
    static func normalizedOrder(_ ids: [UUID?]) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(ids.count)
        var taken = [Bool](repeating: false, count: ids.count)
        for i in ids.indices where !taken[i] {
            taken[i] = true
            out.append(i)
            guard let id = ids[i] else { continue }
            for j in (i + 1)..<ids.count where !taken[j] && ids[j] == id {
                taken[j] = true
                out.append(j)
            }
        }
        return out
    }
}
