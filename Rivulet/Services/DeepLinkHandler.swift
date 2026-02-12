//
//  DeepLinkHandler.swift
//  Rivulet
//
//  Handles deep links from Top Shelf and other URL schemes
//

import Foundation
import Combine

/// Centralized handler for deep link URLs
/// Primary use case: Top Shelf selection triggers rivulet://play?ratingKey=X
@MainActor
final class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()

    /// Metadata to play when a deep link is received
    /// TVSidebarView observes this and presents the player
    @Published var pendingPlayback: PlexMetadata?

    private init() {}

    // MARK: - URL Handling

    /// Handle an incoming URL
    /// - Parameter url: The URL to process (e.g., rivulet://play?ratingKey=12345)
    func handle(url: URL) async {
        guard url.scheme == "rivulet" else { return }

        switch url.host {
        case "play":
            await handlePlayURL(url)
        default:
            break
        }
    }

    // MARK: - Play URL

    /// Handle rivulet://play?ratingKey=X&server=Y
    private func handlePlayURL(_ url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let ratingKey = components.queryItems?.first(where: { $0.name == "ratingKey" })?.value
        else {
            print("DeepLinkHandler: Missing ratingKey in play URL")
            return
        }

        // Get auth credentials
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let authToken = PlexAuthManager.shared.authToken
        else {
            print("DeepLinkHandler: No Plex credentials available")
            return
        }

        do {
            // Fetch full metadata for the item
            let metadata = try await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )

            // Set pending playback - TVSidebarView will observe and present player
            pendingPlayback = metadata
        } catch {
            print("DeepLinkHandler: Failed to fetch metadata for ratingKey \(ratingKey): \(error)")
        }
    }
}
