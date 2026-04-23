//
//  PlexModels.swift
//  Rivulet
//
//  Ported from plex_watchOS - Models.swift
//  Original created by Bain Gurley on 4/19/24.
//

import Foundation

// MARK: - Plex API Configuration

/// Plex API constants
nonisolated enum PlexAPI: Sendable {
    static let baseUrl = "https://plex.tv"
    static let discoverBaseUrl = "https://discover.provider.plex.tv"
    static let clientIdentifier = "com.gstudios.rivulet"
    static let productName = "Rivulet"
    static let deviceName = "Apple TV"
    static let platform = "tvOS"
}

// MARK: - Server/Device Models

nonisolated struct PlexDevice: Codable, Sendable {
    let name: String
    let product: String
    let productVersion: String
    let platform: String?
    let platformVersion: String?
    let device: String?
    let clientIdentifier: String
    let createdAt: String
    let lastSeenAt: String
    let provides: String
    let ownerId: String?
    let sourceTitle: String?
    let publicAddress: String?
    let accessToken: String?
    let owned: Bool?
    let home: Bool?
    let synced: Bool?
    let relay: Bool?
    let presence: Bool?
    let httpsRequired: Bool?
    let publicAddressMatches: Bool?
    let dnsRebindingProtection: Bool?
    let natLoopbackSupported: Bool?
    let connections: [PlexConnection]?

    /// The 32-char server identifier used for plex.direct URLs
    /// This is fetched separately from pms/servers.xml
    var machineIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case name, product, productVersion, platform, platformVersion, device
        case clientIdentifier, createdAt, lastSeenAt, provides, ownerId
        case sourceTitle, publicAddress, accessToken, owned, home, synced
        case relay, presence, httpsRequired, publicAddressMatches
        case dnsRebindingProtection, natLoopbackSupported, connections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        product = try container.decode(String.self, forKey: .product)
        productVersion = try container.decode(String.self, forKey: .productVersion)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        platformVersion = try container.decodeIfPresent(String.self, forKey: .platformVersion)
        device = try container.decodeIfPresent(String.self, forKey: .device)
        clientIdentifier = try container.decode(String.self, forKey: .clientIdentifier)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        lastSeenAt = try container.decode(String.self, forKey: .lastSeenAt)
        provides = try container.decode(String.self, forKey: .provides)

        // Handle ownerId as either String or Int
        if let ownerIdString = try? container.decode(String.self, forKey: .ownerId) {
            ownerId = ownerIdString
        } else if let ownerIdInt = try? container.decode(Int.self, forKey: .ownerId) {
            ownerId = String(ownerIdInt)
        } else {
            ownerId = nil
        }

        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        publicAddress = try container.decodeIfPresent(String.self, forKey: .publicAddress)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        owned = try container.decodeIfPresent(Bool.self, forKey: .owned)
        home = try container.decodeIfPresent(Bool.self, forKey: .home)
        synced = try container.decodeIfPresent(Bool.self, forKey: .synced)
        relay = try container.decodeIfPresent(Bool.self, forKey: .relay)
        presence = try container.decodeIfPresent(Bool.self, forKey: .presence)
        httpsRequired = try container.decodeIfPresent(Bool.self, forKey: .httpsRequired)
        publicAddressMatches = try container.decodeIfPresent(Bool.self, forKey: .publicAddressMatches)
        dnsRebindingProtection = try container.decodeIfPresent(Bool.self, forKey: .dnsRebindingProtection)
        natLoopbackSupported = try container.decodeIfPresent(Bool.self, forKey: .natLoopbackSupported)
        connections = try container.decodeIfPresent([PlexConnection].self, forKey: .connections)
    }
}

nonisolated struct PlexConnection: Codable, Sendable {
    let protocolType: String
    let address: String
    let port: Int
    let uri: String
    let local: Bool
    let relay: Bool
    let IPv6: Bool

    enum CodingKeys: String, CodingKey {
        case protocolType = "protocol"
        case address, port, uri, local, relay, IPv6
    }

    /// Full URL for this connection
    var fullURL: String {
        return uri
    }
}

// MARK: - Library Models

nonisolated struct PlexLibraryContainer: Codable, Sendable {
    let MediaContainer: PlexLibraryMediaContainer
}

nonisolated struct PlexLibraryMediaContainer: Codable, Sendable {
    let size: Int
    let title1: String?
    let Directory: [PlexLibrary]?
}

nonisolated struct PlexLibrary: Codable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let type: String          // "movie", "show", "artist", etc.
    let title: String
    let agent: String
    let scanner: String
    let language: String
    let uuid: String
    let updatedAt: Int?
    let createdAt: Int?
    let scannedAt: Int?
    let Location: [PlexLibraryLocation]?

    /// Check if this is a video library
    var isVideoLibrary: Bool {
        type == "movie" || type == "show"
    }

    /// Check if this is a music library
    var isMusicLibrary: Bool {
        type == "artist"
    }
}

nonisolated struct PlexLibraryLocation: Codable, Sendable {
    let id: Int
    let path: String
}

// MARK: - Media Container (Generic Response Wrapper)

