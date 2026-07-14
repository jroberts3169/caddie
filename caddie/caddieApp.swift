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
    @State private var overlaySettings = OverlaySettings()

    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: RecentCourse.self, FavoriteCourse.self, OSMCourseData.self, ShotRecord.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(overlaySettings)
        }
        .modelContainer(modelContainer)
        #if DEBUG
        .commands {
            CommandMenu("Debug") {
                Button("Clear OSM Cache") {
                    clearOSMCache()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
        #endif

        Settings {
            OverlaySettingsView()
                .environment(overlaySettings)
        }
    }

    #if DEBUG
    /// Removes every cached OSM boundary/feature row so courses re-fetch fresh data,
    /// leaving recents and favorites untouched.
    private func clearOSMCache() {
        let context = modelContainer.mainContext
        do {
            try context.delete(model: OSMCourseData.self)
            try context.save()
        } catch {
            print("Failed to clear OSM cache: \(error)")
        }
    }
    #endif
}
