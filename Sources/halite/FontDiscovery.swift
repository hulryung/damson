import AppKit

/// 시스템에 설치된 monospace 폰트 가족 목록을 enumerate하고, halite의 기본 폰트
/// 선택 정책을 적용.
///
/// Nerd Font가 설치돼 있으면 우선 사용 (Starship/Powerlevel10k의 powerline 글리프가
/// 깨지지 않음). 없으면 Menlo로 폴백.
enum FontDiscovery {
    /// 모든 fixed-pitch 폰트 가족 (sorted alphabetically).
    static func allMonospaceFamilies() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies
            .filter { family in
                guard let font = NSFont(name: family, size: 12) else { return false }
                return font.isFixedPitch
            }
            .sorted()
    }

    /// Nerd Font (이름에 "Nerd Font", "NF", "NFM" 포함)만.
    static func nerdFontFamilies() -> [String] {
        allMonospaceFamilies().filter { isNerdFont($0) }
    }

    /// Nerd Font가 아닌 monospaced 폰트들.
    static func regularMonospaceFamilies() -> [String] {
        allMonospaceFamilies().filter { !isNerdFont($0) }
    }

    static func isNerdFont(_ family: String) -> Bool {
        let lower = family.lowercased()
        return lower.contains("nerd font")
            || lower.contains("nerd fon")  // 짧게 truncated 케이스
            || family.contains(" NF")
            || family.contains(" NFM")
            || family.contains(" NFP")
    }

    /// halite의 디폴트 폰트 가족 = **Menlo** (macOS 모든 시스템 기본 monospace).
    /// Powerline glyph는 HaliteTerminal의 `fontWithNerdFallback` cascade에서 시스템
    /// 설치된 Nerd Font로 자동 fallback 처리되므로 디폴트가 Nerd Font일 필요 없음.
    /// 한글도 같은 cascade에서 Apple SD Gothic Neo로 처리.
    static func defaultFamily() -> String {
        "Menlo"
    }

    /// Nerd Font의 "Mono" 변형 (글리프가 1셀 폭으로 강제). 터미널엔 보통 이게 정렬됨.
    private static func isMonoVariant(_ family: String) -> Bool {
        let lower = family.lowercased()
        return lower.contains("nerd font mono")
            || family.hasSuffix(" NFM")
            || family.contains(" NFM ")
    }
}
