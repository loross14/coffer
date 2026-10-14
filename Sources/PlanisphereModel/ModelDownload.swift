import Foundation

public enum ModelDownload {
    /// Downloads into the model folder so the verified file can be moved, not copied, into place.
    /// The caller verifies size and fingerprint with `ModelStore.install(from:move:)`.
    ///
    /// The async `URLSession.download(from:delegate:)` never delivers `didWriteData` to a per-task
    /// delegate, so progress uses a session that owns its delegate. Cancelling the calling task
    /// cancels the download.
    public static func fetch(_ source: URL, into location: ModelLocation,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = location.directory.appendingPathComponent(".download-\(UUID().uuidString).gguf")
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: source)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var last = 0.0

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if fraction - last >= 0.005 || fraction >= 1 { last = fraction; progress(fraction) }
    }

    // The temporary file is deleted when this returns, so it is moved here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            record(.failure(URLError(.badServerResponse))); return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            record(.success(destination))
        } catch { record(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { record(.failure(error)) }
        lock.lock()
        let waiting = continuation, result = outcome ?? .failure(URLError(.unknown))
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    private func record(_ result: Result<URL, Error>) {
        lock.lock(); if outcome == nil { outcome = result }; lock.unlock()
    }
}
