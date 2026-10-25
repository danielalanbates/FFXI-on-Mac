import Foundation

/// One large download written straight to its file, where it is going, and resumed from where it
/// stopped. URLSession's own download tasks write to the system temporary folder first, which is on
/// the Mac's internal disk: a 5 GB archive for an external drive must not pass through it.
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// LocalizedError too, so a catch that only has `localizedDescription` prints this text.
    struct Failure: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }

    private let dest: URL
    private let progress: (Int64, Int64) -> Void
    private var handle: FileHandle?
    private var have: Int64 = 0
    private var total: Int64 = 0
    private var failure: Error?
    private let done = DispatchSemaphore(value: 0)
    /// Beside `dest`: what names the copy its bytes came from (the 200's ETag, else Last-Modified).
    /// A resume sends it as If-Range, so a file changed on the server comes back whole (200) instead
    /// of its tail being joined onto the old start.
    private var validatorURL: URL { URL(fileURLWithPath: dest.path + ".validator") }

    private init(dest: URL, progress: @escaping (Int64, Int64) -> Void) {
        self.dest = dest; self.progress = progress
    }

    /// `url` into `dest`. A partial `dest` from an earlier try is continued with a Range request (a
    /// server that answers 200 instead starts it again; one that answers from anywhere but where it
    /// stopped empties it, and the next try starts again). Returns once the file is complete.
    static func run(_ url: URL, to dest: URL, userAgent: String = "FFXI-on-Mac", stop: StopFlag,
                    progress: @escaping (Int64, Int64) -> Void = { _, _ in }) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: dest.path) { fm.createFile(atPath: dest.path, contents: nil) }
        let d = FileDownload(dest: dest, progress: progress)
        d.have = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 120
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: c, delegate: d, delegateQueue: q)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if d.have > 0 {
            req.setValue("bytes=\(d.have)-", forHTTPHeaderField: "Range")
            if let v = try? String(contentsOf: d.validatorURL, encoding: .utf8), !v.isEmpty { req.setValue(v, forHTTPHeaderField: "If-Range") }
        }
        let task = session.dataTask(with: req)
        task.resume()
        while d.done.wait(timeout: .now() + 0.5) == .timedOut { if stop.raised { task.cancel() } }
        try? d.handle?.close()
        if stop.raised { throw Failure(description: "Stopped. Press the button again to carry on; the download continues where it stopped.") }
        if let f = d.failure { throw f }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let h = response as? HTTPURLResponse else { failure = Failure(description: "no HTTP answer"); completionHandler(.cancel); return }
        let range = h.value(forHTTPHeaderField: "Content-Range") ?? ""
        do {
            switch h.statusCode {
            case 206:
                // The rest of this file only, from its last byte on: bytes from anywhere else would
                // make a file that is neither copy.
                guard range.hasPrefix("bytes \(have)-") else {
                    startAgain("resumed download did not continue where it stopped; starting again")
                    completionHandler(.cancel); return
                }
                handle = try FileHandle(forWritingTo: dest); try handle?.seekToEnd()
                total = have + max(h.expectedContentLength, 0)
            case 200:
                // A fresh copy: whatever was there is replaced, and this copy's validator kept for a resume
                // (a weak ETag is not one If-Range may carry).
                handle = try FileHandle(forWritingTo: dest); try handle?.truncate(atOffset: 0)
                have = 0; total = max(h.expectedContentLength, 0)
                try? FileManager.default.removeItem(at: validatorURL)
                let etag = h.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
                if let v = etag ?? h.value(forHTTPHeaderField: "Last-Modified") { try? Data(v.utf8).write(to: validatorURL, options: .atomic) }
            case 416:
                // Nothing left to send: the file is already whole, when the server's size
                // ("bytes */N") is the size here. Anything else, and this is not their file.
                if range.hasPrefix("bytes */"), Int64(range.dropFirst("bytes */".count)) == have { completionHandler(.cancel); return }
                startAgain("resumed download did not match the server's copy; starting again")
                completionHandler(.cancel); return
            default:
                failure = Failure(description: "HTTP \(h.statusCode) for \(h.url?.host ?? "the download")")
                completionHandler(.cancel); return
            }
        } catch { failure = error; completionHandler(.cancel); return }
        completionHandler(.allow)
    }

    /// The partial file is not the start of the server's copy: emptied, its validator with it, so the
    /// next try fetches the file whole.
    private func startAgain(_ why: String) {
        if let h = try? FileHandle(forWritingTo: dest) { try? h.truncate(atOffset: 0); try? h.close() }
        try? FileManager.default.removeItem(at: validatorURL)
        have = 0
        failure = Failure(description: why)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { failure = error; dataTask.cancel(); return }
        have += Int64(data.count)
        progress(have, total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as? URLError, e.code == .cancelled { } else if let error, failure == nil { failure = error }
        done.signal()
    }
}
