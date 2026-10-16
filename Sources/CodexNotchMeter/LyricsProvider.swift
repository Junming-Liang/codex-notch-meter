#if os(macOS)
import Foundation
import Darwin
import NotchCore

/// No settings access or implicit consent. Retain one instance so cooldowns
/// survive track changes. The controller cancels its lookup Task on disable,
/// consent revocation, sleep, session deactivation, stop and track replacement.
final class LRCLIBLyricsProvider: Sendable {
    private let client = LyricsLookupClient(transport: LRCLIBHTTPTransport())

    func lookup(track: LyricsLookupTrack, consent: Bool) async throws -> LyricsLookupResult {
        try await client.lookup(track: track, consent: consent)
    }
}

/// This adapter is intentionally private: there is no generic URL/session entry
/// point, redirect fallback, search, auth, persistent cache or retry mechanism.
private struct LRCLIBHTTPTransport: LyricsLookupTransport {
    func fetch(_ request: LyricsLookupRequest) async throws -> LyricsLookupResponse {
        try await BoundedLyricsRequest(request: request).run()
    }
}

/// URLSession's data(for:) buffers the complete body before returning. A data
/// delegate instead bounds decoded bytes as they arrive, including responses
/// without Content-Length. All state and callbacks use one serial queue.
private final class BoundedLyricsRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: LyricsLookupRequest
    private let queue = DispatchQueue(label: "org.codexnotchmeter.lyrics.http", qos: .utility)
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var continuation: CheckedContinuation<LyricsLookupResponse, Error>?
    private var response: HTTPURLResponse?
    private var bodyBuffer = LyricsResponseBuffer()
    private var finished = false
    private var terminalError: LyricsLookupError?

    init(request: LyricsLookupRequest) {
        self.request = request
        super.init()
    }

    func run() async throws -> LyricsLookupResponse {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        }, onCancel: {
            self.queue.async { self.finish(.failure(.cancelled)) }
        })
    }

    private func start(_ continuation: CheckedContinuation<LyricsLookupResponse, Error>) {
        guard !finished else {
            continuation.resume(throwing: terminalError ?? LyricsLookupError.cancelled)
            return
        }
        self.continuation = continuation
        guard LRCLIBLookup.isAllowed(url: request.url), request.method == "GET",
              request.timeout == LRCLIBLookup.requestTimeout,
              request.maximumResponseBytes == LRCLIBLookup.maximumResponseBytes else {
            finish(.failure(.requestNotAllowed)); return
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = request.timeout
        config.timeoutIntervalForResource = request.timeout
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: self, delegateQueue: callbacks)
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                    timeoutInterval: request.timeout)
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        task = session?.dataTask(with: urlRequest)
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(.timedOut)) }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + request.timeout, execute: deadline)
        task?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Also reject same-host redirects: consent covers only the reviewed fixed endpoints.
        completionHandler(nil)
        finish(.failure(.requestNotAllowed))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(.requestNotAllowed))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse,
              response.url == request.url, let url = response.url,
              LRCLIBLookup.isAllowed(url: url) else {
            completionHandler(.cancel); finish(.failure(.requestNotAllowed)); return
        }
        self.response = response
        guard !(300...399).contains(response.statusCode) else {
            completionHandler(.cancel); finish(.failure(.requestNotAllowed)); return
        }
        if response.statusCode != 200 {
            // The status and bounded Retry-After are sufficient. Never read or
            // report arbitrary error bodies (including HTML edge responses).
            completionHandler(.cancel)
            finish(.success(makeResponse(response, body: Data())))
            return
        }
        guard response.expectedContentLength <= Int64(request.maximumResponseBytes) else {
            completionHandler(.cancel); finish(.failure(.tooLarge)); return
        }
        guard response.mimeType?.lowercased() == "application/json" else {
            completionHandler(.cancel); finish(.failure(.invalidResponse)); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !finished else { return }
        do { try bodyBuffer.append(chunk) }
        catch { finish(.failure(.tooLarge)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error {
            let failure: LyricsLookupError
            switch (error as? URLError)?.code {
            case .cancelled: failure = .cancelled
            case .timedOut: failure = .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed: failure = .offline
            default: failure = .transportFailure
            }
            finish(.failure(failure))
        } else if let response {
            finish(.success(makeResponse(response, body: bodyBuffer.data)))
        } else {
            finish(.failure(.invalidResponse))
        }
    }

    private func makeResponse(_ response: HTTPURLResponse, body: Data) -> LyricsLookupResponse {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        let boundedRetry = retryAfter.flatMap { $0.utf8.count <= 128 ? $0 : nil }
        return LyricsLookupResponse(url: request.url, statusCode: response.statusCode,
                                    contentType: response.mimeType, retryAfter: boundedRetry, body: body)
    }

    private func finish(_ result: Result<LyricsLookupResponse, LyricsLookupError>) {
        guard !finished else { return }
        finished = true
        if case .failure(let error) = result { terminalError = error }
        deadline?.cancel()
        deadline = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        bodyBuffer = LyricsResponseBuffer()
        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case .success(let response): continuation?.resume(returning: response)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}

/// Use only an explicit file-picker selection. The opened descriptor must be a
/// regular, nonsymlink UTF-8 .lrc/.txt file. No file path/bookmark is persisted.
/// Byte bounds are checked both before and during reads to cover file growth.
/// Regular-file I/O can still block on a mounted/provider-backed filesystem.
/// Do not await this task during shutdown: cancel, retire its generation, and
/// reject late completion. Do not queue a second import while this one is active.
enum LocalLyricsImporter {
    private static let workerSlot = LocalLyricsImportSlot()

    static func load(userSelectedURL url: URL) async throws -> LyricsDocument {
        guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
        guard workerSlot.acquire() else { throw LyricsLookupError.busy }
        let task = Task.detached(priority: .utility) {
            // Cancellation retires a result but cannot force a filesystem driver
            // to return. Hold this slot until the underlying read really ends.
            defer { workerSlot.release() }
            return try readSelectedFile(url)
        }
        return try await withTaskCancellationHandler(operation: {
            let document = try await task.value
            guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
            return document
        }, onCancel: { task.cancel() })
    }

    private static func readSelectedFile(_ url: URL) throws -> LyricsDocument {
        guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
        guard url.isFileURL, (url.host == nil || url.host == "" || url.host == "localhost"),
              !url.path.utf8.contains(0), ["lrc", "txt"].contains(url.pathExtension.lowercased()) else {
            throw LyricsLookupError.unsupportedFile
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw LyricsLookupError.fileUnavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw LyricsLookupError.unsupportedFile
        }
        let limit = LRCParser.maximumInputBytes
        guard info.st_size <= Int64(limit) else { throw LyricsLookupError.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
            let remaining = min(buffer.count, limit + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, remaining)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw LyricsLookupError.fileUnavailable
            }
            guard data.count + count <= limit else { throw LyricsLookupError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard !Task.isCancelled else { throw LyricsLookupError.cancelled }
        return try LyricsLocalImport.parse(data: data)
    }
}

/// One actual worker, including cancelled/stuck reads, with no waiting queue.
private final class LocalLyricsImportSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false

    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !occupied else { return false }
        occupied = true
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        occupied = false
    }
}
#endif
