import Foundation
import zlib

/// Streaming zlib inflate from one file to another, 1 MB at a time, each chunk in its own autorelease
/// pool. `raw`: a bare DEFLATE stream (zip members); otherwise a zlib stream with its header
/// (Olympus XI's delta packs). Returns the bytes written; the caller checks their hash.
enum Inflate {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func file(_ src: URL, to dst: URL, raw: Bool = false, limit: Int64 = .max) throws -> Int64 {
        guard let input = try? FileHandle(forReadingFrom: src) else { throw Failure(description: "cannot read \(src.lastPathComponent)") }
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: dst) else { throw Failure(description: "cannot write \(dst.lastPathComponent)") }
        defer { try? output.close() }
        var z = z_stream()
        guard inflateInit2_(&z, raw ? -MAX_WBITS : MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure(description: "inflate could not start")
        }
        defer { inflateEnd(&z) }
        var outBuf = [UInt8](repeating: 0, count: 1 << 20)
        var status = Z_OK, written: Int64 = 0
        while status != Z_STREAM_END {
            guard var chunk = try autoreleasepool(invoking: { try input.read(upToCount: 1 << 20) }), !chunk.isEmpty else { break }
            let count = chunk.count
            try chunk.withUnsafeMutableBytes { (inPtr: UnsafeMutableRawBufferPointer) in
                z.next_in = inPtr.bindMemory(to: Bytef.self).baseAddress
                z.avail_in = uInt(count)
                repeat {
                    let produced: Int = outBuf.withUnsafeMutableBytes { o in
                        z.next_out = o.bindMemory(to: Bytef.self).baseAddress
                        z.avail_out = uInt(o.count)
                        status = inflate(&z, Z_NO_FLUSH)
                        return o.count - Int(z.avail_out)
                    }
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw Failure(description: "\(dst.lastPathComponent) is damaged (inflate \(status))")
                    }
                    if produced > 0 {
                        written += Int64(produced)
                        guard written <= limit else { throw Failure(description: "\(dst.lastPathComponent) is larger than listed") }
                        try output.write(contentsOf: Data(outBuf[0..<produced]))
                    }
                } while z.avail_out == 0 && status != Z_STREAM_END
            }
        }
        guard status == Z_STREAM_END else { throw Failure(description: "\(dst.lastPathComponent) is cut short") }
        return written
    }
}
