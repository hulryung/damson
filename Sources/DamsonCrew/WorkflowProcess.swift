import Darwin
import Foundation

/// A PID alone is not an identity after its parent exits. Keep the kernel start time
/// so a later coordinator can distinguish a surviving command from PID reuse.
struct WorkflowProcessIdentity: Codable, Equatable {
    var pid: Int32
    var startSeconds: UInt64
    var startMicroseconds: UInt64

    static func capture(_ pid: Int32) -> WorkflowProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return WorkflowProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec,
                                       startMicroseconds: info.pbi_start_tvusec)
    }

    var isAlive: Bool { Self.capture(pid) == self }
}
