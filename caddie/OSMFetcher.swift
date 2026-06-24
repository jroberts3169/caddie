//
//  OSMFetcher.swift
//  caddie
//

import Foundation

@inlinable
nonisolated func osmLog(_ message: @autoclosure () -> String) {
    #if OSM_DEBUG
    print("[OSM] \(message())")
    #endif
}

enum OSMFetchOutcome {
    case found(OSMCourse)
    case notFound
}

enum OSMFetchError: Error {
    case http(status: Int, bodyPrefix: Data)
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(underlying: Error)
    case transport(underlying: Error)
}

actor OSMFetcher {
    private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private let session: URLSession
    private let userAgent = "Caddie/1.0"

    private var inFlight: Set<String> = []
    private var lastRequestStartedAt: Date?
    private var minGap: TimeInterval = 1.0
    private let baseMinGap: TimeInterval = 1.0
    private let maxMinGap: TimeInterval = 30.0

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Public entry point. Returns nil if a fetch is already in-flight for the identifier.
    func fetch(identifier: String, name: String, latitude: Double, longitude: Double) async throws -> OSMFetchOutcome? {
        guard !inFlight.contains(identifier) else { return nil }
        inFlight.insert(identifier)
        defer { inFlight.remove(identifier) }

        try await waitForGap()
        lastRequestStartedAt = .now

        let query = buildQuery(name: name, latitude: latitude, longitude: longitude)
        let response: OverpassResponse
        do {
            response = try await postOverpass(query: query)
        } catch OSMFetchError.rateLimited(let retryAfter) {
            minGap = min(maxMinGap, max(minGap * 2, retryAfter ?? minGap * 2))
            throw OSMFetchError.rateLimited(retryAfter: retryAfter)
        }

        // Successful response — relax throttling back toward baseline.
        minGap = max(baseMinGap, minGap / 2)

        if let course = OSMCourseBuilder.makeCourse(from: response) {
            return .found(course)
        }
        return .notFound
    }

    // MARK: - Query construction

    private func buildQuery(name: String, latitude: Double, longitude: Double) -> String {
        let bbox = boundingBox(latitude: latitude, longitude: longitude, kilometers: 2.0)
        let bboxString = "\(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east)"
        let namePattern = escapeForOverpassRegex(simplifyName(name))

        return """
        [out:json][timeout:30];
        (
          way["leisure"="golf_course"]["name"~"\(namePattern)",i](\(bboxString));
          relation["leisure"="golf_course"]["name"~"\(namePattern)",i](\(bboxString));
        )->.course;
        (
          .course;
          way(around.course:50)["golf"];
          node(around.course:50)["golf"];
          relation(around.course:50)["golf"];
        );
        out body;
        >;
        out skel qt;
        """
    }

    private func boundingBox(latitude: Double, longitude: Double, kilometers: Double) -> (north: Double, south: Double, east: Double, west: Double) {
        let latDelta = kilometers / 111.0
        let lonDelta = kilometers / (111.0 * max(cos(latitude * .pi / 180), 0.01))
        return (
            north: latitude + latDelta,
            south: latitude - latDelta,
            east: longitude + lonDelta,
            west: longitude - lonDelta
        )
    }

    /// Removes generic suffixes so a search hit like "Pebble Beach Golf Links"
    /// still matches an OSM record named "Pebble Beach".
    private func simplifyName(_ name: String) -> String {
        let strippable = ["golf course", "golf club", "golf links", "country club", "golf"]
        var result = name
        for term in strippable {
            if let range = result.range(of: term, options: .caseInsensitive) {
                result.removeSubrange(range)
            }
        }
        let collapsed = result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escapeForOverpassRegex(_ input: String) -> String {
        let metacharacters: Set<Character> = ["\\", ".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "/", "\""]
        var escaped = ""
        for character in input {
            if metacharacters.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    // MARK: - Network

    private func postOverpass(query: String) async throws -> OverpassResponse {
        osmLog("POST \(endpoint.absoluteString) query bytes=\(query.count)")
        osmLog("query:\n\(query)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body = "data=" + formEncode(query)
        request.httpBody = body.data(using: .utf8)
        osmLog("body bytes=\(body.count)")
        osmLog("body: \(body.prefix(400))\(body.count > 400 ? "…" : "")")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            osmLog("transport error: \(error)")
            throw OSMFetchError.transport(underlying: error)
        }

        if let http = response as? HTTPURLResponse {
            osmLog("HTTP \(http.statusCode), body bytes=\(data.count)")
            if http.statusCode == 429 || http.statusCode == 503 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                throw OSMFetchError.rateLimited(retryAfter: retryAfter)
            }
            if http.statusCode >= 400 {
                let snippet = String(data: Data(data.prefix(512)), encoding: .utf8) ?? "(non-utf8 body)"
                osmLog("error body snippet: \(snippet)")
                throw OSMFetchError.http(status: http.statusCode, bodyPrefix: Data(data.prefix(512)))
            }
        }

        do {
            return try JSONDecoder().decode(OverpassResponse.self, from: data)
        } catch {
            let snippet = String(data: Data(data.prefix(512)), encoding: .utf8) ?? "(non-utf8 body)"
            osmLog("decode error: \(error)\n  body snippet: \(snippet)")
            throw OSMFetchError.decoding(underlying: error)
        }
    }

    /// Percent-encodes everything except the unreserved set defined by RFC 3986.
    /// `.urlQueryAllowed` is too permissive for form-urlencoded bodies because it
    /// leaves `=` and `&` (and other reserved chars) intact — which mod_security
    /// on the Overpass front-end rejects with 406.
    private func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    // MARK: - Throttling

    private func waitForGap() async throws {
        guard let last = lastRequestStartedAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        let remaining = minGap - elapsed
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }
}
