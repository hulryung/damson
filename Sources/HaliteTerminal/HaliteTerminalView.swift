import AppKit
import Combine
import SwiftUI

/// SwiftUI에서 한 줄로 끼울 수 있는 진입점.
/// cmux/halite.app 양쪽에서 동일 API.
public struct HaliteTerminalView: NSViewRepresentable {
    public let session: HaliteSession
    public var isActive: Bool
    public var onFocus: (() -> Void)?

    public init(
        session: HaliteSession,
        isActive: Bool = true,
        onFocus: (() -> Void)? = nil
    ) {
        self.session = session
        self.isActive = isActive
        self.onFocus = onFocus
    }

    public func makeNSView(context: Context) -> HaliteSurfaceView {
        let view = HaliteSurfaceView(session: session)
        view.onFocus = onFocus
        return view
    }

    public func updateNSView(_ nsView: HaliteSurfaceView, context: Context) {
        nsView.isActive = isActive
        nsView.onFocus = onFocus
    }
}

/// 내부 표시용 NSTextView. first responder도 mouse hit도 거부해서
/// 키/클릭 라우팅이 항상 부모 `HaliteSurfaceView`에 가도록 함.
private final class PassiveTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func becomeFirstResponder() -> Bool { false }
}

/// M1 placeholder: 자식 `NSTextView`에 PTY 출력을 누적해서 보여주고,
/// 키 이벤트는 이쪽에서 잡아 `session.write(_:)`로 전달.
/// M4 이후 `CAMetalLayer` + 자체 렌더러로 교체.
public final class HaliteSurfaceView: NSView {
    public let session: HaliteSession

    public var isActive: Bool = true {
        didSet { needsDisplay = true }
    }

    public var onFocus: (() -> Void)?

    private let scrollView: NSScrollView
    private let textView: PassiveTextView
    private var outputSubscription: AnyCancellable?
    private var lastReportedSize: (cols: Int, rows: Int)? = nil
    private var sgr: SGRState

    public init(session: HaliteSession) {
        self.session = session
        self.sgr = SGRState(defaultFG: session.config.foregroundColor)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false

        let tv = PassiveTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isRichText = true
        tv.allowsUndo = false
        tv.font = NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
        tv.textColor = session.config.foregroundColor
        tv.backgroundColor = session.config.backgroundColor
        tv.drawsBackground = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 4)

        scroll.documentView = tv

        self.scrollView = scroll
        self.textView = tv

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = session.config.backgroundColor.cgColor

        addSubview(scroll)
        scroll.frame = bounds

