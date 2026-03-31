//
//  DeepLinkHandler.swift
//  Rivulet
//
//  Handles deep links from Top Shelf, Siri intents, and other URL schemes
//

import Foundation
import Combine

@MainActor
final class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()

    @Published var pendingPlayback: PlexMetadata?
    @Published var pendingDetail: PlexMetadata?

    private init() {}

    // MARK: - URL Handling

    func handle(url: URL) async {
        guard url.scheme == "rivulet" else { return }

        switch url.host {
        case "play":
            await handlePlayURL(url)
        case "detail":
            await handleDetailURL(url)
        default:
            break
        }
    }

    // MARK: - Direct Intent Handlers

    func handlePlay(ratingKey: String) {
        Task {
            await fetchAndSetPlayback(ratingKey: ratingKey)
        }
    }

    func handleDetail(ratingKey: String) {
        Task {
            await fetchAndSetDetail(ratingKey: ratingKey)
        }
    }

    // MARK: - Play URL

    private func handlePlayURL(_ url: URL) async {
        guard let ratingKey = extractRatingKey(from: url) else {
            print("DeepLinkHandler: Missing ratingKey in play URL")
            return
        }
        await fetchAndSetPlayback(ratingKey: ratingKey)
    }

    // MARK: - Detail URL

    private func handleDetailURL(_ url: URL) async {
        guard let ratingKey = extractRatingKey(from: url) else {
            print("DeepLinkHandler: Missing ratingKey in detail URL")
            return
        }
        await fetchAndSetDetail(ratingKey: ratingKey)
    }

    // MARK: - Shared Helpers

    private func extractRatingKey(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "ratingKey" })?.value
    }

    private func fetchAndSetPlayback(ratingKey: String) async {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let authToken = PlexAuthManager.shared.authToken else {
            print("DeepLinkHandler: No Plex credentials available")
            return
        }

        do {
            let metadata = try await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            pendingPlayback = metadata
        } catch {
            print("DeepLinkHandler: Failed to fetch metadata for ratingKey \(ratingKey): \(error)")
        }
    }

    private func fetchAndSetDetail(ratingKey: String) async {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let authToken = PlexAuthManager.shared.authToken else {
            print("DeepLinkHandler: No Plex credentials available")
            return
        }

        do {
            let metadata = try await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            pendingDetail = metadata
        } catch {
            print("DeepLinkHandler: Failed to fetch metadata for ratingKey \(ratingKey): \(error)")
        }
    }
}
