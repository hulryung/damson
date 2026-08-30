import Foundation

/// A named bundle of tabs. A coordinator opens one run as one group; a user bundles
/// whatever they like.
///
/// The group carries no tab list. Membership lives in `TabGroupLayout`, parallel to the
/// window's tab array, so there is exactly one place that can be wrong about which tabs
/// belong where — a group holding its own member list would be a second copy of that fact,
/// free to disagree with the first.
public struct TabGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Index into the theme's palette, not a colour value: a stored colour would keep the
    /// old theme's hue after the user switches themes.
    public var colorIndex: Int?
    public var collapsed: Bool

    public init(id: UUID = UUID(), name: String, colorIndex: Int? = nil, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.collapsed = collapsed
    }
}
