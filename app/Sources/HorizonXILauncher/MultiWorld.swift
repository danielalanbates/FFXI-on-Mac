import Foundation
import Combine

/// Game clients running on this Mac, keyed by the login host their loader was given.
///
/// HorizonXI and the local world both run `horizon-loader.exe` out of the same folder, so a
/// process name says nothing about which world it is. The loader's `--server <host>` argument
/// does. See docs/MULTI_WORLD.md.
enum LiveClients {
    static let loaderNames = ["horizon-loader.exe", "xiloader.exe", "gxiloader.exe",
                              "catseye-loader.exe", "pol.exe"]
    private static let pattern = #"horizon-loader\.exe|xiloader\.exe|catseye-loader\.exe|pol\.exe|ffxi-bootmod"#

    /// `127.0.0.1` and `localhost` are the same world; hosts are case-insensitive.
    static func normalize(_ host: String) -> String {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h == "localhost" ? "127.0.0.1" : h
    }

    /// `pgrep -fl` output -> `[host: [pid]]`. A client whose command line names no `--server`
    /// is filed under "": it still holds the prefix, it just cannot be matched to a world.
    ///
    /// The x87 sidecar wraps the loader (`x87sidecar-coop --cooperative …/wine …loader.exe`),
    /// so one client is usually two pids under one host. A line counts only when the loader is
    /// the command itself or follows a wine/sidecar executable, which keeps a shell or grep that
    /// merely mentions the name out of it.
    static func parse(_ text: String) -> [String: [pid_t]] {
        var out: [String: [pid_t]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let sp = line.firstIndex(of: " "), let pid = pid_t(line[..<sp]) else { continue }
            let tokens = line[line.index(after: sp)...].split(separator: " ").map(String.init)
            guard let at = tokens.firstIndex(where: isLoader),
                  at == 0 || tokens[..<at].contains(where: isLauncherOfLoader) else { continue }
            var host = ""
            for (n, t) in tokens.enumerated() {
                if t == "--server", n + 1 < tokens.count { host = tokens[n + 1]; break }
                if t.hasPrefix("--server=") { host = String(t.dropFirst("--server=".count)); break }
            }
            out[normalize(host), default: []].append(pid)
        }
        return out.mapValues { $0.sorted() }
    }

    private static func basename(_ t: String) -> String {
        t.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { String($0).lowercased() } ?? ""
    }

    private static func isLoader(_ t: String) -> Bool {
        loaderNames.contains(basename(t)) || t.lowercased().contains("ffxi-bootmod")
    }

    private static func isLauncherOfLoader(_ t: String) -> Bool {
        let b = basename(t)
        return b.hasPrefix("wine") || b.contains("preloader") || b.contains("x87sidecar")
    }

    static func scan() -> [String: [pid_t]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-fil", pattern]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }
}

/// The rules for running several worlds side by side in one prefix.
enum MultiWorld {
    /// Why launching `world` now must be refused, or nil. Only a duplicate of a world that does
    /// not allow several clients is refused; different worlds always may run together.
    static func refusal(world: String, host: String, allowsMultipleClients: Bool,
                        live: [String: [pid_t]]) -> String? {
        let key = LiveClients.normalize(host)
        guard !allowsMultipleClients, !key.isEmpty, let pid = live[key]?.first else { return nil }
        return "\(world) is already running (pid \(pid)). \(world) does not allow a second client "
             + "from the same player, so another copy is refused. Stop the running one first."
    }

    /// Default DXVK frame-rate log, one per world so two clients never write the same file.
    static func fpsLogPath(gameDirName: String, world: String) -> String {
        let slug = world.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "C:\\" + gameDirName + "\\" + (slug.isEmpty ? "fps.csv" : "fps-\(slug).csv")
    }

    /// 8 GB Mac: two clients plus LSB took HorizonXI to 0.4 fps on 2026-09-25/26. A warning,
    /// never a block.
    static func memoryWarning(swapUsedFraction: Double, freePercent: Int) -> String? {
        guard swapUsedFraction > 0.6 || freePercent < 20 else { return nil }
        return "Memory is short (swap \(Int((swapUsedFraction * 100).rounded()))% used, "
             + "\(freePercent)% free). A second client on this Mac may run at a few fps or slow "
             + "down the one already playing. Starting anyway."
    }

    /// Swap used as a fraction of swap in use, and the kernel's free-memory percentage (what
    /// `memory_pressure` prints as "System-wide memory free percentage").
    static func memorySnapshot() -> (swapUsedFraction: Double, freePercent: Int) {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapFraction = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 && swap.xsu_total > 0
            ? Double(swap.xsu_used) / Double(swap.xsu_total) : 0
        var level: Int32 = 100
        var lsize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &lsize, nil, 0) != 0 { level = 100 }
        return (swapFraction, Int(level))
    }

    static func currentMemoryWarning() -> String? {
        let m = memorySnapshot()
        return memoryWarning(swapUsedFraction: m.swapUsedFraction, freePercent: m.freePercent)
    }
}

/// One `Runner` per world session. The selected world's session drives Play, Stop and the log
/// pane; `live` feeds the Running list.
@MainActor
final class Sessions: ObservableObject {
    /// Not @Published: `runner(for:)` creates sessions while a view body reads it, and a new
    /// session is idle, so nothing on screen changes. Runner changes are forwarded below.
    private(set) var ids: [String] = []
    private var runners: [String: Runner] = [:]
    private var worldOf: [String: String] = [:]
    /// Which session a world's Play/Stop/log currently mean: the newest one started for it.
    private var current: [String: String] = [:]
    private var forwards: [String: AnyCancellable] = [:]

    func runner(for world: String) -> Runner {
        if let id = current[world], let r = runners[id] { return r }
        return make(id: world, world: world)
    }

    /// A further session for a world that allows several clients. Idle extras are reused.
    func newSession(for world: String) -> Runner {
        if let id = ids.first(where: { worldOf[$0] == world && runners[$0]?.running == false
                                       && runners[$0]?.busy == false }),
           let r = runners[id] {
            current[world] = id
            return r
        }
        var n = 2
        while runners["\(world) #\(n)"] != nil { n += 1 }
        return make(id: "\(world) #\(n)", world: world)
    }

    var live: [(id: String, world: String, runner: Runner)] {
        ids.compactMap { id in
            guard let r = runners[id], r.running, let w = worldOf[id] else { return nil }
            return (id, w, r)
        }
    }

    var anyBusy: Bool { runners.values.contains { $0.busy } }

    private func make(id: String, world: String) -> Runner {
        let r = Runner(session: id)
        runners[id] = r
        worldOf[id] = world
        current[world] = id
        ids.append(id)
        forwards[id] = r.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return r
    }
}
