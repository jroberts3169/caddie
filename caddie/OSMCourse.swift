//
//  OSMCourse.swift
//  caddie
//

import Foundation

nonisolated struct Coordinate: Codable, Hashable {
    let lat: Double
    let lon: Double
}

// MARK: - Domain

/// One playable course inside a multi-course facility. Two shapes produce these:
///  - a child boundary polygon (Balboa Park's Championship / Executive ways), or
///  - a `golf:course:name` group of holes inside one shared ring (Augusta's
///    "Augusta National" 18 + "Par 3 Course" 9), whose `boundary` is a convex hull
///    synthesized from those holes.
/// `boundary` is a list of rings (a polygon may be several disjoint pieces — see
/// `OSMCourse.boundary`). Attribution is resolved once at build time:
/// `holeIDs`/`featureIDs` reference the owning `OSMCourse`'s top-level
/// `holes`/`features` by `osmIdentifier`.
nonisolated struct OSMSubCourse: Codable, Hashable, Identifiable {
    /// Stable identity: "way-123" / "relation-123" for polygon courses, or
    /// "tag-<golf:course:name>" for tag-grouped courses.
    let id: String
    let name: String?
    let boundary: [[Coordinate]]
    let holeIDs: [Int64]
    let featureIDs: [Int64]
}

nonisolated struct OSMCourse: Codable, Hashable {
    let osmIdentifier: Int64
    let osmType: String
    let name: String?
    let tags: [String: String]
    /// The course outline as a list of rings. Most courses are a single ring, but a
    /// `type=multipolygon` course (e.g. TPC Sawgrass) is several disjoint outer rings
    /// — the parcels the course occupies, split by water/roads/housing. Storing every
    /// ring is what keeps holes in outlying parcels inside the drawn boundary.
    let boundary: [[Coordinate]]
    let holes: [OSMHole]
    let features: [OSMFeature]
    /// Sub-courses of a multi-course facility, largest first. Empty for an ordinary
    /// single course, in which case `boundary`/`holes`/`features` are the whole course.
    let subCourses: [OSMSubCourse]

    init(
        osmIdentifier: Int64,
        osmType: String,
        name: String?,
        tags: [String: String],
        boundary: [[Coordinate]],
        holes: [OSMHole],
        features: [OSMFeature],
        subCourses: [OSMSubCourse] = []
    ) {
        self.osmIdentifier = osmIdentifier
        self.osmType = osmType
        self.name = name
        self.tags = tags
        self.boundary = boundary
        self.holes = holes
        self.features = features
        self.subCourses = subCourses
    }

    // Custom decoder so cache rows written before a shape change still decode (a hard
    // decode failure would strand the map blank within the row's TTL). `boundary`
    // also accepts the legacy single-ring `[Coordinate]` shape and wraps it, and
    // `subCourses` falls back to [] if its (newer, more volatile) shape mismatches.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        osmIdentifier = try c.decode(Int64.self, forKey: .osmIdentifier)
        osmType = try c.decode(String.self, forKey: .osmType)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        tags = try c.decode([String: String].self, forKey: .tags)
        if let rings = try? c.decode([[Coordinate]].self, forKey: .boundary) {
            boundary = rings
        } else if let ring = try? c.decode([Coordinate].self, forKey: .boundary) {
            boundary = ring.isEmpty ? [] : [ring]
        } else {
            boundary = []
        }
        holes = try c.decode([OSMHole].self, forKey: .holes)
        features = try c.decode([OSMFeature].self, forKey: .features)
        subCourses = (try? c.decode([OSMSubCourse].self, forKey: .subCourses)) ?? []
    }
}

nonisolated struct OSMHole: Codable, Hashable {
    let osmIdentifier: Int64
    let ref: String?
    let par: Int?
    let lengthMeters: Double?
    let coordinates: [Coordinate]
    let tags: [String: String]
}

nonisolated struct OSMFeature: Codable, Hashable {
    let osmIdentifier: Int64
    let kind: Kind
    let coordinates: [Coordinate]
    let isClosed: Bool
    let tags: [String: String]

    enum Kind: String, Codable {
        case green
        case fairway
        case tee
        case bunker
        case rough
        case waterHazard = "water_hazard"
        case cartpath
        case path
        case drivingRange = "driving_range"
        case unknown
    }
}

// MARK: - Transport (mirrors Overpass JSON)

nonisolated struct OverpassResponse: Codable, Hashable {
    let version: Double
    let generator: String
    let elements: [OverpassElement]
}

