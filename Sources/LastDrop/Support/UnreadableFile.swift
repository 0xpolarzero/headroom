import Foundation

/// Files lastdrop keeps its state in and that other versions write too. One that exists but can't be read or
/// decoded is never written over or deleted: it is kept under a unique name first.
enum UnreadableFile {
    /// `<name>.unreadable-<timestamp>`, with a counter when that name is taken, so a second bad file never
    /// replaces an earlier backup.
    static func backupURL(for url: URL, now: Date = Date()) -> URL {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        var candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp)-\(n)")
        }
        return candidate
    }

    /// Moves the file away to its backup name. True only when the file is gone from `url` and the backup exists.
    static func moveAside(_ url: URL, move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) -> Bool {
        let kept = backupURL(for: url)
        do { try move(url, kept) } catch {
            SubagentLog.write("\(url.lastPathComponent) is unreadable and couldn't be moved aside: \(error)")
            return false
        }
        let moved = !FileManager.default.fileExists(atPath: url.path) && FileManager.default.fileExists(atPath: kept.path)
        SubagentLog.write(moved ? "\(url.lastPathComponent) couldn't be read; kept as \(kept.lastPathComponent)"
                                : "\(url.lastPathComponent) is unreadable and the move aside didn't hold")
        return moved
    }

    /// Copies the file to its backup name, for a file that stays in place and is about to be saved over.
    static func copyAside(_ url: URL) throws {
        try FileManager.default.copyItem(at: url, to: backupURL(for: url))
    }
}
