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

nonisolated struct OSMCourse: Codable, Hashable {
    let osmIdentifier: Int64
    let osmType: String
    let name: String?
    let tags: [String: String]
    let boundary: [Coordinate]
    let holes: [OSMHole]
    let features: [OSMFeature]
    let trees: [Coordinate]

    init(
        osmIdentifier: Int64,
        osmType: String,
        name: String?,
        tags: [String: String],
        boundary: [Coordinate],
        holes: [OSMHole],
        features: [OSMFeature],
        trees: [Coordinate]
    ) {
        self.osmIdentifier = osmIdentifier
        self.osmType = osmType
        self.name = name
        self.tags = tags
        self.boundary = boundary
        self.holes = holes
        self.features = features
        self.trees = trees
    }

    // Custom decoder so rows cached before `trees` existed still load (the key
    // defaults to empty rather than failing the whole decode).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        osmIdentifier = try c.decode(Int64.self, forKey: .osmIdentifier)
        osmType = try c.decode(String.self, forKey: .osmType)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        tags = try c.decode([String: String].self, forKey: .tags)
        boundary = try c.decode([Coordinate].self, forKey: .boundary)
        holes = try c.decode([OSMHole].self, forKey: .holes)
        features = try c.decode([OSMFeature].self, forKey: .features)
        trees = try c.decodeIfPresent([Coordinate].self, forKey: .trees) ?? []
    }

    /// Returns a copy with the trees replaced — used when trees arrive in a separate
    /// final fetch stage after the features have already been drawn and cached.
    func withTrees(_ trees: [Coordinate]) -> OSMCourse {
        OSMCourse(
            osmIdentifier: osmIdentifier,
            osmType: osmType,
            name: name,
            tags: tags,
            boundary: boundary,
            holes: holes,
            features: features,
            trees: trees
        )
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
    /// Walks an Overpass response and produces an OSMCourse for the first matching
    /// `leisure=golf_course` element, resolving node references into coordinate arrays.
    static func makeCourse(from response: OverpassResponse) -> OSMCourse? {
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

        // Prefer a relation tagged as a golf course; fall back to a way.
        if let relation = relationsByID.values.first(where: { ($0.tags?["leisure"]) == "golf_course" }) {
            let boundary = boundaryCoordinates(for: relation, waysByID: waysByID, nodesByID: nodesByID)
            return OSMCourse(
                osmIdentifier: relation.id,
                osmType: "relation",
                name: relation.tags?["name"],
                tags: relation.tags ?? [:],
                boundary: boundary,
                holes: holes(from: waysByID, nodesByID: nodesByID),
                features: features(from: waysByID, relationsByID: relationsByID, nodesByID: nodesByID),
                trees: trees(from: nodesByID, boundary: boundary)
            )
        }

        if let way = waysByID.values.first(where: { ($0.tags?["leisure"]) == "golf_course" }) {
            let boundary = coordinates(for: way, nodesByID: nodesByID)
            return OSMCourse(
                osmIdentifier: way.id,
                osmType: "way",
                name: way.tags?["name"],
                tags: way.tags ?? [:],
                boundary: boundary,
                holes: holes(from: waysByID, nodesByID: nodesByID),
                features: features(from: waysByID, relationsByID: relationsByID, nodesByID: nodesByID),
                trees: trees(from: nodesByID, boundary: boundary)
            )
        }

        return nil
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

    private static func boundaryCoordinates(
        for relation: OverpassRelation,
        waysByID: [Int64: OverpassWay],
        nodesByID: [Int64: OverpassNode]
    ) -> [Coordinate] {
        // OSM splits a large outer boundary across multiple ways stored in arbitrary
        // order and direction. Stitch them into a single ordered ring by matching
        // shared endpoints; blindly concatenating them yields crossing edges and a
        // self-intersecting polygon that renders as jagged wedges.
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
        return stitchRing(from: segments)
    }

    /// Greedily connects boundary segments end-to-end, reversing a segment when its
    /// matching endpoint faces the wrong way, until no further segment connects.
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
                    lengthMeters: way.tags?["distance"].flatMap(Double.init),
                    coordinates: coordinates(for: way, nodesByID: nodesByID),
                    tags: way.tags ?? [:]
                )
            }
            .sorted { ($0.ref ?? "") < ($1.ref ?? "") }
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

    /// Collects `natural=tree` node positions, keeping only those that fall inside
    /// the course boundary polygon. The Overpass bbox is wider than the course, so
    /// this filter drops trees that belong to neighbouring streets/parks.
    private static func trees(from nodesByID: [Int64: OverpassNode], boundary: [Coordinate]) -> [Coordinate] {
        guard boundary.count >= 3 else { return [] }
        return nodesByID.values
            .filter { ($0.tags?["natural"]) == "tree" }
            .map { Coordinate(lat: $0.lat, lon: $0.lon) }
            .filter { isInside($0, polygon: boundary) }
    }

    /// Extracts tree coordinates from a standalone trees response (the final fetch
    /// stage), clipped to the course boundary.
    static func treeCoordinates(from response: OverpassResponse, boundary: [Coordinate]) -> [Coordinate] {
        var nodesByID: [Int64: OverpassNode] = [:]
        for element in response.elements {
            if case .node(let n) = element { nodesByID[n.id] = n }
        }
        return trees(from: nodesByID, boundary: boundary)
    }

    /// Ray-casting point-in-polygon test. Treats lon as x and lat as y.
    private static func isInside(_ point: Coordinate, polygon: [Coordinate]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[j]
            if (a.lat > point.lat) != (b.lat > point.lat) {
                let slope = (point.lat - a.lat) / (b.lat - a.lat)
                let intersectLon = a.lon + slope * (b.lon - a.lon)
                if point.lon < intersectLon {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }
}