nonisolated enum OverpassElement: Codable, Hashable {
    case node(OverpassNode)
    case way(OverpassWay)
    case relation(OverpassRelation)

    private enum TypeKey: String, CodingKey { case type }
    private enum ElementType: String, Codable { case node, way, relation }

    init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TypeKey.self)
        let type = try typeContainer.decode(ElementType.self, forKey: .type)
        let single = try decoder.singleValueContainer()
        switch type {
        case .node: self = .node(try single.decode(OverpassNode.self))
        case .way: self = .way(try single.decode(OverpassWay.self))
        case .relation: self = .relation(try single.decode(OverpassRelation.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .node(let n): try container.encode(n)
        case .way(let w): try container.encode(w)
        case .relation(let r): try container.encode(r)
        }
    }

    var id: Int64 {
        switch self {
        case .node(let n): return n.id
        case .way(let w): return w.id
        case .relation(let r): return r.id
        }
    }
}

nonisolated struct OverpassNode: Codable, Hashable {
    let type: String
    let id: Int64
    let lat: Double
    let lon: Double
    let tags: [String: String]?
}

nonisolated struct OverpassWay: Codable, Hashable {
    let type: String
    let id: Int64
    let nodes: [Int64]?
    let geometry: [Coordinate]?
    let tags: [String: String]?
}

nonisolated struct OverpassRelation: Codable, Hashable {
    let type: String
    let id: Int64
    let members: [OverpassMember]
    let tags: [String: String]?
}

nonisolated struct OverpassMember: Codable, Hashable {
    let type: String
    let ref: Int64
    let role: String
    let geometry: [Coordinate]?
}

// MARK: - Domain conversion

