import Foundation

/// One large download written straight to its file, where it is going, and resumed from where it
/// stopped. URLSession's own download tasks write to the system temporary folder first, which is on
/// the Mac's internal disk: a 5 GB archive for an external drive must not pass through it.
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private let dest: URL
    private let progress: (Int64, Int64) -> Void
    private var handle: FileHandle?
    private var have: Int64 = 0
    private var total: Int64 = 0
    private var failure: Error?
    private let done = DispatchSemaphore(value: 0)

    private init(dest: URL, progress: @escaping (Int64, Int64) -> Void) {
        self.dest = dest; self.progress = progress
    }

    /// `url` into `dest`. A partial `dest` from an earlier try is continued with a Range request (a
    /// server that answers 200 instead starts it again). Returns once the file is complete.
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
        if d.have > 0 { req.setValue("bytes=\(d.have)-", forHTTPHeaderField: "Range") }
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
        do {
            switch h.statusCode {
            case 206:
                handle = try FileHandle(forWritingTo: dest); try handle?.seekToEnd()
                total = have + max(h.expectedContentLength, 0)
            case 200:
                // A fresh copy: whatever was there is replaced.
                handle = try FileHandle(forWritingTo: dest); try handle?.truncate(atOffset: 0)
                have = 0; total = max(h.expectedContentLength, 0)
            case 416:
                // Nothing left to send: the file is already whole.
                completionHandler(.cancel); return
            default:
                failure = Failure(description: "HTTP \(h.statusCode) for \(h.url?.host ?? "the download")")
                completionHandler(.cancel); return
            }
        } catch { failure = error; completionHandler(.cancel); return }
        completionHandler(.allow)
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
