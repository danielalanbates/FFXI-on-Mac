// Copyright (c) 2026 Bates LLC. All rights reserved.

import Foundation

/// Setup's progress on the main button. Daniel, live on the b60 preview (2026-10-15): "it's been
/// stuck on setting up 0%". Measured: aria2c was fetching at ~5 MB/s while the button sat at
/// "Setting up… 0%" for minutes, because update-client.sh ran it with --summary-interval=60 (its
/// "(N%)" readout is the only figure the button read), the 9.4 GB unzip said nothing at all, and
/// the steps before the torrent (Wine, the Windows drive) reported nothing either.
///
/// Now each step names itself on the button ("Downloading HorizonXI… 37%", "Unpacking
/// HorizonXI… 60%"), and the figure is the whole chain's (`SetupMeter`): it only ever goes up, and
/// never drops back to 0% when one step ends and the next begins. The scripts report every 2 s
/// (aria2c --summary-interval=2, update-client.sh's "==> unpacking N%").

/// What the button names while Setup works. Short: the button is one line, in capitals.
enum SetupStage: String, CaseIterable {
    case rosetta = "Installing Rosetta"
    case downloadingWine = "Downloading Wine"
    case buildingWine = "Building Wine"
    case gameWine = "Installing game Wine"
    case movingFiles = "Moving game files"
    case copyingFiles = "Copying game files"
    case downloadingGame = "Downloading HorizonXI"
    case unpackingGame = "Unpacking HorizonXI"
    case updatingGame = "Updating HorizonXI"
    case finishing = "Finishing"
    case buildingServer = "Building the server"

    /// The setup sheet's step (Bootstrap), as the button names it.
    init(_ s: Bootstrap.Step) {
        switch s {
        case .rosetta: self = .rosetta
        case .download: self = .downloadingWine
        case .assemble, .prefix: self = .buildingWine
        }
    }
}

/// Reads a setup script's output (update-client.sh, game-wine.sh): the stage it is at and how far
/// the whole job is, 0...1, never going back.
struct ScriptProgress {
    enum Job { case horizonInstall, horizonUpdate, gameWine }

    let job: Job
    private(set) var fraction = 0.0
    private(set) var stage: SetupStage
    /// "2.0.4 · 1 of 2" while updates apply.
    private(set) var label = ""
    /// A fresh install's base (its download and its unzip) fills the first 85% of the job, its
    /// updates the rest; an update alone fills all of it.
    private var phase = (start: 0.0, span: 1.0)
    private var step = (n: 1, total: 1)
    /// Of each step, the download's share; the unzip is the rest. The base zip unpacks to 15.5 GB,
    /// which takes a while on a spinning drive; an update's unzip is quick.
    private var downloadShare: Double
    private var inBase: Bool
    private var partial = ""

    init(_ job: Job) {
        self.job = job
        switch job {
        case .horizonInstall:
            stage = .downloadingGame; phase = (0, 0.85); downloadShare = 0.7; inBase = true
        case .horizonUpdate:
            stage = .updatingGame; downloadShare = 0.9; inBase = false
        case .gameWine:
            stage = .gameWine; downloadShare = 0.9; inBase = false
        }
    }

    /// A chunk of output as it arrives: whole lines are read, a part line waits for its end.
    mutating func read(_ chunk: String) {
        let text = partial + chunk
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        partial = lines.removeLast()
        // aria2's readout rewrites one line with \r on a terminal; each part is a reading.
        for l in lines { for part in l.split(separator: "\r") { line(String(part)) } }
    }

