import Foundation

/// Reading what Ashita and the boot loader print into the game's stdout file (Runner tails it).
enum LoaderOutput {
    /// The boot loader's verdict when a login is refused ("Failed to login. Invalid username or
    /// password." / "…Account already logged in." / "…xiloader version mismatch…"). Every xiloader
    /// fork prints one of these and then sits at its menu.
    static let refusalMarkers = ["Failed to login", "Bad json reply from remote", "Error from remote",
                                 "version mismatch", "xi_connect", "Account already logged in"]

    /// The loader's own account menu ("What would you like to do? 1.) Login 2.) Create New
    /// Account … Enter a selection:"). It reads the answer from a stdin that is never a terminal
    /// here, so it gets end-of-file and prints the menu again, for as long as nobody stops it:
    /// 831 times in five minutes on 2026-10-15 (b60, a HorizonXI profile booting Ashita's
    /// DarkStar-era pol.exe), with no window and the button saying "Starting…". Reaching it means
    /// the autologin did not happen, whichever loader it is.
    static let menuMarkers = ["What would you like to do?", "Enter a selection"]

    struct Refusal: Equatable {
        /// What the player is told: the loader's own words, or one plain line for the menu.
        let message: String
        let atMenu: Bool
    }

    /// The refusal `chunk` shows, if any. A loader's own refusal line wins over its menu, which
    /// follows it. `menu`: whether the menu counts (the game's output; a job's never did).
    /// `account`: the boot command carried an account name and password. Without them the loader
    /// opens at its menu having tried nothing (a world whose card says the loader window makes the
    /// account, Play pressed with the fields empty), and "didn't accept the login" would be wrong.
    static func refusal(in chunk: String, world: String, menu: Bool = true, account: Bool = true) -> Refusal? {
        if let hit = refusalMarkers.first(where: { chunk.contains($0) }), let r = chunk.range(of: hit) {
            let raw = String(chunk[r.lowerBound...]).split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? hit
            let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \u{1b}[m")).trimmingCharacters(in: .whitespaces)
            let message = hit == "Bad json reply from remote"
                ? "The login server sent a reply this client could not read. Usually the wrong password, an account that does not exist, or a client-version mismatch."
                : (clean.isEmpty ? hit : clean)
            return Refusal(message: message, atMenu: false)
        }
        if menu, menuMarkers.contains(where: { chunk.contains($0) }) {
            let who = world.isEmpty ? "The server" : world
            return Refusal(message: account
                               ? "\(who) didn't accept the login — check the account name and password."
                               : "\(who) needs an account — enter its name and password, then press Play.",
                           atMenu: true)
        }
        return nil
    }

    /// b70: what the game's output says about its GPU device. Only a loss: nothing brings a lost
    /// device back (MoltenVK never un-loses a VkDevice, and the HorizonXI DXVK latches it), so
    /// there is no line for a recovery. MoltenVK's "Resumed VkDevice" (a GPU reset it rode out,
    /// `MVK_CONFIG_RESUME_LOST_DEVICE`) is a warning, printed only at log level 2, and says
    /// nothing here either way.
    enum RenderEvent: Equatable { case lost }

    /// The HorizonXI DXVK's one line once the device is lost (`Logger::err`, so it survives the
    /// launcher's `DXVK_LOG_LEVEL=error`).
    static let renderLostMarker = "horizonxi: GPU device lost"

    /// Whole lines of the game's output (`RepeatCap.filter`'s; a line's first time always
    /// passes). Each of these means the client can never draw again: MoltenVK's error
    /// `[mvk-error] …: Lost VkDevice after MTLCommandBuffer …`, DXVK's `err:` lines naming
    /// `VK_ERROR_DEVICE_LOST`, and the HorizonXI DXVK's own line. By the line's start, so a chat
    /// line or anything else that merely names the error says nothing. 2026-10-16 21:31 printed
    /// the first two kinds, three of its four lines.
    static func renderEvents(in lines: String) -> [RenderEvent] {
        lines.split(whereSeparator: \.isNewline).compactMap { raw -> RenderEvent? in
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[mvk-error]"), l.contains("Lost VkDevice") { return .lost }
            if l.hasPrefix("err:"), l.contains("VK_ERROR_DEVICE_LOST") || l.contains(renderLostMarker) { return .lost }
            return nil
        }
    }

    /// Keeps a looping loader from filling launcher.log. Each distinct line (its leading
    /// `[mm/dd/yy hh:mm:ss]` stamp aside, since the menu's changes every second) is written at most
    /// `limit` times per session; after that it is dropped, with one note the first time.
    /// Incomplete lines wait for their end, so a line split across two reads still counts once.
    struct RepeatCap {
        let limit: Int
        /// Distinct lines remembered at most; past that, new lines are not counted (and pass).
        let maxDistinct: Int
        private var seen: [String: Int] = [:]
        private var carry = ""
        private(set) var dropped = 0

        init(limit: Int = 20, maxDistinct: Int = 4096) {
            self.limit = limit; self.maxDistinct = maxDistinct
        }

        static let note = "i  this output keeps repeating; launcher.log keeps each line only the first few times\n"

        /// The part of `chunk` to write: whole lines only, repeats past the limit removed.
        mutating func filter(_ chunk: String) -> String {
            let text = carry + chunk
            // By Unicode scalar: Swift's "\r\n" is one Character and splitting on "\n" misses it.
            var parts = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String(String.UnicodeScalarView($0)) }
            carry = parts.removeLast()
            var out = ""
            for line in parts {
                let key = Self.normalised(line)
                let n = (seen[key] ?? 0) + 1
                if seen[key] != nil || seen.count < maxDistinct { seen[key] = n }
                if n <= limit {
                    out += line + "\n"
                } else {
                    if dropped == 0 { out += Self.note }
                    dropped += 1
                }
            }
            return out
        }

        /// Whatever incomplete line is left, when the output has ended.
        mutating func flush() -> String {
            defer { carry = "" }
            return carry
        }

        /// The line without its loader timestamp, its CR and surrounding blanks.
        static func normalised(_ line: String) -> String {
            var t = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
            if t.hasPrefix("["), let close = t.firstIndex(of: "]"),
               t.distance(from: t.startIndex, to: close) <= 24,
               t[t.index(after: t.startIndex)..<close].allSatisfy({ $0.isNumber || "/: ".contains($0) }) {
                t = t[t.index(after: close)...]
            }
            return t.trimmingCharacters(in: .whitespaces)
        }
    }
}
