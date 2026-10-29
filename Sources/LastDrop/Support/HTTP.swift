import Foundation

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.connectionProxyDictionary = [:] // never loop through our own proxy
        return URLSession(configuration: config)
    }()

    /// Sends a request and returns the decoded JSON object plus the status code.
    static func json(_ request: URLRequest) async throws -> (Any, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        return (object, http)
    }

    static func request(_ url: String, method: String = "GET", headers: [String: String] = [:], json body: Any? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }
}

/// Small helpers for walking untyped JSON.
extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }
}

enum Dates {
    static func iso(_ string: String?) -> Date? {
        guard let string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: string) { return d }
        // Go and Python emit up to nanosecond precision; trim the fraction to milliseconds.
        guard let r = string.range(of: #"\.\d{4,}"#, options: .regularExpression) else { return nil }
        return iso(string.replacingCharacters(in: r, with: String(string[r].prefix(4))))
    }

    /// Epoch seconds or milliseconds.
    static func epoch(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
    }
}
