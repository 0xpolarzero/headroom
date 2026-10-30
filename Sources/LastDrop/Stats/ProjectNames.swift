import Darwin
import Foundation

/// Names the project a working directory belongs to. A worktree counts as its repository, wherever it lives:
/// that's how `sic-worktrees/novelcore` adds up under `sic`. Asks the disk once per directory.
struct ProjectNames {
    static let scratch = "scratch"
    private let home: String
    private var known: [String: String] = [:]

    init(home: String = NSHomeDirectory()) { self.home = home }

    mutating func name(directory: String, repository: String? = nil) -> String {
        if let name = known[directory] { return name }
        var name = gitRoot(directory) ?? repository.flatMap(Self.repositoryName) ?? guess(directory)
        if name.hasPrefix(Self.scratch + "-") { name = Self.scratch }   // Throwaway folders, one per task.
        known[directory] = name
        return name
    }

    /// A path in the project most of `mentions` belong to; nil when none is in a repository.
    func mostMentioned(_ mentions: [String: Int]) -> String? {
        var counts: [String: (path: String, count: Int)] = [:]
        for (path, count) in mentions {
            guard let root = gitRoot(path) else { continue }
            counts[root, default: (path, 0)].count += count
        }
        return counts.values.max { ($0.count, $1.path) < ($1.count, $0.path) }?.path
    }

    /// `git@github.com:amontlabs/sic.git` → `sic`.
    static func repositoryName(_ url: String) -> String? {
        let last = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init)
        guard let last, !last.isEmpty else { return nil }
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    /// Walks up to the nearest `.git`. A folder there is the repository; a file is a worktree that points at it.
    private func gitRoot(_ directory: String) -> String? {
        var path = directory
        while path.count > 1, path != home {
            let dotGit = path + "/.git"
            var info = stat()
            if lstat(dotGit, &info) == 0 {
                if info.st_mode & S_IFMT == S_IFDIR { return Self.last(path) }
                return worktreeOwner(dotGit)
            }
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `gitdir: /repo/.git/worktrees/name` → `repo`.
    private func worktreeOwner(_ dotGit: String) -> String? {
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let range = text.range(of: "/.git/worktrees/"),
              let start = text.range(of: "gitdir: ") else { return nil }
        return Self.last(String(text[start.upperBound..<range.lowerBound]))
    }

    /// For a directory that's gone, as worktrees soon are: known worktree layouts, then its own name.
    private func guess(_ directory: String) -> String {
        if directory.isEmpty { return "Other" }
        if directory.hasPrefix("/private/") || directory.hasPrefix("/tmp") || directory.hasPrefix("/var/") { return Self.scratch }
        if directory.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == home.trimmingCharacters(in: CharacterSet(charactersIn: "/")) { return "Home" }
        if let range = directory.range(of: "/.codex/worktrees/") {
            let parts = directory[range.upperBound...].split(separator: "/")
            if parts.count >= 2 { return String(parts[1]) }
        }
        for marker in ["/.claude/worktrees/", "/.worktrees/"] {
            if let range = directory.range(of: marker) { return Self.last(String(directory[..<range.lowerBound])) }
        }
        if let range = directory.range(of: "-worktrees/") { return Self.last(String(directory[..<range.lowerBound])) }
        return Self.last(directory)
    }

    private static func last(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
