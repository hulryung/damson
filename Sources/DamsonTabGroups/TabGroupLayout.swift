import Foundation

/// Which tab belongs to which group, held parallel to the window's tab array.
///
/// **The invariant is contiguity:** the tabs of a group occupy one unbroken index range.
/// Everything else here exists to keep that true. It buys three things that are otherwise
/// each their own problem — collapsing is hiding one range, moving a group is moving one
/// range, and "which group is this tab in" never needs a search.
///
/// Group *order* is not stored, because it is implied by tab order (a group sits where its
/// first tab sits). A separate ordering would be a second source of truth free to disagree
/// with the first.
///
/// This type is deliberately window-free and holds no tabs — it holds ids. The AppKit side
/// applies the same insert/remove/move to its own arrays using the indices returned here.
public struct TabGroupLayout: Equatable {
    /// One entry per tab, in tab order. nil = the tab is in no group.
    public internal(set) var membership: [UUID?]
    /// Groups by id. A group with no tabs is not kept — see `dropEmptyGroups`.
    public internal(set) var groups: [UUID: TabGroup]

    public init() {
        membership = []
        groups = [:]
    }

    public var tabCount: Int { membership.count }
    public var isEmpty: Bool { groups.isEmpty }

    public func group(at index: Int) -> TabGroup? {
        guard membership.indices.contains(index), let id = membership[index] else { return nil }
        return groups[id]
    }

    public func groupID(at index: Int) -> UUID? {
        membership.indices.contains(index) ? membership[index] : nil
    }

    /// The index range a group occupies, or nil if it has no tabs. Relies on contiguity:
    /// first and last member with everything between them.
    public func range(of id: UUID) -> Range<Int>? {
        guard let first = membership.firstIndex(of: id),
              let last = membership.lastIndex(of: id) else { return nil }
        return first..<(last + 1)
    }

    /// Groups in the order they appear on screen, which is the order of their first tab.
    public func orderedGroups() -> [TabGroup] {
        var seen = Set<UUID>()
        var out: [TabGroup] = []
        for id in membership.compactMap({ $0 }) where !seen.contains(id) {
            seen.insert(id)
            if let g = groups[id] { out.append(g) }
        }
        return out
    }

    // MARK: - Group lifetime

    /// Register a group. Adding a group nobody is in is legal but transient: it disappears
    /// the next time membership changes, since a group with no tabs is not kept.
    public mutating func define(_ group: TabGroup) {
        groups[group.id] = group
    }

    public mutating func update(_ group: TabGroup) {
        guard groups[group.id] != nil else { return }
        groups[group.id] = group
    }

    /// Find a group by name. Names are for humans and are not unique; ids are the identity.
    /// Used by the control socket, where a coordinator names a run rather than tracking a
    /// UUID it never saw.
    public func group(named name: String) -> TabGroup? {
        orderedGroups().first { $0.name == name }
    }

    private mutating func dropEmptyGroups() {
        let live = Set(membership.compactMap { $0 })
        groups = groups.filter { live.contains($0.key) }
    }

    // MARK: - Tab mutations
    //
    // Each mirrors one mutation of the window's tab array. The caller applies the same
    // change at the index these return, so the two arrays stay the same length and the
    // same order.

    /// Where a new tab joining `group` must be inserted to keep the group contiguous:
    /// just after the group's last tab, or at the end for a tab that joins nothing.
    public func insertionIndex(joining group: UUID?) -> Int {
        guard let group, let r = range(of: group) else { return membership.count }
        return r.upperBound
    }

    /// Record a tab inserted at `index`. Returns the index actually used, which is
    /// `insertionIndex(joining:)` when a group is given — a tab cannot join a group and
    /// also sit somewhere else.
    @discardableResult
    public mutating func insert(group: UUID?, at index: Int) -> Int {
        let at = group.map { g in range(of: g).map { $0.upperBound } ?? min(max(index, 0), membership.count) }
            ?? min(max(index, 0), membership.count)
        membership.insert(group, at: at)
        return at
    }

