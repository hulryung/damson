import Darwin
import Foundation
import os

/// Spawns the child shell on a PTY and manages read/write/resize/wait.
/// Reading runs on a dedicated thread; callbacks hop to the main queue.
///
/// This is the default `SessionIOBackend` (local forkpty). A tmux control-mode
/// backend will be a sibling conformance — see `docs/TMUX-INTEGRATION.md`.
public final class PTYHost: SessionIOBackend {
    public enum SpawnError: Error {
        case forkptyFailed(errno: Int32)
    }

    public var onData: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private var primaryFD: Int32 = -1
    private var childPID: pid_t = -1
    /// Adopted = the child is NOT our child (it survived a previous app instance via the
    /// keeper). waitpid is impossible (launchd reaped it), so exit detection is EOF/POLLHUP
    /// on the master, and any signal is gated on a process-identity check (pid + start time)
    /// because the pid may have been recycled since the handoff.
    private var isAdopted = false
    private var adoptedStart: (sec: UInt64, usec: UInt64) = (0, 0)
    private var adoptedReplay = Data()
    private var didFirstAdoptedResize = false
    /// Set by `releaseOwnership()` — the fd/child now belong to the keeper, so
    /// `terminate()`/`deinit` and the pending waitpid callback must all no-op.
    private var released = false
    /// Wakes the poll-based read loop without touching the pty fd (see `startReading`).
    private var wakePipeRead: Int32 = -1
    private var wakePipeWrite: Int32 = -1
    /// Signaled every time the read loop exits; `releaseOwnership` waits on it so the
    /// loop is provably out of poll/read before the fd changes hands.
    private let readLoopDone = DispatchSemaphore(value: 0)
    /// Loop-control flag written on the main thread (`terminate`) and read on the read
    /// thread (`startReading`/`enqueueOutput`). Backed by a lock so the cross-thread
    /// access is a defined atomic op rather than a data race (UB under TSan).
    private let readingState = OSAllocatedUnfairLock(initialState: false)
    private var isReading: Bool {
        get { readingState.withLock { $0 } }
        set { readingState.withLock { $0 = newValue } }
    }

    private let readQueue = DispatchQueue(label: "damson.pty.read", qos: .userInteractive)
    private let waitQueue = DispatchQueue(label: "damson.pty.wait", qos: .utility)

    // Read-side coalescing buffer (see startReading). Guarded by pendingLock; shared
    // between the read thread (append) and the main thread (drain).
    private let pendingLock = NSLock()
    private var pendingOutput = Data()
    /// Read cursor into `pendingOutput`: bytes before it are already delivered but not yet
    /// physically removed. Draining advances this instead of `removeFirst`-ing every turn
    /// (which memmoves the whole remaining backlog each drain → O(n²) over a flood). The
    /// consumed prefix is compacted only once it grows past the un-drained tail, which
    /// amortizes the memmove to O(1) per byte. Guarded by `pendingLock`.
    private var drainOffset = 0
    private var drainScheduled = false
    /// Cap on bytes buffered between the read thread and the main thread. When the main
    /// thread can't keep up with an output flood (e.g. `yes`), the read thread stalls at
    /// this cap; the kernel PTY buffer then fills and the child blocks in write() —
    /// natural backpressure with bounded memory, instead of an unbounded main-queue
    /// backlog that freezes the UI.
    private static let maxPendingBytes = 2 * 1024 * 1024
    /// Max bytes handed to the consumer per drain (one main-runloop turn). This bounds the
    /// VTParser time spent per turn, so UI events interleave at a steady cadence no matter
    /// how fast the child produces output — without it, a single drain could carry the whole
    /// 2MB backlog and stall the UI for however long that takes to parse. The remainder is
    /// rescheduled onto the next turn.
    private static let maxDrainBytes = 128 * 1024

    public init() {}

