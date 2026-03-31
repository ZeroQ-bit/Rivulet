//
//  MediaItemEntity.swift
//  Rivulet
//
//  AppEntity representing a Plex media item for Siri integration.
//  Used by PlayMediaIntent and SearchMediaIntent for disambiguation and results.
//

import AppIntents
import Foundation

// MARK: - Media Item Entity

struct MediaItemEntity: AppEntity {
    var id: String
    var title: String
    var subtitle: String?
    var mediaType: String
    var thumbURL: URL?

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media")
    static var defaultQuery = MediaItemQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { LocalizedStringResource(stringLiteral: $0) },
            image: thumbURL.map { .init(url: $0) }
        )
    }

    /// Create from PlexMetadata
    init(from metadata: PlexMetadata, serverURL: String, token: String) {
        self.id = metadata.ratingKey ?? ""
        self.title = metadata.title ?? "Unknown"
        self.mediaType = metadata.type ?? "movie"
        self.subtitle = Self.buildSubtitle(from: metadata)
        self.thumbURL = Self.buildThumbURL(from: metadata, serverURL: serverURL, token: token)
    }

    /// Direct init for testing/manual construction
    init(id: String, title: String, subtitle: String? = nil, mediaType: String, thumbURL: URL? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.mediaType = mediaType
        self.thumbURL = thumbURL
    }

    // MARK: - Subtitle Builder

    private static func buildSubtitle(from metadata: PlexMetadata) -> String {
        switch metadata.type {
        case "episode":
            let season = metadata.parentIndex ?? 0
            let episode = metadata.index ?? 0
            let epString = String(format: "S%02dE%02d", season, episode)
            if let showTitle = metadata.grandparentTitle {
                return "\(epString) \u{00B7} \(showTitle)"
            }
            return epString

        default:
            // Movie, Show, Season, etc.
            let typeDisplay = metadata.mediaTypeDisplay
            if let year = metadata.year {
                return "\(year) \u{00B7} \(typeDisplay)"
            }
            return typeDisplay
        }
    }

    // MARK: - Thumbnail URL Builder

    private static func buildThumbURL(from metadata: PlexMetadata, serverURL: String, token: String) -> URL? {
        guard let thumb = metadata.bestThumb else { return nil }
        var components = URLComponents(string: "\(serverURL)\(thumb)")
        components?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return components?.url
    }
}

// MARK: - Entity Query

struct MediaItemQuery: EntityStringQuery {

    private func credentials() async -> (serverURL: String, token: String)? {
        let (serverURL, token) = await MainActor.run {
            (PlexAuthManager.shared.selectedServerURL,
             PlexAuthManager.shared.selectedServerToken)
        }
        guard let serverURL, let token else { return nil }
        return (serverURL, token)
    }

    func entities(for identifiers: [String]) async throws -> [MediaItemEntity] {
        guard let creds = await credentials() else { return [] }

        var results: [MediaItemEntity] = []
        for ratingKey in identifiers {
            do {
                let metadata = try await PlexNetworkManager.shared.getMetadata(
                    serverURL: creds.serverURL,
                    authToken: creds.token,
                    ratingKey: ratingKey
                )
                results.append(MediaItemEntity(from: metadata, serverURL: creds.serverURL, token: creds.token))
            } catch {
                continue
            }
        }
        return results
    }

    func entities(matching query: String) async throws -> [MediaItemEntity] {
        guard !query.isEmpty, let creds = await credentials() else { return [] }

        let results = try await PlexNetworkManager.shared.search(
            serverURL: creds.serverURL,
            authToken: creds.token,
            query: query,
            size: 10
        )

        return results.map { MediaItemEntity(from: $0, serverURL: creds.serverURL, token: creds.token) }
    }

    func suggestedEntities() async throws -> [MediaItemEntity] {
        guard let creds = await credentials() else { return [] }

        do {
            let onDeck = try await PlexNetworkManager.shared.getOnDeck(
                serverURL: creds.serverURL,
                authToken: creds.token
            )
            return onDeck.prefix(5).map { MediaItemEntity(from: $0, serverURL: creds.serverURL, token: creds.token) }
        } catch {
            return []
        }
    }
}
