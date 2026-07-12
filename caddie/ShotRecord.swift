//
//  ShotRecord.swift
//  caddie
//
//  SwiftData persistence for a recorded shot. Ported from the golf-gen project
//  and adapted to caddie's data model: caddie tracks shots per hole keyed by the
//  hole's OSM identifier (`holeID`) rather than golf-gen's `HoleSession`
//  relationship, so a plain stored `holeID` replaces that relationship here.
//

import CoreLocation
import Foundation
import SwiftData

@Model
final class ShotRecord {
    var timestamp: Date
    /// OSM identifier of the hole this shot was played on.
    var holeID: Int64
    /// Course identifier (matches `GolfCourse.identifier`) so shots survive across
    /// launches and can be scoped to the displayed course.
    var courseIdentifier: String
    /// 1-based order of the shot within its hole.
    var shotIndex: Int
    var club: Club

    // Where the shot started and landed.
    var start: GeoPoint
    var land: GeoPoint

    var surface: Surface

    /// Generated Trackman measurement for this shot.
    var trackman: TrackmanShot

    init(timestamp: Date = .now,
         holeID: Int64,
         courseIdentifier: String,
         shotIndex: Int,
         club: Club,
         start: GeoPoint,
         land: GeoPoint,
         surface: Surface,
         trackman: TrackmanShot) {
        self.timestamp = timestamp
        self.holeID = holeID
        self.courseIdentifier = courseIdentifier
        self.shotIndex = shotIndex
        self.club = club
        self.start = start
        self.land = land
        self.surface = surface
        self.trackman = trackman
    }
}

extension ShotRecord {
    var startCoord: CLLocationCoordinate2D {
        get { start.coordinate }
        set { start = GeoPoint(newValue) }
    }
    var landCoord: CLLocationCoordinate2D {
        get { land.coordinate }
        set { land = GeoPoint(newValue) }
    }
}
