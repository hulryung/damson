import Foundation

/// 빌드 메타 — Info.plist에 build-app.sh가 주입한 git hash / 채널.
/// dev 빌드는 윈도우 타이틀에 hash를 표시해 정식(release)과 시각적으로 구분.
enum BuildInfo {
    static var gitHash: String? {
        guard let h = Bundle.main.object(forInfoDictionaryKey: "HaliteGitHash") as? String,
              !h.isEmpty, h != "__GIT_HASH__", h != "unknown"
        else { return nil }
        return h
    }

    static var channel: String {
        (Bundle.main.object(forInfoDictionaryKey: "HaliteBuildChannel") as? String) ?? "release"
    }

    static var isDevBuild: Bool { channel == "dev" }

    /// 윈도우 타이틀에 붙일 dev 표시 (" · dev a12ee87"). release면 빈 문자열.
    static var titleSuffix: String {
        guard isDevBuild else { return "" }
        if let hash = gitHash { return " · dev \(hash)" }
        return " · dev"
    }
}
