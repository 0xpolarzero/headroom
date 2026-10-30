import Foundation

/// The worktree an agent with `isolation: "worktree"` works in, named as Claude Code names its own: the folder
/// `<repo>/.claude/worktrees/agent-<id>` on the branch `worktree-agent-<id>`. Codex and Antigravity make theirs
/// here; Claude Code makes its own for the Claude-runner providers. Like Claude Code, a run that changed nothing
/// has its worktree removed, and one that changed something keeps it for follow-ups and Open in Terminal.
enum AgentWorktree {
    struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Creates the worktree from `directory`'s repository at its current HEAD. `directory` of the result is where
    /// to run: the same subfolder of the worktree that the call was made from, as Claude Code does.
    static func create(in directory: String, agentID: String) throws -> (path: String, branch: String, directory: String) {
        let top = git(["-C", directory, "rev-parse", "--show-toplevel"])
        guard top.status == 0, !top.output.isEmpty else { throw Failure("Worktree isolation needs a git repository: \(top.output)") }
        let prefix = git(["-C", directory, "rev-parse", "--show-prefix"]).output   // "sub/dir/", or "" at the top
        let name = "agent-" + agentID
        let path = URL(fileURLWithPath: top.output).appendingPathComponent(".claude/worktrees/\(name)").path
        let branch = "worktree-\(name)"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let added = git(["-C", directory, "worktree", "add", "-b", branch, path, "HEAD"])
        guard added.status == 0 else { throw Failure("Couldn't create a worktree: \(String(added.output.suffix(2000)))") }
        let inside = prefix.isEmpty ? path : path + "/" + prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // A folder that is untracked or ignored in the repository has no twin in the worktree.
        return (path, branch, FileManager.default.fileExists(atPath: inside) ? inside : path)
    }

    /// The top of the working tree `directory` is in.
    static func root(of directory: String) -> String? {
        let top = git(["-C", directory, "rev-parse", "--show-toplevel"])
        return top.status == 0 && !top.output.isEmpty ? top.output : nil
    }

    /// No uncommitted changes and no commits on its branch since it was created. When git can't say, it counts as changed.
    static func isUnchanged(_ path: String) -> Bool {
        let status = git(["-C", path, "status", "--porcelain"])
        let branch = git(["-C", path, "symbolic-ref", "--short", "-q", "HEAD"])
        guard status.status == 0, status.output.isEmpty, branch.status == 0, !branch.output.isEmpty else { return false }
        let log = git(["-C", path, "reflog", "show", "--format=%H", branch.output])
        return log.status == 0 && log.output.split(separator: "\n").count == 1
    }

    /// Removes the worktree and its branch, from the repository's common git directory (which is the repository
    /// itself for a bare one). True once the worktree folder is gone.
    @discardableResult
    static func remove(_ path: String) -> Bool {
        let branch = git(["-C", path, "symbolic-ref", "--short", "-q", "HEAD"]).output
        let common = git(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard common.status == 0, !common.output.isEmpty else { return false }
        _ = git(["-C", common.output, "worktree", "remove", "--force", path])
        if !FileManager.default.fileExists(atPath: path), !branch.isEmpty { _ = git(["-C", common.output, "branch", "-D", branch]) }
        return !FileManager.default.fileExists(atPath: path)
    }

    private static func git(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "git was not found") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
