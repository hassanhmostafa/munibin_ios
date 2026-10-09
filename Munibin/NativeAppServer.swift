import Foundation
import Network
import zlib

/// Hosts the packaged Munibin frontend on a loopback-only HTTP origin and
/// transparently proxies backend-dependent routes to the production backend.
///
/// Why a loopback HTTP origin instead of file://:
/// - fetch()/tRPC keep same-origin semantics
/// - secure-context browser APIs continue to work on loopback origins
/// - cookies stay inside the native proxy rather than becoming third-party cookies
/// - SPA routes and streaming API responses continue to behave like the web build
final class NativeAppServer {
    static let shared = NativeAppServer()

    private let queue = DispatchQueue(label: "com.motoonai.native-http", qos: .userInitiated)
    // Keep disk reads/inflation away from Network.framework's callback queue.
    // Separate bounded pools prevent a cold, multi-megabyte text asset from
    // sitting in front of the tiny page JSON needed by the next Quran swipe.
    private let assetReadQueue: OperationQueue = {
        let operations = OperationQueue()
        operations.name = "com.motoonai.native-http.assets"
        operations.qualityOfService = .userInitiated
        operations.maxConcurrentOperationCount = 3
        return operations
    }()
    private let largeAssetReadQueue: OperationQueue = {
        let operations = OperationQueue()
        operations.name = "com.motoonai.native-http.large-assets"
        operations.qualityOfService = .userInitiated
        operations.maxConcurrentOperationCount = 1
        return operations
    }()
    private let decodedAssetCacheLock = NSLock()
    private var decodedAssetCache: [URL: Data] = [:]
    private var decodedAssetCacheOrder: [URL] = []
    private var decodedAssetCacheBytes = 0
    private let decodedAssetCacheByteLimit = 16 * 1024 * 1024
    private let decodedAssetCacheEntryLimit = 128
    private let decodedAssetCacheFileLimit = 8 * 1024 * 1024
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var listener: NWListener?
    private var pendingStarts: [(Result<URL, Error>) -> Void] = []
    // Keep this stable: Cache Storage, IndexedDB, localStorage and Service Worker
    // registration are keyed by scheme + host + port.
    private let localPort = NWEndpoint.Port(rawValue: 49321)!

    private(set) var baseURL: URL?
    let backendURL = URL(string: "https://munibin.com")!
    private let quranReciterOfflinePlaybackPath = "/__quran-reciter-offline-audio"
    // Dynamic admin data: bypass the packaged build-time seed so add/edit/delete
    // changes can reach the device. The Service Worker/local catalog provides the
    // last-known-good offline fallback after a successful online sync.
    private let quranReciterCatalogPath = "/api/quran/reciters"
    // Old bundled Service Workers pass /api/* through instead of answering from the
    // app-shell cache. That makes this same-origin path a reliable escape hatch when
    // a previous release has cached an old index.html.
    private let shellResetPath = "/api/__native-shell-reset-v196"
    // URLSession persists ordinary cookies, but session cookies can disappear across
    // an app update/process replacement. Persist the trusted backend cookie jar
    // explicitly so the active login and the server-side saved-account device
    // session survive updates as well.
    private let backendCookieDefaultsKey = "munibin.backend.cookies.v1"

