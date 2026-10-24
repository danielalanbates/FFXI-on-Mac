import Foundation

/// One AscensionXI install or Play-time update, run off the main actor: their launcher's
/// `Core.Run` without the window (see AscensionChannel for what each step is and why).
///
/// Every file it keeps or writes has matched the SHA-256 the channel gives for it. Nothing outside
/// `root` is written; `donors` (other worlds' game folders) are only read.
final class AscensionSync: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }

    enum Outcome: Equatable {
        /// Everything matches the channel. `changed`: files written this run.
        case ok(changed: Int)
        /// No mirror answered, and the last update ran to the end: its client is still all there.
        case offline(String)
        /// Stop was pressed. Nothing is started after it.
        case stopped
        case failed(String)
    }

    let root: URL
    /// `root/Ashita/polplugins/DATs` as Wine names it, for pivot.ini's `root_path`.
    let datsWine: String
    private let log: (String) -> Void
    private let progress: (String, Double) -> Void
    private let stop: StopFlag
    private let session: URLSession
    /// Where the channel is (`AscensionChannel.mirrors`; a local one under --selftest-ascension).
    private let mirrors: [String]
    /// The mirrors that answered `/manifest.json`, the one in use first.
    private var live: [String] = []
    private var channel: String { live.first ?? mirrors[0] }
    private let hashes: HashCache
    private var changed = 0
    private let fm = FileManager.default
    private var ashita: URL { root.appendingPathComponent("Ashita") }
    private var stateDir: URL { root.appendingPathComponent(".ffxi-on-mac") }
    private var baseCopy: URL { root.appendingPathComponent(".base-manifest.json") }

    init(root: URL, datsWine: String, stop: StopFlag = StopFlag(), mirrors: [String] = AscensionChannel.mirrors,
         log: @escaping (String) -> Void, progress: @escaping (String, Double) -> Void = { _, _ in }) {
        self.root = root; self.datsWine = datsWine; self.stop = stop; self.log = log; self.progress = progress
        self.mirrors = mirrors; live = mirrors
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 6 * 3600
        c.httpMaximumConnectionsPerHost = 8
        c.httpAdditionalHeaders = ["User-Agent": "FFXI-on-Mac (AscensionXI channel client)"]
        session = URLSession(configuration: c)
        hashes = HashCache(url: root.appendingPathComponent(".ffxi-on-mac/hashes.json"))
    }

    // MARK: - The whole run

    /// `install`: the base client is checked file by file (the first run, or Repair) rather than
    /// against the last copy of its manifest. `donors`: folders holding `FINAL FANTASY XI` and
    /// `PlayOnlineViewer` whose identical files are copied instead of downloaded.
    func run(install: Bool = false, donors: [URL] = []) -> Outcome {
        defer { hashes.save() }
        // Setup and Repair hash every file again, as their Repair does: a file corrupted in place
        // with its size and date unchanged would pass the cache (b71 review).
        hashes.trustStamps = !install
        var outcome: Outcome
        do { outcome = try steps(install: install, donors: donors) }
        catch let f as Failure { outcome = .failed(f.description) }
        catch { outcome = .failed("AscensionXI update failed: \(error.localizedDescription)") }
        // Whatever the step it reached, a Stop is a Stop: never "offline" or "ok" and then a game.
        return stop.raised ? .stopped : outcome
    }

    private func steps(install: Bool, donors: [URL]) throws -> Outcome {
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let settings = AscensionChannel.settings(in: root)
        log("i  AscensionXI: optional packs " + (AscensionChannel.wantedPacks(settings).sorted().joined(separator: ", ").nilIfEmpty ?? "off")
            + " (launcher.json: hd, hdMaps, lofiMusic)")
        guard resolveChannel() else {
            try checkStop()
            if installedBefore, lastUpdateFinished {
                return .offline("AscensionXI's update server didn't answer; playing with the files from the last update.")
            }
            if installedBefore {
                return .failed("AscensionXI's update server didn't answer, and the last update did not finish, so the "
                               + "client may be half updated. Try again in a few minutes.")
            }
            return .failed("AscensionXI's update server didn't answer (\(mirrors.joined(separator: ", "))). Try again in a few minutes.")
        }
        try belongsToChannel()
        // Cleared before anything is written and set again only at the very end, so an update that
        // stopped or failed half way never lets an offline Play start on the half-updated client.
        writeState(["finished": false])
        let full = install || !fm.fileExists(atPath: baseCopy.path)
        if full {
            try ensureBase(full: true, donors: donors, settings: settings)
        } else {
            // `RoutineBaseCheck`: a base check that fails is skipped with a warning, as theirs does;
            // the runtime check below still refuses a client that is not the one the release needs.
            do { try ensureBase(full: false, donors: donors, settings: settings) }
            catch {
                try checkStop()
                log("i  AscensionXI base check skipped (\(error)); their DATs and runtime are still checked")
            }
        }
        try checkStop()
        let manifest = try fetchManifest()
        if manifest.version != AscensionChannel.manifestVersion {
            log("i  AscensionXI's manifest is version \(manifest.version); this launcher reads version \(AscensionChannel.manifestVersion)")
        }
        try validateRuntime(manifest)
        let writtenBefore = changed
        try syncOverlay(AscensionChannel.overlay, manifest.files, prefix: "dats")
        if settings.hd {
            try syncOverlay(AscensionChannel.overlay + "-hd", manifest.filesHD, prefix: "dats-hd")
        }
        try checkStop()
        if settings.manageAddons { try syncAddons() } else { log("i  AscensionXI addons: management off (manageAddons=false)") }
        try checkStop()
        // Their launcher's own guard: a release published mid-update is retried, not mixed. Only
        // needed when this update wrote something from that manifest.
        if manifest.clientVersion != nil, changed > writtenBefore,
           try fetchManifest().contentHash != manifest.contentHash {
            throw Failure(description: "AscensionXI published a new release during this update; press Play again.")
        }
        try validateRuntime(manifest)
        try checkStop()
        removeRetiredFiles()
        try rewritePivot(settings)
        installLoader(manifest)
        try prepareBootProfile()
        try checkStop()
        saveState(manifest)
        return .ok(changed: changed)
    }

    /// A client this launcher updated before (its state file and the base manifest copy are there).
    var installedBefore: Bool {
        fm.fileExists(atPath: stateDir.appendingPathComponent("ascension.json").path)
            && fm.fileExists(atPath: baseCopy.path)
            && fm.fileExists(atPath: ashita.appendingPathComponent("Ashita-cli.exe").path)
    }

    /// The last update ran to its end (`saveState`), not into a Stop, a failure or a crash.
    var lastUpdateFinished: Bool { readState()?["finished"] as? Bool == true }

    private func checkStop() throws {
        if stop.raised { throw Failure(description: "Stopped. Press the button again to carry on; nothing finished is lost.") }
    }

    // MARK: - HTTP

    private func url(_ relOrAbsolute: String, base: String? = nil) -> URL? {
        if relOrAbsolute.lowercased().hasPrefix("http://") || relOrAbsolute.lowercased().hasPrefix("https://") {
            return URL(string: relOrAbsolute)
        }
        let rel = relOrAbsolute.replacingOccurrences(of: "\\", with: "/")
        guard let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: (base ?? channel) + "/" + enc)
    }

    /// One GET. A 304 gives no data. Throws on transport errors and on statuses other than
    /// 200/206/304.
    private func get(_ u: URL, ifModifiedSince: String? = nil, timeout: TimeInterval = 30) throws -> (data: Data?, response: HTTPURLResponse) {
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let ims = ifModifiedSince { req.setValue(ims, forHTTPHeaderField: "If-Modified-Since") }
        let sem = DispatchSemaphore(value: 0)
        var out: Result<(Data?, HTTPURLResponse), Error> = .failure(Failure(description: "no answer"))
        let task = session.dataTask(with: req) { d, r, e in
            if let e { out = .failure(e) }
            else if let h = r as? HTTPURLResponse {
                if h.statusCode == 304 { out = .success((nil, h)) }
                else if (200...299).contains(h.statusCode) { out = .success((d ?? Data(), h)) }
                else { out = .failure(Failure(description: "HTTP \(h.statusCode) for \(u.absoluteString)")) }
            }
            sem.signal()
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut {
            if stop.raised { task.cancel() }
        }
        return try out.get()
    }

    /// Download `u` into `dest`, keeping it only when its SHA-256 is `sha` (when given). Written
    /// beside `dest` first, so a half-downloaded file never takes the real name.
    private func save(_ u: URL, to dest: URL, sha: String?) throws {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".ffxi-part")
        try? fm.removeItem(at: part)
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = session.downloadTask(with: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)) { tmp, r, e in
            defer { sem.signal() }
            if let e { failure = e; return }
            guard let h = r as? HTTPURLResponse, (200...299).contains(h.statusCode), let tmp else {
                failure = Failure(description: "HTTP \((r as? HTTPURLResponse)?.statusCode ?? 0) for \(u.absoluteString)"); return
            }
            do { try FileManager.default.moveItem(at: tmp, to: part) } catch { failure = error }
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.5) == .timedOut {
            if stop.raised { task.cancel() }
        }
        if let failure { try? fm.removeItem(at: part); throw failure }
        if let sha, !sha.isEmpty, AscensionChannel.sha256(of: part) != sha {
            try? fm.removeItem(at: part)
            throw Failure(description: "hash mismatch downloading \(u.absoluteString)")
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }

    private struct Job { var rel: String; var source: String; var dest: URL; var sha: String; var size: Int64; var channelRelative: Bool }

    /// Fetch every job, eight at a time, over every live mirror (a channel-relative file that fails
    /// on one is tried on the other). Returns the jobs that failed four times.
    private func fetchAll(_ jobs: [Job], label: String) -> [Job] {
        guard !jobs.isEmpty else { return [] }
        let total = max(jobs.reduce(Int64(0)) { $0 + $1.size }, 1)
        let lock = NSLock()
        var next = 0, done: Int64 = 0, failed: [Job] = [], lastReport = Date.distantPast
        let workers = min(8, jobs.count)
        let mirrors = live.isEmpty ? self.mirrors : live
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            while true {
                lock.lock()
                if next >= jobs.count || stop.raised { lock.unlock(); return }
                let job = jobs[next]; next += 1
                lock.unlock()
                var ok = false
                for attempt in 0..<4 where !stop.raised {
                    let base = mirrors[(w + attempt) % mirrors.count]
                    guard let u = job.channelRelative ? url(job.source, base: base) : url(job.source) else { break }
                    do {
                        try save(u, to: job.dest, sha: job.sha)
                        hashes.record(job.rel, at: job.dest, sha: job.sha)
                        ok = true; break
                    } catch {
                        if stop.raised { break }
                        log("i  retrying \(job.rel) (\(error.localizedDescription))")
                        Thread.sleep(forTimeInterval: Double(attempt + 1))
                    }
                }
                lock.lock()
                if ok { done += job.size; changed += 1 } else { failed.append(job) }
                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.25 {
                    lastReport = now
                    let f = Double(done) / Double(total)
                    lock.unlock()
                    progress(label, f)
                } else { lock.unlock() }
            }
        }
        progress(label, 1)
        return failed
    }

    // MARK: - Channel

    /// The first mirror that serves `/manifest.json` is used; both are kept when both answer.
    private func resolveChannel() -> Bool {
        // Their launcher probes with /manifest.json (280 KB); /environment is 5 bytes and served by
        // the same channel. Both mirrors at once: each answer is under a second.
        var answered = [Bool](repeating: false, count: mirrors.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: mirrors.count) { k in
            guard let u = URL(string: mirrors[k] + "/environment") else { return }
            let ok = (try? get(u, timeout: 15)) != nil
            lock.lock(); answered[k] = ok; lock.unlock()
        }
        if stop.raised { live = []; return false }
        live = mirrors.indices.filter { answered[$0] }.map { mirrors[$0] }
        for k in mirrors.indices where !answered[k] { log("i  AscensionXI mirror \(mirrors[k]) didn't answer") }
        return !live.isEmpty
    }

    /// A GET of a channel file from the first live mirror that answers it, so a mirror whose
    /// /environment answers but whose files are missing mid-republish is passed over, as their
    /// launcher's fallback does. The one that answered is used first from then on.
    private func getFromChannel(_ rel: String, ifModifiedSince: String? = nil, timeout: TimeInterval) throws -> (data: Data?, response: HTTPURLResponse) {
        var last: Error = Failure(description: "no AscensionXI mirror answered \(rel)")
        for m in (live.isEmpty ? mirrors : live) {
            try checkStop()
            guard let u = url(rel, base: m) else { continue }
            do {
                let got = try get(u, ifModifiedSince: ifModifiedSince, timeout: timeout)
                if m != live.first, let k = live.firstIndex(of: m) { live.remove(at: k); live.insert(m, at: 0) }
                return got
            } catch {
                last = error
                log("i  AscensionXI mirror \(m): \(rel) failed (\(error.localizedDescription))")
            }
        }
        throw last
    }

    /// A GET answered from `cache` when the channel says it has not changed since (If-Modified-Since,
    /// the copy dated as the channel's Last-Modified). A copy is kept only when the channel dates it
    /// and `valid` accepts it: a truncated answer must not be kept and then reused on every 304.
    private func fetchCached(_ rel: String, cache: URL, timeout: TimeInterval, valid: (Data) -> Bool) throws -> Data {
        let have = (try? Data(contentsOf: cache)).flatMap { valid($0) ? $0 : nil }
        let since = have == nil ? nil : Self.httpDate((try? fm.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date)
        let got = try getFromChannel(rel, ifModifiedSince: since, timeout: timeout)
        guard let d = got.data else {
            if let have { return have }
            throw Failure(description: "\(rel): not modified, and no copy here")
        }
        guard valid(d) else { throw Failure(description: "\(rel) could not be read") }
        try? fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let lm = got.response.value(forHTTPHeaderField: "Last-Modified"), let date = Self.parseHTTPDate(lm),
           (try? d.write(to: cache, options: .atomic)) != nil {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: cache.path)
        } else {
            try? fm.removeItem(at: cache)
        }
        return d
    }

    /// `FolderBelongsToChannel`: a folder holds one environment's client (prod or staging) for good.
    private func belongsToChannel() throws {
        guard let u = URL(string: channel + "/environment"),
              let got = try? get(u, timeout: 15), let d = got.data,
              let env = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              env == "prod" || env == "staging" else { return }
        guard env == "prod" else {
            throw Failure(description: "AscensionXI's channel at \(channel) serves its \(env) client, not prod.")
        }
        let mark = root.appendingPathComponent(".client-environment")
        let had = (try? String(contentsOf: mark, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if had.isEmpty { try? (env + "\r\n").write(to: mark, atomically: true, encoding: .utf8); return }
        if had != env {
            throw Failure(description: "This folder holds AscensionXI's \(had) client; the player channel serves \(env). Use an empty folder for it.")
        }
    }

    // MARK: - Base client

    private func fetchBase(ifModifiedSince: String?) throws -> AscensionChannel.BaseManifest? {
        let got = try getFromChannel("base/client-manifest.json", ifModifiedSince: ifModifiedSince, timeout: 120)
        guard let d = got.data else { return nil }
        guard let bm = AscensionChannel.parseBase(d, lastModified: got.response.value(forHTTPHeaderField: "Last-Modified")),
              !bm.files.isEmpty else { throw Failure(description: "AscensionXI's base manifest could not be read.") }
        // Every key, pack keys included (they are kept in .base-manifest.json and later used to
        // delete what a revision drops): one unsafe path and the whole manifest is refused.
        if let bad = bm.files.keys.first(where: { !Self.safeRelative($0) }) {
            throw Failure(description: "AscensionXI's base manifest names an unsafe path: \(bad)")
        }
        if bm.version != AscensionChannel.baseVersion {
            log("i  AscensionXI's base manifest is version \(bm.version); this launcher reads version \(AscensionChannel.baseVersion)")
        }
        return bm
    }

    private func wanted(_ files: [String: AscensionChannel.FileEntry], _ s: AscensionChannel.Settings) -> [String] {
        let packs = AscensionChannel.wantedPacks(s)
        return files.keys.filter { rel in AscensionChannel.pack(of: rel).map(packs.contains) ?? true }.sorted()
    }

    /// The base client as `full` (check every wanted file) or as a delta against the copy of the
    /// manifest from the last update (`RoutineBaseCheck`), and packs switched on since.
    private func ensureBase(full: Bool, donors: [URL], settings s: AscensionChannel.Settings) throws {
        var oldFiles: [String: AscensionChannel.FileEntry]?
        var ims: String?
        if !full, let d = try? Data(contentsOf: baseCopy), let old = AscensionChannel.parseBase(d, lastModified: nil) {
            oldFiles = old.files
            ims = Self.httpDate((try? fm.attributesOfItem(atPath: baseCopy.path))?[.modificationDate] as? Date)
        }
        let fetched = try fetchBase(ifModifiedSince: oldFiles == nil ? nil : ims)
        let packs = AscensionChannel.wantedPacks(s)
        let had = Set(readState()?["packs"] as? [String] ?? [])
        guard let bm = fetched else {
            // Unchanged upstream. Only packs switched on since the last update are fetched.
            let newPacks = packs.subtracting(had)
            if newPacks.isEmpty { log("i  AscensionXI base client up to date"); return }
            guard let d = try? Data(contentsOf: baseCopy), let old = AscensionChannel.parseBase(d, lastModified: nil) else { return }
            let names = old.files.keys.filter { AscensionChannel.pack(of: $0).map(newPacks.contains) ?? false }.sorted()
            log("==> AscensionXI: fetching \(newPacks.sorted().joined(separator: ", "))")
            try restore(names, from: old.files, donors: [], label: "Downloading AscensionXI packs")
            writeState(["packs": Array(packs).sorted()])
            return
        }
        let want = wanted(bm.files, s)
        var names: [String]
        if let old = oldFiles {
            let newPacks = packs.subtracting(had)
            names = want.filter { rel in
                old[rel]?.sha256 != bm.files[rel]?.sha256 || (AscensionChannel.pack(of: rel).map(newPacks.contains) ?? false)
            }
            let removed = old.keys.filter { bm.files[$0] == nil }
            log("==> AscensionXI base client -> revision \(bm.revision): \(names.count) changed, \(removed.count) removed")
            // Files only, as their launcher deletes them (File.Exists + File.Delete): never a folder,
            // never a path that leaves the client.
            for rel in removed where Self.safeRelative(rel) {
                let f = root.appendingPathComponent(rel)
                guard Self.isRegularFile(f) else { continue }
                if (try? fm.removeItem(at: f)) != nil { changed += 1; log("i  removed \(rel)") }
            }
        } else {
            log("==> AscensionXI: checking every file of the client against revision \(bm.revision) (one time)")
            // The two files both launchers edit in place stay as they are when they exist: the boot
            // profile (the account, the loader) and the boot script (the player's addon choices).
            // Their launcher's Repair puts both back to the published copy, which switches off
            // every addon the player turned on and back on the ones the catalog retired. When the
            // channel publishes a new copy of either, the update above still fetches it.
            let inPlace = Set(["Ashita/config/boot/\(AscensionChannel.bootProfile)",
                               String(scriptURL.path.dropFirst(root.path.count + 1))])
            names = want.filter { !inPlace.contains($0) || !fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        }
        try restore(names, from: bm.files, donors: donors, label: oldFiles == nil ? "Checking AscensionXI" : "Updating AscensionXI")
        try? bm.raw.write(to: baseCopy, options: .atomic)
        if let lm = bm.lastModified, let date = Self.parseHTTPDate(lm) {
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: baseCopy.path)
        }
        writeState(["packs": Array(packs).sorted(), "revision": bm.revision, "clientVersion": bm.clientVersion])
    }

    /// Every `names` file correct on disk: kept when it already matches, copied from a donor when
    /// one has it byte for byte, otherwise downloaded from `base/files/`.
    private func restore(_ names: [String], from files: [String: AscensionChannel.FileEntry],
                         donors: [URL], label: String) throws {
        guard !names.isEmpty else { return }
        var jobs: [Job] = []
        var kept = 0, copied = 0
        let check = Swift.max(names.count, 1)
        for (n, rel) in names.enumerated() {
            if n % 500 == 0 { try checkStop(); progress(label, Double(n) / Double(check) * 0.999) }
            guard let e = files[rel] else { continue }
            guard Self.safeRelative(rel) else { throw Failure(description: "AscensionXI's manifest names an unsafe path: \(rel)") }
            let dest = root.appendingPathComponent(rel)
            if hashes.verified(rel, at: dest, sha: e.sha256) { kept += 1; continue }
            if rel.hasPrefix("Game/"), copyFromDonor(String(rel.dropFirst(5)), to: dest, key: rel, entry: e, donors: donors) {
                copied += 1; changed += 1
                continue
            }
            jobs.append(Job(rel: rel, source: "base/files/" + rel, dest: dest, sha: e.sha256, size: e.size, channelRelative: true))
        }
        if copied > 0 || !jobs.isEmpty {
            let mb = Double(jobs.reduce(Int64(0)) { $0 + $1.size }) / 1_048_576
            log("==> AscensionXI: \(kept) files already right, \(copied) copied from other clients on this Mac, "
                + "\(jobs.count) to download (\(String(format: "%.0f", mb)) MB)")
        }
        hashes.save()
        let failed = fetchAll(jobs, label: "Downloading AscensionXI")
        try checkStop()
        if !failed.isEmpty {
            throw Failure(description: "\(failed.count) of AscensionXI's files didn't download (first: \(failed[0].rel)). Press the button again to retry them.")
        }
    }

    /// `sub` (a path under the base client's `Game/`) copied from the first donor that has it byte
    /// for byte. The copy itself is hashed, not the donor before copying: a donor rewritten by its
    /// own world's updater between the two would otherwise be kept under the channel's hash.
    private func copyFromDonor(_ sub: String, to dest: URL, key: String, entry e: AscensionChannel.FileEntry, donors: [URL]) -> Bool {
        let part = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".ffxi-part")
        for d in donors {
            let c = d.appendingPathComponent(sub)
            guard let a = try? fm.attributesOfItem(atPath: c.path), (a[.size] as? NSNumber)?.int64Value == e.size,
                  (a[.type] as? FileAttributeType) == .typeRegular else { continue }
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: part)
                try fm.copyItem(at: c, to: part)
                guard AscensionChannel.sha256(of: part) == e.sha256 else { try? fm.removeItem(at: part); continue }
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: part, to: dest)
                hashes.record(key, at: dest, sha: e.sha256)
                return true
            } catch {
                try? fm.removeItem(at: part)
                log("i  couldn't copy \(key) from \(c.path): \(error.localizedDescription)")
            }
        }
        return false
    }

    /// A regular file, not a folder or a link (`lstat`).
    static func isRegularFile(_ u: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.type] as? FileAttributeType == .typeRegular
    }

    static func safeRelative(_ rel: String) -> Bool {
        let r = rel.replacingOccurrences(of: "\\", with: "/")
        guard !r.isEmpty, !r.hasPrefix("/"), !r.contains(":") else { return false }
        return !r.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    // MARK: - Manifest, runtime, overlays

    /// Always fetched whole, as their launcher does: it is what every DAT is checked against, and
    /// a republish dated no later than the last one would slip past an If-Modified-Since.
    private func fetchManifest() throws -> AscensionChannel.Manifest {
        guard let d = try getFromChannel("manifest.json", timeout: 60).data,
              let m = AscensionChannel.parseManifest(d) else {
            throw Failure(description: "AscensionXI's update manifest could not be read.")
        }
        return m
    }

    /// `ValidateRuntime`: the retail runtime this release was built against, byte for byte.
    private func validateRuntime(_ m: AscensionChannel.Manifest) throws {
        guard let v = m.clientVersion else { return }
        guard v.range(of: #"^30\d{6}_\d+$"#, options: .regularExpression) != nil else {
            throw Failure(description: "AscensionXI's channel has an invalid client compatibility contract.")
        }
        for need in ["Game/FINAL FANTASY XI/FFXiMain.dll", "Ashita/Ashita.dll", "Ashita/Ashita-cli.exe"] where m.runtimeFiles[need] == nil {
            throw Failure(description: "AscensionXI's channel does not pin its required runtime: \(need)")
        }
        for (rel, sha) in m.runtimeFiles.sorted(by: { $0.key < $1.key }) {
            guard Self.safeRelative(rel), sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw Failure(description: "AscensionXI's channel has an invalid runtime file: \(rel)")
            }
            if !hashes.verified(rel, at: root.appendingPathComponent(rel), sha: sha) {
                throw Failure(description: "\(rel) is not the one AscensionXI \(v) needs. Wait for their maintenance to finish, "
                              + "or press Repair to check every file.")
            }
        }
    }

    private func syncOverlay(_ name: String, _ files: [String: AscensionChannel.FileEntry], prefix: String) throws {
        let dir = ashita.appendingPathComponent("polplugins/DATs/\(name)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var jobs: [Job] = []
        for (rel, e) in files.sorted(by: { $0.key < $1.key }) {
            guard Self.safeRelative(rel) else { throw Failure(description: "AscensionXI's manifest names an unsafe path: \(rel)") }
            let dest = dir.appendingPathComponent(rel)
            let key = "Ashita/polplugins/DATs/\(name)/\(rel)"
            if !hashes.verified(key, at: dest, sha: e.sha256) {
                jobs.append(Job(rel: key, source: prefix + "/" + rel, dest: dest, sha: e.sha256, size: e.size, channelRelative: true))
            }
        }
        let failed = fetchAll(jobs, label: "Updating AscensionXI's DATs")
        try checkStop()
        if !failed.isEmpty { throw Failure(description: "\(failed.count) of AscensionXI's DATs didn't download (first: \(failed[0].rel)).") }
        var pruned = 0
        // Relative paths from the walk itself: a URL enumerator may hand back the folder's
        // resolved spelling (/private/var/... for /var/...), and cutting its prefix off by length
        // then names no manifest file at all -- every DAT just fetched would be pruned.
        if let walk = fm.enumerator(atPath: dir.path) {
            var extra: [String] = []
            for case let rel as String in walk {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue else { continue }
                if files[rel] == nil { extra.append(rel) }
            }
            for rel in extra { try? fm.removeItem(at: dir.appendingPathComponent(rel)); pruned += 1 }
        }
        Self.removeEmptyFolders(under: dir)
        log("i  overlay [\(name)] in sync: \(files.count) files, \(jobs.count) updated, \(pruned) pruned")
    }

    static func removeEmptyFolders(under dir: URL) {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var dirs: [URL] = []
        for case let d as URL in walk where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(d) }
        for d in dirs.sorted(by: { $0.path.count > $1.path.count })
        where ((try? fm.contentsOfDirectory(atPath: d.path)) ?? ["x"]).isEmpty {
            try? fm.removeItem(at: d)
        }
    }

    // MARK: - Addons (SyncAddons)

    private var scriptURL: URL {
        let ini = ashita.appendingPathComponent("config/boot/\(AscensionChannel.bootProfile)")
        let text = (try? String(contentsOf: ini, encoding: .isoLatin1)) ?? ""
        // A `script=` that leaves Ashita/scripts (the profile comes from their channel) is not used.
        let named = BootProfile.value("script", section: "ashita.boot", in: text) ?? ""
        let script = Self.safeRelative(named) ? named.replacingOccurrences(of: "\\", with: "/") : "default.txt"
        return ashita.appendingPathComponent("scripts").appendingPathComponent(script)
    }

    private func addonTarget(_ e: AscensionChannel.Catalog.Entry, _ rel: String) throws -> URL {
        let r = rel.replacingOccurrences(of: "\\", with: "/")
        guard Self.safeRelative(r), AscensionChannel.safeAddonName(e.name) else {
            throw Failure(description: "catalog entry \(e.name) names an unsafe path: \(rel)")
        }
        let base = (e.kind == "plugin" ? ashita.appendingPathComponent("plugins") : ashita.appendingPathComponent("addons/\(e.name)")).standardizedFileURL
        let t = base.appendingPathComponent(r).standardizedFileURL
        guard t.path.hasPrefix(base.path + "/") else { throw Failure(description: "catalog entry \(e.name) leaves its folder: \(rel)") }
        return t
    }

    private func addonLocation(_ e: AscensionChannel.Catalog.Entry) -> URL {
        e.kind == "plugin" ? ashita.appendingPathComponent("plugins/\(e.name).dll") : ashita.appendingPathComponent("addons/\(e.name)")
    }

    private func installed(_ e: AscensionChannel.Catalog.Entry) -> Bool {
        if e.files.isEmpty { return fm.fileExists(atPath: addonLocation(e).path) }
        return e.files.keys.allSatisfy { (try? addonTarget(e, $0)).map { fm.fileExists(atPath: $0.path) } ?? false }
    }

    private func isWorkingCopy(_ e: AscensionChannel.Catalog.Entry) -> Bool {
        e.kind == "addon" && fm.fileExists(atPath: addonLocation(e).appendingPathComponent(".git").path)
    }

    private func current(_ e: AscensionChannel.Catalog.Entry) -> Bool {
        e.files.allSatisfy { rel, f in
            guard let t = try? addonTarget(e, rel) else { return false }
            return addonFileCurrent(e, rel: rel, at: t, sha: f.sha256)
        }
    }

    /// Is this addon file the catalog's? Also yes for an addon's entry file (`<name>/<name>.lua`)
    /// that is the catalog's file with LuaJITGuard's lines in front: Play adds those to every
    /// allowed addon, and without this every Play after the first fetched 80 files again to undo
    /// them (b71, 2026-10-24). The bytes after the guard must be the catalog's exactly.
    private func addonFileCurrent(_ e: AscensionChannel.Catalog.Entry, rel: String, at t: URL, sha: String) -> Bool {
        if hashes.verified(String(t.path.dropFirst(root.path.count + 1)), at: t, sha: sha) { return true }
        guard e.kind == "addon", rel.caseInsensitiveCompare("\(e.name).lua") == .orderedSame,
              let d = try? Data(contentsOf: t) else { return false }
        return AscensionSync.withoutJITGuard(d).map { AscensionChannel.sha256($0) == sha } ?? false
    }

    /// `d` without the lines LuaJITGuard.patch put at its front (after a UTF-8 BOM, which it keeps
    /// first), or nil when it has none.
    static func withoutJITGuard(_ d: Data) -> Data? {
        let bom = Data([0xEF, 0xBB, 0xBF]), shim = Data(LuaJITGuard.shim.utf8)
        let lead = d.starts(with: bom) ? bom : Data()
        let rest = d.dropFirst(lead.count)
        guard rest.starts(with: shim) else { return nil }
        return lead + rest.dropFirst(shim.count)
    }

    private struct AddonState {
        var seen = Set<String>(), ignoreUpdates = Set<String>(), followUpdates = Set<String>(), switchedOff = Set<String>()
        func ignores(_ e: AscensionChannel.Catalog.Entry) -> Bool {
            if ignoreUpdates.contains(where: { $0.caseInsensitiveCompare(e.name) == .orderedSame }) { return true }
            if followUpdates.contains(where: { $0.caseInsensitiveCompare(e.name) == .orderedSame }) { return false }
            return e.defaultIgnoreUpdates
        }
    }

    private func loadState() -> AddonState {
        var s = AddonState()
        guard let d = try? Data(contentsOf: root.appendingPathComponent("addons.json")),
              let o = (try? JSONSerialization.jsonObject(with: d.starts(with: [0xEF, 0xBB, 0xBF]) ? d.dropFirst(3) : d)) as? [String: Any]
        else { return s }
        func set(_ k: String) -> Set<String> { Set(((o[k] as? [Any]) ?? []).map { "\($0)" }) }
        s.seen = set("seen"); s.ignoreUpdates = set("ignoreUpdates"); s.followUpdates = set("followUpdates"); s.switchedOff = set("switchedOff")
        return s
    }

    /// addons.json exactly as their launcher writes it, so either launcher can read the other's.
    private func saveState(_ s: AddonState) {
        func arr(_ set: Set<String>) -> String {
            // OrdinalIgnoreCase compares upper-cased; JavaScriptSerializer escapes < > & ' as \u00XX.
            let sorted = set.sorted { $0.uppercased() < $1.uppercased() }
            let d = (try? JSONSerialization.data(withJSONObject: sorted, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
            return (String(data: d, encoding: .utf8) ?? "[]")
                .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
                .replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "'", with: "\\u0027")
        }
        let note = "The launcher's memory of the addon catalog: 'seen' entries were auto-enabled once and are now the player's to switch; 'ignoreUpdates' entries stay at their installed version and 'followUpdates' entries take every catalog update - both are the player's choices on the Addons page; an entry in neither list does what the catalog says. 'switchedOff' entries left the catalog and were unticked once; switching one back on is the player's choice."
        let text = "{\r\n  \"//\": \"\(note)\",\r\n  \"seen\": \(arr(s.seen)),\r\n  \"ignoreUpdates\": \(arr(s.ignoreUpdates)),\r\n  \"followUpdates\": \(arr(s.followUpdates)),\r\n  \"switchedOff\": \(arr(s.switchedOff))\r\n}\r\n"
        try? text.write(to: root.appendingPathComponent("addons.json"), atomically: true, encoding: .utf8)
    }

    private func syncAddons() throws {
        let catalog: AscensionChannel.Catalog
        do {
            // Kept where their launcher keeps it, which is also what AscensionChannel.addonPolicy reads.
            let d = try fetchCached("addons/catalog.json", cache: root.appendingPathComponent("addons-catalog.json"), timeout: 60,
                                    valid: { AscensionChannel.catalogReadable($0) })
            catalog = AscensionChannel.parseCatalog(d)
            if catalog.version != AscensionChannel.catalogVersion {
                log("i  AscensionXI's addon catalog is version \(catalog.version); this launcher reads version \(AscensionChannel.catalogVersion)")
            }
        } catch {
            try checkStop()
            log("i  AscensionXI addon catalog not fetched (\(error.localizedDescription)); addons left as they are")
            return
        }
        var state = loadState()
        let scriptFile = scriptURL
        var script = AscensionScript(try? String(contentsOf: scriptFile, encoding: .isoLatin1))
        // What this run changes in the script, replayed on the file as it is right before writing:
        // the Addons… sheet may have written it while the catalog was syncing (minutes, the first time).
        var ops: [(AscensionScript) -> AscensionScript] = []
        func apply(_ op: @escaping (AscensionScript) -> AscensionScript) { script = op(script); ops.append(op) }
        var updated = 0, enabled = 0, held = 0, failedCount = 0
        for (n, e) in catalog.entries.enumerated() {
            try checkStop()
            progress("Updating AscensionXI's addons", Double(n) / Double(max(catalog.entries.count, 1)))
            var ok = installed(e)
            let working = isWorkingCopy(e)
            if (!e.files.isEmpty || !e.remove.isEmpty), working || (ok && state.ignores(e)) {
                if working || !current(e) { held += 1; log("i  addon held: \(e.name)" + (working ? " (a git working copy - never written)" : " (updates ignored)")) }
                ok = true
            } else {
                do {
                    var stale: [String] = []
                    for (rel, f) in e.files.sorted(by: { $0.key < $1.key }) {
                        let t = try addonTarget(e, rel)
                        if !addonFileCurrent(e, rel: rel, at: t, sha: f.sha256) { stale.append(rel) }
                    }
                    if !stale.isEmpty, !e.archives.isEmpty {
                        let took = try takeFromArchives(e, stale)
                        updated += took.count
                        changed += took.count
                        stale.removeAll { took.contains($0) }
                    }
                    let jobs = try stale.map { rel -> Job in
                        let f = e.files[rel]!
                        let t = try addonTarget(e, rel)
                        let absolute = f.path.lowercased().hasPrefix("http://") || f.path.lowercased().hasPrefix("https://")
                        return Job(rel: String(t.path.dropFirst(root.path.count + 1)), source: f.path, dest: t,
                                   sha: f.sha256, size: f.size, channelRelative: !absolute)
                    }
                    let failed = fetchAll(jobs, label: "Updating AscensionXI's addons")
                    if !failed.isEmpty { throw Failure(description: "\(failed.count) file(s) didn't download") }
                    updated += jobs.count
                    let removed = try removeObsolete(e)
                    if removed > 0 { log("i  addon cleaned: \(e.name) (\(removed) obsolete file(s) removed)") }
                    ok = true
                } catch {
                    try checkStop()
                    failedCount += 1
                    log("i  addon \(e.name) not synced (\(error))")
                }
            }
            guard ok else { continue }
            if !state.seen.contains(where: { $0.caseInsensitiveCompare(e.name) == .orderedSame }) {
                state.seen.insert(e.name)
                if e.defaultEnabled, !script.isEnabled(kind: e.kind, e.name) {
                    apply { var s = $0; s.enable(kind: e.kind, e.name); return s }; enabled += 1
                    log("i  addon enabled: \(e.name) (new in the catalog)")
                }
            }
            if e.required, !script.isEnabled(kind: e.kind, e.name) { apply { var s = $0; s.enable(kind: e.kind, e.name); return s }; enabled += 1 }
        }
        var switched = 0
        for off in catalog.switchOff {
            // Case-insensitive, as their HashSet is: "FPS" is the "fps" switched off before.
            guard !state.switchedOff.contains(where: { $0.caseInsensitiveCompare(off.name) == .orderedSame }) else { continue }
            state.switchedOff.insert(off.name)
            if script.isEnabled(kind: off.kind, off.name) {
                apply { var s = $0; s.disable(kind: off.kind, off.name); return s }; switched += 1
                log("i  addon switched off: \(off.name) (\(off.reason))")
            }
        }
        if !script.isEnabled(kind: "addon", "fps"), script.hasLine("/bind F12 /fps") {
            apply { var s = $0; if !s.isEnabled(kind: "addon", "fps") { s.removeLine("/bind F12 /fps") }; return s }
            log("i  addons: removed \"/bind F12 /fps\" (the fps addon is not loaded)")
        }
        saveState(state)
        if !ops.isEmpty {
            let now = try? String(contentsOf: scriptFile, encoding: .isoLatin1)
            let fresh = ops.reduce(AscensionScript(now)) { $1($0) }
            if let text = fresh.changed {
                try? fm.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? text.write(to: scriptFile, atomically: true, encoding: .isoLatin1)) != nil {
                    log("i  addons: \(scriptFile.lastPathComponent) rewritten")
                }
            }
        } else if let text = AscensionScript(try? String(contentsOf: scriptFile, encoding: .isoLatin1)).changed,
                  !fm.fileExists(atPath: scriptFile.path) {
            // No script at all yet: theirs writes the (empty) block anyway.
            try? fm.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: scriptFile, atomically: true, encoding: .isoLatin1)
        }
        log("i  AscensionXI addons: \(catalog.entries.count) in catalog, \(updated) file(s) updated, \(enabled) newly enabled, "
            + "\(switched) switched off, \(held) held, \(failedCount) failed")
    }

    /// `TakeFromArchives`: an addon whose stale files are worth one archive (at least one file
    /// per 200 KB of it) takes them out of that archive; the rest come one by one.
    private func takeFromArchives(_ e: AscensionChannel.Catalog.Entry, _ stale: [String]) throws -> Set<String> {
        var took = Set<String>()
        for a in e.archives {
            let mine = stale.filter { rel in
                let best = e.archives.filter { rel.hasPrefix($0.into) }.max { $0.into.count < $1.into.count }
                return best == a
            }
            guard !mine.isEmpty, Int64(mine.count) * 204_800 >= a.size else { continue }
            // `from` names a folder inside the zip and `into` one inside the addon: neither may climb
            // out (theirs only ever compares names inside the zip; extracted to disk, a "../" would
            // reach files outside the temporary folder).
            guard AscensionChannel.safeArchivePrefix(a.from), AscensionChannel.safeArchivePrefix(a.into) else {
                log("i  addon \(e.name): archive with an unsafe folder (\(a.from) -> \(a.into)) not used"); continue
            }
            let tmp = stateDir.appendingPathComponent("tmp/\(e.name)-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tmp) }
            do {
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let zip = tmp.appendingPathComponent("archive.zip")
                guard let u = url(a.url) else { continue }
                try save(u, to: zip, sha: nil)
                let out = tmp.appendingPathComponent("x")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", zip.path, out.path]
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw Failure(description: "ditto \(p.terminationStatus)") }
                var got = 0
                let outBase = out.standardizedFileURL.path + "/"
                for rel in mine {
                    let inner = a.from + rel.dropFirst(a.into.count)
                    let src = out.appendingPathComponent(String(inner)).standardizedFileURL
                    guard src.path.hasPrefix(outBase), Self.isRegularFile(src),
                          let f = e.files[rel], AscensionChannel.sha256(of: src) == f.sha256 else { continue }
                    let t = try addonTarget(e, rel)
                    try fm.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: t)
                    try fm.moveItem(at: src, to: t)
                    hashes.record(String(t.path.dropFirst(root.path.count + 1)), at: t, sha: f.sha256)
                    took.insert(rel); got += 1
                }
                log("i  addon synced: \(e.name) - \(got) file(s) from one archive" + (got < mine.count ? " (\(mine.count - got) fetched one by one)" : ""))
            } catch {
                log("i  addon \(e.name) archive not used (\(error)); its files are fetched one by one")
            }
        }
        return took
    }

    /// `RemoveObsoleteAddonFiles`, with every one of its safety checks.
    private func removeObsolete(_ e: AscensionChannel.Catalog.Entry) throws -> Int {
        guard !e.remove.isEmpty else { return 0 }
        guard e.name != ".", e.name != "..", !e.name.contains("/"), !e.name.contains("\\"), !e.name.contains(":") else {
            throw Failure(description: "unsafe obsolete addon name: \(e.name)")
        }
        let base = (e.kind == "plugin" ? ashita.appendingPathComponent("plugins") : ashita.appendingPathComponent("addons/\(e.name)")).standardizedFileURL
        var doomed: [URL] = []
        for item in e.remove {
            let clean = item.replacingOccurrences(of: "\\", with: "/")
            if clean.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".") })
                || clean.contains(":") { throw Failure(description: "unsafe obsolete addon path: \(item)") }
            if e.files.keys.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) { continue }
            let full = try addonTarget(e, clean).standardizedFileURL
            guard full.path.hasPrefix(base.path + "/") else { throw Failure(description: "obsolete addon path escapes its folder: \(item)") }
            // A file only, as theirs (File.Exists is false for a folder): an old file that became a
            // folder in a later version keeps that folder and what is in it.
            guard Self.isRegularFile(full) else { continue }
            var p = full
            while p.path.count >= base.path.count {
                if (try? p.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw Failure(description: "obsolete addon path crosses a link: \(item)")
                }
                p.deleteLastPathComponent()
            }
            doomed.append(full)
        }
        var n = 0
        for f in doomed {
            if (try? fm.removeItem(at: f)) != nil { n += 1 }
            var d = f.deletingLastPathComponent()
            while d.path.count > base.path.count, ((try? fm.contentsOfDirectory(atPath: d.path)) ?? ["x"]).isEmpty {
                try? fm.removeItem(at: d)
                d.deleteLastPathComponent()
            }
        }
        return n
    }

    // MARK: - The rest of Play's steps

    private func removeRetiredFiles() {
        var doomed = AscensionChannel.retiredRootFiles.map { root.appendingPathComponent($0) }
        doomed += AscensionChannel.devBootProfiles.map { ashita.appendingPathComponent("config/boot/\($0)") }
        for f in doomed where fm.fileExists(atPath: f.path) {
            if (try? fm.removeItem(at: f)) != nil { log("i  removed \(f.lastPathComponent) (not part of the player client)") }
        }
    }

    private func rewritePivot(_ s: AscensionChannel.Settings) throws {
        let file = ashita.appendingPathComponent("config/pivot/pivot.ini")
        let dats = ashita.appendingPathComponent("polplugins/DATs")
        var present = Set<String>()
        if fm.fileExists(atPath: dats.appendingPathComponent("ffxi-maps/1024x1024").path) { present.insert("ffxi-maps") }
        for p in ["ffxi-hd", "ffxi-lofi"] where fm.fileExists(atPath: dats.appendingPathComponent(p).path) { present.insert(p) }
        let old = try? String(contentsOf: file, encoding: .isoLatin1)
        let text = AscensionChannel.pivot(old, datsWine: datsWine, settings: s, present: present)
        guard text != old else { return }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Their Encoding.ASCII turns what it cannot encode into "?"; a folder name with an accent
        // must not stop Play. Windows-1252 keeps Latin accents as the Wine side reads them.
        guard let bytes = text.data(using: .windowsCP1252, allowLossyConversion: true) else { return }
        try bytes.write(to: file, options: .atomic)
        log("i  pivot.ini: overlays set")
    }

    /// Their loader, out of the launcher their channel publishes (`InstallNativeLoader`). Any
    /// failure keeps the stock xiloader their base client ships, which their login server also takes.
    private func installLoader(_ m: AscensionChannel.Manifest) {
        guard let entry = m.launcher[AscensionChannel.launcherExe], !entry.path.isEmpty else {
            log("i  AscensionXI's manifest names no launcher; keeping the stock xiloader"); return
        }
        let exe = root.appendingPathComponent(AscensionChannel.launcherExe)
        if !hashes.verified(AscensionChannel.launcherExe, at: exe, sha: entry.sha256) {
            guard let u = url(entry.path) else { return }
            do { try save(u, to: exe, sha: entry.sha256); hashes.record(AscensionChannel.launcherExe, at: exe, sha: entry.sha256) }
            catch { log("i  AscensionXI's launcher didn't download (\(error.localizedDescription)); keeping the loader there is"); return }
        }
        guard let data = try? Data(contentsOf: exe), let l = DotNetResources.ascensionLoader(in: data) else {
            log("i  AscensionXI's launcher carries no loader this launcher can read; keeping the stock xiloader"); return
        }
        let dir = ashita.appendingPathComponent("bootloader")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in [("LICENSE", l.license), ("NOTICE", l.notice)] {
            let f = dir.appendingPathComponent("ascensionxi-loader-\(name).txt")
            if (try? String(contentsOf: f, encoding: .utf8)) != text { try? text.write(to: f, atomically: true, encoding: .utf8) }
        }
        let target = dir.appendingPathComponent(AscensionChannel.loaderName)
        let want = AscensionChannel.sha256(l.exe)
        guard AscensionChannel.sha256(of: target) != want else { return }
        let part = dir.appendingPathComponent(AscensionChannel.loaderName + ".new")
        do {
            try l.exe.write(to: part, options: .atomic)
            guard AscensionChannel.sha256(of: part) == want else { throw Failure(description: "verification failed") }
            try? fm.removeItem(at: target)
            try fm.moveItem(at: part, to: target)
            changed += 1
            log("i  AscensionXI's loader installed (\(AscensionChannel.loaderName))")
        } catch {
            try? fm.removeItem(at: part)
            log("i  AscensionXI's loader not installed (\(error)); keeping the stock xiloader")
        }
    }

    /// `PrepareBootProfile`, minus what this launcher does itself at Play: the loader line
    /// (`Credentials.fixBootLoader`, `Server.loader`), graphics (the Graphics panel) and the
    /// account (`Credentials.apply`). Only a leftover `--json` from their launcher is taken out.
    private func prepareBootProfile() throws {
        let ini = ashita.appendingPathComponent("config/boot/\(AscensionChannel.bootProfile)")
        guard let text = try? String(contentsOf: ini, encoding: .isoLatin1) else {
            throw Failure(description: "AscensionXI's boot profile (\(AscensionChannel.bootProfile)) is missing. Press Repair.")
        }
        guard let cmd = BootProfile.value("command", section: "ashita.boot", in: text) else { return }
        let clean = AscensionChannel.commandWithoutJSON(cmd)
        guard clean != cmd else { return }
        let out = BootProfile.setting(.init(section: "ashita.boot", key: "command", value: clean), in: text)
        try out.write(to: ini, atomically: true, encoding: .isoLatin1)
    }

    // MARK: - State

    private var stateURL: URL { stateDir.appendingPathComponent("ascension.json") }
    private func readState() -> [String: Any]? {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    private func writeState(_ merge: [String: Any]) {
        var s = readState() ?? [:]
        for (k, v) in merge { s[k] = v }
        if let d = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: stateURL, options: .atomic)
        }
    }
    private func saveState(_ m: AscensionChannel.Manifest) {
        writeState(["finished": true, "manifest": m.contentHash, "clientVersion": m.clientVersion ?? "",
                    "updated": ISO8601DateFormatter().string(from: Date())])
    }

    // MARK: - HTTP dates

    private static let httpDateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
    static func httpDate(_ d: Date?) -> String? { d.map { httpDateFormat.string(from: $0) } }
    static func parseHTTPDate(_ s: String) -> Date? { httpDateFormat.date(from: s) }
}