    private static let updateLine = try! NSRegularExpression(pattern: #"==> update (\S+) \((\d+)/(\d+)\)"#)
    private static let unpacking = try! NSRegularExpression(pattern: #"==> unpacking (\d{1,3})%"#)
    private static let readout = try! NSRegularExpression(pattern: #"\((\d{1,3})%\)"#)

    private static func groups(_ re: NSRegularExpression, _ l: String) -> [String]? {
        guard let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) else { return nil }
        return (1..<m.numberOfRanges).map { k in Range(m.range(at: k), in: l).map { String(l[$0]) } ?? "" }
    }

    mutating func line(_ l: String) {
        if job == .horizonInstall, inBase,
           l.contains("==> base client in place") || l.contains("==> already has a client") {
            inBase = false
            phase = (0.85, 0.15); step = (1, 1); downloadShare = 0.9
            stage = .updatingGame
            set(0)
        } else if let g = Self.groups(Self.updateLine, l), let n = Int(g[1]), let t = Int(g[2]) {
            step = (n, max(t, 1))
            label = "\(g[0]) · \(n) of \(t)"
            stage = .updatingGame
            set(0)
        } else if let g = Self.groups(Self.unpacking, l), let pct = Double(g[0]) {
            set(downloadShare + (1 - downloadShare) * pct / 100)
        } else if let g = Self.groups(Self.readout, l), let pct = Double(g[0]) {
            set(downloadShare * pct / 100)
        } else if l.contains("==> extracting") {
            if inBase { stage = .unpackingGame }
            set(downloadShare)
        } else if l.contains("==> fetching"), inBase {
            stage = .downloadingGame
        }
    }

    /// `inStep` (0...1) of the current step, as a fraction of the whole job; never lower than before.
    private mutating func set(_ inStep: Double) {
        let s = min(max(inStep, 0), 1)
        let v = phase.start + phase.span * (Double(step.n - 1) + s) / Double(step.total)
        fraction = max(fraction, min(v, 1))
    }

    /// The chunk without the readouts the button shows instead: aria2's summary blocks and the
    /// unzip's percentages (launcher.log keeps the "==> extracting" line itself).
    static func loggable(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[#") || t.hasPrefix("***") || t.hasPrefix("====") || t.hasPrefix("FILE:") || t.hasPrefix("----") {
                    return false
                }
                return groups(unpacking, t) == nil
            }
            .joined(separator: "\n")
    }
}

/// Setup's whole chain as one figure for the button: each step it will take has a weight (about
/// how long it takes), and the figure is how much of the planned weight is done. It never goes
/// down: a step that ends does not drop it back to 0%, a step that turns out not to be needed
/// makes it jump ahead, and one that was not planned leaves it where it is until the next.
struct SetupMeter {
    /// In the order Setup takes them (ContentView.runSetup).
    enum Step: Int, CaseIterable, Comparable {
        case rosetta, wine, files, gameWine, game, configure, localServer
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    /// Rough minutes on a typical connection and disk: the 250 MB Wine download and its build; a
    /// local copy of a 15 GB client; the game's 200 MB Wine; HorizonXI's 9.4 GB torrent, its unzip
    /// and updates; the local server's build.
    static func weight(_ s: Step) -> Double {
        switch s {
        case .rosetta: return 2
        case .wine: return 8
        case .files: return 12
        case .gameWine: return 5
        case .game: return 70
        case .configure: return 2
        case .localServer: return 30
        }
    }

    private(set) var planned: Set<Step>
    private(set) var current: Step?
    private var shown = 0.0

    init(planned: Set<Step> = []) { self.planned = planned }

    /// What a press of Setup will do, from the state it starts in. A step the chain finds it does
    /// not need is skipped (the figure jumps); the location chooser can add or drop some.
    static func plan(_ x: PrimaryInputs) -> Set<Step> {
        var s: Set<Step> = []
        let bad = Set(x.checks.filter { $0.state == .bad }.map(\.id))
        let driveGone = x.rememberedDrive != nil || x.checks.contains { $0.state == .bad && $0.drive != nil }
        if x.hasInstall, x.rosettaMissing { s.insert(.rosetta) }
        if !x.hasInstall || driveGone || bad.contains("wine") { s.insert(.wine) }
        if x.patchedWineMissing { s.insert(.gameWine) }
        if !x.hasInstall || driveGone || !x.hasGame || !bad.isDisjoint(with: Primary.gameFiles) {
            s.insert(.game); s.insert(.configure)
        }
        if bad.contains("rpath") { s.insert(.configure) }
        if x.isLocal, x.localReady == false { s.insert(.localServer) }
        return s
    }

    mutating func plan(_ s: Step) { planned.insert(s) }
    mutating func drop(_ s: Step) { if s != current { planned.remove(s) } }
    mutating func begin(_ s: Step) { current = s }

    private var total: Double { planned.reduce(0) { $0 + Self.weight($1) } }

    /// How far the chain is (0...0.99; it says 100% only by ending), given how far the current
    /// step is (0...1), and never less than it said before.
    mutating func overall(_ live: Double) -> Double {
        let t = total
        guard t > 0, let c = current else { return shown }
        let before = planned.filter { $0 < c }.reduce(0) { $0 + Self.weight($1) }
        let w = planned.contains(c) ? Self.weight(c) : 0
        let v = min(0.99, (before + w * min(max(live, 0), 1)) / t)
        shown = max(shown, v)
        return shown
    }
}