nonisolated struct PlexMediaContainer: Codable, Sendable {
    var size: Int?
    var totalSize: Int?  // Total items in collection (for pagination)
    var librarySectionID: Int?  // Library section ID (at container level)
    var librarySectionTitle: String?
    var Metadata: [PlexMetadata]?
    var Hub: [PlexHub]?

    enum CodingKeys: String, CodingKey {
        case size
        case totalSize
        case librarySectionID
        case librarySectionTitle
        case Metadata
        case Hub
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        totalSize = try container.decodeIfPresent(Int.self, forKey: .totalSize)

        if let sectionID = try? container.decodeIfPresent(Int.self, forKey: .librarySectionID) {
            librarySectionID = sectionID
        } else if let sectionIDString = try? container.decodeIfPresent(String.self, forKey: .librarySectionID),
                  let parsedSectionID = Int(sectionIDString) {
            librarySectionID = parsedSectionID
        } else {
            librarySectionID = nil
        }

        librarySectionTitle = try container.decodeIfPresent(String.self, forKey: .librarySectionTitle)
        Metadata = try container.decodeIfPresent([PlexMetadata].self, forKey: .Metadata)
        Hub = try container.decodeIfPresent([PlexHub].self, forKey: .Hub)
    }
}

nonisolated struct PlexMediaContainerWrapper: Codable, Sendable {
    var MediaContainer: PlexMediaContainer
}

// MARK: - Subtitle Search / Download

nonisolated struct PlexSubtitleSearchContainerWrapper: Codable, Sendable {
    let MediaContainer: PlexSubtitleSearchMediaContainer
}

nonisolated struct PlexSubtitleSearchMediaContainer: Codable, Sendable {
    let size: Int?
    let Stream: [PlexSubtitleCandidate]?

    enum CodingKeys: String, CodingKey {
        case size
        case Stream
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decodeIfPresent(Int.self, forKey: .size)

        if let streams = try? container.decodeIfPresent([PlexSubtitleCandidate].self, forKey: .Stream) {
            Stream = streams
        } else if let stream = try? container.decodeIfPresent(PlexSubtitleCandidate.self, forKey: .Stream) {
            Stream = [stream]
        } else {
            Stream = nil
        }
    }
}

nonisolated struct PlexSubtitleCandidate: Codable, Sendable {
    let id: Int?
    let key: String?
    let sourceKey: String?
    let streamType: Int?
    let codec: String?
    let index: Int?
    let language: String?
    let languageCode: String?
    let score: Double?
    let providerTitle: String?
    let title: String?
    let displayTitle: String?
    let reason: String?
    let hearingImpaired: Bool?
    let perfectMatch: Bool?
    let downloaded: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case sourceKey
        case streamType
        case codec
        case index
        case language
        case languageCode
        case score
        case providerTitle
        case title
        case displayTitle
        case reason
        case hearingImpaired
        case perfectMatch
        case downloaded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        sourceKey = try container.decodeIfPresent(String.self, forKey: .sourceKey)
        streamType = try container.decodeIfPresent(Int.self, forKey: .streamType)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        if let numericScore = try? container.decodeIfPresent(Double.self, forKey: .score) {
            score = numericScore
        } else if let stringScore = try? container.decodeIfPresent(String.self, forKey: .score),
                  let parsedScore = Double(stringScore) {
            score = parsedScore
        } else {
            score = nil
        }
        providerTitle = try container.decodeIfPresent(String.self, forKey: .providerTitle)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        hearingImpaired = try container.decodeIfPresent(Bool.self, forKey: .hearingImpaired)
        perfectMatch = try container.decodeIfPresent(Bool.self, forKey: .perfectMatch)
        downloaded = try container.decodeIfPresent(Bool.self, forKey: .downloaded)
    }
}

/// Container for extras API response
nonisolated struct PlexExtrasMediaContainer: Codable, Sendable {
    var size: Int?
    var Metadata: [PlexExtra]?
}

nonisolated struct PlexExtrasContainerWrapper: Codable, Sendable {
    var MediaContainer: PlexExtrasMediaContainer
}

// MARK: - Hub (for home screen sections)

nonisolated struct PlexHub: Codable, Identifiable, Sendable {
    var id: String { hubIdentifier ?? title ?? UUID().uuidString }
    var hubIdentifier: String?
    var title: String?
    var type: String?
    var hubKey: String?
    var key: String?
    var more: Bool?
    var size: Int?
    var Metadata: [PlexMetadata]?

    init(
        hubIdentifier: String? = nil,
        title: String? = nil,
        type: String? = nil,
        hubKey: String? = nil,
        key: String? = nil,
        more: Bool? = nil,
        size: Int? = nil,
        Metadata: [PlexMetadata]? = nil
    ) {
        self.hubIdentifier = hubIdentifier
        self.title = title
        self.type = type
        self.hubKey = hubKey
        self.key = key
        self.more = more
        self.size = size
        self.Metadata = Metadata
    }
}

// MARK: - Media Item (Movie, Show, Episode, etc.)

struct PlexMedia: Codable, Sendable {
    let id: Int
    let duration: Int?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let aspectRatio: Double?
    let audioChannels: Int?
    let audioCodec: String?
    let videoCodec: String?
    let videoResolution: String?
    let container: String?
    let videoFrameRate: String?
    let Part: [PlexPart]?
}

struct PlexPart: Codable, Sendable {
    let id: Int
    let key: String
    let duration: Int?
    let file: String?
    let size: Int?
    let container: String?
    let Stream: [PlexStream]?
}

struct PlexChapter: Codable, Sendable {
    let id: Int?
    let tag: String?              // Chapter name (e.g., "Chapter 1", "Opening")
    let index: Int?               // Chapter sequence number
    let startTimeOffset: Int?     // Start time in milliseconds
    let endTimeOffset: Int?       // End time in milliseconds
    let thumb: String?            // Chapter thumbnail path (e.g., "/library/media/202357/chapterImages/1")
}
