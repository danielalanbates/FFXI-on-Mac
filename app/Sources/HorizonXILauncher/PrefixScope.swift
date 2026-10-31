// Copyright (c) 2026 Bates LLC. All rights reserved.
import Foundation
import Darwin

/// Evidence about which Windows drive a running process group actually uses. Login hosts do
/// not identify a prefix: two worlds may share a host, and one world's clients may span drives.
/// Unknown or conflicting evidence always keeps a client in a prefix's safety checks. Only a
/// positively identified different prefix may be excluded before changing registry/renderer
/// state or stopping that prefix's wineserver. Server account/client caps still use the full
/// client list, across every prefix.
enum PrefixScope {
    static func canonical(_ path: String) -> String? {
        guard (path as NSString).isAbsolutePath else { return nil }
        let resolved = OwnWine.resolve(path)
        return resolved == "/" ? nil : resolved
    }

    /// Include this prefix's clients and every unassigned group. Pure: callers can use the same
    /// evidence for several prefix decisions without reading the processes again.
    static func clients(_ clients: [LiveClients.Client], prefix: URL,
                        groupPrefixes: [pid_t: String]) -> [LiveClients.Client] {
        guard let want = canonical(prefix.path) else { return clients }
        return clients.filter { client in
            guard let path = groupPrefixes[client.group], let actual = canonical(path) else { return true }
            return actual == want
        }
    }

    static func clients(in snapshot: LiveClients.Snapshot, prefix: URL,
                        knownGroups: [pid_t: String] = [:],
                        knownPrefixes: [String] = []) -> [LiveClients.Client] {
        let found = prefixes(snapshot, knownGroups: knownGroups,
                             knownPrefixes: knownPrefixes + [prefix.path])
        return clients(snapshot.clients, prefix: prefix, groupPrefixes: found)
    }

    /// One group's members may provide the launcher's recorded prefix, readable WINEPREFIXs,
    /// or mapped wineserver folders. A group names a prefix only when every positive piece of
    /// evidence agrees. Unreadable processes provide no evidence; contradictory processes keep
    /// the entire group unknown. Dictionaries are injectable so tests never scan real clients.
    static func infer(_ snapshot: LiveClients.Snapshot, knownGroups: [pid_t: String] = [:],
                      environmentPrefixes: [pid_t: String] = [:],
                      mappedPrefixes: [pid_t: Set<String>] = [:]) -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        for group in Set(snapshot.clients.map(\.group)) where group > 1 {
            var evidence: Set<String> = []
            if let path = knownGroups[group], let value = canonical(path) { evidence.insert(value) }
            for pid in members(of: group, in: snapshot) {
                if let path = environmentPrefixes[pid], let value = canonical(path) { evidence.insert(value) }
                for path in mappedPrefixes[pid] ?? [] {
                    if let value = canonical(path) { evidence.insert(value) }
                }
            }
            if evidence.count == 1 { result[group] = evidence.first! }
        }
        return result
    }

    /// Read-only, off the main actor. Only WINEPREFIX survives the environment read; account
    /// arguments and all other environment values are discarded by Leftovers.prefixes.
    /// Wine rewrites its clients' environment, so their mapped tmpmap files identify the
    /// server directory when no environment remains. Those directories are derived from actual
    /// prefix device/inode pairs, never from similarly named game folders or login hosts.
    static func prefixes(_ snapshot: LiveClients.Snapshot, knownGroups: [pid_t: String] = [:],
                         knownPrefixes: [String] = []) -> [pid_t: String] {
        let groups = Set(snapshot.clients.map(\.group)).filter { $0 > 1 }
        guard !groups.isEmpty else { return [:] }
        let pids = Set(groups.flatMap { members(of: $0, in: snapshot) }).sorted()
        let identities = Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            Leftovers.procID(pid).map { (pid, $0) }
        })
        let environment = Leftovers.prefixes(of: pids)
        let paths = Set((knownPrefixes + Array(knownGroups.values) + Array(environment.values))
            .compactMap(canonical))
        let folders = paths.compactMap { path in
            Leftovers.serverDir(forPrefix: path).map { (prefix: path, directory: $0) }
        }
        var mappings: [pid_t: Set<String>] = [:]
        if !folders.isEmpty {
            for pid in pids {
                guard identities[pid] != nil else { continue }
                // One region read per process for this decision, even when many world
                // prefixes are candidates. No global mutable attribution cache survives the
                // pass: startup mappings can change and refresh/Play run on different threads.
                guard let mapped = Leftovers.mappedFolders(of: pid) else { continue }
                mappings[pid] = Set(folders.filter { folder in
                    mapped.contains { Leftovers.isUnder($0, dir: folder.directory) }
                }.map(\.prefix))
            }
        }
        var found = infer(snapshot, knownGroups: knownGroups,
                          environmentPrefixes: environment, mappedPrefixes: mappings)
        // A PID can exit or be reused while the environment/regions are read. Never turn that
        // stale observation into permission to mutate a prefix underneath an uncertain group.
        for group in groups {
            let stable = members(of: group, in: snapshot).allSatisfy { pid in
                guard let before = identities[pid], let after = Leftovers.procID(pid) else { return false }
                return before == after && getpgid(pid) == group
            }
            if !stable { found.removeValue(forKey: group) }
        }
        return found
    }

    private static func members(of group: pid_t, in snapshot: LiveClients.Snapshot) -> [pid_t] {
        let clients = snapshot.clients.filter { $0.group == group }.map(\.pid)
        let others = snapshot.members(ofGroup: group).filter {
            snapshot.wine.contains($0) || snapshot.sidecars.contains($0)
        }
        return Set(clients + others).sorted()
    }
}
