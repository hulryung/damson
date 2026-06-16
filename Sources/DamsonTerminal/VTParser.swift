import Foundation

/// VT/ANSI escape sequence state machine.
///
/// A simplified Paul Williams' DEC VT-series parser. Only four core states:
///   - ground: printable + C0 controls
///   - escape: immediately after ESC
///   - csi: after ESC '[', collecting parameters/intermediates/final byte
///   - osc: after ESC ']', collecting a string until BEL or ST (ESC '\\')
///
/// Emits semantic events (text/control/CSI/OSC) to the delegate. Interpreting
/// CSI/OSC (SGR colors, cursor movement, title, etc.) is the consumer's job.
///
/// UTF-8 multibyte sequences are accumulated in the ground state, then only the
/// safe prefix is emitted as a String. Partial sequences are held until the next feed.
public protocol VTParserDelegate: AnyObject {
    func vtParser(_ parser: VTParser, didEmitText text: String)
    func vtParser(_ parser: VTParser, didExecute byte: UInt8)
    func vtParser(
        _ parser: VTParser,
        didEmitCSI params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    )
    func vtParser(_ parser: VTParser, didEmitOSC params: [String])
    /// ESC + single final byte sequences (e.g. `ESC 7` = DECSC, `ESC 8` = DECRC, `ESC c` = RIS).
    /// Single-byte escapes with no arguments only. Separate path from CSI/OSC.
    func vtParser(_ parser: VTParser, didEmitESC finalByte: UInt8)
}

public extension VTParserDelegate {
    func vtParser(_ parser: VTParser, didEmitESC finalByte: UInt8) {}
}

public final class VTParser {
    public weak var delegate: VTParserDelegate?

    private enum State {
        case ground
        case escape
        case csi
        case osc
        case oscEsc   // just received ESC inside an OSC (if the next byte is '\\' it's ST)
        case dcsParam        // ESC P seen — collecting params up to the final byte
        case dcsPassthrough  // unrecognized DCS — swallow payload until ST
        case dcsEsc          // ESC inside a DCS payload (next '\\' is ST)
        /// tmux `-CC` control mode detected (DCS `1000p`): the stream is no longer VT —
        /// every subsequent byte is the tmux control protocol. The parser stops interpreting
        /// and stashes bytes in `takeoverBuffer` for the host to hand to a TmuxControlClient.
        case tmuxTakeover
    }

    private var state: State = .ground

    // CSI accumulator
    private var params: [Int] = []
    /// `-1` = unspecified (the consumer applies the default appropriate for the op)
    private var currentParam: Int = -1
    private var intermediates: [UInt8] = []
    private var privateMarker: UInt8?

    // OSC accumulator (UTF-8 decoding happens at dispatch time)
    private var oscBytes: [UInt8] = []

    // Ground text accumulator (UTF-8 partial-safe decoding)
    private var textBytes: [UInt8] = []

    /// True once the stream entered tmux `-CC` control mode (DCS `1000p` — what the tmux
    /// client emits when a user runs `tmux -CC` in this terminal). From that point the
    /// parser interprets nothing; bytes pile into the takeover buffer for the host to hand
    /// to a `TmuxControlClient`. See docs/TMUX-INTEGRATION.md (P3 auto-detect).
    public private(set) var tmuxControlModeDetected = false
    private var takeoverBuffer: [UInt8] = []

    /// Drain the bytes that arrived after the tmux-control DCS introducer (the start of
    /// the control stream — typically `%begin …`). Call after observing
    /// `tmuxControlModeDetected`; subsequent feeds keep accumulating here until drained.
    public func takeTakeoverRemainder() -> Data {
        let d = Data(takeoverBuffer)
        takeoverBuffer.removeAll()
        return d
    }

    /// Leave tmux-takeover mode (the control client saw `%exit`); the parser resumes
    /// normal VT interpretation from ground state.
    public func endTmuxTakeover() {
        tmuxControlModeDetected = false
        takeoverBuffer.removeAll()
        state = .ground
    }

    public init() {}

