import Foundation
import Darwin

// MARK: - The terminal of a hook's sender
//
// A session's tab in Terminal.app or iTerm2 is told apart by the tty of its shell. The installed
// `luna-hook` does not send it, and is not changed for that: Luna asks the system itself. The
// socket of a hook connection knows the pid of its peer (`LOCAL_PEERPID`); the process table
// knows the parent and the controlling terminal of every process. The hook is a child of the
// agent, which is a child of the shell on the tty, so the first process up the chain that has a
// terminal gives the tab.
//
// A fire-and-forget hook exits right after it has written its event, and then neither its pid nor
// its process is there to ask about; one that waits for an answer (a permission request, a
// question) is always there. So the tty of a session is learned from the first event that finds
// its hook alive — in practice within a few tool calls — and kept (`AgentSessionBook`).
//
// The walk takes its table as a closure, so the logic is tested with a fake one
// (`scripts/test-agent-jump.sh`); the real table is `sysctl(KERN_PROC_PID)`.

enum ProcessTTY {

    struct Entry: Equatable {
        let parent: Int32
        /// The controlling terminal's device number, nil when the process has none.
        let terminal: Int32?
    }

    /// How far up the chain the walk goes: hook → agent → (wrappers) → shell is a handful.
    static let maxDepth = 16

    /// The tty (`/dev/ttys003`) of the nearest process, from `pid` up, that has a terminal.
    /// `name` turns a device number into `ttys003`. Nil when none has one (a hook started
    /// from a GUI, a daemon) or the name is not a pty slave.
    static func tty(from pid: Int32,
                    entry: (Int32) -> Entry? = ProcessTTY.systemEntry,
                    name: (Int32) -> String? = ProcessTTY.deviceName) -> String? {
        var current = pid
        var seen = Set<Int32>()
        for _ in 0..<maxDepth {
            guard current > 1, seen.insert(current).inserted, let e = entry(current) else { return nil }
            if let dev = e.terminal, let device = name(dev),
               let tty = AgentJumpPlan.validTTY("/dev/" + device) {
                return tty
            }
            current = e.parent
        }
        return nil
    }

    // MARK: System

    /// The pid of the process on the other end of a connected unix socket.
    static func peerPID(of fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 1 else { return nil }
        return pid
    }

    /// Parent and controlling terminal of one process, from the process table.
    static func systemEntry(_ pid: Int32) -> Entry? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let dev = Int32(bitPattern: UInt32(truncatingIfNeeded: info.kp_eproc.e_tdev))
        return Entry(parent: info.kp_eproc.e_ppid, terminal: dev == -1 ? nil : dev)
    }

    /// `ttys003` for a terminal device number; nil when it has no name.
    static func deviceName(_ dev: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard devname_r(dev_t(dev), S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return nil }
        let name = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.hasPrefix("ttys") ? name : nil
    }
}
