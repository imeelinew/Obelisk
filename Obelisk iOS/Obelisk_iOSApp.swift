//
//  Obelisk_iOSApp.swift
//  Obelisk iOS
//
//  Created by Eli New on 2026.07.14.
//

import SwiftUI

@main
struct Obelisk_iOSApp: App {
    @State private var library = ObeliskLibraryModel()
    @State private var favicons = FaviconStore()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .environment(favicons)
                .task {
                    await library.start()
                }
        }
    }
}
