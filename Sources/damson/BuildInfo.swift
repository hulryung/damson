import Foundation

/// Build metadata — git hash / channel injected into Info.plist by build-app.sh.
/// Dev builds show the hash in the window title to visually distinguish them from release.
enum BuildInfo {
    static var gitHash: String? {
        guard let h = Bundle.main.object(forInfoDictionaryKey: "DamsonGitHash") as? String,
              !h.isEmpty, h != "__GIT_HASH__", h != "unknown"
        else { return nil }
        return h
    }

    static var channel: String {
        (Bundle.main.object(forInfoDictionaryKey: "DamsonBuildChannel") as? String) ?? "release"
    }

    static var isDevBuild: Bool { channel == "dev" }

    /// Build time injected by build-app.sh ("YYYY-MM-DD HH:MM"). nil if not injected or still a placeholder.
    static var buildDate: String? {
        guard let d = Bundle.main.object(forInfoDictionaryKey: "DamsonBuildDate") as? String,
              !d.isEmpty, d != "__BUILD_DATE__"
        else { return nil }
        return d
    }

    /// Top-right window badge: "dev a12ee87" for dev builds, the build time for release builds.
    static var badgeText: String? {
        if isDevBuild { return gitHash.map { "dev \($0)" } ?? "dev" }
        return buildDate
    }

    /// Dev marker appended to the window title (" · dev a12ee87"). Empty string for release.
    static var titleSuffix: String {
        guard isDevBuild else { return "" }
        if let hash = gitHash { return " · dev \(hash)" }
        return " · dev"
    }
}