/// Size, modification time and SHA-256 of files this launcher has verified, so the next check of
/// an unchanged file is a `stat`. Keyed by path under the client root. Any change to a file's size
/// or time makes it hashed again.
final class HashCache: @unchecked Sendable {
    /// False: every `verified` hashes the file again (Setup, Repair), and updates the cache.
    var trustStamps = true
    private var map: [String: [String]] = [:]
    private let lock = NSLock()
    private var dirty = false
    let url: URL

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: [String]].self, from: d) { map = m }
    }

    private static func stamp(_ file: URL) -> [String]? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: file.path),
              (a[.type] as? FileAttributeType) == .typeRegular,
              let size = a[.size] as? NSNumber, let m = a[.modificationDate] as? Date else { return nil }
        return [size.stringValue, String(m.timeIntervalSince1970)]
    }

    /// Is the file at `file` the one with `sha`? Hashed only when it changed since last time.
    func verified(_ key: String, at file: URL, sha: String) -> Bool {
        guard let s = Self.stamp(file) else { return false }
        lock.lock()
        if trustStamps, let e = map[key], e.count == 3, e[0] == s[0], e[1] == s[1] { lock.unlock(); return e[2] == sha }
        lock.unlock()
        guard let h = AscensionChannel.sha256(of: file) else { return false }
        lock.lock(); map[key] = s + [h]; dirty = true; lock.unlock()
        return h == sha
    }

    /// A file just written after its hash was checked.
    func record(_ key: String, at file: URL, sha: String) {
        guard let s = Self.stamp(file) else { return }
        lock.lock(); map[key] = s + [sha]; dirty = true; lock.unlock()
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        guard dirty, let d = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? d.write(to: url, options: .atomic)) != nil { dirty = false }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
