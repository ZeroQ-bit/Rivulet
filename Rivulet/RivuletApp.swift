//
//  RivuletApp.swift
//  Rivulet
//
//  Created by Bain Gurley on 11/28/25.
//

import SwiftUI
import SwiftData
import Sentry

@main
struct RivuletApp: App {

    init() {
        #if !DEBUG
        SentrySDK.start { options in
            options.dsn = Secrets.sentryDSN
            options.debug = false
            options.tracesSampleRate = 1.0
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            options.enableCaptureFailedRequests = true
            options.enableSwizzling = true
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2

            options.beforeSend = { event in
                // Drop cancelled URL request errors — these are normal when navigating away
                if let exceptions = event.exceptions,
                   exceptions.contains(where: { $0.value?.contains("Code=-999") == true || $0.value?.contains("cancelled") == true }) {
                    return nil
                }
                if let message = event.message?.formatted,
                   message.contains("Code=-999") || (message.contains("NSURLErrorDomain") && message.contains("cancelled")) {
                    return nil
                }
                return event
            }
        }
        #endif

        // NowPlayingService disabled — AVPlayerViewController handles Now Playing natively.
        // NowPlayingService.shared.initialize()
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ServerConfiguration.self,
            PlexServer.self,
            IPTVSource.self,
            Channel.self,
            FavoriteChannel.self,
            WatchProgress.self,
            EPGProgram.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // Handle deep links from Top Shelf
                    Task {
                        await DeepLinkHandler.shared.handle(url: url)
                    }
                }
                .onContinueUserActivity("com.rivulet.viewMedia") { activity in
                    guard let ratingKey = activity.userInfo?["ratingKey"] as? String,
                          !ratingKey.isEmpty else { return }
                    Task {
                        await DeepLinkHandler.shared.handle(
                            url: URL(string: "rivulet://detail?ratingKey=\(ratingKey)")!
                        )
                    }
                }
                .onContinueUserActivity("com.rivulet.playMedia") { activity in
                    guard let ratingKey = activity.userInfo?["ratingKey"] as? String,
                          !ratingKey.isEmpty else { return }
                    Task {
                        await DeepLinkHandler.shared.handle(
                            url: URL(string: "rivulet://play?ratingKey=\(ratingKey)")!
                        )
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
