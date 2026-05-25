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

/// 내부 표시용 NSTextView. first responder도 mouse hit도 거부.
private final class PassiveTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func becomeFirstResponder() -> Bool { false }
}

/// M3 placeholder: 자식 `NSTextView`에 Grid 스냅샷을 그대로 투영.
/// 한 번에 textStorage 전체를 갈아끼움 (run-length attrs 그룹핑).
/// 키 이벤트는 이쪽에서 잡아 `session.write(_:)`로 전달.
/// M4 이후 `CAMetalLayer` + 자체 렌더러로 교체.
public final class HaliteSurfaceView: NSView, NSTextInputClient {
    public let session: HaliteSession

    public var isActive: Bool = true {
        didSet { needsDisplay = true }
    }

    public var onFocus: (() -> Void)?

    private let scrollView: NSScrollView
    private let textView: PassiveTextView
    private var gridSubscription: AnyCancellable?
    private var lastReportedSize: (cols: Int, rows: Int)? = nil
    private var renderScheduled = false
    private var lastRenderedVersion: UInt64 = .max
    /// 마지막 렌더 시점의 marked text. grid 변화 없이 marked text만 비워질 때
    /// (BS-cancel 등) 강제 재렌더링하기 위한 비교용.
    private var lastRenderedMarkedText: String = ""
    /// 캐시된 cell metrics. `reportSizeIfChanged`가 갱신, render가 paragraph style에 사용.
    private var cellMetrics: (width: CGFloat, height: CGFloat) = (1, 1)

    /// IME 조합 중인 텍스트. 비어있지 않으면 cursor 자리에 시각적 overlay.
    /// 실제 PTY 전송은 `insertText`(commit)이 올 때만 일어남.
    private var markedText: String = ""

    /// 현재 처리 중인 `NSEvent`. `keyDown`이 set, IME 콜백(setMarkedText/insertText)에서
    /// "이 commit/preedit을 일으킨 키가 무엇인가" 판단에 사용. BS-cancel spurious commit 감지용.
    private var currentKeyEvent: NSEvent?

    /// 이 keyDown 사이클의 doCommand(deleteBackward:)를 1회 swallow. BS-cancel 처리 시,
    /// IME 콜백이 이미 marked text를 비웠고 PTY에 BS를 또 보내면 안 될 때 use.
    private var swallowNextDeleteCommand: Bool = false

    /// startup IME warmup 진행 중 플래그. `.app` 등록만으로는 TSM↔IMK 첫 IPC 핸드셰이크가
    /// 사용자의 첫 keystroke 시점에야 일어나서 첫 자모가 leak되는 잔존 race가 있음.
    /// view가 first responder가 되자마자 합성 dummy event를 inputContext로 흘려서
    /// IPC를 미리 wake up 시킨다. 그동안 콜백되는 insertText/doCommand는 PTY로 안 보냄.
    private var isWarmingUpIME: Bool = false
    private var didWarmupIME: Bool = false

    public init(session: HaliteSession) {
        self.session = session

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
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

        // 줄 자동 wrap을 끔. 셀 단위 격자에서는 wrap이 시각 라인 수를 늘려
        // scrollToEnd가 위쪽을 잘라낸 화면을 보여주는 원인이 됨.
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scroll.documentView = tv

        self.scrollView = scroll
        self.textView = tv

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = session.config.backgroundColor.cgColor

        addSubview(scroll)
        scroll.frame = bounds

        gridSubscription = session.gridChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.scheduleRender()
            }

