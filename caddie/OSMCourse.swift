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
    let raw: OverpassResponse
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
    let nodes: [Int64]
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
                features: features(from: waysByID, nodesByID: nodesByID),
                raw: response
            )
        }

        if let way = waysByID.values.first(where: { ($0.tags?["leisure"]) == "golf_course" }) {
            return OSMCourse(
                osmIdentifier: way.id,
                osmType: "way",
                name: way.tags?["name"],
                tags: way.tags ?? [:],
                boundary: coordinates(for: way, nodesByID: nodesByID),
                holes: holes(from: waysByID, nodesByID: nodesByID),
                features: features(from: waysByID, nodesByID: nodesByID),
                raw: response
            )
        }

        return nil
    }

    private static func coordinates(for way: OverpassWay, nodesByID: [Int64: OverpassNode]) -> [Coordinate] {
        way.nodes.compactMap { id in
            nodesByID[id].map { Coordinate(lat: $0.lat, lon: $0.lon) }
        }
    }

    private static func boundaryCoordinates(
        for relation: OverpassRelation,
        waysByID: [Int64: OverpassWay],
        nodesByID: [Int64: OverpassNode]
    ) -> [Coordinate] {
        // Concatenate the outer-ring ways; not a full ring-stitch but good enough for a single closed boundary.
        relation.members
            .filter { $0.type == "way" && ($0.role == "outer" || $0.role.isEmpty) }
            .compactMap { waysByID[$0.ref] }
            .flatMap { coordinates(for: $0, nodesByID: nodesByID) }
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

    private static func features(from waysByID: [Int64: OverpassWay], nodesByID: [Int64: OverpassNode]) -> [OSMFeature] {
        waysByID.values.compactMap { way in
            guard let golfTag = way.tags?["golf"], golfTag != "hole", golfTag != "golf_course" else { return nil }
            let kind = OSMFeature.Kind(rawValue: golfTag) ?? .unknown
            let coords = coordinates(for: way, nodesByID: nodesByID)
            let isClosed = coords.count > 2 && coords.first == coords.last
            return OSMFeature(
                osmIdentifier: way.id,
                kind: kind,
                coordinates: coords,
                isClosed: isClosed,
                tags: way.tags ?? [:]
            )
        }
    }
}