    /// Record a tab appended to the end, joining `group` if given.
    @discardableResult
    public mutating func append(group: UUID?) -> Int {
        insert(group: group, at: membership.count)
    }

    /// Record a tab removed. Removing from a contiguous range leaves it contiguous, so this
    /// can never break the invariant; it can empty a group, which then disappears.
    public mutating func remove(at index: Int) {
        guard membership.indices.contains(index) else { return }
        membership.remove(at: index)
        dropEmptyGroups()
    }

    /// Move a tab, keeping every group contiguous. Returns the index it ended at.
    ///
    /// The moved tab joins a group only when it lands **strictly inside** it — both
    /// neighbours in the same group. Landing on a boundary leaves it ungrouped. That rule
    /// is what makes the move safe by construction: a tab can never come to rest between
    /// two members of a group it is not in, so no group is ever split.
    @discardableResult
    public mutating func move(from: Int, to: Int) -> Int {
        guard membership.indices.contains(from) else { return from }
        let moved = membership.remove(at: from)
        let dest = min(max(to, 0), membership.count)

        let left = dest > 0 ? membership[dest - 1] : nil
        let right = dest < membership.count ? membership[dest] : nil
        // Strictly inside a group (same non-nil id on both sides) means join it. Otherwise
        // the tab keeps its group only if it never left it — which, after the removal above,
        // is exactly the case where both neighbours are still that group.
        let joined: UUID?
        if let left, left == right {
            joined = left                       // strictly inside a group: join it
        } else if let own = moved, left == own || right == own {
            joined = own                        // still touching its own group: stays in
        } else {
            joined = nil                        // anywhere else: ungrouped
        }
        membership.insert(joined, at: dest)
        dropEmptyGroups()
        return dest
    }

    /// Move a whole group. Returns the index its first tab ended at.
    ///
    /// Reordering *groups* has to be its own operation. Moving a member tab can only ever
    /// take that tab out of its group — which, for a group of one, would silently destroy
    /// the group the user was trying to drag. Dragging the header is a different gesture and
    /// this is the model half of it.
    ///
    /// A group cannot land inside another group, so a destination that would split one
    /// slides past it.
    @discardableResult
    public mutating func moveGroup(_ id: UUID, to destination: Int) -> Int {
        guard let r = range(of: id) else { return destination }
        let block = Array(membership[r])
        membership.removeSubrange(r)
        var dest = min(max(destination, 0), membership.count)
        while dest > 0, dest < membership.count,
              let left = membership[dest - 1], left == membership[dest] {
            dest += 1
        }
        membership.insert(contentsOf: block, at: dest)
        return dest
    }

    /// Put a tab into a group (or take it out), relocating it so the group stays
    /// contiguous. Returns the index it ended at.
    @discardableResult
    public mutating func assign(at index: Int, to group: UUID?) -> Int {
        guard membership.indices.contains(index) else { return index }
        if membership[index] == group { return index }
        membership.remove(at: index)
        // Joining relocates to the end of the group's range; leaving stays put.
        let dest = (group.flatMap { range(of: $0)?.upperBound }) ?? index
        let at = min(max(dest, 0), membership.count)
        membership.insert(group, at: at)
        dropEmptyGroups()
        return at
    }

    /// Whether a group should show an attention marker while folded: any tab in it is
    /// flagged. `flagged` is asked per tab index, so this stays free of what a badge is.
    ///
    /// Folding must never be the reason someone misses a blocked agent. A folded group hides
    /// the tabs that would have carried the badge, so the header has to carry it instead.
    public func needsAttention(_ id: UUID, flagged: (Int) -> Bool) -> Bool {
        guard let r = range(of: id) else { return false }
        return r.contains(where: flagged)
    }

    // MARK: - Invariant

    /// True when every group occupies one unbroken range. Production code maintains this;
    /// tests assert it after every mutation, and `sanitized` restores it for data that
    /// arrived without it.
    public var isContiguous: Bool {
        var seen = Set<UUID>()
        var previous: UUID?
        for id in membership {
            if id != previous, let id, seen.contains(id) { return false }
            if let previous { seen.insert(previous) }
            previous = id
        }
        return true
    }
}
