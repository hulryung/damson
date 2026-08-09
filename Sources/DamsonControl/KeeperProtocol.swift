import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Wire format shared by damson (handoff sender / claim client) and damson-keeper.
///
/// Both streams are LOCKSTEP: one newline-framed JSON header, optionally followed by
/// exactly one SCM_RIGHTS message (1 payload byte + 1 fd), then the peer's reply line.
/// Each side always knows which message type comes next, so there is no envelope —
/// every line decodes straight into the expected struct.
///
/// Lines are read ONE BYTE AT A TIME on purpose. A buffered reader could consume the
/// payload byte that carries the next SCM_RIGHTS control message with a plain read(),
/// and ancillary data received without MSG_CONTROL is silently discarded — the fd
/// would be gone. Byte-wise reads are irrelevant at this protocol's message count.

/// The keeper's claim socket for one handoff generation.
public func keeperSocketPath(generation: String) -> String {
    (damsonRuntimeDir() as NSString).appendingPathComponent("keeper-\(generation).sock")
}

/// The fd number the keeper inherits its handoff socket on (posix_spawn dup2).
public let keeperHandoffFD: Int32 = 3

// MARK: - Messages

/// App → keeper, once per surviving session ("hold"), then a final "done".
/// A "hold" line is followed by one fd message; "done" is not.
public struct KeeperHold: Codable {
    public var op: String            // "hold" | "done"
    public var uuid: String?
    public var pid: Int32?
    public var startSec: UInt64?
    public var startUsec: UInt64?
    /// Base64 — bytes the app had read but not yet parsed at handoff time.
    public var tail: String?

    public init(op: String, uuid: String? = nil, pid: Int32? = nil,
                startSec: UInt64? = nil, startUsec: UInt64? = nil, tail: String? = nil) {
        self.op = op
        self.uuid = uuid
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
        self.tail = tail
    }
}

/// Keeper's reply to any request line.
public struct KeeperAck: Codable {
    public var ok: Bool
    public var error: String?
    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }
}

/// Claim client → keeper, first line after connecting.
public struct KeeperClaimHello: Codable {
    public var op: String            // "hello"
    public var generation: String
    public init(generation: String) {
        self.op = "hello"
        self.generation = generation
    }
}

/// Keeper → client: what it is holding.
public struct KeeperInventory: Codable {
    public struct Entry: Codable {
        public var uuid: String
        public var alive: Bool
        public var buffered: Int
        public init(uuid: String, alive: Bool, buffered: Int) {
            self.uuid = uuid
            self.alive = alive
            self.buffered = buffered
        }
    }
    public var ok: Bool
    public var error: String?
    public var sessions: [Entry]
    public init(ok: Bool, error: String? = nil, sessions: [Entry] = []) {
        self.ok = ok
        self.error = error
        self.sessions = sessions
    }
}

/// Claim client → keeper: "claim" one uuid, "ack" fd receipt, or "end" the claim
/// session (keeper closes whatever remains → children get SIGHUP).
public struct KeeperClaimRequest: Codable {
    public var op: String            // "claim" | "ack" | "end"
    public var uuid: String?
    public init(op: String, uuid: String? = nil) {
        self.op = op
        self.uuid = uuid
    }
}

/// Keeper → client, before the fd message: the session being granted.
public struct KeeperClaimGrant: Codable {
    public var ok: Bool
    public var error: String?
    public var pid: Int32?
    public var startSec: UInt64?
    public var startUsec: UInt64?
    /// Base64 — handoff tail + everything buffered while the app was down.
    public var buffer: String?
    public init(ok: Bool, error: String? = nil, pid: Int32? = nil,
                startSec: UInt64? = nil, startUsec: UInt64? = nil, buffer: String? = nil) {
        self.ok = ok
        self.error = error
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
        self.buffer = buffer
    }
}

// MARK: - Line IO

/// Read one newline-terminated line, byte by byte (see header comment). nil on EOF
/// before any byte, on error, or past `max` bytes.
public func keeperReadLine(fd: Int32, max: Int = 16 * 1024 * 1024) -> Data? {
    var out = Data()
    var byte: UInt8 = 0
    while out.count < max {
        let n = read(fd, &byte, 1)
        if n == 1 {
            if byte == 0x0A { return out }
            out.append(byte)
        } else if n == 0 {
            return out.isEmpty ? nil : out
        } else {
            if errno == EINTR { continue }
            return nil
        }
    }
    return nil
}

/// Write one JSON line (appends the newline). Returns false on any short write/error.
public func keeperWriteLine<T: Encodable>(fd: Int32, _ message: T) -> Bool {
    guard var data = try? JSONEncoder().encode(message) else { return false }
    data.append(0x0A)
    return data.withUnsafeBytes { buf -> Bool in
        guard let base = buf.baseAddress else { return false }
        var remaining = buf.count
        var ptr = base
        while remaining > 0 {
            let n = write(fd, ptr, remaining)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            remaining -= n
            ptr = ptr.advanced(by: n)
        }
        return true
    }
}

/// Decode a line produced by `keeperReadLine`.
public func keeperDecode<T: Decodable>(_ type: T.Type, _ line: Data) -> T? {
    try? JSONDecoder().decode(type, from: line)
}
