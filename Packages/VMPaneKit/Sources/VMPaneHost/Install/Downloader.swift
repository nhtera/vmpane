import CryptoKit
import Foundation

public enum DownloadError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case checksumMismatch(expected: String, actual: String)
    case insecureURL
    /// The transfer ended early; the partial file is kept and the next call resumes it.
    case incomplete(received: Int64, expected: Int64)
}

/// Large-file downloads (IPSWs, ISOs) that survive interruption: data goes to `<file>.partial`, a later
/// call resumes it with an HTTP `Range` request, and the result is checked against its SHA-256 before it
/// is moved into place.
public enum Downloader {
    /// Downloads `url` to `destination`, resuming a previous partial download. `progress` gets (bytes, total).
    public static func download(
        _ url: URL, to destination: URL, sha256 expected: String, session: URLSession = .shared,
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> URL {
        guard url.scheme == "https" else { throw DownloadError.insecureURL }
        let partial = destination.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let have = Int64((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0)
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

        let writer = try PartialFileWriter(file: partial, progress: progress)
        let delegate = StreamingDelegate(writer: writer, resumeFrom: have)
        try await delegate.run(request, session: session)

        let actual = try sha256(of: partial)
        guard actual == expected.lowercased() else {
            try? FileManager.default.removeItem(at: partial)
            throw DownloadError.checksumMismatch(expected: expected, actual: actual)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    /// SHA-256 (hex) of a file, read in 8 MiB chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Appends received data to the partial file.
private final class PartialFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let progress: @Sendable (Int64, Int64?) -> Void
    private(set) var written: Int64 = 0
    var total: Int64?

    init(file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) throws {
        handle = try FileHandle(forWritingTo: file)
        self.progress = progress
    }

    /// Starts over (the server ignored the Range request) or continues at the end.
    func prepare(restart: Bool, offset: Int64) throws {
        if restart {
            try handle.truncate(atOffset: 0)
            written = 0
        } else {
            try handle.seekToEnd()
            written = offset
        }
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        written += Int64(data.count)
        progress(written, total)
    }

    func finish() throws {
        try handle.synchronize()
        try handle.close()
    }
}

/// Bridges a URLSession data task (delegate callbacks, data in chunks) to async/await.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let writer: PartialFileWriter
    private let resumeFrom: Int64
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(writer: PartialFileWriter, resumeFrom: Int64) {
        self.writer = writer
        self.resumeFrom = resumeFrom
    }

    func run(_ request: URLRequest, session: URLSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let task = session.dataTask(with: request)
            task.delegate = self
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        do {
            switch status {
            case 206:
                try writer.prepare(restart: false, offset: resumeFrom)
                writer.total = response.expectedContentLength > 0 ? resumeFrom + response.expectedContentLength : nil
            case 200:
                try writer.prepare(restart: true, offset: 0)
                writer.total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            case 416 where resumeFrom > 0:
                // Already complete: the checksum decides.
                try writer.prepare(restart: false, offset: resumeFrom)
                completionHandler(.cancel)
                return
            default:
                throw DownloadError.httpStatus(status)
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try writer.append(data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var finishError: Error? = (try? writer.finish()) == nil ? CocoaError(.fileWriteUnknown) : nil
        if error == nil, failure == nil, let total = writer.total, writer.written < total {
            finishError = DownloadError.incomplete(received: writer.written, expected: total)
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error, (error as? URLError)?.code != .cancelled {
            continuation?.resume(throwing: error)
        } else if let finishError {
            continuation?.resume(throwing: finishError)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
