import Foundation

/// A private server the launcher can connect to.
///
/// Only HorizonXI is verified — its host is the one this project actually logs into. The other
/// entries are seeded with the login hosts those communities publish, but they are **untested
/// here**, which is why every field is editable and why `verified` is surfaced in the UI rather
/// than hidden. Do not present an unverified host as if it were known-good.
struct Server: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var host: String
    /// Ashita boot profile under `config/boot/`. Each server community ships its own.
    var bootProfile: String
    var verified: Bool
    /// Optional note shown under the server picker.
    var note: String
    /// Era / level cap, shown as a subtitle in the dropdown.
    var era: String = ""
    /// Rough community size, used **only** for ordering the dropdown. Never shown as a number:
    /// these are estimates from public trackers and would be stale within a month. Ordering by
    /// them is useful; publishing them as fact is not.
    var population: Int = 0
    /// Pinned entries sort above everything else regardless of population.
    var pinned: Bool = false
    /// A server that runs on this Mac. Selecting it turns the launcher into an installer for
    /// LandSandBoat as well: see `LocalServer` and `scripts/lsb-server.sh`. Optional in the
    /// decoder so a `servers.json` written by an older build still loads.
    var local: Bool = false
    /// Where this server publishes the retail client version it insists on (its LandSandBoat
    /// `login.lua`, `CLIENT_VER`). Blank when it publishes nothing; the pre-game check then only
    /// has the compiled-in `requiredClient` snapshot to go on.
    var requiredClientURL: String = ""
    /// Retail patch level (e.g. `30251204_1`) the login server rejects anything older than with
    /// "The game's data has been updated". Snapshot; refreshed from `requiredClientURL` on start.
    var requiredClient: String = ""
    /// Folder on this Mac holding the world's game files (Ashita-cli.exe, SquareEnix/…). Empty =
    /// the classic HorizonXI folder inside the wrapper. Chosen by the user the first time they
    /// pick a world whose data is not installed yet; may be on any drive.
    var dataPath: String = ""
    /// Where a new player gets this world's client, and how (see `InstallKind`).
    var installURL: String = ""
    var installKind: InstallKind = .website
    /// One line about the download: what it is and roughly how big.
    var installNote: String = ""

    /// Dropped from the picker because the *server* is gone -- not because of its codebase.
    /// Checked 2026-08-21 against live population counters and Discord member counts.
    var retired: Bool = false

    /// Which server emulator this world runs. Decides whether it appears in the launcher at
    /// all: LandSandBoat is the only FFXI emulator still in development, so a world on anything
    /// else is frozen at whatever its fork inherited. Established 2026-08-21 by probing each
    /// login server directly -- see `Codebase` and docs/CODEBASE.md.
    var codebase: Codebase = .unknown

    /// The emulator a world runs on, as told by its login server.
    ///
    /// The discriminator is port 54231. Modern LandSandBoat speaks JSON over TLS there
    /// (`src/login/auth_session.cpp`) and answers a stale version tuple with a verbatim
    /// "Your xiloader is too old." payload. DarkStar-lineage login servers predate TLS entirely
    /// and never complete a handshake. `scripts/login-probe.py` re-runs the test.
    enum Codebase: String, Codable {
        /// TLS completed and the server answered LandSandBoat's own JSON (or its binary result
        /// code, for a world running an older LSB login).
        case landSandBoat
        /// Port open, TLS refused or timed out: the pre-LSB binary login protocol.
        case darkStarLineage
        /// Not probed, or no login host published.
        case unknown
    }

    /// Where a new player signs up for this world, and how signing up actually works there.
    /// Checked 2026-08-21, each against the server's own site or the invite API — several of
    /// these worlds have no web signup at all (the account is typed into the loader console on
    /// first launch, or gated behind a Discord bot), and saying so is more useful than pointing
    /// at a page that cannot create an account.
    var accountURL: String = ""
    /// Short sentence describing the signup route. Shown next to the button, always.
    var accountHow: String = ""
    /// The world's own Discord invite, verified live against discord.com's invite API.
    var discordURL: String = ""
    /// Renderer this world's client needs, when the global choice does not work for it.
    /// nil = use the user's setting. Measured 2026-08-19: Gaia XI's client reaches its title
    /// screen on wined3d/OpenGL but exits about a second after login (Ashita
    /// UninstallAshita(204)) on the DXVK pathway that every other world runs fine, so the
    /// choice has to be per world rather than global.
    var renderer: Renderer? = nil
    /// May this world's client run under the x87 acceleration sidecar? Default yes — it is worth
    /// roughly 2.5x. Measured 2026-08-21: Gaia XI's client logs in and then prints "Closing…"
    /// about a second later under the cooperative x87 wine, and boots to its title screen under
    /// the wrapper's own wine with everything else identical. A world that exits is worth less
    /// than a slow one, so this is per world.
    var x87: Bool = true
    /// May this world's client run with wine's msync fast synchronisation? Default yes.
    /// Measured 2026-08-21 by bisecting the launch environment one variable at a time: Gaia XI's
    /// client logs in and prints "Closing…" a second later with `WINEMSYNC=1`, and boots to its
    /// title screen without it. Everything else in the environment (the x87 sidecar,
    /// DYLD_FALLBACK_LIBRARY_PATH, WINE_LARGE_ADDRESS_AWARE, FFXI_FPS_DIVISOR, the MVK knobs)
    /// was ruled out individually.
    var msync: Bool = true

    /// How a world's client is obtained.
    /// - `clientZip`: a plain archive of the finished client, unpacked straight into `dataPath`.
    ///   No Windows installer runs at all. Several worlds ship their "installer" as a small
    ///   downloader whose only job is to fetch exactly such an archive (ValhallaXI's is a .NET
    ///   WinForms app that downloads `mirror.valhalla.group/ValhallaXI.zip`); going to the
    ///   archive directly skips a GUI that cannot be driven unattended under wine.
    enum InstallKind: String, Codable { case website, installerExe, catseyeLauncher, horizonTorrent, retail, clientZip, none }

    // A hand-written decoder because the synthesised one treats a missing key as an error rather
    // than as "use the default". `servers.json` on disk was written by whichever build the user
    // had before, so every field added since then is missing from it — and a decode failure here
    // throws the file away and silently resets the login hosts they typed in.
    init(name: String, host: String, bootProfile: String, verified: Bool, note: String,
         era: String = "", population: Int = 0, pinned: Bool = false,
         codebase: Codebase = .unknown, retired: Bool = false, local: Bool = false,
         requiredClientURL: String = "", requiredClient: String = "",
         installURL: String = "", installKind: InstallKind = .website, installNote: String = "",
         accountURL: String = "", accountHow: String = "", discordURL: String = "",
         renderer: Renderer? = nil, x87: Bool = true, msync: Bool = true) {
        self.codebase = codebase; self.retired = retired
        self.name = name; self.host = host; self.bootProfile = bootProfile
        self.verified = verified; self.note = note; self.era = era
        self.population = population; self.pinned = pinned; self.local = local
        self.requiredClientURL = requiredClientURL; self.requiredClient = requiredClient
        self.installURL = installURL; self.installKind = installKind; self.installNote = installNote
        self.accountURL = accountURL; self.accountHow = accountHow; self.discordURL = discordURL
        self.renderer = renderer; self.x87 = x87; self.msync = msync
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name        = try c.decode(String.self, forKey: .name)
        host        = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        bootProfile = try c.decodeIfPresent(String.self, forKey: .bootProfile) ?? "horizonxi.ini"
        verified    = try c.decodeIfPresent(Bool.self,   forKey: .verified) ?? false
        note        = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        era         = try c.decodeIfPresent(String.self, forKey: .era) ?? ""
        population  = try c.decodeIfPresent(Int.self,    forKey: .population) ?? 0
        pinned      = try c.decodeIfPresent(Bool.self,   forKey: .pinned) ?? false
        local       = try c.decodeIfPresent(Bool.self,   forKey: .local) ?? false
        requiredClientURL = try c.decodeIfPresent(String.self, forKey: .requiredClientURL) ?? ""
        requiredClient    = try c.decodeIfPresent(String.self, forKey: .requiredClient) ?? ""
        dataPath    = try c.decodeIfPresent(String.self, forKey: .dataPath) ?? ""
        installURL  = try c.decodeIfPresent(String.self, forKey: .installURL) ?? ""
        installKind = try c.decodeIfPresent(InstallKind.self, forKey: .installKind) ?? .website
        accountURL  = try c.decodeIfPresent(String.self, forKey: .accountURL) ?? ""
        accountHow  = try c.decodeIfPresent(String.self, forKey: .accountHow) ?? ""
        retired     = try c.decodeIfPresent(Bool.self, forKey: .retired)
            ?? Server.all.first { $0.name == name }?.retired ?? false
        codebase    = try c.decodeIfPresent(Codebase.self, forKey: .codebase)
            ?? Server.all.first { $0.name == name }?.codebase ?? .unknown
        discordURL  = try c.decodeIfPresent(String.self, forKey: .discordURL) ?? ""
        installNote = try c.decodeIfPresent(String.self, forKey: .installNote) ?? ""
        renderer    = try c.decodeIfPresent(Renderer.self, forKey: .renderer)
        x87         = try c.decodeIfPresent(Bool.self, forKey: .x87) ?? Server.builtins.first { $0.name == name }?.x87 ?? true
        msync       = try c.decodeIfPresent(Bool.self, forKey: .msync) ?? Server.builtins.first { $0.name == name }?.msync ?? true
        // A world the user has not renamed inherits a renderer the project has since measured
        // for it -- otherwise a servers.json written before this field existed keeps launching
        // Gaia XI on the pathway that is known to kill it.
        if renderer == nil, let b = Server.builtins.first(where: { $0.name == name }) {
            renderer = b.renderer
        }
        if installURL.isEmpty, let b = Server.builtins.first(where: { $0.name == name }) {
            installURL = b.installURL; installKind = b.installKind; installNote = b.installNote
        }
        // Signup details were added after most servers.json files on disk were written, so a
        // world the user has not renamed picks them up rather than showing an empty card.
        if accountHow.isEmpty, let b = Server.builtins.first(where: { $0.name == name }) {
            accountURL = b.accountURL; accountHow = b.accountHow; discordURL = b.discordURL
        }
        // Older servers.json files predate the version check; give the built-in entry's values
        // back to a server the user has not renamed, so the check works without a reset.
        if requiredClientURL.isEmpty, requiredClient.isEmpty,
           let b = Server.builtins.first(where: { $0.name == name }) {
            requiredClientURL = b.requiredClientURL; requiredClient = b.requiredClient
        }
    }

    /// Ranking and population from nostalgic.gg's live-tracked FFXI private-server list
    /// (checked 2026-08-13; it tracks nine servers despite its "Top 10" title, hence Local
    /// server standing in as the round tenth). Login hosts below are copied verbatim from each
    /// server's own connect/setup page or wiki — real values, not guesses — but `verified` is
    /// still false for all of them except HorizonXI: published-by-the-server and
    /// tested-by-this-project are different claims, and only the second earns the badge. Two
    /// servers (Gaia XI, Tabula Rasa XI) publish no login host anywhere this project could find;
    /// those stay blank on purpose rather than guessing.
    /// The worlds the launcher offers: **LandSandBoat only**, and still running.
    ///
    /// Daniel's qualification, restated 2026-08-21: LSB is mandatory, because it is the only
    /// FFXI emulator still in development and therefore the only lineage that keeps receiving
    /// content and fixes over time. Population does not override it — Eden is the second-largest
    /// community on this list (835 online when checked) and is still cut, because its login
    /// server is DarkStar-lineage. Which world is which was measured, not assumed: see
    /// `Codebase`, `scripts/login-probe.py`, and docs/CODEBASE.md.
    ///
    /// `retired` is a separate axis: the server itself has stopped (Tabula Rasa XI).
    static var builtins: [Server] {
        all.filter { !$0.retired && $0.codebase == .landSandBoat }
    }

    /// Everything the picker withholds — non-LandSandBoat *or* stopped. Both axes, because a
    /// saved servers.json written before either cut still lists them, and dropping only the
    /// stopped ones (which is what this did until 2026-08-21) left Eden, FFEra and ValhallaXI
    /// alive in `--check` and in an existing install's picker while a fresh one showed six.
    static var retiredWorlds: [Server] {
        let offered = Set(builtins.map(\.name))
        return all.filter { !offered.contains($0.name) }
    }

    static let all: [Server] = [
        Server(name: "HorizonXI", host: "play.horizonxi.com", bootProfile: "horizonxi.ini",
               verified: true,
               note: "The server this project was built and tested against.",
               era: "Treasures of Aht Urhgan · 75 cap", population: 9495, pinned: true, codebase: .landSandBoat,
               installURL: "https://horizonxi.com/play", installKind: .horizonTorrent,
               installNote: "HorizonXI's own client, fetched the way their launcher does it: a 9.4 GB torrent, then their updates. Needs aria2 (brew install aria2).",
               accountURL: "https://horizonxi.com/register",
               accountHow: "Sign up on horizonxi.com, then log in here with that account.",
               discordURL: "https://discord.gg/horizonxi"),
        Server(name: "Local server", host: "127.0.0.1", bootProfile: "lsb.ini",
               verified: true,
               note: "LandSandBoat, built and run on this Mac. Nobody else can reach it.",
               era: "LandSandBoat · your own world", population: 9494, pinned: true, codebase: .landSandBoat,
               local: true,
               accountHow: "Your own world: the loader window offers to create the account the "
                     + "first time you connect. No signup site, and nobody to ask."),
        Server(name: "CatsEyeXI", host: "server.catseyexi.com", bootProfile: "catseyexi.ini",
               verified: false,
               note: "Login host from CatsEyeXI's own connect page. Untested by this project.",
               era: "Custom content · 75 cap", population: 2722, codebase: .landSandBoat,
               // CatsEyeXI's server settings are public; CLIENT_VER there is what its login
               // server enforces (VER_LOCK = 2, "this version or newer"). 30251204_1 as of
               // 2026-08-15. HorizonXI's client was at 30251101_2 that day, which is exactly
               // why logging into CatsEye from a HorizonXI install fails.
               requiredClientURL: "https://raw.githubusercontent.com/CatsAndBoats/catseyexi/base/settings/default/login.lua",
               requiredClient: "30251204_1",
               installURL: "https://catseyexi.com/download", installKind: .catseyeLauncher,
               installNote: "CatsEyeXI's own launcher runs inside the wrapper and installs their client (full FFXI + their DATs, ~27 GB).",
               accountURL: "https://www.catseyexi.com/register",
               accountHow: "Register on catseyexi.com, then create the game account from that "
                     + "site's account page — the website login is not the game login.",
               discordURL: "https://discord.gg/catseyexi"),
        Server(name: "Eden", host: "play.edenxi.com", bootProfile: "eden.ini", verified: false,
               note: "Login host from Eden's own new-player wiki. Untested by this project.",
               era: "Classic · 75 cap", population: 1925, codebase: .darkStarLineage,
               // Eden534.zip on Google Drive (5.8 GB, checked 2026-08-16): a full pre-retail-era
               // client + Ashita + Windower, default C:\Eden, loader Ashita\ffxi-bootmod\xiloader.exe.
               // The bit.ly on their site resolves to this file id; if Eden ships a new build the id
               // changes and this falls back to opening their page.
               installURL: "https://drive.usercontent.google.com/download?id=196Da1f9Wx1Oy8LfDyqlvmJLaRr24n5A7&export=download&confirm=t", installKind: .installerExe,
               installNote: "Eden's own installer (Eden534.zip, 5.8 GB from their Google Drive): full client, Ashita and Windower. It runs inside the wrapper; install into C:\\Games\\Eden.",
               // Eden has no signup page at all: edenxi.com is a news SPA. Their wiki's new-player
               // guide says a registration code comes from their Discord bot (`!getcode`, 7
               // digits, valid 10 minutes) and the account itself is typed into the loader
               // console. Pointing at edenxi.com would be pointing at a page that cannot sign
               // anyone up, so this points at the invite (checked live: guild "Eden").
               accountHow: "No signup page — the account is created in the loader window that "
                     + "opens when you press Play. Eden gates that with a registration code "
                     + "their Discord bot hands out (!getcode: 7 digits, good for 10 minutes).",
               discordURL: "https://discord.gg/S3EAWr2Jec"),
        Server(name: "FFEra", host: "ffera.com", bootProfile: "ffera.ini", verified: false,
               note: "Longest-running 75-cap community server. Login host from FFEra's own "
                     + "wiki. Untested by this project.",
               era: "Wings of the Goddess · 75 cap", population: 218, codebase: .darkStarLineage,
               // FFEraInstaller-Jan2023.zip on Google Drive (5.5 GB): installer + RetailClient pak,
               // default C:\Games\FFEra, stock xiloader. Registration is on their site.
               installURL: "https://drive.usercontent.google.com/download?id=1w2o3XH9jmeFF81kG07TUf8hP7cwo8tuD&export=download&confirm=t", installKind: .installerExe,
               installNote: "FFEra's own installer (5.5 GB from their Google Drive): full client, Ashita and Windower. It runs inside the wrapper; install into C:\\Games\\FFEra. Accounts: ffera.com › Register.",
               accountURL: "https://www.ffera.com/?p=register",
               accountHow: "Register on ffera.com (their Register tab), then log in here.",
               discordURL: "https://discord.gg/v2T95kq"),
        // play.gaiaxi.com verified 2026-08-19: resolves, LSB auth port 54231 open, answers the
        // standard xiloader TLS/JSON login (bad-credential probe returned LOGIN_ERROR).
        Server(name: "Gaia XI", host: "play.gaiaxi.com", bootProfile: "GaiaXI.ini", verified: false,
               note: "Accounts are registered on gaiaxi.com.",
               era: "75 cap", population: 276, codebase: .landSandBoat,
               installURL: "https://gaiaxi.com/account/index.xi?return=downloadzip", installKind: .website,
               installNote: "Gaia XI's launcher zip is behind their site login (register there first). Save it, then Run installer… — their launcher.exe downloads the whole game into C:\\Games\\Gaia XI.",
               accountURL: "https://gaiaxi.com/account/index.xi",
               accountHow: "Register on gaiaxi.com — the same account gates their download and "
                     + "the game login.",
               discordURL: "https://discord.gg/gaiaxi",
               // Their client dies about a second after login on the DXVK pathway and boots on
               // wined3d/OpenGL. Slower, but a slow world beats a world that exits. See
               // docs/SERVERS-WORKLOG.md, 2026-08-19.
               renderer: .openGL, msync: false),
        Server(name: "ValhallaXI", host: "logon.valhalla.group", bootProfile: "valhallaxi.ini",
               verified: false,
               note: "Login host from Valhalla's own connect page (2026-08). Untested by this project.",
               era: "90 cap", population: 216, codebase: .darkStarLineage,
               // Their web installer zip (3.6 MB, 2026r14 as of 2026-08-16); the installer then
               // downloads the client. If this exact file goes away the launcher opens their page.
               // Their web installer is a .NET WinForms downloader; its strings name the file it
               // fetches. Checked 2026-08-21: 7,879,409,522 bytes, no auth, ranges supported.
               // Google Drive mirrors of the same zip: 1LPNOf8rvYRmGlnlaKD9lYvnSG4ygOe9r and
               // 1Y014QyqSTnNQJA7HgjXHDZrsGXudqU_Q.
               installURL: "https://mirror.valhalla.group/ValhallaXI.zip", installKind: .clientZip,
               installNote: "Valhalla's client, straight from their own mirror (a 7.9 GB zip; their web installer only downloads this). Accounts: ucp.valhalla.group.",
               // ucp.valhalla.group is a control panel for an account that already exists (its
               // only form is /login); their connect page documents no web signup, so the
               // account is made in the loader console like other LandSandBoat worlds.
               accountURL: "https://ucp.valhalla.group/",
               accountHow: "No signup page — the account is created in the loader window that "
                     + "opens when you press Play. ucp.valhalla.group then manages it.",
               discordURL: "https://discord.gg/enB8nh3FKp"),
        Server(name: "Supernova", host: "login.supernovaffxi.com", bootProfile: "supernova.ini",
               verified: false,
               note: "Login host from Supernova's own Ashita setup guide. Untested by this "
                     + "project.",
               era: "75 cap", population: 155, codebase: .landSandBoat,
               installURL: "https://supernovaffxi.wordpress.com/get-started-on-supernova/client-installation/", installKind: .retail,
               installNote: "Bring-your-own retail FFXI: Square Enix's free client (7.7 GB, five parts) installs inside the wrapper, then PlayOnline updates it, then Supernova's patch and DATs go on top. Slow (hours) but every step is automated.",
               accountHow: "No signup page — the account is created in the loader window that "
                     + "opens when you press Play, then linked to Discord from their Get "
                     + "Started guide.",
               discordURL: "https://discord.gg/QBBdfQh"),
        Server(name: "OmicronXI", host: "OmicronFFXI.com", bootProfile: "omicronxi.ini",
               verified: false,
               note: "Heavily customized. Login host from Omicron's own wiki. Untested by this "
                     + "project.",
               era: "99 cap", population: 105, codebase: .landSandBoat,
               installURL: "https://omicronxi.fandom.com/wiki/Connecting_to_OmicronXI", installKind: .retail,
               installNote: "Bring-your-own retail FFXI: Square Enix's free client (7.7 GB, five parts) installs inside the wrapper, then PlayOnline updates it, then Ashita + xiloader are added. Slow (hours) but every step is automated.",
               // omicronffxi.com sits behind a Cloudflare challenge this project cannot read,
               // so the wiki's own connect page is the honest destination.
               accountURL: "https://omicronxi.fandom.com/wiki/Connecting_to_OmicronXI",
               accountHow: "Omicron publishes no signup form — their wiki's connect page and "
                     + "their Discord are where new accounts are arranged."),
        Server(name: "Tabula Rasa XI", host: "", bootProfile: "tabularasa.ini", verified: false,
               note: "No login host published anywhere this project could find — get it from "
                     + "their own launcher.",
               era: "75 cap", population: 70, codebase: .unknown, retired: true,
               installKind: .none,
               installNote: "Server appears defunct: site parked and their GitHub last touched 2024-05 (checked 2026-08-16). Kept on the list so an existing install can still be pointed at a host from their Discord.",
               accountHow: "No signup anywhere: tabularasaxi.com is a parked domain (checked "
                     + "2026-08-21). Only an account you already have will work."),
    ]
}

