import Foundation

/// The managed resources a .NET assembly carries, read straight out of its PE file.
///
/// AscensionXI's loader (`ascensionxi-loader.exe`, their build of LandSandBoat's xiloader) is not
/// published on its own: their launcher carries it as the manifest resource
/// `AscensionXILauncher.loader`, beside its GPL licence and notice, and writes it into
/// `Ashita/bootloader` at every Play (`Core.InstallNativeLoader`). Running their launcher under
/// Wine to get it would mean Wine Mono and a WinForms window; reading the file is enough.
///
/// The layout (ECMA-335 II.24.2.4 and II.25.3.3): the CLI header is data directory 14 of the PE
/// optional header; its `Resources` directory points at one blob holding every resource back to
/// back, each a little-endian UInt32 length followed by that many bytes, each started on an 8-byte
/// boundary from the blob's start (checked against AscensionXI.exe 3.6.0: icon, loader, licence,
/// notice, eleven fonts, in declaration order). Names live in the ManifestResource metadata
/// table; this does not read them -- the loader is recognised by what it is, see `ascensionLoader`.
enum DotNetResources {
    private static func u16(_ d: Data, _ o: Int) -> Int? {
        guard o >= 0, o + 2 <= d.count else { return nil }
        return Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8
    }
    private static func u32(_ d: Data, _ o: Int) -> Int? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        let b = d.startIndex + o
        return Int(d[b]) | Int(d[b + 1]) << 8 | Int(d[b + 2]) << 16 | Int(d[b + 3]) << 24
    }

    /// Every resource blob, in file order. nil when this is not a .NET PE or it is cut short.
    static func blobs(in data: Data) -> [Data]? {
        // Zero-based indices throughout (`subdata` below takes absolute ones).
        let d = data.startIndex == 0 ? data : Data(data)
        guard d.count > 0x40, d.prefix(2) == Data("MZ".utf8), let pe = u32(d, 0x3C),
              d.count > pe + 24, d.subdata(in: pe..<(pe + 4)) == Data([0x50, 0x45, 0, 0]),
              let sections = u16(d, pe + 6), let optSize = u16(d, pe + 20), let magic = u16(d, pe + 24)
        else { return nil }
        let opt = pe + 24
        // PE32 (0x10b) keeps the data directories 96 bytes in, PE32+ (0x20b) 112.
        let dirs = opt + (magic == 0x20B ? 112 : 96)
        guard let cliRVA = u32(d, dirs + 14 * 8), cliRVA != 0 else { return nil }
        var table: [(va: Int, size: Int, raw: Int)] = []
        for n in 0..<sections {
            let s = opt + optSize + n * 40
            guard let vsize = u32(d, s + 8), let va = u32(d, s + 12), let rsize = u32(d, s + 16),
                  let raw = u32(d, s + 20) else { return nil }
            table.append((va, max(vsize, rsize), raw))
        }
        func offset(_ rva: Int) -> Int? {
            table.first { $0.va <= rva && rva < $0.va + $0.size }.map { $0.raw + rva - $0.va }
        }
        guard let cli = offset(cliRVA), let resRVA = u32(d, cli + 24), let resSize = u32(d, cli + 28),
              resRVA != 0, let base = offset(resRVA), base + resSize <= d.count else { return nil }
        var out: [Data] = []
        var at = 0
        while at + 4 <= resSize {
            guard let len = u32(d, base + at), at + 4 + len <= resSize else { return nil }
            out.append(d.subdata(in: (base + at + 4)..<(base + at + 4 + len)))
            at = (at + 4 + len + 7) & ~7
        }
        return out
    }

    /// AscensionXI's loader and the two texts that go beside it.
    struct AscensionLoader { var exe: Data; var license: String; var notice: String }

    /// The one resource that is itself a Windows PE is the loader; the licence is the text that
    /// carries the GNU GPL, the notice the text that names "AscensionXI native loader". Anything
    /// else (two PEs, no licence) means their launcher changed shape: nil, and Play keeps the
    /// stock xiloader their client also ships.
    static func ascensionLoader(in launcher: Data) -> AscensionLoader? {
        guard let all = blobs(in: launcher) else { return nil }
        let pes = all.filter { blobs(in: $0) == nil && isPE($0) }
        let texts = all.compactMap { String(data: $0, encoding: .utf8) }
        guard pes.count == 1,
              let lic = texts.first(where: { $0.contains("GNU GENERAL PUBLIC LICENSE") }),
              let notice = texts.first(where: { $0.contains("AscensionXI native loader") })
        else { return nil }
        return AscensionLoader(exe: pes[0], license: lic, notice: notice)
    }

    /// An executable PE image: "MZ", then "PE\0\0" where e_lfanew says.
    static func isPE(_ data: Data) -> Bool {
        let d = data.startIndex == 0 ? data : Data(data)
        guard d.count > 0x40, d.prefix(2) == Data("MZ".utf8), let pe = u32(d, 0x3C), pe + 4 <= d.count else { return false }
        return d.subdata(in: pe..<(pe + 4)) == Data([0x50, 0x45, 0, 0])
    }
}