        // 초기 1회 렌더.
        scheduleRender()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        reportSizeIfChanged()
    }

    private func reportSizeIfChanged() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let font = textView.font ?? NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
            ?? NSFont.systemFont(ofSize: session.config.fontSize)
        let glyphSize = ("M" as NSString).size(withAttributes: [.font: font])
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let cellW = max(glyphSize.width, 1)
        let cellH = max(lineHeight, 1)
        cellMetrics = (cellW, cellH)
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
        guard let window = window else { return }
        window.makeFirstResponder(self)
        inputContext?.activate()
        warmupIMEIfNeeded()
    }

    /// 사용자가 첫 키를 누르기 전에 TSM↔IMK IPC 핸드셰이크를 강제로 트리거.
    /// `.app` 등록만으로는 launch 후 첫 자모가 leak되는 잔존 race가 남아있는 환경 대응.
    private func warmupIMEIfNeeded() {
        guard !didWarmupIME else { return }
        didWarmupIME = true
        guard let window = window else { return }

        // 다음 runloop tick에 실행 — window가 fully key 된 다음에 IMK가 받도록.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            ) else { return }
            self.isWarmingUpIME = true
            self.inputContext?.handleEvent(event)
            self.isWarmingUpIME = false
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

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

    // MARK: - Input (IME-aware)

    public override func keyDown(with event: NSEvent) {
        // 새 keyDown 사이클 시작 — IME 콜백들이 참조할 컨텍스트 set.
        currentKeyEvent = event
        swallowNextDeleteCommand = false
        defer { currentKeyEvent = nil }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd는 performKeyEquivalent에서 처리. 여기에 도달했다는 건 어떤 메뉴/단축키도
        // 안 잡았다는 뜻이고, IME에 보내거나 PTY로 보내면 의도와 다른 동작이 생김 → 무시.
        if mods.contains(.command) {
            return
        }

        // Ctrl+letter (다른 modifier 없이) → terminal control byte. IME 우회.
        // Shift+Ctrl도 같은 group (e.g. Ctrl+Shift+C → Ctrl+C와 동일 바이트 → 0x03).
        if mods.subtracting(.shift) == .control,
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let scalar = chars.unicodeScalars.first?.value,
           (0x41...0x5A).contains(scalar) || (0x61...0x7A).contains(scalar) {
            let lower = scalar | 0x20
            session.write(Data([UInt8(lower - 0x60)]))
            return
        }

        // 나머지: NSTextInputContext로 보냄. 한글/일어/중어 IME composition,
        // 평문 입력, Enter/Tab/화살표 (doCommand 경로), Backspace (doCommand) 등을
        // 일관되게 처리.
        inputContext?.handleEvent(event)
    }

    public override func doCommand(by selector: Selector) {
        if isWarmingUpIME {
            return
        }
        // AppKit selector → terminal escape byte 시퀀스. NSTextInputClient의 핵심 contract:
        // IME가 처리하지 않은 키, 또는 IME가 commit하고 추가로 처리해야 할 키들이
        // 여기로 dispatched 됨.
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            session.write(Data([0x0D])) // CR
        case #selector(NSResponder.insertTab(_:)):
            session.write(Data([0x09]))
        case #selector(NSResponder.insertBacktab(_:)):
            session.write(Data([0x1B, 0x5B, 0x5A])) // CSI Z
        case #selector(NSResponder.deleteBackward(_:)):
            // BS-cancel spurious commit이 이미 IME 콜백에서 처리됐다면 PTY로는 BS 안 보냄.
            if swallowNextDeleteCommand {
                swallowNextDeleteCommand = false
                return
            }
            session.write(Data([0x7F])) // DEL (대부분의 셸이 erase에 mapping)
        case #selector(NSResponder.deleteForward(_:)):
            session.write(Data([0x1B, 0x5B, 0x33, 0x7E])) // CSI 3 ~
        case #selector(NSResponder.cancelOperation(_:)):
            session.write(Data([0x1B])) // ESC
        case #selector(NSResponder.moveUp(_:)),
             #selector(NSResponder.moveUpAndModifySelection(_:)):
            session.write(Data([0x1B, 0x5B, 0x41]))
        case #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.moveDownAndModifySelection(_:)):
            session.write(Data([0x1B, 0x5B, 0x42]))
        case #selector(NSResponder.moveLeft(_:)),
             #selector(NSResponder.moveLeftAndModifySelection(_:)):
            session.write(Data([0x1B, 0x5B, 0x44]))
        case #selector(NSResponder.moveRight(_:)),
             #selector(NSResponder.moveRightAndModifySelection(_:)):
            session.write(Data([0x1B, 0x5B, 0x43]))
        case #selector(NSResponder.scrollPageUp(_:)),
             #selector(NSResponder.pageUp(_:)):
            session.write(Data([0x1B, 0x5B, 0x35, 0x7E])) // PageUp
        case #selector(NSResponder.scrollPageDown(_:)),
             #selector(NSResponder.pageDown(_:)):
            session.write(Data([0x1B, 0x5B, 0x36, 0x7E])) // PageDown
        case #selector(NSResponder.moveToBeginningOfLine(_:)):
            session.write(Data([0x1B, 0x5B, 0x48])) // Home
        case #selector(NSResponder.moveToEndOfLine(_:)):
            session.write(Data([0x1B, 0x5B, 0x46])) // End
        default:
            break // 알 수 없는 command — 무시
        }
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.unwrapString(string)

        // startup warmup 중에는 콜백된 텍스트를 PTY로 보내지 않는다.
        if isWarmingUpIME {
            return
        }

        // BS-cancel spurious commit 감지.
        // macOS Hangul IME가 마지막 자모를 BS로 취소할 때, 같은 자모를 insertText로
        // emit하는 버그가 있음. 트리거 키가 BS이고 markedText와 동일한 글자가 commit
        // 되려 하면 spurious로 판단하고 drop. 동일 keyDown 사이클의 doCommand
        // (deleteBackward:)도 swallow.
        if let event = currentKeyEvent,
           event.keyCode == 51,
           !markedText.isEmpty,
           text == markedText {
            markedText = ""
            swallowNextDeleteCommand = true
            scheduleRender()
            return
        }

        // 알려진 한계: 한영키 직후 첫 자모는 setMarkedText를 거치지 않고 직접 insertText로
        // 들어옴 (raw binary 실행 시 TSM↔IMK IPC가 첫 keystroke 도착 전에 set up 안 됨).
        // 해법은 `.app` bundle 등록 (halite Rust 문서 참조). state machine 트릭은 IMK 내부
        // 상태와 어긋나서 lossy. 현재는 그대로 PTY로 commit — 사용자가 BS+재입력으로 복원 가능.

        // 일반 commit: marked text 비우고 PTY로.
        if !markedText.isEmpty {
            markedText = ""
            scheduleRender()
        }
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        session.write(data)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.unwrapString(string)
        if markedText != text {
            markedText = text
            scheduleRender()
        }
    }

    public func unmarkText() {
        if !markedText.isEmpty {
            markedText = ""
            scheduleRender()
        }
    }

    public func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    public func markedRange() -> NSRange {
        if markedText.isEmpty {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedText.utf16.count)
    }

    public func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// IME 후보창이 뜰 위치 — cursor 셀의 화면 좌표 반환.
    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let window = window else { return .zero }
        let grid = session.grid
        let cellW = cellMetrics.width
        let cellH = cellMetrics.height
        let inset = textView.textContainerInset

        // textView 좌표계에서 cursor 셀의 origin
        let rowInTextView = grid.scrollback.count + grid.cursorRow
        let cellOrigin = CGPoint(
            x: inset.width + CGFloat(grid.cursorCol) * cellW,
            y: inset.height + CGFloat(rowInTextView) * cellH
        )
        let cellRectInTextView = NSRect(origin: cellOrigin, size: NSSize(width: cellW, height: cellH))

        // textView → window → screen
        let cellRectInWindow = textView.convert(cellRectInTextView, to: nil)
        return window.convertToScreen(cellRectInWindow)
    }

    private static func unwrapString(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let attr = value as? NSAttributedString { return attr.string }
        return ""
    }

    // MARK: - Render

    /// 여러 grid mutation을 한 runloop tick의 한 번의 renderNow 호출로 합침.
    private func scheduleRender() {
        if renderScheduled { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.renderNow()
        }
    }

    private func renderNow() {
        let grid = session.grid
        // marked text가 직전과 같지 않으면 (조합 시작/갱신/취소) 반드시 재렌더.
        // 같으면서 grid도 안 변했으면 skip.
        // 참고: halite Rust의 ImeState도 모든 IME 콜백에 request_redraw=true를 set함.
        if grid.version == lastRenderedVersion && markedText == lastRenderedMarkedText {
            return
        }
        lastRenderedVersion = grid.version
        lastRenderedMarkedText = markedText

        guard let storage = textView.textStorage else { return }
        let baseFont = textView.font
            ?? NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
            ?? NSFont.systemFont(ofSize: session.config.fontSize)

        // 줄 높이를 정확히 cellH로 강제 (NSTextView 기본 spacing이 우리 cellH와
        // 어긋나면 전체 컨텐츠가 viewport보다 커져 scroll이 발생).
        let lineHeight = max(cellMetrics.height, 1)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineSpacing = 0
        paragraphStyle.lineBreakMode = .byClipping

        let result = NSMutableAttributedString()
        result.beginEditing()

        // Scrollback (오래된 → 최근). cursor는 안 그림.
        for line in grid.scrollback {
            appendLine(
                line, cols: line.count, cursorCol: nil,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
            result.append(NSAttributedString(string: "\n"))
        }

        // 현재 viewport. 커서가 있는 줄에서만 cursorCol 전달.
        let cursorRow = grid.cursorVisible ? grid.cursorRow : -1
        let mt = markedText
        for r in 0..<grid.rows {
            if r == cursorRow && !mt.isEmpty {
                // 조합 중 텍스트가 있으면 cursor 자리에 overlay
                appendCursorRowWithMarkedText(
                    grid.row(r),
                    cols: grid.cols,
                    cursorCol: grid.cursorCol,
                    markedText: mt,
                    baseFont: baseFont,
                    paragraphStyle: paragraphStyle,
                    into: result
                )
            } else {
                let cc: Int? = (r == cursorRow) ? grid.cursorCol : nil
                appendLine(
                    grid.row(r), cols: grid.cols, cursorCol: cc,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
            if r < grid.rows - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        result.endEditing()

        storage.beginEditing()
        storage.setAttributedString(result)
        storage.endEditing()

        // primary 화면에서만 자동 바닥 스크롤.
        // alt screen에선 buffer 전체가 viewport에 fit 하도록 우리가 크기를
        // 잡아두므로 스크롤 자체가 발생하면 안 되고, 우리가 강제로 호출하면
        // 매 cursor move마다 화면이 튐.
        if !grid.isAltScreenActive {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// 한 줄(Cell 배열)을 run-length attribute 그룹으로 묶어서 attributed string에 append.
    /// `cursorCol`이 주어지면 그 위치의 한 셀은 단독으로 inverse 처리해서 그림.
    private func appendLine(
        _ line: [Cell],
        cols: Int,
        cursorCol: Int?,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        guard cols > 0 else { return }
        let cc = cursorCol ?? -1
        if cc >= 0 && cc < cols {
            if cc > 0 {
                appendRunGroup(
                    line, range: 0..<cc,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
            var attrs = line[cc].attrs
            attrs.inverse.toggle()
            let nsAttrs = makeAttributes(for: attrs, baseFont: baseFont, paragraphStyle: paragraphStyle)
            result.append(NSAttributedString(string: String(line[cc].char), attributes: nsAttrs))
            if cc + 1 < cols {
                appendRunGroup(
                    line, range: (cc + 1)..<cols,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
        } else {
            appendRunGroup(
                line, range: 0..<cols,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }
    }

    /// cursor 자리에 IME 조합 중 텍스트를 시각적 overlay로 그림.
    /// grid 자체는 mutate 안 함 (commit이 오면 PTY echo로 grid 갱신).
    private func appendCursorRowWithMarkedText(
        _ line: [Cell],
        cols: Int,
        cursorCol: Int,
        markedText: String,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        // cursor 이전 셀들 — 평소처럼
        if cursorCol > 0 {
            appendRunGroup(
                line, range: 0..<cursorCol,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }

        // 조합 텍스트 — 진한 파란 배경 + 두꺼운 underline. "조합 중" 명확한 시각 단서.
        // (M11.x에서 config 옵션으로 underline/background/both 선택지 추가 가능)
        let imeAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
            .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.65),
        ]
        result.append(NSAttributedString(string: markedText, attributes: imeAttrs))

        // 조합 텍스트가 가린 만큼 row의 나머지 셀을 건너뜀.
        // markedText.count로 대략의 cell 폭 산정 (CJK wide는 M5에서 처리).
        let overlayCols = markedText.count
        let afterCol = min(cursorCol + overlayCols, cols)
        if afterCol < cols {
            appendRunGroup(
                line, range: afterCol..<cols,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }
    }

    private func appendRunGroup(
        _ line: [Cell],
        range: Range<Int>,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        var c = range.lowerBound
        while c < range.upperBound {
            // Continuation cell은 NSAttributedString에 추가하지 않음 —
            // 직전 wide glyph가 두 칸을 자연스럽게 차지함.
            if line[c].isContinuation {
                c += 1
                continue
            }
            let runAttrs = line[c].attrs
            var endC = c + 1
            // 같은 attrs가 이어지는 한 묶음. continuation은 묶음 경계로 다룸.
            while endC < range.upperBound,
                  !line[endC].isContinuation,
                  line[endC].attrs == runAttrs {
                endC += 1
            }
            var runChars = ""
            runChars.reserveCapacity(endC - c)
            for i in c..<endC { runChars.append(line[i].char) }
            let nsAttrs = makeAttributes(for: runAttrs, baseFont: baseFont, paragraphStyle: paragraphStyle)
            result.append(NSAttributedString(string: runChars, attributes: nsAttrs))
            c = endC
        }
    }

    private func makeAttributes(
        for cellAttrs: CellAttrs,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        let (fg, bg) = cellAttrs.resolvedColors(defaultBG: session.config.backgroundColor)
        let font: NSFont
        if cellAttrs.bold {
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        } else {
            font = baseFont
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
            .paragraphStyle: paragraphStyle,
        ]
        if let bg = bg {
            attrs[.backgroundColor] = bg
        }
        if cellAttrs.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }
}
