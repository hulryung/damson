import AppKit
import Foundation

/// 16/256-색 ANSI 팔레트. 표준 xterm 디폴트에 가까운 톤.
/// M2 한정. M5에서 config.palette 우선 사용 + 사용자 테마 시스템으로 교체.
enum Palette {
    static let normal16: [NSColor] = [
        rgb(0x00, 0x00, 0x00),   // 0 black
        rgb(0xCD, 0x00, 0x00),   // 1 red
        rgb(0x00, 0xCD, 0x00),   // 2 green
        rgb(0xCD, 0xCD, 0x00),   // 3 yellow
        rgb(0x00, 0x00, 0xEE),   // 4 blue
        rgb(0xCD, 0x00, 0xCD),   // 5 magenta
        rgb(0x00, 0xCD, 0xCD),   // 6 cyan
        rgb(0xE5, 0xE5, 0xE5),   // 7 white
    ]

    static let bright16: [NSColor] = [
        rgb(0x7F, 0x7F, 0x7F),   // 8 bright black
        rgb(0xFF, 0x00, 0x00),   // 9 bright red
        rgb(0x00, 0xFF, 0x00),   // 10 bright green
        rgb(0xFF, 0xFF, 0x00),   // 11 bright yellow
        rgb(0x5C, 0x5C, 0xFF),   // 12 bright blue
        rgb(0xFF, 0x00, 0xFF),   // 13 bright magenta
        rgb(0x00, 0xFF, 0xFF),   // 14 bright cyan
        rgb(0xFF, 0xFF, 0xFF),   // 15 bright white
    ]

    /// xterm 256-색 인덱스 → NSColor.
    /// 0-15: 16색, 16-231: 6×6×6 cube, 232-255: 24단계 그레이스케일.
    static func color256(_ n: Int) -> NSColor {
        if n < 8 { return normal16[n] }
        if n < 16 { return bright16[n - 8] }
        if n >= 232 {
            let v = (n - 232) * 10 + 8
            return rgb(v, v, v)
        }
        let c = n - 16
        let r = c / 36
        let g = (c / 6) % 6
        let b = c % 6
        let levels = [0, 95, 135, 175, 215, 255]
        return rgb(levels[r], levels[g], levels[b])
    }

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }
}
