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

/// Result of fetching a course: the complete course (boundary + holes + features)
/// in a single request, or `notFound` when no matching golf course exists in OSM.
enum OSMFetchStage {
    case complete(OSMCourse)
    case notFound
}

enum OSMFetchError: Error {
    case http(status: Int, bodyPrefix: Data)
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(underlying: Error)
    case transport(underlying: Error)
}

actor OSMFetcher {
    /// Public Overpass mirrors, tried in rotation. The working mirror is remembered
    /// so subsequent requests start from the one that last succeeded.
    private let endpoints: [URL] = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]
    private var endpointIndex = 0
    private let session: URLSession
    private let userAgent = "Caddie/1.0"

    private var inFlight: Set<String> = []
    private var lastRequestStartedAt: Date?
    private var minGap: TimeInterval = 1.0
    private var lastRateLimitedAt: Date?
    private let baseMinGap: TimeInterval = 1.0
    private let maxMinGap: TimeInterval = 30.0
    /// How long an elevated `minGap` takes to decay back to baseline once rate
    /// limiting stops — so a single 429 doesn't penalize a much-later selection.
    private let backoffDecay: TimeInterval = 60.0

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Public entry point. Fetches the complete course in a single request and
    /// emits it as one `.complete` result (or `.notFound`). The stream finishes
    /// without emitting if a fetch for the same course is already in-flight.
    nonisolated func fetch(identifier: String, name: String, latitude: Double, longitude: Double) -> AsyncThrowingStream<OSMFetchStage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runFetch(
                        identifier: identifier,
                        name: name,
                        latitude: latitude,
                        longitude: longitude,
                        yield: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drives the fetch on the actor: dedup + throttle, then a single query for the
    /// course plus every golf feature. The features response already carries the
    /// course boundary (the `leisure=golf_course` element with inline geometry), so
    /// one round-trip yields the complete drawable course.
    private func runFetch(
        identifier: String,
        name: String,
        latitude: Double,
        longitude: Double,
        yield: @Sendable (OSMFetchStage) -> Void
    ) async throws {
        guard !inFlight.contains(identifier) else { return }
        inFlight.insert(identifier)
        defer { inFlight.remove(identifier) }

        let gapStart = Date()
        try await waitForGap()
        let gapMs = Int(Date().timeIntervalSince(gapStart) * 1000)
        osmLog("timing id=\(identifier) throttle-gap=\(gapMs)ms (minGap=\(String(format: "%.1f", minGap))s)")

        let fetchStart = Date()
        let response = try await post(featuresQuery(name: name, latitude: latitude, longitude: longitude))
        osmLog("timing id=\(identifier) fetch-features=\(Int(Date().timeIntervalSince(fetchStart) * 1000))ms")
        guard let course = OSMCourseBuilder.makeCourse(from: response, matching: name) else {
            yield(.notFound)
            return
        }
        yield(.complete(course))
    }

    /// Posts a query and adjusts throttling: relax on success, back off on rate limit.
    /// Stamps `lastRequestStartedAt` per call so the inter-fetch gap is measured
    /// against the most recent network request, not just the first stage of the
    /// previous course.
    private func post(_ query: String) async throws -> OverpassResponse {
        lastRequestStartedAt = .now
        do {
            let response = try await postWithFailover(query: query)
            minGap = max(baseMinGap, minGap / 2)
            return response
        } catch OSMFetchError.rateLimited(let retryAfter) {
            lastRateLimitedAt = .now
            minGap = min(maxMinGap, max(minGap * 2, retryAfter ?? minGap * 2))
            throw OSMFetchError.rateLimited(retryAfter: retryAfter)
        }
    }

    /// Tries each mirror in rotation starting from the last working one. Rotates on
    /// rate-limit or transport failure; surfaces the error only when every mirror
    /// has been exhausted.
    private func postWithFailover(query: String) async throws -> OverpassResponse {
        var lastError: Error = OSMFetchError.transport(underlying: URLError(.cannotConnectToHost))
        for offset in 0..<endpoints.count {
            let index = (endpointIndex + offset) % endpoints.count
            do {
                let response = try await postOverpass(query: query, endpoint: endpoints[index])
                endpointIndex = index // remember the working mirror
                return response
            } catch OSMFetchError.rateLimited(let retryAfter) {
                lastError = OSMFetchError.rateLimited(retryAfter: retryAfter)
                osmLog("mirror \(endpoints[index].host ?? "?") rate limited, trying next")
            } catch OSMFetchError.transport(let underlying) {
                lastError = OSMFetchError.transport(underlying: underlying)
                osmLog("mirror \(endpoints[index].host ?? "?") transport error, trying next")
            }
        }
        throw lastError
    }

    // MARK: - Query construction

    /// Features query: the course plus every golf feature INSIDE the course polygon.
    /// Uses `map_to_area` so interior holes/greens (far from the boundary line) are
    /// included — `around.course:N` only catches features near the perimeter.
    private func featuresQuery(name: String, latitude: Double, longitude: Double) -> String {
        let bboxString = bboxString(latitude: latitude, longitude: longitude)
        let namePattern = escapeForOverpassRegex(simplifyName(name))

        return """
        [out:json][timeout:30];
        (
          way["leisure"="golf_course"]["name"~"\(namePattern)",i](\(bboxString));
          relation["leisure"="golf_course"]["name"~"\(namePattern)",i](\(bboxString));
        )->.named;
        // A multi-course facility (e.g. Balboa Park) is a `type=multipolygon` whose
        // member ways ARE the sub-courses (Championship as `outer`, Executive as
        // `inner`). Fold those member ways in alongside the named matches so the area
        // set below is the UNION of the facility and each sub-course — otherwise the
        // inner sub-course is cut out of the donut area and its holes/features are
        // never returned.
        way(r.named)->.members;
        (.named; .members;)->.course;
        .course map_to_area->.courseArea;
        (
          .course;
          way(area.courseArea)["golf"];
          node(area.courseArea)["golf"];
          relation(area.courseArea)["golf"];
          // Child course polygons of a multi-course facility, which carry no `golf=*`
          // tag and rarely share the facility name, so neither the name match nor the
          // `golf` clauses above return them: nested sibling ways via the area set,
          // and multipolygon members via the relation recursion.
          way(area.courseArea)["leisure"="golf_course"];
          relation(area.courseArea)["leisure"="golf_course"];
          way(r.named);
        );
        out geom;
        """
    }

    private func bboxString(latitude: Double, longitude: Double) -> String {
        let bbox = boundingBox(latitude: latitude, longitude: longitude, kilometers: 4.0)
        return "\(bbox.south),\(bbox.west),\(bbox.north),\(bbox.east)"
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

    /// Strips qualifier suffixes from an Apple Maps course name so the remainder
    /// matches the (often shorter) name in OSM.
    ///
    /// The two-step approach handles the most common mismatches:
    ///  - Parenthetical course qualifiers: "Torrey Pines (South)" → "Torrey Pines"
    ///  - Dash-separated qualifiers: "TPC Sawgrass - Stadium" → "TPC Sawgrass"
    ///  - Trailing golf-category words: "Pebble Beach Golf Links" → "Pebble Beach"
    ///
    /// Falls back to the original name if every word would be stripped away, so the
    /// caller never sends an empty regex pattern (which matches ALL named elements).
    private func simplifyName(_ name: String) -> String {
        var result = name

        // Remove parenthetical qualifiers, e.g. "(South)", "(No. 1)", "(Championship)"
        if let regex = try? NSRegularExpression(pattern: #"\s*\([^)]*\)"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Remove dash-separated suffixes, e.g. " - Stadium Course", " – Links"
        if let regex = try? NSRegularExpression(pattern: #"\s*[-–—]\s*\S.*$"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        let strippable = ["golf course", "golf club", "golf links", "country club", "golf"]
        for term in strippable {
            if let range = result.range(of: term, options: .caseInsensitive) {
                result.removeSubrange(range)
            }
        }

        let collapsed = result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Guard against a fully-stripped name producing an empty regex that would
        // match every named element in the bounding box.
        return collapsed.isEmpty ? name : collapsed
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

    private func postOverpass(query: String, endpoint: URL) async throws -> OverpassResponse {
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
        decayBackoff()
        guard let last = lastRequestStartedAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        let remaining = minGap - elapsed
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    /// Linearly relaxes an elevated `minGap` back toward baseline based on how long
    /// it has been since the last rate limit, so an old 429 doesn't keep stalling
    /// selections the user makes minutes later.
    private func decayBackoff() {
        guard minGap > baseMinGap, let rateLimited = lastRateLimitedAt else { return }
        let elapsed = Date().timeIntervalSince(rateLimited)
        guard elapsed > 0 else { return }
        let fraction = min(1.0, elapsed / backoffDecay)
        minGap = max(baseMinGap, minGap - (minGap - baseMinGap) * fraction)
        if minGap <= baseMinGap { lastRateLimitedAt = nil }
    }
}