nonisolated enum OSMCourseBuilder {
    /// Walks an Overpass response and produces an OSMCourse for the named course,
    /// resolving node references into coordinate arrays. `searchName` is the name the
    /// user selected (from Apple Maps); it disambiguates the primary course from any
    /// neighbouring clubs the area query swept in.
    static func makeCourse(from response: OverpassResponse, matching searchName: String?) -> OSMCourse? {
        var nodesByID: [Int64: OverpassNode] = [:]
        var waysByID: [Int64: OverpassWay] = [:]
        var relationsByID: [Int64: OverpassRelation] = [:]

        for element in response.elements {
            switch element {
            case .node(let n): nodesByID[n.id] = n
            case .way(let w): waysByID[w.id] = w
            case .relation(let r): relationsByID[r.id] = r
            }
        }

        let allHoles = holes(from: waysByID, nodesByID: nodesByID)
        let allFeatures = features(from: waysByID, relationsByID: relationsByID, nodesByID: nodesByID)

        // A response can carry more than one `leisure=golf_course` element: the
        // course itself, child courses of a facility (Balboa), or a neighbouring
        // club the 4 km area query swept in (Augusta National pulls in Augusta
        // Country Club). Prefer the boundary whose name matches what the user
        // selected, so a larger neighbour can't hijack the displayed course; fall
        // back to the largest boundary when nothing matches (loose Apple↔OSM names).
        let candidates = courseBoundaries(
            relationsByID: relationsByID, waysByID: waysByID, nodesByID: nodesByID
        )
        let nameMatched = candidates.filter { nameMatches($0.name, searchName) }
        let pool = nameMatched.isEmpty ? candidates : nameMatched
        guard let primary = pool.max(by: { lhs, rhs in
            let lhsArea = GolfGeometry.polygonArea(lhs.boundary)
            let rhsArea = GolfGeometry.polygonArea(rhs.boundary)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            // Equal area (a multipolygon facility shares its outer ring with a member
            // way): the relation is the facility wrapper, so let it win the tie.
            return rhs.osmType == "relation" && lhs.osmType != "relation"
        }) else { return nil }

        let subCourses = makeSubCourses(
            primary: primary, candidates: candidates, holes: allHoles, features: allFeatures,
            relationsByID: relationsByID, waysByID: waysByID, nodesByID: nodesByID
        )

        return OSMCourse(
            osmIdentifier: primary.id,
            osmType: primary.osmType,
            name: primary.name,
            tags: primary.tags,
            boundary: primary.boundary,
            holes: allHoles,
            features: allFeatures,
            subCourses: subCourses
        )
    }

    /// Loose name match between an OSM candidate and the user's selected course:
    /// true when either normalized name contains the other (after dropping golf
    /// boilerplate). Empty/absent names never match, so the largest-boundary fallback
    /// takes over.
    private static func nameMatches(_ candidate: String?, _ search: String?) -> Bool {
        guard let a = normalizedName(candidate), let b = normalizedName(search),
              !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    private static func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        var s = name.lowercased()
        for term in ["golf course", "golf club", "golf links", "country club", "golf"] {
            s = s.replacingOccurrences(of: term, with: " ")
        }
        let kept = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Stricter one-directional match used only for sub-course polygon preference:
    /// the CANDIDATE polygon's normalized name must contain the GROUP name, not the
    /// other way around. This prevents "Augusta Country Club" (normalized "augusta")
    /// from matching the "Augusta National" group via the reverse direction
    /// ("augusta national".contains("augusta") = true, a false positive with the
    /// bidirectional `nameMatches`).
    private static func candidateContainsGroupName(_ candidate: String?, _ groupName: String?) -> Bool {
        guard let a = normalizedName(candidate), let b = normalizedName(groupName),
              !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b)
    }

    /// Splits a facility into its selectable sub-courses, by a signal cascade:
    ///  - Tier 1 — holes tagged `golf:course:name` (Augusta's 18 + Par 3). Group by
    ///    the tag; each group is a sub-course whose boundary is a convex hull of its
    ///    holes, and whose untagged features are attributed by that hull.
    ///  - Tier 2 — child `leisure=golf_course` boundary polygons (Balboa: relation
    ///    members or spatially enclosed). Holes/features attributed by the smallest
    ///    containing polygon.
    ///  - Tier 1b — holes carrying no `golf:course:name` tag but whose `name` encodes
    ///    the course as a prefix (TPC Sawgrass: "Stadium 1"… + "Valley 1"…). Group by
    ///    that prefix; boundary is a convex hull of each group's holes, like Tier 1.
    /// Real mapped polygons (Tier 2) are preferred over the synthesized hulls of the
    /// tag/name tiers, so the cascade tries tag → polygon → hole-name. Tier 1 wins
    /// outright when its tag yields two or more courses (the tag is authoritative).
    /// Returns `[]` for an ordinary single course, preserving current behaviour.
    private static func makeSubCourses(
        primary: CourseBoundary,
        candidates: [CourseBoundary],
        holes: [OSMHole],
        features: [OSMFeature],
        relationsByID: [Int64: OverpassRelation],
        waysByID: [Int64: OverpassWay],
        nodesByID: [Int64: OverpassNode]
    ) -> [OSMSubCourse] {
        // Exclude the primary so a facility ring (e.g. "Augusta National Golf Club")
        // can't substitute itself as the boundary of the same-named sub-course group.
        let nonPrimary = candidates.filter {
            !($0.osmType == primary.osmType && $0.id == primary.id)
        }
        if let tagged = tagBasedSubCourses(holes: holes, features: features, candidates: nonPrimary) {
            return tagged
        }
        let polygons = polygonSubCourses(
            primary: primary, candidates: candidates, holes: holes, features: features,
            relationsByID: relationsByID, waysByID: waysByID, nodesByID: nodesByID
        )
        if !polygons.isEmpty {
            return polygons
        }
        return holeNameSubCourses(holes: holes, features: features, candidates: nonPrimary) ?? []
    }

    /// Tier 1: group holes by `golf:course:name`. Returns `nil` (not `[]`) when fewer
    /// than two distinct course names are present, so the caller falls through to the
    /// polygon tier. `candidates` are the non-primary `leisure=golf_course` boundaries
    /// in the response; when a candidate's name matches a group name it is used as the
    /// sub-course boundary in place of the synthesized convex hull (real polygon wins).
    private static func tagBasedSubCourses(
        holes: [OSMHole],
        features: [OSMFeature],
        candidates: [CourseBoundary]
    ) -> [OSMSubCourse]? {
        let grouped = Dictionary(grouping: holes.compactMap { hole -> (String, OSMHole)? in
            guard let course = hole.tags["golf:course:name"] else { return nil }
            return (course, hole)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        guard grouped.count >= 2 else { return nil }

        // Convex hull per group (always computed — used for feature attribution even
        // when a real polygon replaces it as the display boundary, because the hull
        // is tighter around its own holes and gives cleaner attribution). One ring,
        // wrapped as a single-ring polygon.
        let hulls: [String: [[Coordinate]]] = grouped.mapValues { holes in
            [GolfGeometry.buffered(GolfGeometry.convexHull(holes.flatMap(\.coordinates)), by: 0.08)]
        }

        // Display boundary: prefer a real mapped polygon whose name matches the group.
        // Use the strict directional check (candidate must contain the group name, not
        // the reverse) so "Augusta Country Club" → normalized "augusta" does NOT match
        // the "Augusta National" group → normalized "augusta national".
        let displayBoundaries: [String: [[Coordinate]]] = grouped.keys.reduce(into: [:]) { dict, name in
            if let polygon = candidates.first(where: { candidateContainsGroupName($0.name, name) }),
               polygon.boundary.contains(where: { $0.count >= 3 }) {
                dict[name] = polygon.boundary
            } else {
                dict[name] = hulls[name] ?? []
            }
        }

        return grouped
            .map { name, holes -> OSMSubCourse in
                let featureIDs = features.filter { feature in
                    guard let center = GolfGeometry.centroid(of: feature.coordinates) else { return false }
                    return smallestContainer(of: center, in: hulls) == name
                }.map(\.osmIdentifier)
                return OSMSubCourse(
                    id: "tag-\(name)", name: name, boundary: displayBoundaries[name] ?? [],
                    holeIDs: holes.map(\.osmIdentifier), featureIDs: featureIDs
                )
            }
            .sorted { $0.holeIDs.count > $1.holeIDs.count }
    }

    /// Tier 1b: split a course whose holes are NOT tagged `golf:course:name` but whose
    /// `name` encodes the course as a prefix — TPC Sawgrass names its 36 holes
    /// "Stadium 1"…"Stadium 18" (THE PLAYERS Stadium Course) and "Valley 1"…"Valley 18"
    /// (Dye's Valley Course). Group by the prefix (the name with its trailing hole
    /// number removed); each group of three or more holes is a sub-course whose boundary
    /// is a convex hull of its holes (a real mapped polygon replaces it when a candidate
    /// name matches), and whose untagged features are attributed by the smallest
    /// containing hull. Returns `nil` (not `[]`) when fewer than two plausible prefix
    /// groups exist, so an ordinary single course is kept whole. Skipped entirely once
    /// any hole carries `golf:course:name` — that is Tier 1's job.
    private static func holeNameSubCourses(
        holes: [OSMHole],
        features: [OSMFeature],
        candidates: [CourseBoundary]
    ) -> [OSMSubCourse]? {
        guard !holes.contains(where: { $0.tags["golf:course:name"] != nil }) else { return nil }

        // Group case-insensitively so "West"/"west" coalesce; keep the first hole's
        // original casing for display. Drop groups of fewer than three holes so a stray
        // "Practice 1" can't peel off as a course.
        let grouped = Dictionary(grouping: holes.compactMap { hole -> (String, OSMHole)? in
            guard let prefix = courseNamePrefix(of: hole) else { return nil }
            return (prefix.lowercased(), hole)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        let plausible = grouped.filter { $0.value.count >= 3 }
        guard plausible.count >= 2 else { return nil }

        let names: [String: String] = plausible.reduce(into: [:]) { dict, entry in
            dict[entry.key] = entry.value.lazy.compactMap { courseNamePrefix(of: $0) }.first ?? entry.key
        }

        // Convex hull per group — used for feature attribution even when a real polygon
        // replaces it as the display boundary (the hull is tighter around its own holes).
        let hulls: [String: [[Coordinate]]] = plausible.mapValues { holes in
            [GolfGeometry.buffered(GolfGeometry.convexHull(holes.flatMap(\.coordinates)), by: 0.08)]
        }

        let displayBoundaries: [String: [[Coordinate]]] = plausible.keys.reduce(into: [:]) { dict, key in
            if let polygon = candidates.first(where: { candidateContainsGroupName($0.name, names[key]) }),
               polygon.boundary.contains(where: { $0.count >= 3 }) {
                dict[key] = polygon.boundary
            } else {
                dict[key] = hulls[key] ?? []
            }
        }

        return plausible
            .map { key, holes -> OSMSubCourse in
                let featureIDs = features.filter { feature in
                    guard let center = GolfGeometry.centroid(of: feature.coordinates) else { return false }
                    return smallestContainer(of: center, in: hulls) == key
                }.map(\.osmIdentifier)
                return OSMSubCourse(
                    id: "holename-\(key)", name: names[key] ?? key,
                    boundary: displayBoundaries[key] ?? [],
                    holeIDs: holes.map(\.osmIdentifier), featureIDs: featureIDs
                )
            }
            .sorted { $0.holeIDs.count > $1.holeIDs.count }
    }

    /// The course label carried in a hole's `name`: the name with its trailing hole
    /// number stripped ("Stadium 1" → "Stadium", "Valley 18" → "Valley"). Strips the
    /// `ref` when the name ends with it, otherwise trailing digits. Returns `nil` when
    /// the name is absent or numeric only ("7" → nil), so number-only holes never split.
    private static func courseNamePrefix(of hole: OSMHole) -> String? {
        guard var base = hole.tags["name"]?.trimmingCharacters(in: .whitespaces), !base.isEmpty else {
            return nil
        }
        if let ref = hole.ref, !ref.isEmpty, base.lowercased().hasSuffix(ref.lowercased()) {
            base = String(base.dropLast(ref.count))
        } else {
            while let last = base.last, last.isNumber { base = String(base.dropLast()) }
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: " -#."))
        return base.isEmpty ? nil : base
    }

    /// Tier 2: child course boundary polygons (relation members + spatially enclosed),
    /// with holes/features attributed by the smallest containing polygon.
    private static func polygonSubCourses(
        primary: CourseBoundary,
        candidates: [CourseBoundary],
        holes: [OSMHole],
        features: [OSMFeature],
        relationsByID: [Int64: OverpassRelation],
        waysByID: [Int64: OverpassWay],
        nodesByID: [Int64: OverpassNode]
    ) -> [OSMSubCourse] {
        var collected: [CourseBoundary] = []
        var seen = Set<String>()
        func add(_ candidate: CourseBoundary) {
            guard candidate.boundary.contains(where: { $0.count >= 3 }),
                  !(candidate.osmType == primary.osmType && candidate.id == primary.id) else { return }
            if seen.insert("\(candidate.osmType)/\(candidate.id)").inserted {
                collected.append(candidate)
            }
        }

        // 1. Member ways of a multipolygon facility that are themselves courses.
        if primary.osmType == "relation", let relation = relationsByID[primary.id] {
            for member in relation.members where member.type == "way" {
                guard let way = waysByID[member.ref], isCourseBoundary(way.tags) else { continue }
                add(CourseBoundary(
                    id: way.id, osmType: "way", name: way.tags?["name"],
                    tags: way.tags ?? [:], boundary: [coordinates(for: way, nodesByID: nodesByID)]
                ))
            }
        }

        // 2. Other valid course boundaries enclosed by the facility polygon.
        for candidate in candidates {
            guard let center = GolfGeometry.centroid(ofRings: candidate.boundary),
                  GolfGeometry.isInside(center, rings: primary.boundary) else { continue }
            add(candidate)
        }

        let ordered = collected.sorted {
            GolfGeometry.polygonArea($0.boundary) > GolfGeometry.polygonArea($1.boundary)
        }
        guard !ordered.isEmpty else { return [] }

        let boundariesByID = Dictionary(uniqueKeysWithValues: ordered.map { ("\($0.osmType)-\($0.id)", $0.boundary) })
        func owner(of point: Coordinate) -> String? { smallestContainer(of: point, in: boundariesByID) }

        return ordered.map { sub in
            let key = "\(sub.osmType)-\(sub.id)"
            let holeIDs = holes.filter { ($0.coordinates.first).map { owner(of: $0) == key } ?? false }.map(\.osmIdentifier)
            let featureIDs = features.filter { GolfGeometry.centroid(of: $0.coordinates).map { owner(of: $0) == key } ?? false }.map(\.osmIdentifier)
            return OSMSubCourse(id: key, name: sub.name, boundary: sub.boundary, holeIDs: holeIDs, featureIDs: featureIDs)
        }
    }

    /// Key of the smallest-area boundary in `boundaries` that contains `point`, or
    /// `nil` when none do. Resolves overlap when courses nest. Boundaries are
    /// multi-ring polygons; containment uses the even-odd rule across all rings.
    private static func smallestContainer(of point: Coordinate, in boundaries: [String: [[Coordinate]]]) -> String? {
        boundaries
            .filter { GolfGeometry.isInside(point, rings: $0.value) }
            .min { GolfGeometry.polygonArea($0.value) < GolfGeometry.polygonArea($1.value) }?
            .key
    }

    /// A candidate course boundary (relation or way) with its assembled rings. A way
    /// is a single ring; a `type=multipolygon` relation may be several disjoint rings.
    private struct CourseBoundary {
        let id: Int64
        let osmType: String
        let name: String?
        let tags: [String: String]
        let boundary: [[Coordinate]]
    }

    /// Every valid `leisure=golf_course` boundary in the response — relations and
    /// ways alike — with mis-tagged feature areas (driving ranges) excluded and
    /// boundaries with no ring of ≥ 3 points dropped.
    private static func courseBoundaries(
        relationsByID: [Int64: OverpassRelation],
        waysByID: [Int64: OverpassWay],
        nodesByID: [Int64: OverpassNode]
    ) -> [CourseBoundary] {
        let relations = relationsByID.values
            .filter { isCourseBoundary($0.tags) }
            .map { relation in
                CourseBoundary(
                    id: relation.id, osmType: "relation",
                    name: relation.tags?["name"], tags: relation.tags ?? [:],
                    boundary: boundaryRings(for: relation, waysByID: waysByID, nodesByID: nodesByID)
                )
            }
        let ways = waysByID.values
            .filter { isCourseBoundary($0.tags) }
            .map { way in
                CourseBoundary(
                    id: way.id, osmType: "way",
                    name: way.tags?["name"], tags: way.tags ?? [:],
                    boundary: [coordinates(for: way, nodesByID: nodesByID)]
                )
            }
        return (relations + ways).filter { $0.boundary.contains { $0.count >= 3 } }
    }

    /// True for an element that represents a whole golf course rather than a feature
    /// inside one. A real course is `leisure=golf_course` with no `golf=*` sub-tag;
    /// the `golf` tag marks features (greens, tees, driving ranges) that are
    /// sometimes additionally — and incorrectly — tagged `leisure=golf_course`.
    private static func isCourseBoundary(_ tags: [String: String]?) -> Bool {
        tags?["leisure"] == "golf_course" && tags?["golf"] == nil
    }


    private static func coordinates(for way: OverpassWay, nodesByID: [Int64: OverpassNode]) -> [Coordinate] {
        // `out geom` inlines vertex coordinates directly on the way; fall back to
        // resolving node references for responses that only carry a node table.
        if let geometry = way.geometry, !geometry.isEmpty {
            return geometry
        }
        return (way.nodes ?? []).compactMap { id in
            nodesByID[id].map { Coordinate(lat: $0.lat, lon: $0.lon) }
        }
    }

    private static func boundaryRings(
        for relation: OverpassRelation,
        waysByID: [Int64: OverpassWay],
        nodesByID: [Int64: OverpassNode]
    ) -> [[Coordinate]] {
        // OSM splits each outer boundary across multiple ways stored in arbitrary
        // order and direction, and a `type=multipolygon` course has SEVERAL disjoint
        // outer loops (TPC Sawgrass is 4 parcels split by water/roads/housing).
        // Assemble every closed ring — stitching one loop until it closes, then
        // starting the next from the leftover segments — so outlying parcels (and the
        // holes inside them) are not dropped.
        //
        // With `out geom` the relation's member ways carry their geometry inline, so
        // prefer that and fall back to the way table for node-reference responses.
        let segments = relation.members
            .filter { $0.type == "way" && ($0.role == "outer" || $0.role.isEmpty) }
            .map { member -> [Coordinate] in
                if let geometry = member.geometry, !geometry.isEmpty {
                    return geometry
                }
                return waysByID[member.ref].map { coordinates(for: $0, nodesByID: nodesByID) } ?? []
            }
        return assembleRings(from: segments)
    }

    /// Assembles boundary segments into one or more closed rings. Extends the current
    /// ring from either endpoint (reversing a segment that faces the wrong way) and
    /// stops as soon as the ring closes — critically, this prevents a separate disjoint
    /// loop from being merged onto the first. Any leftover segments seed the next ring,
    /// so a multipolygon yields all of its disjoint pieces.
    private static func assembleRings(from segments: [[Coordinate]]) -> [[Coordinate]] {
        var remaining = segments.filter { $0.count >= 2 }
        var rings: [[Coordinate]] = []

        while !remaining.isEmpty {
            var ring = remaining.removeFirst()

            while ring.first != ring.last {
                guard let ringStart = ring.first, let ringEnd = ring.last else { break }
                let match = remaining.enumerated().first { _, seg in
                    seg.first == ringEnd || seg.last == ringEnd ||
                    seg.first == ringStart || seg.last == ringStart
                }
                guard let (index, seg) = match else { break }
                remaining.remove(at: index)

                if seg.first == ringEnd {
                    ring.append(contentsOf: seg.dropFirst())
                } else if seg.last == ringEnd {
                    ring.append(contentsOf: seg.reversed().dropFirst())
                } else if seg.last == ringStart {
                    ring.insert(contentsOf: seg.dropLast(), at: 0)
                } else { // seg.first == ringStart
                    ring.insert(contentsOf: seg.reversed().dropLast(), at: 0)
                }
            }

            if ring.count >= 3 { rings.append(ring) }
        }

        return rings
    }

    /// Greedily connects boundary segments end-to-end into a SINGLE ring, reversing a
    /// segment when its matching endpoint faces the wrong way. Used for multipolygon
    /// *features* (a fairway/green), which are a single area rather than a course made
    /// of disjoint parcels.
    private static func stitchRing(from segments: [[Coordinate]]) -> [Coordinate] {
        var remaining = segments.filter { $0.count >= 2 }
        guard !remaining.isEmpty else { return [] }

        var ring = remaining.removeFirst()

        while !remaining.isEmpty {
            guard let ringStart = ring.first, let ringEnd = ring.last else { break }

            let match = remaining.enumerated().first { _, seg in
                seg.first == ringEnd || seg.last == ringEnd ||
                seg.first == ringStart || seg.last == ringStart
            }
            guard let (index, seg) = match else { break }
            remaining.remove(at: index)

            if seg.first == ringEnd {
                ring.append(contentsOf: seg.dropFirst())
            } else if seg.last == ringEnd {
                ring.append(contentsOf: seg.reversed().dropFirst())
            } else if seg.last == ringStart {
                ring.insert(contentsOf: seg.dropLast(), at: 0)
            } else { // seg.first == ringStart
                ring.insert(contentsOf: seg.reversed().dropLast(), at: 0)
            }
        }

        return ring
    }

    private static func holes(from waysByID: [Int64: OverpassWay], nodesByID: [Int64: OverpassNode]) -> [OSMHole] {
        waysByID.values
            .filter { ($0.tags?["golf"]) == "hole" }
            .map { way in
                OSMHole(
                    osmIdentifier: way.id,
                    ref: way.tags?["ref"],
                    par: way.tags?["par"].flatMap(Int.init),
                    lengthMeters: (way.tags?["length"] ?? way.tags?["distance"]).flatMap(Double.init),
                    coordinates: coordinates(for: way, nodesByID: nodesByID),
                    tags: way.tags ?? [:]
                )
            }
            // Order by hole number *numerically* — a lexicographic sort would order
            // refs as "1, 10, 11 … 18, 2, 3 …", making Play-mode navigation jump from
            // hole 1 straight to 10. Non-numeric / missing refs sort last, then by
            // string for a stable order.
            .sorted { lhs, rhs in
                let l = lhs.ref.flatMap { Int($0) } ?? Int.max
                let r = rhs.ref.flatMap { Int($0) } ?? Int.max
                if l != r { return l < r }
                return (lhs.ref ?? "") < (rhs.ref ?? "")
            }
    }

    private static func features(
        from waysByID: [Int64: OverpassWay],
        relationsByID: [Int64: OverpassRelation],
        nodesByID: [Int64: OverpassNode]
    ) -> [OSMFeature] {
        var result: [OSMFeature] = []

        // Way features: a single ring/line per way.
        for way in waysByID.values {
            guard let golfTag = way.tags?["golf"], golfTag != "hole", golfTag != "golf_course" else { continue }
            let kind = OSMFeature.Kind(rawValue: golfTag) ?? .unknown
            let coords = coordinates(for: way, nodesByID: nodesByID)
            let isClosed = coords.count > 2 && coords.first == coords.last
            result.append(OSMFeature(
                osmIdentifier: way.id,
                kind: kind,
                coordinates: coords,
                isClosed: isClosed,
                tags: way.tags ?? [:]
            ))
        }

        // Relation (multipolygon) features: many fairways/greens are mapped as
        // multipolygons rather than simple ways. The builder used to ignore these,
        // so they went missing. Stitch each relation's `outer` members into a ring
        // and emit it as a closed feature. Inner rings (holes cut out of the area,
        // e.g. a bunker) are not subtracted; the overlap is hidden by the bunker
        // overlay drawn on top.
        for relation in relationsByID.values {
            guard let golfTag = relation.tags?["golf"], golfTag != "hole", golfTag != "golf_course" else { continue }
            let kind = OSMFeature.Kind(rawValue: golfTag) ?? .unknown
            let outerSegments = relation.members
                .filter { $0.role == "outer" }
                .compactMap { member -> [Coordinate]? in
                    if let geometry = member.geometry, !geometry.isEmpty { return geometry }
                    return waysByID[member.ref].map { coordinates(for: $0, nodesByID: nodesByID) }
                }
            let ring = stitchRing(from: outerSegments)
            guard ring.count >= 3 else { continue }
            result.append(OSMFeature(
                osmIdentifier: relation.id,
                kind: kind,
                coordinates: ring,
                isClosed: true,
                tags: relation.tags ?? [:]
            ))
        }

        return result
    }
}

// MARK: - Geometry

nonisolated enum GolfGeometry {
    /// Ray-casting point-in-polygon test (lon = x, lat = y). Attributes holes and
    /// features to a sub-course and tests sub-course containment within a facility.
    static func isInside(_ point: Coordinate, polygon: [Coordinate]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.lat > point.lat) != (b.lat > point.lat),
               point.lon < (b.lon - a.lon) * (point.lat - a.lat) / (b.lat - a.lat) + a.lon {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Multi-ring point-in-polygon test using the even-odd rule across every ring.
    /// Correct for both a course made of disjoint outer parcels (inside iff inside one
    /// of them) and a donut with an inner cutout (the cutout reads as outside).
    static func isInside(_ point: Coordinate, rings: [[Coordinate]]) -> Bool {
        var inside = false
        for ring in rings where ring.count >= 3 {
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[i]
                let b = ring[j]
                if (a.lat > point.lat) != (b.lat > point.lat),
                   point.lon < (b.lon - a.lon) * (point.lat - a.lat) / (b.lat - a.lat) + a.lon {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
    }

    /// Absolute polygon area via the shoelace formula, in degree². Only meaningful
    /// for *comparing* boundaries (largest wins), not as a real-world measurement.
    static func ringArea(_ coords: [Coordinate]) -> Double {
        guard coords.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<coords.count {
            let a = coords[i]
            let b = coords[(i + 1) % coords.count]
            sum += a.lon * b.lat - b.lon * a.lat
        }
        return abs(sum) / 2
    }

    /// Total area of a multi-ring polygon (sum of its rings). Used to compare whole
    /// boundaries — e.g. to pick the largest as the facility primary.
    static func polygonArea(_ rings: [[Coordinate]]) -> Double {
        rings.reduce(0) { $0 + ringArea($1) }
    }

    /// A point guaranteed to lie inside a multi-ring polygon: the centroid of its
    /// largest ring. (The area-weighted centroid of disjoint rings can fall in the gap
    /// between them, so the largest ring's centroid is used for containment tests.)
    static func centroid(ofRings rings: [[Coordinate]]) -> Coordinate? {
        rings.max { ringArea($0) < ringArea($1) }.flatMap { centroid(of: $0) }
    }

    /// Area-weighted polygon centroid, falling back to the vertex average for a
    /// degenerate (zero-area) ring. The centroid of a child course ring sits inside
    /// the enclosing facility, which is what sub-course containment relies on.
    static func centroid(of coords: [Coordinate]) -> Coordinate? {
        guard !coords.isEmpty else { return nil }
        var area = 0.0
        var cx = 0.0
        var cy = 0.0
        for i in 0..<coords.count {
            let a = coords[i]
            let b = coords[(i + 1) % coords.count]
            let cross = a.lon * b.lat - b.lon * a.lat
            area += cross
            cx += (a.lon + b.lon) * cross
            cy += (a.lat + b.lat) * cross
        }
        if area == 0 {
            let n = Double(coords.count)
            return Coordinate(
                lat: coords.reduce(0) { $0 + $1.lat } / n,
                lon: coords.reduce(0) { $0 + $1.lon } / n
            )
        }
        area *= 0.5
        return Coordinate(lat: cy / (6 * area), lon: cx / (6 * area))
    }

    /// Convex hull (Andrew's monotone chain) of a coordinate set, returned as a
    /// counter-clockwise ring. Used to synthesize a boundary for a tag-grouped
    /// sub-course that has no polygon of its own — the hull of its holes' coordinates
    /// (tee→green polylines) encloses the playing corridors, greens included.
    static func convexHull(_ points: [Coordinate]) -> [Coordinate] {
        let unique = Array(Set(points))
        guard unique.count >= 3 else { return unique }
        let sorted = unique.sorted { $0.lon != $1.lon ? $0.lon < $1.lon : $0.lat < $1.lat }

        func cross(_ o: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Double {
            (a.lon - o.lon) * (b.lat - o.lat) - (a.lat - o.lat) * (b.lon - o.lon)
        }
        func half(_ pts: [Coordinate]) -> [Coordinate] {
            var chain: [Coordinate] = []
            for p in pts {
                while chain.count >= 2, cross(chain[chain.count - 2], chain[chain.count - 1], p) <= 0 {
                    chain.removeLast()
                }
                chain.append(p)
            }
            chain.removeLast()
            return chain
        }
        return half(sorted) + half(sorted.reversed())
    }

    /// Expands a ring outward from its centroid by `fraction` (e.g. 0.08 = +8%), so a
    /// synthesized hull catches edge bunkers and greens that sit just outside the raw
    /// hull of the hole centerlines.
    static func buffered(_ ring: [Coordinate], by fraction: Double) -> [Coordinate] {
        guard fraction != 0, ring.count >= 3, let center = centroid(of: ring) else { return ring }
        return ring.map {
            Coordinate(
                lat: center.lat + ($0.lat - center.lat) * (1 + fraction),
                lon: center.lon + ($0.lon - center.lon) * (1 + fraction)
            )
        }
    }
}
