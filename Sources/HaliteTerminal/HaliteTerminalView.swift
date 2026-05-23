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

    public init(session: HaliteSession) {
        self.session = session

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false

        let tv = PassiveTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isRichText = false
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

        // PTY 출력 chunk를 textView에 append.
        outputSubscription = session.outputChunks
            .receive(on: RunLoop.main)
            .sink { [weak self] chunk in
                self?.appendOutput(chunk)
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

    // MARK: - Output

    /// PTY 출력 chunk를 받아 textStorage에 직접 append.
    /// 전체 텍스트 교체 대신 델타만 추가해서 O(n²) 회피.
    /// M2에서 VTParser가 도착하면 이 부분은 .text 이벤트 핸들러로 갈아끼움.
    private func appendOutput(_ chunk: String) {
        guard let storage = textView.textStorage else { return }

        var pending = ""
        var iterator = chunk.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar.value {
            case 0x1B: // ESC — CSI/OSC 등은 일단 끝까지 소비하고 버림 (M2에서 파서로)
                flushPlain(&pending, into: storage)
                if let next = iterator.next() {
                    if next.value == 0x5B { // '['
                        // CSI — 영문자(0x40-0x7E) 종결자까지
                        while let c = iterator.next() {
                            if (0x40...0x7E).contains(c.value) { break }
                        }
                    } else if next.value == 0x5D { // ']'
                        // OSC — BEL(0x07) 또는 ST(ESC \) 까지
                        while let c = iterator.next() {
                            if c.value == 0x07 { break }
                            if c.value == 0x1B {
                                _ = iterator.next() // ST의 \\ 소비
                                break
                            }
                        }
                    } else {
                        // 기타 escape 1바이트 — 무시
                    }
                }
            case 0x07: // BEL — TODO: bell 콜백
                flushPlain(&pending, into: storage)
            case 0x08: // BS — 마지막 글자 제거
                flushPlain(&pending, into: storage)
                if storage.length > 0 {
                    storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1))
                }
            case 0x0D: // CR — M1은 LF만 사용
                continue
            default:
                pending.unicodeScalars.append(scalar)
            }
        }
        flushPlain(&pending, into: storage)
        textView.scrollToEndOfDocument(nil)
    }

    private func flushPlain(_ pending: inout String, into storage: NSTextStorage) {
        if pending.isEmpty { return }
        let font = textView.font
            ?? NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
            ?? NSFont.systemFont(ofSize: session.config.fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: session.config.foregroundColor,
        ]
        storage.append(NSAttributedString(string: pending, attributes: attrs))
        pending = ""
    }
}
