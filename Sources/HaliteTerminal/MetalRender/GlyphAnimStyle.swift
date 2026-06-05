import simd

/// 커서 근처에서 글자가 새로 생기거나(appear) 지워질 때(disappear) 짧게 재생하는
/// per-glyph 애니메이션. 정적 화면효과와 달리 시간 기반이라, 진행 중일 때만 transient
/// display link가 돈다(끝나면 정지 → idle 0).
///
/// 대표 몇 가지로 시작하고 점차 확장(slide / glow / dissolve / burn …).
public enum GlyphAnimStyle: String, CaseIterable, Sendable {
    case none
    case fade
    case pop   // scale: appear 0.6→1.0, disappear 1.0→0.6 (+fade)

    public func appearDisplayName() -> String {
        switch self {
        case .none: return "None (없음)"
        case .fade: return "Fade in"
        case .pop:  return "Pop (튀어나오며)"
        }
    }

    public func disappearDisplayName() -> String {
        switch self {
        case .none: return "None (없음)"
        case .fade: return "Fade out"
        case .pop:  return "Collapse (줄어들며)"
        }
    }

    /// 글리프 인스턴스에 진행도(p: 0~1, appearing 기준 1=완전히 보임)를 적용해
    /// 알파/스케일을 변조한 새 인스턴스를 만든다. `appearing`이면 p 그대로, 아니면 1-p.
    func apply(to inst: GlyphInstance, appearing: Bool, p: Float) -> GlyphInstance {
        let prog = appearing ? p : (1 - p)         // 1 = 완전히 보임
        let e = easeOut(max(0, min(1, prog)))
        var out = inst
        switch self {
        case .none:
            break
        case .fade:
            out.color.w *= e
        case .pop:
            let s = 0.6 + 0.4 * e                  // 0.6 → 1.0
            let cx = inst.origin.x + inst.size.x * 0.5
            let cy = inst.origin.y + inst.size.y * 0.5
            out.size = inst.size * s
            out.origin = SIMD2<Float>(cx - out.size.x * 0.5, cy - out.size.y * 0.5)
            out.color.w *= e
        }
        return out
    }

    private func easeOut(_ p: Float) -> Float { 1 - (1 - p) * (1 - p) * (1 - p) }
}
