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

    /// halite의 디폴트 폰트 가족 = **JetBrainsMono Nerd Font Mono** (NFM).
    ///
    /// Latin 글자는 NF와 100% 동일하면서, Nerd 아이콘을 **1셀 폭으로 축소**해 터미널
    /// cell-grid에 맞춘다. 비-Mono(NF)는 아이콘 잉크가 1셀을 넘어(예: U+F43A 클럭
    /// ink 0~1.67셀) Metal rasterizer의 1셀 박스에서 잘리므로 피한다. 한글/CJK는
    /// `cjkFallbackFont`(D2Coding 계열)로 fallback — fallback 최소화. 없으면 NF → Menlo.
    static func defaultFamily() -> String {
        let preferred = [
            "JetBrainsMono Nerd Font Mono",  // NFM: Latin=NF 동일 + 아이콘 1셀 폭
            "JetBrainsMono Nerd Font",       // NF (아이콘 자연 폭) — 차선
        ]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        for family in preferred where installed.contains(family) {
            return family
        }
        return "Menlo"
    }

    /// Nerd Font의 "Mono" 변형 (글리프가 1셀 폭으로 강제). 터미널엔 보통 이게 정렬됨.
    private static func isMonoVariant(_ family: String) -> Bool {
        let lower = family.lowercased()
        return lower.contains("nerd font mono")
            || family.hasSuffix(" NFM")
            || family.contains(" NFM ")
    }
}
