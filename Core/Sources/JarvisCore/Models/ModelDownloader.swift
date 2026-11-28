import Foundation

/// File downloads for `ModelStore`: one `URLSession` download task per file, progress in bytes,
/// HTTPS-only redirects, and a resumed retry when the connection drops mid-file.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        var continuation: CheckedContinuation<Void, Error>
        var destination: URL
        var progress: @Sendable (Int64) -> Void
        var moveError: Error?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    static let attempts = 3

    override init() {
        super.init()
        // Ephemeral: no disk cache for gigabyte files, no cookies.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Release the session (it retains its delegate).
    func finish() { session.finishTasksAndInvalidate() }

    /// Download `url` to `destination`, retrying with resume data after a dropped connection.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var resumeData: Data?
        for attempt in 1...Self.attempts {
            do {
                try await run(url: url, resumeData: resumeData, destination: destination, progress: progress)
                return
            } catch let error as URLError where attempt < Self.attempts && Self.isTransient(error) {
                resumeData = error.downloadTaskResumeData
                Log.models.notice(
                    "download interrupted (\(error.code.rawValue, privacy: .public)), retry \(attempt, privacy: .public)"
                )
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(error.code)
    }

    private func run(
        url: URL, resumeData: Data?, destination: URL, progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(
                        continuation: continuation, destination: destination, progress: progress)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let progress = lock.withLock { pending[downloadTask.taskIdentifier]?.progress }
        progress?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it now.
        guard let destination = lock.withLock({ pending[downloadTask.taskIdentifier]?.destination }) else { return }
        var failure: Error?
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = ModelStoreError.httpStatus(
                http.statusCode, downloadTask.originalRequest?.url?.lastPathComponent ?? "?")
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }
        lock.withLock {
            // Keep an earlier failure (an insecure redirect) rather than the response it produced.
            if pending[downloadTask.taskIdentifier]?.moveError == nil {
                pending[downloadTask.taskIdentifier]?.moveError = failure
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = entry.moveError ?? error {
            entry.continuation.resume(throwing: error)
        } else {
            entry.continuation.resume()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Hugging Face redirects large files to its CDN; never follow a redirect off HTTPS.
        guard request.url?.scheme == "https" else {
            let host = request.url?.host ?? "?"
            lock.withLock { pending[task.taskIdentifier]?.moveError = ModelStoreError.insecureRedirect(host) }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
