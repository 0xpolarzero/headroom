import Darwin
import Foundation

/// Finds which process opened a connection to the relay, from the connection's source port.
///
/// The relay only decrypts traffic of Claude Code processes started after the relay's CA was put in
/// `settings.json`. Older ones picked up `HTTPS_PROXY` live but never loaded the CA, and would fail
/// TLS, so they get a plain tunnel.
struct ClientProcess: Sendable {
    var pid: pid_t
    var path: String
    var startedAt: Date

    /// Claude Code's binary: the Claude app's bundled `…/claude.app/Contents/MacOS/claude`, or the native
    /// terminal install, whose `~/.local/bin/claude` symlink resolves to `~/.local/share/claude/versions/<v>`
    /// (so the process is named after the version). An npm install runs as `node` and isn't recognised.
    static func isClaudeCode(path: String) -> Bool {
        (path as NSString).lastPathComponent == "claude" || path.contains("/claude/versions/")
    }

    var isClaudeCode: Bool { Self.isClaudeCode(path: path) }

    /// The Claude Code process whose TCP socket has local port `clientPort` and remote port `relayPort`.
    /// Only Claude Code processes are searched: anything else is tunnelled whoever it is.
    static func claudeCode(clientPort: UInt16, relayPort: UInt16) -> ClientProcess? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let me = getpid()
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 && pid != me {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, isClaudeCode(path: String(cString: buffer)) else { continue }
            if hasSocket(pid: pid, localPort: clientPort, remotePort: relayPort), let info = describe(pid) { return info }
        }
        return nil
    }

    static func describe(_ pid: pid_t) -> ClientProcess? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = n > 0 ? String(cString: buffer) : ""
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
        return ClientProcess(pid: pid, path: path, startedAt: started)
    }

    private static func hasSocket(pid: pid_t, localPort: UInt16, remotePort: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let n = Int(size) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: n + 16)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard used > 0 else { return false }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, Int32(MemoryLayout<socket_fdinfo>.size))
                    == Int32(MemoryLayout<socket_fdinfo>.size),
                  socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ini = socket.psi.soi_proto.pri_tcp.tcpsi_ini
            // Ports are stored in network byte order in an Int32.
            if UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)) == localPort,
               UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)) == remotePort { return true }
        }
        return false
    }
}