/// The server list, stored next to the app's other state so the user can edit or extend it.
@MainActor
final class ServerStore: ObservableObject {
    @Published var servers: [Server]
    @Published var selectedID: String

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonXI-on-Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("servers.json")
    }

    init() {
        let list: [Server]
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode([Server].self, from: d), !s.isEmpty {
            list = Self.merge(saved: s)
        } else {
            list = Server.builtins
        }
        let saved = UserDefaults.standard.string(forKey: "server.selected")
        servers = list
        selectedID = list.first(where: { $0.name == saved })?.name ?? list.first?.name ?? ""
    }

    /// Keep the user's edited hosts, but pick up servers added to `builtins` in later releases.
    private static func merge(saved: [Server]) -> [Server] {
        // A servers.json written before the LSB-only cut still lists the retired worlds. Drop
        // those by name -- but only ones this project shipped and has since retired, never a
        // server the user added themselves.
        let retiredNames = Set(Server.retiredWorlds.map(\.name))
        var out = saved.filter { !retiredNames.contains($0.name) }
        for b in Server.builtins where !saved.contains(where: { $0.name == b.name }) {
            out.append(b)
        }
        // refresh the ordering metadata, which is ours to curate, not the user's to maintain
        for i in out.indices {
            if let b = Server.builtins.first(where: { $0.name == out[i].name }) {
                out[i].population = b.population
                out[i].pinned = b.pinned
                out[i].era = b.era
                // Not the user's to edit, and an old servers.json predates the flag entirely.
                out[i].local = b.local
                if b.local { out[i].host = b.host }
                // A stored blank host means the user never set one — adopt a host this project
                // has since sourced (Gaia XI shipped blank until 2026-08-19). A user-typed host
                // is never overwritten.
                if out[i].host.isEmpty, !b.host.isEmpty { out[i].host = b.host }
                // How a world's client is fetched is this project's research, refreshed each
                // release (URLs go stale); it is not something the user edits.
                out[i].installURL = b.installURL; out[i].installKind = b.installKind; out[i].installNote = b.installNote
            }
        }
        return out
    }

    /// HorizonXI first because Daniel asked for it; everything else by community size, largest
    /// first — except the local server, which Daniel wants last: it is a tool, not a community,
    /// and its pinned fake population was floating it to second place. Numbers stay out of the UI.
    var ordered: [Server] {
        servers.sorted {
            if $0.local != $1.local { return $1.local }
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.population != $1.population { return $0.population > $1.population }
            return $0.name < $1.name
        }
    }

    var selected: Server? { servers.first { $0.name == selectedID } }

    func select(_ s: Server) {
        selectedID = s.name
        UserDefaults.standard.set(s.name, forKey: "server.selected")
    }

    func update(_ s: Server) {
        if let i = servers.firstIndex(where: { $0.name == s.name }) { servers[i] = s }
        save()
    }

    func add(name: String, host: String, profile: String) {
        guard !name.isEmpty, !servers.contains(where: { $0.name == name }) else { return }
        servers.append(Server(name: name, host: host,
                              bootProfile: profile.isEmpty ? "horizonxi.ini" : profile,
                              verified: false, note: "Added by you.", era: "", population: 0))
        save()
    }

    func remove(_ s: Server) {
        servers.removeAll { $0.name == s.name }
        if selectedID == s.name { selectedID = ordered.first?.name ?? "" }
        save()
    }

    func save() {
        if let d = try? JSONEncoder().encode(servers) { try? d.write(to: Self.url) }
    }
}