    private init() {
        restorePersistedBackendCookies()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self] in self?.clearDecodedAssetCache() }
        pressure.resume()
        memoryPressureSource = pressure
    }

    private func restorePersistedBackendCookies() {
        guard let records = UserDefaults.standard.array(forKey: backendCookieDefaultsKey) as? [[String: Any]] else { return }
        for record in records {
            guard let name = record["name"] as? String, !name.isEmpty,
                  let value = record["value"] as? String else { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: (record["domain"] as? String) ?? (backendURL.host ?? "munibin.com"),
                .path: (record["path"] as? String) ?? "/",
            ]
            if (record["secure"] as? Bool) == true { properties[.secure] = "TRUE" }
            if let expires = record["expires"] as? Date { properties[.expires] = expires }
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    private func persistBackendCookies() {
        let cookies = HTTPCookieStorage.shared.cookies(for: backendURL) ?? []
        let records: [[String: Any]] = cookies.map { cookie in
            var record: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": cookie.isSecure,
            ]
            if let expires = cookie.expiresDate { record["expires"] = expires }
            return record
        }
        UserDefaults.standard.set(records, forKey: backendCookieDefaultsKey)
    }

    enum ServerError: LocalizedError {
        case invalidPort
        case missingFrontend
        case malformedRequest
        case unsupportedTransferEncoding

        var errorDescription: String? {
            switch self {
            case .invalidPort: return "تعذر إنشاء منفذ محلي للتطبيق"
            case .missingFrontend: return "حزمة واجهة منيبين غير موجودة داخل التطبيق"
            case .malformedRequest: return "طلب محلي غير صالح"
            case .unsupportedTransferEncoding: return "صيغة رفع غير مدعومة"
            }
        }
    }

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            if let baseURL = self.baseURL {
                DispatchQueue.main.async { completion(.success(baseURL)) }
                return
            }

            self.pendingStarts.append(completion)
            guard self.listener == nil else { return }

            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                // Keep the HTTP origin private to this app process/device.
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: self.localPort)

                let listener = try NWListener(using: parameters)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener else { return }
                    // Ignore terminal callbacks from an older listener that was
                    // deliberately replaced after returning from the background.
                    guard self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port,
                              let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
                            self.baseURL = nil
                            self.finishStarts(.failure(ServerError.invalidPort))
                            return
                        }
                        self.baseURL = url
                        self.finishStarts(.success(url))
                    case .failed(let error):
                        listener.cancel()
                        self.listener = nil
                        self.baseURL = nil
                        self.finishStarts(.failure(error))
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: self.queue)
            } catch {
                self.listener = nil
                self.finishStarts(.failure(error))
            }
        }
    }

    /// iOS can suspend the loopback NWListener while the app sleeps even though
    /// the WKWebView itself survives. Re-create the listener on the same stable
    /// port when the scene returns so API calls and Quran download proxy requests
    /// do not inherit a stale server object. The origin stays identical, so
    /// localStorage / IndexedDB / Cache Storage / Service Worker data are kept.
    func restartForForeground(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            if let listener = self.listener {
                // Prevent a delayed .failed callback from this old listener from
                // cancelling the replacement listener after it has started.
                listener.stateUpdateHandler = nil
                listener.cancel()
            }
            self.listener = nil
            self.baseURL = nil

            // Give Network.framework one run-loop turn to release the bound
            // socket. allowLocalEndpointReuse keeps the stable port reusable.
            self.queue.asyncAfter(deadline: .now() + 0.05) {
                self.start(completion: completion)
            }
        }
    }

    private func finishStarts(_ result: Result<URL, Error>) {
        let callbacks = pendingStarts
        pendingStarts.removeAll()
        DispatchQueue.main.async {
            callbacks.forEach { $0(result) }
        }
    }

    /// Maps a public Munibin URL/deep link to the locally hosted frontend.
    func localURL(for externalURL: URL?) -> URL? {
        guard let baseURL else { return nil }
        guard let externalURL else { return baseURL.appendingPathComponent("") }

        if externalURL.host == "127.0.0.1" || externalURL.host == "localhost" {
            return externalURL
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let source = URLComponents(url: externalURL, resolvingAgainstBaseURL: false)
        let encodedPath = source?.percentEncodedPath ?? ""
        components?.percentEncodedPath = encodedPath.isEmpty ? "/" : encodedPath
        components?.percentEncodedQuery = source?.percentEncodedQuery
        components?.percentEncodedFragment = source?.percentEncodedFragment
        return components?.url
    }

    func localURL(path: String) -> URL? {
        guard let external = URL(string: path, relativeTo: backendURL)?.absoluteURL else { return baseURL }
        return localURL(for: external)
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var next = buffer
            if let data { next.append(data) }

            if let parsed = self.parseRequestIfComplete(next) {
                switch parsed {
                case .success(let request):
                    self.handle(request, connection: connection)
                case .failure(let error):
                    self.sendText(connection, status: 400, text: error.localizedDescription)
                }
                return
            }

            if isComplete {
                self.sendText(connection, status: 400, text: ServerError.malformedRequest.localizedDescription)
                return
            }

            if next.count > 64 * 1024 * 1024 {
                self.sendText(connection, status: 413, text: "Request too large")
                return
            }

            self.receiveRequest(on: connection, buffer: next)
        }
    }

    private struct HTTPRequest {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data
    }

    /// Returns nil while more bytes are required.
    private func parseRequestIfComplete(_ data: Data) -> Result<HTTPRequest, Error>? {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: separator) else { return nil }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(ServerError.malformedRequest)
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .failure(ServerError.malformedRequest) }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return .failure(ServerError.malformedRequest) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            let encoded = data.subdata(in: bodyStart..<data.count)
            guard let decoded = parseChunkedBodyIfComplete(encoded) else { return nil }
            switch decoded {
            case .success(let value): body = value
            case .failure(let error): return .failure(error)
            }
        } else {
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            guard contentLength >= 0, contentLength <= 64 * 1024 * 1024 else {
                return .failure(ServerError.malformedRequest)
            }
            guard data.count >= bodyStart + contentLength else { return nil }
            body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        }

        return .success(HTTPRequest(method: parts[0], target: parts[1], headers: headers, body: body))
    }

    /// Decodes a complete HTTP/1.1 chunked request body. Returns nil while more
    /// bytes are required so uploads/streaming POSTs are not truncated.
    private func parseChunkedBodyIfComplete(_ data: Data) -> Result<Data, Error>? {
        let crlf = Data([13, 10])
        var cursor = data.startIndex
        var decoded = Data()

        while true {
            guard let lineRange = data.range(of: crlf, in: cursor..<data.endIndex) else { return nil }
            let lineData = data.subdata(in: cursor..<lineRange.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8) else {
                return .failure(ServerError.malformedRequest)
            }
            let sizeToken = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let chunkSize = Int(sizeToken.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16), chunkSize >= 0 else {
                return .failure(ServerError.malformedRequest)
            }
            cursor = lineRange.upperBound

            if chunkSize == 0 {
                // Consume optional trailer headers until the empty terminating line.
                while true {
                    guard let trailerRange = data.range(of: crlf, in: cursor..<data.endIndex) else { return nil }
                    if trailerRange.lowerBound == cursor {
                        return .success(decoded)
                    }
                    cursor = trailerRange.upperBound
                }
            }

            guard decoded.count + chunkSize <= 64 * 1024 * 1024 else {
                return .failure(ServerError.malformedRequest)
            }
            guard data.distance(from: cursor, to: data.endIndex) >= chunkSize + 2 else { return nil }
            let chunkEnd = data.index(cursor, offsetBy: chunkSize)
            decoded.append(data.subdata(in: cursor..<chunkEnd))
            let terminatorEnd = data.index(chunkEnd, offsetBy: 2)
            guard data.subdata(in: chunkEnd..<terminatorEnd) == crlf else {
                return .failure(ServerError.malformedRequest)
            }
            cursor = terminatorEnd
        }
    }

    private func handle(_ request: HTTPRequest, connection: NWConnection) {
        guard let requestURL = URL(string: request.target, relativeTo: baseURL)?.absoluteURL else {
            sendText(connection, status: 400, text: "Invalid URL")
            return
        }

        let path = requestURL.path

        // Escape a stale Service Worker shell before generic /api proxy handling.
        if (request.method == "GET" || request.method == "HEAD"), path == shellResetPath {
            serveShellReset(request, connection: connection)
            return
        }

        // The App Store build owns its Service Worker. Never depend on the website
        // to provide it, otherwise a first launch without Internet cannot become offline-ready.
        if isServiceWorkerPath(path) {
            serveBundledFile(request, relativePath: "sw.js", immutable: false, connection: connection)
            return
        }

        // The Service Worker normally owns this synthetic playback URL. On the first
        // native launch it may not control the page yet, so proxy the online audio
        // source rather than serving index.html as if it were an audio file.
        if (request.method == "GET" || request.method == "HEAD"), path == quranReciterOfflinePlaybackPath {
            proxyExternalAudio(request, requestURL: requestURL, connection: connection)
            return
        }

        // Build-time seed for resources the web PWA intentionally keeps offline.
        // When present, these exact API/storage paths are served from the app bundle.
        if (request.method == "GET" || request.method == "HEAD"), isBackendPath(path), path != quranReciterCatalogPath, let seedPath = offlineSeedPath(for: path), bundledFileExists(relativePath: seedPath) {
            serveBundledFile(request, relativePath: seedPath, immutable: true, connection: connection)
            return
        }

        if isBackendPath(path) {
            proxy(request, requestURL: requestURL, connection: connection)
            return
        }

        if request.method != "GET" && request.method != "HEAD" {
            sendText(connection, status: 405, text: "Method Not Allowed")
            return
        }

        serveFrontend(request, requestURL: requestURL, connection: connection)
    }


    private func serveShellReset(_ request: HTTPRequest, connection: NWConnection) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;background:#fdf8f0}</style></head><body><script>
        (async()=>{const u=new URL(location.href);const next=u.searchParams.get('next')||'/';
        try{if('serviceWorker'in navigator){const rs=await navigator.serviceWorker.getRegistrations();await Promise.all(rs.map(r=>r.unregister()));}}catch(e){}
        try{if('caches'in window){const ks=await caches.keys();await Promise.all(ks.filter(k=>/^munibin-v/.test(k)).map(k=>caches.delete(k)));}}catch(e){}
        location.replace(next);})();
        </script></body></html>
        """
        let data = Data(html.utf8)
        sendHead(connection, status: 200, headers: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store, no-cache, must-revalidate",
        ]) { [weak self] in
            guard let self else { return }
            if request.method == "HEAD" { connection.cancel() }
            else { self.sendBodyAndClose(connection, data: data) }
        }
    }

    private func isBackendPath(_ path: String) -> Bool {
        path == "/api" || path.hasPrefix("/api/") || path.hasPrefix("/manus-storage/")
    }

    private func isServiceWorkerPath(_ path: String) -> Bool {
        if path == "/sw.js" || path == "/api/pwa-worker.js" { return true }
        return path.range(of: #"^/api/pwa-worker-v[^/]+\.js$"#, options: .regularExpression) != nil
    }

    private func offlineSeedPath(for path: String) -> String? {
        let clean = path
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .map(String.init)
            .joined(separator: "/")
        return clean.isEmpty ? nil : "native-offline/\(clean)"
    }

    private func bundledFileURL(relativePath: String) -> URL? {
        guard let www = Bundle.main.url(forResource: "www", withExtension: nil) else { return nil }
        return resolvedBundledFile(at: www.appendingPathComponent(relativePath))
    }

    private func bundledFileExists(relativePath: String) -> Bool {
        return bundledFileURL(relativePath: relativePath) != nil
    }

    // v360: large text assets are stored once as gzip, while every public URL,
    // MIME type and response body stays unchanged. Decode in native code so this
    // also works in older WebViews and cached/offline fetches without JS codecs.
    private func resolvedBundledFile(at logicalURL: URL) -> URL? {
        let compressedURL = logicalURL.appendingPathExtension("gz")
        if cachedDecodedAsset(at: compressedURL) != nil { return compressedURL }
        for url in [logicalURL, compressedURL] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    private func readBundledFile(at url: URL) -> Data? {
        let compressed = url.pathExtension.lowercased() == "gz"
        if compressed, let cached = cachedDecodedAsset(at: url) { return cached }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard compressed else { return data }
        guard !data.isEmpty, data.count <= Int(UInt32.max) else { return nil }

        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let decoded = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data? in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var decoded = Data()
            var chunk = [UInt8](repeating: 0, count: 32 * 1024)
            var status: Int32 = Z_OK
            repeat {
                var produced = 0
                status = chunk.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int32 in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    produced = buffer.count - Int(stream.avail_out)
                    return result
                }
                guard status == Z_OK || status == Z_STREAM_END,
                      decoded.count + produced <= 128 * 1024 * 1024 else { return nil }
                decoded.append(contentsOf: chunk.prefix(produced))
                if status == Z_OK, produced == 0, stream.avail_in == 0 { return nil }
            } while status == Z_OK
            // inflate checks the gzip CRC and declared size before STREAM_END.
            guard status == Z_STREAM_END, stream.avail_in == 0 else { return nil }
            return decoded
        }
        if let decoded { cacheDecodedAsset(decoded, at: url) }
        return decoded
    }

    private func cachedDecodedAsset(at url: URL) -> Data? {
        decodedAssetCacheLock.lock()
        defer { decodedAssetCacheLock.unlock() }
        guard let data = decodedAssetCache[url] else { return nil }
        decodedAssetCacheOrder.removeAll { $0 == url }
        decodedAssetCacheOrder.append(url)
        return data
    }

    private func cacheDecodedAsset(_ data: Data, at url: URL) {
        // Fonts remain WOFF2 and are never held here. In particular, do not let
        // the 20 MB mutoon script displace the reader's small hot working set.
        guard data.count <= decodedAssetCacheFileLimit else { return }
        decodedAssetCacheLock.lock()
        defer { decodedAssetCacheLock.unlock() }
        if let previous = decodedAssetCache.removeValue(forKey: url) {
            decodedAssetCacheBytes -= previous.count
            decodedAssetCacheOrder.removeAll { $0 == url }
        }
        while decodedAssetCacheBytes + data.count > decodedAssetCacheByteLimit
                || decodedAssetCacheOrder.count >= decodedAssetCacheEntryLimit {
            guard !decodedAssetCacheOrder.isEmpty else { break }
            let oldest = decodedAssetCacheOrder.removeFirst()
            if let previous = decodedAssetCache.removeValue(forKey: oldest) {
                decodedAssetCacheBytes -= previous.count
            }
        }
        decodedAssetCache[url] = data
        decodedAssetCacheOrder.append(url)
        decodedAssetCacheBytes += data.count
    }

    private func clearDecodedAssetCache() {
        decodedAssetCacheLock.lock()
        defer { decodedAssetCacheLock.unlock() }
        decodedAssetCache.removeAll()
        decodedAssetCacheOrder.removeAll()
        decodedAssetCacheBytes = 0
    }

    private func readBundledFileInBackground(at url: URL, completion: @escaping (Data?) -> Void) {
        if url.pathExtension.lowercased() == "gz", let cached = cachedDecodedAsset(at: url) {
            completion(cached)
            return
        }
        // Classification only stats the compressed file; no eager decompression
        // or scanning of the Quran/tafsir/font collections is performed.
        let storedBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        let large = url.pathExtension.lowercased() == "gz" && (storedBytes?.intValue ?? 0) > 256 * 1024
        let operations = large ? largeAssetReadQueue : assetReadQueue
        operations.addOperation { [weak self] in
            guard let self else { return }
            let data = self.readBundledFile(at: url)
            self.queue.async { completion(data) }
        }
    }

    private func serveBundledFile(_ request: HTTPRequest, relativePath: String, immutable: Bool, connection: NWConnection) {
        guard let selected = bundledFileURL(relativePath: relativePath) else {
            sendText(connection, status: 404, text: "Not Found")
            return
        }
        readBundledFileInBackground(at: selected) { [weak self] data in
            guard let self else { return }
            guard let data else {
                self.sendText(connection, status: 404, text: "Not Found")
                return
            }
            self.sendHead(connection, status: 200, headers: [
                "Content-Type": self.mimeType(for: (relativePath as NSString).pathExtension.lowercased()),
                "Cache-Control": immutable ? "public, max-age=31536000, immutable" : "no-cache",
                "Content-Length": "\(data.count)",
            ]) { [weak self] in
                guard let self else { return }
                if request.method == "HEAD" { connection.cancel() }
                else { self.sendBodyAndClose(connection, data: data) }
            }
        }
    }

    // MARK: - Bundled frontend

    private func serveFrontend(_ request: HTTPRequest, requestURL: URL, connection: NWConnection) {
        guard let www = Bundle.main.url(forResource: "www", withExtension: nil) else {
            sendText(connection, status: 503, text: ServerError.missingFrontend.localizedDescription)
            return
        }

        let requestedPath = requestURL.path.removingPercentEncoding ?? requestURL.path
        let clean = requestedPath
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .map(String.init)
            .joined(separator: "/")

        let candidate = www.appendingPathComponent(clean.isEmpty ? "index.html" : clean)
        let exists = resolvedBundledFile(at: candidate) != nil

        let acceptsHTML = request.headers["accept"]?.contains("text/html") == true
        let hasExtension = !(clean as NSString).pathExtension.isEmpty
        let logicalURL = exists ? candidate : ((!hasExtension || acceptsHTML) ? www.appendingPathComponent("index.html") : candidate)

        guard let selected = resolvedBundledFile(at: logicalURL) else {
            sendText(connection, status: 404, text: "Not Found")
            return
        }
        let ext = logicalURL.pathExtension.lowercased()
        let shouldRevalidate = logicalURL.lastPathComponent == "index.html" || ext == "html" || ext == "js" || ext == "css"
        readBundledFileInBackground(at: selected) { [weak self] data in
            guard let self else { return }
            guard let data else {
                self.sendText(connection, status: 404, text: "Not Found")
                return
            }
            self.sendHead(connection, status: 200, headers: [
                "Content-Type": self.mimeType(for: ext),
                "Cache-Control": shouldRevalidate ? "no-cache" : "public, max-age=31536000, immutable",
                "Content-Length": "\(data.count)",
            ]) { [weak self] in
                guard let self else { return }
                if request.method == "HEAD" { connection.cancel() }
                else { self.sendBodyAndClose(connection, data: data) }
            }
        }
    }

    private func mimeType(for ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "caf": return "audio/x-caf"
        case "txt": return "text/plain; charset=utf-8"
        case "xml": return "application/xml; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Backend proxy

    private func proxy(_ request: HTTPRequest, requestURL: URL, connection: NWConnection) {
        guard var components = URLComponents(url: backendURL, resolvingAgainstBaseURL: false) else {
            sendText(connection, status: 502, text: "Invalid backend URL")
            return
        }
        // URL.query already contains escapes. Assigning it to `query` escapes `%`
        // again, so tRPC receives "%7B..." instead of its JSON input object.
        let source = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        components.percentEncodedPath = source?.percentEncodedPath ?? requestURL.path
        components.percentEncodedQuery = source?.percentEncodedQuery
        guard let remoteURL = components.url else {
            sendText(connection, status: 502, text: "Invalid backend request")
            return
        }

        var upstream = URLRequest(url: remoteURL)
        upstream.httpMethod = request.method
        if !request.body.isEmpty { upstream.httpBody = request.body }
        upstream.timeoutInterval = 120

        let excluded = Set(["host", "origin", "referer", "cookie", "connection", "content-length", "transfer-encoding", "accept-encoding"])
        for (name, value) in request.headers where !excluded.contains(name) {
            upstream.setValue(value, forHTTPHeaderField: name)
        }
        upstream.setValue("ios", forHTTPHeaderField: "X-Munibin-Native-App")
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let delegate = StreamingProxyDelegate(
            connection: connection,
            localBaseURL: baseURL,
            backendURL: backendURL,
            onComplete: { [weak self] in self?.persistBackendCookies() }
        )
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        let optionalTafsir = requestURL.path.hasPrefix("/api/quran/tafsir/")
        configuration.requestCachePolicy = (requestURL.path == quranReciterCatalogPath || optionalTafsir) ? .reloadIgnoringLocalCacheData : .reloadRevalidatingCacheData
        // Optional books are installed only by the explicit download action.
        // Online reads must not leave another copy in URLSession's disk cache.
        if optionalTafsir { configuration.urlCache = nil }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        let task = session.dataTask(with: upstream)
        delegate.task = task
        task.resume()
    }

    /// Online fallback before the Service Worker controls the current page.
    private func proxyExternalAudio(_ request: HTTPRequest, requestURL: URL, connection: NWConnection) {
        guard let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let rawSource = components.queryItems?.first(where: { $0.name == "source" })?.value,
              let sourceURL = URL(string: rawSource),
              sourceURL.scheme?.lowercased() == "https" else {
            sendText(connection, status: 400, text: "Invalid audio source")
            return
        }

        var upstream = URLRequest(url: sourceURL)
        upstream.httpMethod = request.method
        upstream.timeoutInterval = 120
        for name in ["range", "if-range", "if-none-match", "if-modified-since", "accept", "user-agent"] {
            if let value = request.headers[name], !value.isEmpty {
                upstream.setValue(value, forHTTPHeaderField: name)
            }
        }
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let delegate = StreamingProxyDelegate(
            connection: connection,
            localBaseURL: nil,
            backendURL: sourceURL,
            followRedirects: true,
            preserveContentLength: true
        )
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        let task = session.dataTask(with: upstream)
        delegate.task = task
        task.resume()
    }

    // MARK: - HTTP response helpers

    fileprivate func sendHead(_ connection: NWConnection, status: Int, headers: [String: String], completion: (() -> Void)? = nil) {
        var all = headers
        all["Connection"] = "close"
        let reason = statusReason(status)
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in all { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        connection.send(content: text.data(using: .utf8), completion: .contentProcessed { _ in completion?() })
    }

    fileprivate func sendBodyAndClose(_ connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendText(_ connection: NWConnection, status: Int, text: String) {
        let data = text.data(using: .utf8) ?? Data()
        sendHead(connection, status: status, headers: [
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-store",
        ]) { [weak self] in
            self?.sendBodyAndClose(connection, data: data)
        }
    }

    fileprivate func statusReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "HTTP"
        }
    }
}

private final class StreamingProxyDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    let connection: NWConnection
    let localBaseURL: URL?
    let backendURL: URL
    let followRedirects: Bool
    let preserveContentLength: Bool
    let onComplete: (() -> Void)?
    var session: URLSession?
    weak var task: URLSessionDataTask?

    private var sentHead = false
    private var expectsBody = true
    private var usesChunkedTransfer = false
    private let sendQueue = DispatchQueue(label: "com.motoonai.native-http.proxy-send")

    init(connection: NWConnection, localBaseURL: URL?, backendURL: URL, followRedirects: Bool = false, preserveContentLength: Bool = false, onComplete: (() -> Void)? = nil) {
        self.connection = connection
        self.localBaseURL = localBaseURL
        self.backendURL = backendURL
        self.followRedirects = followRedirects
        self.preserveContentLength = preserveContentLength
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection newRequest: URLRequest,
        newRequest redirectedRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if followRedirects {
            completionHandler(redirectedRequest)
            return
        }
        // Let the local WebView see backend redirects. This is important for auth/deep links.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            connection.cancel()
            return
        }

        var headers: [String: String] = [:]
        for (rawName, rawValue) in http.allHeaderFields {
            let name = String(describing: rawName)
            let lower = name.lowercased()
            if ["content-encoding", "connection", "transfer-encoding", "set-cookie"].contains(lower) { continue }
            if lower == "content-length" {
                if preserveContentLength { headers[name] = String(describing: rawValue) }
                continue
            }
            headers[name] = String(describing: rawValue)
        }

        if let location = http.value(forHTTPHeaderField: "Location"),
           let redirected = URL(string: location, relativeTo: backendURL)?.absoluteURL,
           let backendHost = backendURL.host,
           redirected.host == backendHost,
           let localBaseURL,
           var local = URLComponents(url: localBaseURL, resolvingAgainstBaseURL: false) {
            let source = URLComponents(url: redirected, resolvingAgainstBaseURL: false)
            local.percentEncodedPath = source?.percentEncodedPath ?? redirected.path
            local.percentEncodedQuery = source?.percentEncodedQuery
            local.percentEncodedFragment = source?.percentEncodedFragment
            if let url = local.url { headers["Location"] = url.absoluteString }
        }

        expectsBody = !(dataTask.originalRequest?.httpMethod == "HEAD" || http.statusCode == 204 || http.statusCode == 304)
        if expectsBody {
            let hasContentLength = headers.keys.contains { $0.caseInsensitiveCompare("Content-Length") == .orderedSame }
            if preserveContentLength && !hasContentLength && response.expectedContentLength >= 0 {
                headers["Content-Length"] = String(response.expectedContentLength)
            }
            let fixedLength = preserveContentLength && headers.keys.contains { $0.caseInsensitiveCompare("Content-Length") == .orderedSame }
            usesChunkedTransfer = !fixedLength
            if usesChunkedTransfer {
                headers["Transfer-Encoding"] = "chunked"
            }
        } else {
            usesChunkedTransfer = false
            headers["Content-Length"] = "0"
        }

        var head = "HTTP/1.1 \(http.statusCode) \(reason(http.statusCode))\r\n"
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"

        sentHead = true
        sendQueue.async { [connection] in
            connection.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard expectsBody, !data.isEmpty else { return }
        let packet: Data
        if usesChunkedTransfer {
            var chunk = Data("\(String(data.count, radix: 16))\r\n".utf8)
            chunk.append(data)
            chunk.append(Data("\r\n".utf8))
            packet = chunk
        } else {
            packet = data
        }
        sendQueue.async { [connection] in
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sendQueue.async { [connection, weak self] in
            guard let self else { return }
            if !self.sentHead {
                let body = Data((error?.localizedDescription ?? "Backend request failed").utf8)
                var response = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if self.expectsBody && self.usesChunkedTransfer {
                connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                connection.cancel()
            }
            self.onComplete?()
            self.session?.finishTasksAndInvalidate()
        }
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "HTTP"
        }
    }
}
