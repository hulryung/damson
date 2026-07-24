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
    /// Charset designation: `ESC ( <f>` → G0, `ESC ) <f>` → G1, `ESC * <f>` → G2,
    /// `ESC + <f>` → G3. `slot` is 0…3; `charset` is the final byte (`'B'` = US-ASCII,
    /// `'0'` = DEC Special Graphics / line-drawing). SI (0x0F) / SO (0x0E) select G0 / G1
    /// into GL. Lets ncurses TUIs that box-draw via ACS render ─│┌┐ instead of `qxlk`.
    func vtParser(_ parser: VTParser, didDesignateCharset slot: Int, charset: UInt8)
}

public extension VTParserDelegate {
    func vtParser(_ parser: VTParser, didEmitESC finalByte: UInt8) {}
    func vtParser(_ parser: VTParser, didDesignateCharset slot: Int, charset: UInt8) {}
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
    /// Parallel to `params`: true when this param was separated from the previous one by
    /// a COLON (ISO 8613-6 / ITU-T T.416 sub-parameter) rather than a semicolon. Used
    /// only to normalize colon-form SGR (`38:2:r:g:b` truecolor, `4:3` curly underline)
    /// back into the flat semicolon form the SGR interpreter consumes.
    private var paramIsSub: [Bool] = []
    /// Whether the next appended param follows a colon (armed by the colon case).
    private var pendingSub = false

    // OSC accumulator (UTF-8 decoding happens at dispatch time)
    private var oscBytes: [UInt8] = []
    /// Set when an OSC string blew past `maxOSCBytes` — the OSC is then swallowed to its
    /// terminator and dropped (not dispatched) instead of growing the buffer unbounded.
    private var oscTruncated = false

    // Ground text accumulator (UTF-8 partial-safe decoding)
    private var textBytes: [UInt8] = []

