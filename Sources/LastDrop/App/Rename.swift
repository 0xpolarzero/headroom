import Foundation

/// lastdrop was called Headroom. On the first launch under the new name it takes over the old one's data, so nothing
/// has to be set up again: settings, its support and log folders, its keychain items, and its Claude Code plugin.
enum Rename {
    static let oldName = "Headroom"
    static let oldDefaults = "dev.polarzero.headroom"
    static let oldPlugin = "headroom@headroom", oldMarketplace = "headroom"

    /// Before anything reads its settings or files. Each step runs once: it only acts while the new place is empty.
    static func migrate() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        move(support.appendingPathComponent(oldName), to: LastDropPaths.support)
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        move(logs.appendingPathComponent(oldName), to: logs.appendingPathComponent("lastdrop"))
        if let id = Bundle.main.bundleIdentifier, id != oldDefaults,
           (UserDefaults.standard.persistentDomain(forName: id) ?? [:]).isEmpty,
           let old = UserDefaults.standard.persistentDomain(forName: oldDefaults), !old.isEmpty {
            UserDefaults.standard.setPersistentDomain(old, forName: id)
        }
    }

    private static func move(_ old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