    /// The child shell process's current working directory. Queried directly from the
    /// OS via proc_pidinfo, so it's independent of shell configuration (whether OSC 7 is
    /// emitted, etc.). Used when restoring session state. nil if there's no child or the
    /// query fails.
    public var childWorkingDirectory: String? {
        guard childPID > 0 else { return nil }
        // An adopted pid may have been recycled by an unrelated process; never answer
        // for a stranger.
        if isAdopted, !Self.identityMatches(pid: childPID, start: adoptedStart) { return nil }
        var vpi = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(childPID, PROC_PIDVNODEPATHINFO, 0, &vpi, sz)
        guard r == sz else { return nil }
        return withUnsafePointer(to: &vpi.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// A process's kernel start timestamp — the disambiguator that makes a pid usable
    /// after the process stopped being our child. (0, 0) if the pid is gone.
    public static func processStartTime(pid: pid_t) -> (sec: UInt64, usec: UInt64) {
        var info = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz)
        guard r == sz else { return (0, 0) }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    /// True only when `pid` is alive AND is the same process it was at handoff time.
    private static func identityMatches(pid: pid_t, start: (sec: UInt64, usec: UInt64)) -> Bool {
        guard pid > 0, start != (0, 0) else { return false }
        let now = processStartTime(pid: pid)
        return now == start
    }

    /// true when the PTY's foreground process group differs from the shell itself
    /// (childPID, = the shell's pgid) — i.e. the shell is running some command in the
    /// foreground rather than waiting at a prompt. Used so the exit-confirmation dialog
    /// doesn't prompt when "only the shell is up".
    public var isRunningForegroundJob: Bool {
        guard childPID > 0, primaryFD >= 0 else { return false }
        let fg = tcgetpgrp(primaryFD)
        return fg > 0 && fg != childPID
    }

    deinit {
        terminate()
    }

    /// Take over a PTY that survived a previous app instance (reclaimed from the keeper).
    /// Stores the fd/pid but does NOT start reading — `DamsonSession.init` wires `onData`
    /// first and then calls `spawn`, which for an adopted host skips forkpty, delivers
    /// `replay` (mode preamble + bytes buffered while the app was down) through `onData`,
    /// and only then starts the read loop — so replay is parsed strictly before live output.
    public func adopt(fd: Int32, pid: pid_t, startSec: UInt64, startUsec: UInt64, replay: Data) {
        primaryFD = fd
        childPID = pid
        isAdopted = true
        adoptedStart = (startSec, startUsec)
        adoptedReplay = replay
    }

    public func spawn(
        argv: [String],
        env: [String: String],
        cwd: String?,
        cols: Int = 80,
        rows: Int = 24
    ) throws {
        if isAdopted {
            // The child predates this process; there is nothing to fork and its window
            // size is whatever it already had — leave it, `resize` reconciles later.
            makeWakePipe()
            let replay = adoptedReplay
            adoptedReplay = Data()
            if !replay.isEmpty {
                // Through the main queue, like every live drain — anything the read loop
                // enqueues afterwards lands behind it, preserving byte order end to end.
                DispatchQueue.main.async { [weak self] in self?.onData?(replay) }
            }
            startReading()
            return
        }
        precondition(!argv.isEmpty, "argv must not be empty")

        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var primary: Int32 = 0
        let pid = forkpty(&primary, nil, nil, &ws)

        if pid < 0 {
            throw SpawnError.forkptyFailed(errno: errno)
        }

        if pid == 0 {
            // === child process ===
            if let cwd = cwd {
                _ = chdir(cwd)
            }

            // argv → C
            let argvCStrings: [UnsafeMutablePointer<CChar>?] =
                argv.map { strdup($0) } + [nil]

            // env → array of "KEY=VALUE" C strings
            let envCStrings: [UnsafeMutablePointer<CChar>?] =
                env.map { strdup("\($0.key)=\($0.value)") } + [nil]

            argvCStrings.withUnsafeBufferPointer { argvBuf in
                envCStrings.withUnsafeBufferPointer { envBuf in
                    _ = execve(
                        argv[0],
                        UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                        UnsafeMutablePointer(mutating: envBuf.baseAddress)
                    )
                }
            }

            // execve failed — exit the child immediately
            _exit(127)
        }

        // === parent process ===
        primaryFD = primary
        childPID = pid

        makeWakePipe()
        startReading()
        startWaiting()
    }

    private func makeWakePipe() {
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            wakePipeRead = fds[0]
            wakePipeWrite = fds[1]
            _ = fcntl(wakePipeRead, F_SETFD, FD_CLOEXEC)
            _ = fcntl(wakePipeWrite, F_SETFD, FD_CLOEXEC)
        }
    }

    private func closeWakePipe() {
        if wakePipeRead >= 0 { close(wakePipeRead); wakePipeRead = -1 }
        if wakePipeWrite >= 0 { close(wakePipeWrite); wakePipeWrite = -1 }
    }

    public func write(_ data: Data) {
        guard primaryFD >= 0 else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var remaining = buf.count
            var ptr = base
            while remaining > 0 {
                let n = Darwin.write(primaryFD, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if n == 0 { return }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard primaryFD >= 0 else { return }
        // An adopted child must receive at least one real SIGWINCH, or a full-screen TUI
        // never repaints what it drew for the previous app instance. The kernel signals
        // only on CHANGE, and a back-to-back cols-1 → cols pair is useless: the two
        // signals coalesce, the TUI re-queries the size once, sees its own old value and
        // skips the redraw (top does exactly this). So when the first adopted resize
        // lands on the size the child already has, park it one column short NOW and
        // restore the real width 300ms later — two well-separated WINCHes, guaranteed
        // full repaint (the same dance tmux does on attach). A first resize to any other
        // size is a genuine change and needs none of this.
        if isAdopted, !didFirstAdoptedResize {
            var cur = winsize()
            if ioctl(primaryFD, TIOCGWINSZ, &cur) == 0 {
                didFirstAdoptedResize = true
                if Int(cur.ws_col) == cols, Int(cur.ws_row) == rows, cols > 1 {
                    var jiggle = winsize(
                        ws_row: UInt16(rows), ws_col: UInt16(cols - 1), ws_xpixel: 0, ws_ypixel: 0)
                    _ = ioctl(primaryFD, TIOCSWINSZ, &jiggle)
                    let fd = primaryFD
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        // Still the same live pty, and no newer resize superseded us?
                        guard let self, self.primaryFD == fd, !self.released,
                              self.lastRequestedSize?.cols == cols,
                              self.lastRequestedSize?.rows == rows else { return }
                        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols),
                                         ws_xpixel: 0, ws_ypixel: 0)
                        _ = ioctl(fd, TIOCSWINSZ, &ws)
                    }
                    lastRequestedSize = (cols, rows)
                    return   // stay parked at cols-1 until the delayed restore
                }
            }
        }
        lastRequestedSize = (cols, rows)
        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(primaryFD, TIOCSWINSZ, &ws)
    }

