import Foundation

/// Keeps the Code tab's session presets the same in every account's copy of the Claude app.
///
/// Each copy keeps them in `ccd-session-presets.json`, under `byAccount.<account UUID>.presets`. A preset
/// is a folder, a model, an effort and a worktree switch; nothing in it belongs to an account. Headroom
/// writes only to copies that are not running, since a running copy keeps the list in memory and would
/// write its own version back.
enum SessionPresets {
    typealias Preset = [String: Any]

    struct Source {
        var accountID: String
        var modified: Date
        var presets: [Preset]
    }

    static func url(_ account: ClaudeAccount) -> URL {
        URL(fileURLWithPath: account.appDataDir + "/ccd-session-presets.json")
    }

    /// Every preset from every source. When copies disagree on a preset, the most recently written file
    /// wins (that covers renames and edits). Presets in `deleted` are dropped. The order is the newest
    /// file's, then the others' additions.
    static func merge(_ sources: [Source], deleted: Set<String>) -> [Preset] {
        var result: [Preset] = []
        var seen = Set<String>()
        for source in sources.sorted(by: { $0.modified > $1.modified }) {
            for preset in source.presets {
                guard let id = preset["id"] as? String, !deleted.contains(id), seen.insert(id).inserted else { continue }
                result.append(preset)
            }
        }
        return result
    }

    /// IDs that were in an account's file at the last sync and are gone now: deleted in that copy.
    /// `trusted` limits this to copies whose window has seen the file: a window started before Headroom
    /// last wrote its file still holds its older list and may save it back, which is not a deletion.
    static func deletions(_ sources: [Source], known: [String: [String]], trusted: Set<String>? = nil) -> Set<String> {
        var deleted = Set<String>()
        for source in sources where trusted?.contains(source.accountID) ?? true {
            let now = Set(source.presets.compactMap { $0["id"] as? String })
            deleted.formUnion(Set(known[source.accountID] ?? []).subtracting(now))
        }
        return deleted
    }

    /// What Headroom remembers between passes: each account's preset IDs at the last sync, and when it
    /// last wrote each account's file.
    struct State: Codable {
        var known: [String: [String]] = [:]
        var writtenAt: [String: Date] = [:]
    }

    /// One pass over every account whose copy is signed in. Safe to call often: a file is only
    /// written when its list differs. `launchDate` is nil for a copy that isn't running.
    static func sync(_ accounts: [ClaudeAccount], launchDate: (ClaudeAccount) -> Date?) {
        func isRunning(_ account: ClaudeAccount) -> Bool { launchDate(account) != nil }
        struct Loaded { var account: ClaudeAccount; var uuid: String; var root: [String: Any]; var source: Source }
        var loaded: [Loaded] = []
        var missing: [(ClaudeAccount, String)] = []   // signed in, no presets file yet
        for account in accounts {
            guard let uuid = ClaudeApps.appAccountUUID(account) else { continue }
            let file = url(account)
            guard let data = try? Data(contentsOf: file) else { missing.append((account, uuid)); continue }
            // An unexpected shape means the app changed its format: leave the file alone.
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  root["byAccount"] is [String: Any] else { continue }
            let entry = root.dict("byAccount")?.dict(uuid)
            let presets = entry?["presets"] as? [Preset] ?? []
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            loaded.append(Loaded(account: account, uuid: uuid, root: root,
                                 source: Source(accountID: account.id, modified: modified, presets: presets)))
        }
        guard !loaded.isEmpty else { return }

        var state = loadState()
        let trusted = Set(loaded.filter { item in
            guard let launched = launchDate(item.account), let written = state.writtenAt[item.account.id] else { return true }
            return launched > written
        }.map(\.account.id))
        let deleted = deletions(loaded.map(\.source), known: state.known, trusted: trusted)
        let merged = merge(loaded.map(\.source), deleted: deleted)
        let mergedIDs = merged.compactMap { $0["id"] as? String }
        // builtIns and seededFromDraft for copies that have no file yet, taken from one that does.
        let template = loaded.first.flatMap { $0.root.dict("byAccount")?.dict($0.uuid) } ?? [:]

        for item in loaded {
            let current = item.source.presets
            guard !isRunning(item.account) else {
                if trusted.contains(item.account.id) { state.known[item.account.id] = current.compactMap { $0["id"] as? String } }
                continue
            }
            if !NSDictionary(dictionary: ["p": current]).isEqual(to: ["p": merged]) {
                var root = item.root
                var byAccount = root.dict("byAccount") ?? [:]
                var entry = byAccount.dict(item.uuid) ?? template
                entry["presets"] = merged
                byAccount[item.uuid] = entry
                root["byAccount"] = byAccount
                write(root, to: url(item.account))
                state.writtenAt[item.account.id] = Date()
            }
            state.known[item.account.id] = mergedIDs
        }
        for (account, uuid) in missing where !isRunning(account) && !merged.isEmpty {
            var entry = template
            entry["presets"] = merged
            write(["byAccount": [uuid: entry]], to: url(account))
            state.writtenAt[account.id] = Date()
            state.known[account.id] = mergedIDs
        }
        saveState(state)
    }

    private static func write(_ root: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadState() -> State {
        guard let data = try? Data(contentsOf: HeadroomPaths.presetSync) else { return State() }
        if let state = try? JSONDecoder.headroom.decode(State.self, from: data) { return state }
        // The first version kept only the IDs.
        return State(known: (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:])
    }

    private static func saveState(_ state: State) {
        HeadroomPaths.ensure(HeadroomPaths.support)
        try? JSONEncoder.headroom.encode(state).write(to: HeadroomPaths.presetSync, options: .atomic)
    }
}
