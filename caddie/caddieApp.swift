//
//  caddieApp.swift
//  caddie
//
//  Created by Jeff Roberts on 6/23/26.
//

import SwiftData
import SwiftUI

@main
struct caddieApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [RecentCourse.self, FavoriteCourse.self, OSMCourseData.self])
    }
}