    /// The most recent size the host asked for — lets the delayed adoption jiggle
    /// detect that a newer resize superseded it.
    private var lastRequestedSize: (cols: Int, rows: Int)?

    public func terminate() {
        // Handed off to the keeper — the fd and the child are someone else's now.
        if released { return }
        // ⚠️ macOS PTY: while the read thread is blocked in read() on the primary fd,
        // calling close(fd) from another thread **blocks** until that read returns.
        // (The loop now parks in poll(), which close doesn't block on — but the wake
        // pipe still gets poked so the loop exits promptly instead of discovering the
        // dead fd on its next wakeup.)
        // → move kill + close onto a background queue and return immediately on main.
        let pidToKill = childPID
        let fdToClose = primaryFD
        let adopted = isAdopted
        let start = adoptedStart
        isReading = false
        childPID = -1
        primaryFD = -1
        wake()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            if adopted {
                // Not our child, and the pid may be recycled. Primary mechanism is
                // closing the master — ours is the LAST open descriptor (the keeper
                // closed its copy at claim), so close delivers SIGHUP to the child's
                // session, the standard "terminal went away". Escalate with signals
                // only for HUP-ignorers, and only after proving the pid still is the
                // process we adopted.
                if fdToClose >= 0 { close(fdToClose) }
                if Self.identityMatches(pid: pidToKill, start: start) {
                    kill(pidToKill, SIGTERM)
                    Thread.sleep(forTimeInterval: 1.0)
                    if Self.identityMatches(pid: pidToKill, start: start) {
                        kill(pidToKill, SIGKILL)
                    }
                }
            } else {
                if pidToKill > 0 {
                    kill(pidToKill, SIGTERM)
                    // if the shell ignores SIGTERM (e.g. a foreground app like vim is
                    // holding it), force-kill after a 1-second grace period. Responsiveness
                    // takes priority over data preservation (the user explicitly asked to close).
                    Thread.sleep(forTimeInterval: 1.0)
                    kill(pidToKill, SIGKILL)
                }
                if fdToClose >= 0 {
                    close(fdToClose)
                }
            }
            self?.closeWakePipe()
        }
    }

    /// Poke the read loop out of poll() without touching the pty fd.
    private func wake() {
        if wakePipeWrite >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wakePipeWrite, &byte, 1)
        }
    }

    /// Everything the next app instance needs to resurrect this session around the
    /// still-running child.
    public struct PTYHandoff {
        public let fd: Int32
        public let pid: pid_t
        public let startSec: UInt64
        public let startUsec: UInt64
        public let cwd: String?
        /// Bytes already read from the kernel but not yet delivered to the parser —
        /// dropping them would tear an escape sequence in half for the adopting parser.
        public let tail: Data
    }

    /// Detach this host from its fd and child WITHOUT killing either, for handoff to the
    /// keeper. Stops the read loop (wake pipe, provably out via `readLoopDone`), captures
    /// the undelivered tail, snapshots cwd + process start time while the child is still
    /// ours to query, then clears ownership so `terminate()`/`deinit` no-op.
    public func releaseOwnership() -> PTYHandoff? {
        guard !released, primaryFD >= 0, childPID > 0 else { return nil }
        let fd = primaryFD
        let pid = childPID
        let cwd = childWorkingDirectory
        let start = Self.processStartTime(pid: pid)

        isReading = false
        wake()
        // The loop signals on every exit path; if the child died earlier the signal is
        // already pending and this returns immediately.
        _ = readLoopDone.wait(timeout: .now() + 2.0)

        pendingLock.lock()
        let tail: Data
        if pendingOutput.count > drainOffset {
            let startIdx = pendingOutput.startIndex + drainOffset
            tail = pendingOutput.subdata(in: startIdx..<pendingOutput.endIndex)
        } else {
            tail = Data()
        }
        pendingOutput.removeAll(keepingCapacity: false)
        drainOffset = 0
        drainScheduled = false
        pendingLock.unlock()

        released = true
        childPID = -1
        primaryFD = -1
        closeWakePipe()
        return PTYHandoff(fd: fd, pid: pid, startSec: start.sec, startUsec: start.usec,
                          cwd: cwd, tail: tail)
    }

    // MARK: - Internals

    /// Read loop. Bytes are NOT delivered one main-queue block per read() — under an
    /// output flood (`yes`, `cat hugefile`) that enqueues thousands of small blocks per
    /// second, growing the main queue without bound and freezing the UI. Instead the read
    /// thread appends into `pendingOutput` and schedules at most ONE main-thread drain at
    /// a time; each drain hands the consumer everything accumulated since the last turn as
    /// a single chunk (fewer, larger VTParser feeds — also faster per byte). Combined with
    /// the `maxPendingBytes` stall this keeps the UI responsive at any output rate.
    private func startReading() {
        isReading = true
        let fd = primaryFD
        let wakeFD = wakePipeRead
        let adopted = isAdopted
        readQueue.async { [weak self] in
            // Signaled on EVERY exit path — releaseOwnership waits on this so the loop is
            // provably out of poll/read before the fd changes hands.
            defer { self?.readLoopDone.signal() }
            let bufferSize = 65536
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while self?.isReading == true {
                // Park in poll, not read: poll is interruptible through the wake pipe
                // without touching the pty fd (a close would block while a read is in
                // flight — the documented macOS pty hazard `terminate` works around).
                var fds = [
                    pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0),
                ]
                let pr = poll(&fds, 2, -1)
                if pr < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if fds[1].revents != 0 { return }   // woken — leave the pty fd untouched
                guard fds[0].revents != 0 else { continue }
                // POLLIN or POLLHUP: read won't block now. HUP with drained queue reads 0.
                let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                    read(fd, ptr.baseAddress, ptr.count)
                }
                if n > 0 {
                    self?.enqueueOutput(buffer[0..<n])
                } else if n == 0 {
                    // EOF — every slave descriptor closed, i.e. the child (and its whole
                    // session) is gone. For an adopted child this is the ONLY exit signal
                    // we get: launchd reaped it, waitpid can never see it. The real exit
                    // status is unobtainable; report 0 (the pane-close path ignores it).
                    if adopted {
                        DispatchQueue.main.async { self?.onExit?(0) }
                    }
                    return
                } else {
                    if errno == EINTR { continue }
                    return
                }
            }
        }
    }

    /// Read-thread side: append bytes to the pending buffer, schedule a single main-queue
    /// drain, and stall while the backlog is at the cap (the drain side shrinks it).
    private func enqueueOutput(_ bytes: ArraySlice<UInt8>) {
        pendingLock.lock()
        pendingOutput.append(contentsOf: bytes)
        let needsSchedule = !drainScheduled
        drainScheduled = true
        var backlog = pendingOutput.count - drainOffset
        pendingLock.unlock()

        if needsSchedule {
            DispatchQueue.main.async { [weak self] in self?.drainPendingOutput() }
        }
        while backlog >= Self.maxPendingBytes && isReading {
            usleep(2_000)
            pendingLock.lock()
            backlog = pendingOutput.count - drainOffset
            pendingLock.unlock()
        }
    }

    /// Main-thread side: deliver up to `maxDrainBytes` of the buffer as one chunk. If more
    /// remains, keep `drainScheduled` set and re-arm a drain on the NEXT runloop turn — UI
    /// events get serviced in between, which is what keeps the app responsive while a flood
    /// is being parsed at full speed.
    private func drainPendingOutput() {
        pendingLock.lock()
        let available = pendingOutput.count - drainOffset
        let take = min(available, Self.maxDrainBytes)
        let start = pendingOutput.startIndex + drainOffset
        let chunk = pendingOutput.subdata(in: start..<(start + take))
        drainOffset += take
        if drainOffset >= pendingOutput.count {
            // Fully drained — reset with no memmove.
            pendingOutput.removeAll(keepingCapacity: true)
            drainOffset = 0
            drainScheduled = false
        } else {
            // Compact the delivered prefix only once it's at least as large as the
            // remaining tail: the memmove then costs ≤ (bytes since last compaction),
            // i.e. amortized O(1) per byte instead of O(n) every drain.
            if drainOffset >= pendingOutput.count - drainOffset {
                pendingOutput.removeFirst(drainOffset)
                drainOffset = 0
            }
            DispatchQueue.main.async { [weak self] in self?.drainPendingOutput() }
        }
        pendingLock.unlock()
        if !chunk.isEmpty { onData?(chunk) }
    }

    private func startWaiting() {
        let pid = childPID
        waitQueue.async { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)

            let code: Int32
            if (status & 0x7F) == 0 {
                code = (status >> 8) & 0xFF
            } else {
                code = -1
            }
            DispatchQueue.main.async {
                guard let self, !self.released else { return }
                self.onExit?(code)
            }
        }
    }
}