    public func feed(_ data: Data) {
        // Walk the contiguous storage directly — Data's element iterator does a
        // per-byte bounds/representation check that dominates at flood rates.
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf { handle(byte) }
        }
        flushText()
    }

    public func feed(_ bytes: [UInt8]) {
        for byte in bytes { handle(byte) }
        flushText()
    }

    public func reset() {
        state = .ground
        params.removeAll()
        currentParam = -1
        intermediates.removeAll()
        privateMarker = nil
        oscBytes.removeAll()
        textBytes.removeAll()
        tmuxControlModeDetected = false
        takeoverBuffer.removeAll()
    }

    // MARK: - dispatch

    private func handle(_ b: UInt8) {
        // tmux control mode: nothing is VT anymore — stash and bail before CAN/SUB handling.
        if state == .tmuxTakeover {
            takeoverBuffer.append(b)
            return
        }
        // CAN/SUB — anywhere cancel
        if b == 0x18 || b == 0x1A {
            flushText()
            state = .ground
            return
        }
        switch state {
        case .ground: groundByte(b)
        case .escape: escapeByte(b)
        case .csi: csiByte(b)
        case .osc: oscByte(b)
        case .oscEsc: oscEscByte(b)
        case .dcsParam: dcsParamByte(b)
        case .dcsPassthrough: dcsPassthroughByte(b)
        case .dcsEsc: dcsEscByte(b)
        case .tmuxTakeover: takeoverBuffer.append(b)  // unreachable (handled above)
        }
    }

    private func groundByte(_ b: UInt8) {
        if b == 0x1B {
            flushText()
            enterEscape()
            return
        }
        // C0 controls (< 0x20) + DEL — execute
        if b < 0x20 || b == 0x7F {
            flushText()
            delegate?.vtParser(self, didExecute: b)
            return
        }
        // Printable + UTF-8 continuation bytes
        textBytes.append(b)
    }

    private func enterEscape() {
        state = .escape
        params.removeAll()
        currentParam = -1
        intermediates.removeAll()
        privateMarker = nil
        oscBytes.removeAll()
    }

    private func escapeByte(_ b: UInt8) {
        switch b {
        case 0x1B:
            enterEscape() // re-enter
        case 0x50: // 'P' — DCS
            state = .dcsParam
        case 0x5B: // '['
            state = .csi
        case 0x5D: // ']'
            state = .osc
        case 0x20...0x2F:
            intermediates.append(b)
        case 0x30...0x7E:
            // ESC + single final byte: DECSC(7) / DECRC(8) / RIS(c) / keypad mode, etc.
            delegate?.vtParser(self, didEmitESC: b)
            state = .ground
        default:
            state = .ground
        }
    }

    private func csiByte(_ b: UInt8) {
        switch b {
        case 0x30...0x39: // digit
            if currentParam < 0 { currentParam = 0 }
            currentParam = min(currentParam * 10 + Int(b - 0x30), 9999)
        case 0x3B: // ';'
            params.append(currentParam)
            currentParam = -1
        case 0x3C...0x3F: // private marker (only at the very start)
            if params.isEmpty && currentParam < 0 && privateMarker == nil {
                privateMarker = b
            }
        case 0x20...0x2F:
            intermediates.append(b)
        case 0x40...0x7E:
            // Final byte → dispatch
            params.append(currentParam)
            delegate?.vtParser(
                self,
                didEmitCSI: params,
                intermediates: intermediates,
                finalByte: b,
                privateMarker: privateMarker
            )
            state = .ground
        case 0x1B:
            enterEscape()
        default:
            break
        }
    }

    // MARK: - DCS (ESC P)

    /// DCS parameter section — same shape as CSI (params ; intermediates) up to a final
    /// byte, after which the payload runs to ST. The only DCS we ACT on is tmux's
    /// control-mode introducer `1000p`; everything else (sixel, DECRQSS, …) is swallowed
    /// so its payload can't leak into the grid as text.
    private func dcsParamByte(_ b: UInt8) {
        switch b {
        case 0x30...0x39: // digit
            if currentParam < 0 { currentParam = 0 }
            currentParam = min(currentParam * 10 + Int(b - 0x30), 9999)
        case 0x3B: // ';'
            params.append(currentParam)
            currentParam = -1
        case 0x3C...0x3F:
            if params.isEmpty && currentParam < 0 && privateMarker == nil {
                privateMarker = b
            }
        case 0x20...0x2F:
            intermediates.append(b)
        case 0x40...0x7E:
            params.append(currentParam)
            if b == 0x70 /* 'p' */, params == [1000], privateMarker == nil, intermediates.isEmpty {
                // tmux -CC "enter control mode". Everything after this byte is the control
                // protocol, not VT — hand the stream over (see tmuxControlModeDetected).
                tmuxControlModeDetected = true
                state = .tmuxTakeover
            } else {
                state = .dcsPassthrough
            }
        case 0x1B:
            enterEscape()
        default:
            // Malformed DCS param byte. A C0 control here means this was a false start
            // (see dcsPassthroughByte) — reprocess it in ground rather than eat it.
            state = .ground
            if b < 0x20 { handle(b) }
        }
    }

    private func dcsPassthroughByte(_ b: UInt8) {
        if b == 0x1B {
            state = .dcsEsc
            return
        }
        // Defensive bail-out: a legitimate DCS payload (sixel, DECRQSS, …) never contains
        // C0 controls — sixel even encodes its own newlines as '-'. If one shows up, this
        // "DCS" is almost certainly a FALSE START (a stray ESC P from a torn sequence or
        // binary spew). Without this, the parser would swallow EVERYTHING — including all
        // CSI cursor/erase commands — until the next ST, which in a TUI stream may be a
        // whole screenful away: exactly the "escape commands stopped being processed,
        // stale fragments everywhere" corruption mode. Abort to ground and reprocess the
        // byte so a false start costs at most one line.
        if b < 0x20 {
            state = .ground
            handle(b)
            return
        }
        // else: payload byte of a DCS we don't render — swallow
    }

    private func dcsEscByte(_ b: UInt8) {
        if b == 0x5C { // ST = ESC '\\' — DCS finished
            state = .ground
        } else if b == 0x1B {
            // consecutive ESCs — stay armed for a following '\\'
        } else if b == 0x5B { // ESC '[' — a CSI is starting; the "DCS" was a false start.
            // Don't swallow the CSI: abort the DCS and parse it for real (same defensive
            // rationale as the C0 bail-out above).
            state = .csi
            params.removeAll()
            currentParam = -1
            intermediates.removeAll()
            privateMarker = nil
        } else {
            state = .dcsPassthrough
        }
    }

    private func oscByte(_ b: UInt8) {
        switch b {
        case 0x07: // BEL terminates OSC
            dispatchOSC()
            state = .ground
        case 0x1B:
            state = .oscEsc
        default:
            oscBytes.append(b)
        }
    }

    private func oscEscByte(_ b: UInt8) {
        if b == 0x5C { // ST = ESC '\\'
            dispatchOSC()
            state = .ground
        } else {
            // not ST — cancel the OSC
            oscBytes.removeAll()
            state = .ground
        }
    }

    private func dispatchOSC() {
        let s = String(bytes: oscBytes, encoding: .utf8) ?? ""
        oscBytes.removeAll()
        let parts = s.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        delegate?.vtParser(self, didEmitOSC: parts)
    }

    private func flushText() {
        guard !textBytes.isEmpty else { return }
        // UTF-8 partial-safe: emit only the longest valid prefix, hold the rest.
        let maxTrail = min(3, textBytes.count)
        for trail in 0...maxTrail {
            let len = textBytes.count - trail
            if len == 0 { return }
            if let s = String(bytes: textBytes.prefix(len), encoding: .utf8) {
                delegate?.vtParser(self, didEmitText: s)
                textBytes.removeFirst(len)
                return
            }
        }
        // no prefix decoded at all — drop one byte and try on the next call
        textBytes.removeFirst()
    }
}
