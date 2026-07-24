import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import DamsonControl

/// Framing guard for `readFramedLine`. The prior fixed 64 KB stack buffer silently
/// truncated any response longer than that (a `dump-grid` of a large window — CJK cells
/// are 3 bytes each in UTF-8 — easily exceeds it), turning a valid reply into a decode
/// failure. These tests drive the reader over a real socketpair.
final class SocketIOTests: XCTestCase {
    /// Make a connected AF_UNIX stream pair. Returns (readEnd, writeEnd).
    private func makePair() -> (Int32, Int32)? {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        // The writer thread may keep writing after the reader end closes (the hard-cap
        // test), which would raise SIGPIPE and kill the test process — map it to EPIPE.
        disableSIGPIPE(fds[0])
        disableSIGPIPE(fds[1])
        return (fds[0], fds[1])
    }

    /// Write `bytes` on `fd` from a background thread (so a payload larger than the socket
    /// send buffer can't deadlock the single-threaded test), then close the fd.
    private func writeAndClose(_ bytes: [UInt8], to fd: Int32) {
        DispatchQueue.global().async {
            var sent = 0
            bytes.withUnsafeBufferPointer { buf in
                while sent < buf.count {
                    let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                    if n <= 0 {
                        if n < 0 && errno == EINTR { continue }
                        break
                    }
                    sent += n
                }
            }
            close(fd)
        }
    }

    func testReadsLineLargerThan64KB() throws {
        guard let (r, w) = makePair() else { return XCTFail("socketpair failed") }
        defer { close(r) }
        // 200 KB payload — well past the old fixed 64 KB buffer — plus the newline frame.
        let payload = [UInt8](repeating: UInt8(ascii: "a"), count: 200_000)
        writeAndClose(payload + [0x0A], to: w)

        switch readFramedLine(fd: r) {
        case .line(let data):
            XCTAssertEqual(data.count, payload.count, "full payload must be returned, not truncated")
            XCTAssertEqual(Array(data), payload)
        default:
            XCTFail("expected .line for a newline-terminated payload")
        }
    }

    func testReturnsLineUpToFirstNewline() throws {
        guard let (r, w) = makePair() else { return XCTFail("socketpair failed") }
        defer { close(r) }
        writeAndClose(Array("hello\nworld\n".utf8), to: w)

        switch readFramedLine(fd: r) {
        case .line(let data):
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
        default:
            XCTFail("expected .line")
        }
    }

    func testEOFBeforeNewlineReturnsPartial() throws {
        guard let (r, w) = makePair() else { return XCTFail("socketpair failed") }
        defer { close(r) }
        writeAndClose(Array("partial".utf8), to: w)   // no trailing newline, then close

        switch readFramedLine(fd: r) {
        case .eof(let data):
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "partial")
        case .line:
            XCTFail("no newline was sent — expected .eof, not .line")
        default:
            XCTFail("expected .eof with the partial bytes")
        }
    }

    func testHardCapRefusesUnterminatedFlood() throws {
        guard let (r, w) = makePair() else { return XCTFail("socketpair failed") }
        defer { close(r) }
        // 300 KB with no newline, against a 128 KB cap → .tooLong (bounded memory).
        writeAndClose([UInt8](repeating: UInt8(ascii: "x"), count: 300_000), to: w)

        switch readFramedLine(fd: r, hardCap: 128 * 1024) {
        case .tooLong:
            break   // expected
        default:
            XCTFail("an unterminated over-cap stream must be refused as .tooLong")
        }
    }
}
