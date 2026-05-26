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

    /// halite의 디폴트 폰트 가족. 선호 순 (halite-swift 공식 디폴트는 MesloLGL NFM):
    ///   1. MesloLGL Nerd Font Mono  (L = large line-height — 한글 + 라인 간격 여유)
    ///   2. MesloLGM Nerd Font Mono
    ///   3. MesloLGS Nerd Font Mono / MesloLGS NF (Powerlevel10k 권장)
    ///   4. JetBrainsMono Nerd Font Mono
    ///   5. Hack Nerd Font Mono / FiraCode Nerd Font Mono
    ///   6. 시스템에 있는 첫 Nerd Font Mono
    ///   7. Menlo (Nerd Font 미설치 시)
    static func defaultFamily() -> String {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let preferred = [
            "MesloLGL Nerd Font Mono",
            "MesloLGM Nerd Font Mono",
            "MesloLGS Nerd Font Mono",
            "MesloLGS NF",
            "JetBrainsMono Nerd Font Mono",
            "JetBrainsMonoNL Nerd Font Mono",
            "Hack Nerd Font Mono",
            "FiraCode Nerd Font Mono",
        ]
        for p in preferred where installed.contains(p) {
            return p
        }
        // 위 목록에 없지만 NFM/NF Mono 같은 거 있으면 시도.
        if let any = nerdFontFamilies().first(where: { isMonoVariant($0) }) {
            return any
        }
        if let any = nerdFontFamilies().first {
            return any
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