    /// Parser-state bounds. The parser's accumulators persist across `feed()` chunks, so
    /// an escape that never terminates (`\e[` + a flood of `;`, or an unterminated `\e]`
    /// OSC) would otherwise grow without limit across drains and pin CPU/RAM. These caps
    /// sit far above anything real content emits (xterm's NPARAM is 30; titles/hyperlinks
    /// are tiny; even a large OSC 52 clipboard stays well under the OSC cap).
    private static let maxCSIParams = 32
    private static let maxIntermediates = 4
    private static let maxOSCBytes = 4 * 1024 * 1024

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
        paramIsSub.removeAll()
        pendingSub = false
        oscBytes.removeAll()
        oscTruncated = false
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
            // A single intermediate of ( ) * + means this is a G0…G3 charset
            // designation (`ESC ( 0`); otherwise it's a plain ESC final byte
            // (DECSC(7) / DECRC(8) / RIS(c) / keypad mode, etc.).
            if let slot = Self.charsetSlot(intermediates) {
                delegate?.vtParser(self, didDesignateCharset: slot, charset: b)
            } else {
                delegate?.vtParser(self, didEmitESC: b)
            }
            state = .ground
        default:
            state = .ground
        }
    }

    /// Map an ESC-intermediate to the charset slot it designates: `(`→G0, `)`→G1,
    /// `*`→G2, `+`→G3. nil for any other intermediate (not a charset designation).
    private static func charsetSlot(_ intermediates: [UInt8]) -> Int? {
        guard intermediates.count == 1 else { return nil }
        switch intermediates[0] {
        case 0x28: return 0   // (
        case 0x29: return 1   // )
        case 0x2A: return 2   // *
        case 0x2B: return 3   // +
        default:   return nil
        }
    }

    private func csiByte(_ b: UInt8) {
        switch b {
        case 0x30...0x39: // digit
            if currentParam < 0 { currentParam = 0 }
            currentParam = min(currentParam * 10 + Int(b - 0x30), 9999)
        case 0x3A: // ':' — ISO 8613-6 sub-parameter separator (colon-form SGR)
            appendCSIParam()
            pendingSub = true   // the param after this colon is a sub-parameter
            currentParam = -1
        case 0x3B: // ';'
            appendCSIParam()
            pendingSub = false
            currentParam = -1
        case 0x3C...0x3F: // private marker (only at the very start)
            if params.isEmpty && currentParam < 0 && privateMarker == nil {
                privateMarker = b
            }
        case 0x20...0x2F:
            if intermediates.count < Self.maxIntermediates { intermediates.append(b) }
        case 0x40...0x7E:
            // Final byte → dispatch
            appendCSIParam()
            // SGR (`m`) may carry colon sub-parameters (truecolor / underline style);
            // normalize them into the flat semicolon form the consumer understands.
            let outParams = (b == 0x6D) ? normalizedSGRParams() : params
            delegate?.vtParser(
                self,
                didEmitCSI: outParams,
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

    /// Append `currentParam` to `params` (with its colon/semicolon origin), honoring the
    /// param-count cap so `params` and `paramIsSub` stay parallel and bounded.
    private func appendCSIParam() {
        guard params.count < Self.maxCSIParams else { return }
        params.append(currentParam)
        paramIsSub.append(pendingSub)
    }

    /// Normalize ISO 8613-6 colon sub-parameters in an SGR (`m`) sequence into the flat
    /// semicolon form the SGR interpreter consumes. Params are grouped by colon runs
    /// (a semicolon starts a new group), then each group is rewritten:
    ///   • `38/48/58 : 5 : n`             → `38 ; 5 ; n`         (indexed color)
    ///   • `38/48/58 : 2 [: cs] : r:g:b`  → `38 ; 2 ; r ; g ; b` (truecolor; colorspace id dropped)
    ///   • `4 : style`                    → `4` (style ≠ 0) or `24` (style 0) — underline on/off
    ///   • anything else                  → the group's primary value only (sub-params dropped)
    private func normalizedSGRParams() -> [Int] {
        // Fast path: no colon was used → already flat semicolon form.
        guard paramIsSub.contains(true) else { return params }
        var out: [Int] = []
        var i = 0
        while i < params.count {
            var group = [params[i]]
            var j = i + 1
            while j < params.count && paramIsSub[j] { group.append(params[j]); j += 1 }
            i = j
            let primary = group[0]
            if group.count == 1 {
                out.append(primary)
            } else if primary == 38 || primary == 48 || primary == 58 {
                switch group[1] {
                case 5 where group.count >= 3:
                    out.append(contentsOf: [primary, 5, group[2]])
                case 2 where group.count >= 5:
                    // 5 elems: 2,r,g,b — 6+ elems: 2,cs,r,g,b (colorspace id at [2], dropped).
                    let base = group.count >= 6 ? 3 : 2
                    out.append(contentsOf: [primary, 2, group[base], group[base + 1], group[base + 2]])
                default:
                    out.append(primary)   // unrecognized color form — keep just the primary
                }
            } else if primary == 4 {
                out.append(group[1] == 0 ? 24 : 4)   // underline style → underline on/off
            } else {
                out.append(primary)
            }
        }
        return out
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
            if params.count < Self.maxCSIParams { params.append(currentParam) }
            currentParam = -1
        case 0x3C...0x3F:
            if params.isEmpty && currentParam < 0 && privateMarker == nil {
                privateMarker = b
            }
        case 0x20...0x2F:
            if intermediates.count < Self.maxIntermediates { intermediates.append(b) }
        case 0x40...0x7E:
            if params.count < Self.maxCSIParams { params.append(currentParam) }
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
            if oscBytes.count < Self.maxOSCBytes {
                oscBytes.append(b)
            } else {
                // Past the cap: stop growing and mark the OSC as blown so it's dropped
                // (not dispatched) at its terminator. Bounds memory on an unterminated OSC.
                oscTruncated = true
            }
        }
    }

    private func oscEscByte(_ b: UInt8) {
        if b == 0x5C { // ST = ESC '\\'
            dispatchOSC()
            state = .ground
        } else {
            // not ST — cancel the OSC
            oscBytes.removeAll()
            oscTruncated = false
            state = .ground
        }
    }

    private func dispatchOSC() {
        defer { oscBytes.removeAll(); oscTruncated = false }
        // An over-cap OSC is malformed/hostile — drop it rather than dispatch a
        // multi-megabyte string built from a runaway stream.
        if oscTruncated { return }
        let s = String(bytes: oscBytes, encoding: .utf8) ?? ""
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