        // 파서가 발행하는 이벤트 구독.
        outputSubscription = session.outputEvents
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.handleEvent(event)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        reportSizeIfChanged()
    }

    /// 현재 뷰 크기를 (cols, rows)로 환산해서 변경 시에만 PTY로 통지.
    private func reportSizeIfChanged() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let font = textView.font ?? NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
            ?? NSFont.systemFont(ofSize: session.config.fontSize)
        // monospace 가정. M5에서 정확한 advance/line-height 사용으로 교체.
        let glyphSize = ("M" as NSString).size(withAttributes: [.font: font])
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let cellW = max(glyphSize.width, 1)
        let cellH = max(lineHeight, 1)

        let inset = textView.textContainerInset
        let usableW = bounds.width - inset.width * 2
        let usableH = bounds.height - inset.height * 2
        let cols = max(Int(floor(usableW / cellW)), 1)
        let rows = max(Int(floor(usableH / cellH)), 1)

        if lastReportedSize?.cols == cols && lastReportedSize?.rows == rows {
            return
        }
        lastReportedSize = (cols, rows)
        session.resize(cols: cols, rows: rows)
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI 호스팅을 통과해도 우리 NSView가 first responder가 되도록 강제.
        // 안 그러면 안쪽 NSTextView/NSScrollView가 키를 가져가서 keyDown이 안 옴.
        if let window = window {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self = self, let window = window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        // 클릭으로 키 입력 되찾기 (혹시 다른 곳에 first responder가 가있을 때 대비)
        window?.makeFirstResponder(self)
    }

    /// SwiftPM 실행 시 메뉴바가 자동 인식되지 않을 수 있어서, 표준 단축키를 직접 처리.
    /// 메뉴가 잡혀있어도 안전 (중복 호출은 NSApp/NSWindow가 idempotent).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "q":
            NSApp.terminate(nil)
            return true
        case "w":
            window?.performClose(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Input

    public override func keyDown(with event: NSEvent) {
        guard let bytes = ptyBytes(for: event) else {
            super.keyDown(with: event)
            return
        }
        session.write(bytes)
    }

    /// M1 한정: 흔한 키들만 처리. 실제 키 매핑은 M2+에서 VT 규격대로.
    private func ptyBytes(for event: NSEvent) -> Data? {
        let modifiers = event.modifierFlags

        // Cmd 단축키는 PTY로 안 보냄 (호스트가 처리)
        if modifiers.contains(.command) { return nil }

        // 특수 키
        if let chars = event.charactersIgnoringModifiers, chars.count == 1 {
            switch chars.unicodeScalars.first?.value {
            case 0xF700: return Data([0x1B, 0x5B, 0x41]) // Up
            case 0xF701: return Data([0x1B, 0x5B, 0x42]) // Down
            case 0xF702: return Data([0x1B, 0x5B, 0x44]) // Left
            case 0xF703: return Data([0x1B, 0x5B, 0x43]) // Right
            case 0x7F: return Data([0x7F])               // Backspace → DEL
            case 0x1B: return Data([0x1B])               // Esc
            case 0x0D: return Data([0x0D])               // Return → CR
            case 0x09: return Data([0x09])               // Tab
            default: break
            }
        }

        // Ctrl + 알파벳
        if modifiers.contains(.control), let chars = event.charactersIgnoringModifiers, chars.count == 1 {
            if let scalar = chars.unicodeScalars.first?.value,
               (0x61...0x7A).contains(scalar) || (0x41...0x5A).contains(scalar) {
                let lower = scalar | 0x20
                let ctrl = UInt8(lower - 0x60) // a=1, b=2, ...
                return Data([ctrl])
            }
        }

        // 평문
        if let chars = event.characters, !chars.isEmpty {
            return chars.data(using: .utf8)
        }
        return nil
    }

    // MARK: - Output (VTParser-driven)

    private func handleEvent(_ event: HaliteOutputEvent) {
        switch event {
        case .text(let s):
            appendText(s)
        case .execute(let b):
            handleControl(b)
        case .csi(let params, _, let final, _):
            if final == 0x6D { // 'm' = SGR
                applySGR(params)
            }
            // 기타 CSI(커서 이동/erase 등)는 Grid 모델이 들어오는 M3에서 처리.
        case .osc:
            break // 세션이 이미 title을 잡았음.
        }
    }

    private func handleControl(_ b: UInt8) {
        guard let storage = textView.textStorage else { return }
        switch b {
        case 0x08: // BS
            if storage.length > 0 {
                storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1))
            }
        case 0x07: // BEL
            break // 세션이 onBell 발사 — TODO 시각 피드백
        case 0x09: // TAB
            appendText("\t")
        case 0x0A: // LF
            appendText("\n")
            textView.scrollToEndOfDocument(nil)
        case 0x0D: // CR — Grid 없는 동안은 무시
            break
        default:
            break
        }
    }

    private func appendText(_ s: String) {
        guard let storage = textView.textStorage else { return }
        let attrs = currentAttributes()
        storage.append(NSAttributedString(string: s, attributes: attrs))
    }

    private func currentAttributes() -> [NSAttributedString.Key: Any] {
        let baseFont = textView.font
            ?? NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
            ?? NSFont.systemFont(ofSize: session.config.fontSize)

        let font: NSFont
        if sgr.bold {
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        } else {
            font = baseFont
        }

        let displayFG = sgr.inverse ? (sgr.bg ?? session.config.backgroundColor) : sgr.fg
        let displayBG = sgr.inverse ? sgr.fg : sgr.bg

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: displayFG,
        ]
        if let bg = displayBG {
            attrs[.backgroundColor] = bg
        }
        if sgr.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    private func applySGR(_ rawParams: [Int]) {
        // -1 (unspecified)을 0(reset)으로 정규화.
        let params = rawParams.map { $0 < 0 ? 0 : $0 }
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                sgr = SGRState(defaultFG: session.config.foregroundColor)
            case 1:  sgr.bold = true
            case 3:  sgr.italic = true
            case 4:  sgr.underline = true
            case 7:  sgr.inverse = true
            case 22: sgr.bold = false
            case 23: sgr.italic = false
            case 24: sgr.underline = false
            case 27: sgr.inverse = false
            case 30...37:
                sgr.fg = Palette.normal16[p - 30]
            case 38:
                if let (color, skip) = extendedColor(params: params, from: i + 1) {
                    sgr.fg = color
                    i += skip
                }
            case 39:
                sgr.fg = session.config.foregroundColor
            case 40...47:
                sgr.bg = Palette.normal16[p - 40]
            case 48:
                if let (color, skip) = extendedColor(params: params, from: i + 1) {
                    sgr.bg = color
                    i += skip
                }
            case 49:
                sgr.bg = nil
            case 90...97:
                sgr.fg = Palette.bright16[p - 90]
            case 100...107:
                sgr.bg = Palette.bright16[p - 100]
            default:
                break
            }
            i += 1
        }
    }

    /// `38;5;n` 또는 `38;2;r;g;b` 파싱. 반환은 (색, 소비한 추가 파람 수).
    private func extendedColor(params: [Int], from idx: Int) -> (NSColor, Int)? {
        guard idx < params.count else { return nil }
        switch params[idx] {
        case 5:
            guard idx + 1 < params.count else { return nil }
            return (Palette.color256(params[idx + 1]), 2)
        case 2:
            guard idx + 3 < params.count else { return nil }
            let r = max(0, min(255, params[idx + 1]))
            let g = max(0, min(255, params[idx + 2]))
            let b = max(0, min(255, params[idx + 3]))
            return (Palette.rgb(r, g, b), 4)
        default:
            return nil
        }
    }
}

/// 현재 펜(pen) 속성. 텍스트가 들어올 때 적용할 색/볼드/언더라인/반전.
private struct SGRState {
    var fg: NSColor
    var bg: NSColor? = nil
    var bold = false
    var italic = false
    var underline = false
    var inverse = false

    init(defaultFG: NSColor) {
        self.fg = defaultFG
    }
}
