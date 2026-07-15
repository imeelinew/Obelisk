//
//  Obelisk_iOSApp.swift
//  Obelisk iOS
//
//  Created by Eli New on 2026.07.14.
//

import SwiftUI
import UIKit

@main
struct Obelisk_iOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = ObeliskLibraryModel()
    @State private var favicons = FaviconStore()
    @State private var backgroundSyncTask: Task<Void, Never>?

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .environment(favicons)
                .task {
                    await library.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        backgroundSyncTask?.cancel()
                        backgroundSyncTask = nil
                        Task { await library.resumeCloudSync() }
                    case .background:
                        backgroundSyncTask?.cancel()
                        backgroundSyncTask = Task { @MainActor in
                            let lease = BackgroundSyncLease()
                            defer { lease.end() }
                            await library.finishPendingCloudUploads()
                        }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}

@MainActor
private final class BackgroundSyncLease {
    private var identifier: UIBackgroundTaskIdentifier

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Obelisk Cloud Sync",
            expirationHandler: nil
        )
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
