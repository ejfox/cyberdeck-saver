import Foundation

enum FetchResult {
    case success(Any)
    case failure(FetchError)
}

/// Single shared URLSession with reasonable defaults.
/// The screensaver fires up to 16 concurrent requests on first paint — the default
/// session's per-host concurrency limit is fine, but we give it a longer resource
/// timeout than the default so the slow VPS panels don't all time out at once.
enum ApiClient {
    /// Shared URLSession used by every stream — consistent timeouts, cache,
    /// and wait-for-connectivity behavior across personal APIs, VPS feeds,
    /// and terminal endpoints.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true   // wait-from-sleep friendly
        config.urlCache = URLCache(
            memoryCapacity: 2 * 1024 * 1024,
            diskCapacity: 10 * 1024 * 1024)
        return URLSession(configuration: config)
    }()

    static func fetchJSON(
        from urlString: String,
        timeout: TimeInterval = 10,
        cacheMaxAge: TimeInterval = 0,
        completion: @escaping (FetchResult) -> Void
    ) {
        // Serve from the process-shared cache if we have a fresh enough entry.
        // Multi-monitor wins come from here: the second display asking for the
        // same URL within `cacheMaxAge` skips the network entirely.
        if cacheMaxAge > 0, let cached = StreamCache.get(url: urlString, maxAge: cacheMaxAge) {
            completion(cached)
            return
        }

        guard let url = URL(string: urlString) else {
            completion(.failure(.badUrl))
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout

        session.dataTask(with: req) { data, response, error in
            let result: FetchResult
            if error != nil {
                result = .failure(.offline)
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                result = .failure(.httpError(http.statusCode))
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) {
                result = .success(json)
            } else {
                result = .failure(.parseError)
            }
            if cacheMaxAge > 0 {
                StreamCache.put(url: urlString, result: result)
            }
            completion(result)
        }.resume()
    }

    /// Convenience: fetch + render a header-capped block of lines.
    /// Error responses are rendered with a consistent [STATUS: <err>] banner.
    /// `cacheMaxAge` is passed through to the process-shared StreamCache —
    /// callers should pass ~80% of their refresh interval so multi-monitor
    /// setups coalesce without staleness.
    static func fetchAndFormat(
        url: String,
        timeout: TimeInterval = 10,
        cacheMaxAge: TimeInterval = 30,
        header: String,
        build: @escaping (Any) -> [FormattedLine],
        completion: @escaping (StreamResponse) -> Void
    ) {
        fetchJSON(from: url, timeout: timeout, cacheMaxAge: cacheMaxAge) { result in
            switch result {
            case .success(let json):
                var lines: [FormattedLine] = [FormattedLine(header, Vulpes.teal)]
                lines.append(contentsOf: build(json))
                completion(StreamResponse(lines: lines, ok: true))
            case .failure(let err):
                let lines: [FormattedLine] = [
                    FormattedLine(header, Vulpes.orange),
                    FormattedLine("STATUS: \(err.label)", Vulpes.orange),
                    FormattedLine("Retrying soon", Vulpes.muted),
                ]
                completion(StreamResponse(lines: lines, ok: false))
            }
        }
    }
}
