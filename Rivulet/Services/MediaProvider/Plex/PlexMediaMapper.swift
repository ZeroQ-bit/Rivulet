//
//  PlexMediaMapper.swift
//  Rivulet
//
//  All `PlexMetadata` -> agnostic-type translations live here. The boundary
//  between Plex DTOs and the agnostic media layer.
//

import Foundation

enum PlexMediaMapper {

    // MARK: - Library

    static func library(_ section: PlexLibrary, providerID: String) -> MediaLibrary {
        let kind: MediaLibrary.LibraryKind
        switch section.type {
        case "movie": kind = .movies
        case "show": kind = .shows
        case "artist": kind = .music
        case "photo": kind = .photos
        default: kind = .mixed
        }
        return MediaLibrary(id: section.key, providerID: providerID, title: section.title, kind: kind)
    }

    // MARK: - Kind

    static func kind(_ type: String?) -> MediaKind {
        switch type {
        case "movie": return .movie
        case "show": return .show
        case "season": return .season
        case "episode": return .episode
        case "collection": return .collection
        default: return .unknown
        }
    }

    // MARK: - User state

    static func userState(_ meta: PlexMetadata) -> MediaUserState {
        MediaUserState(
            isPlayed: (meta.viewCount ?? 0) > 0,
            viewOffset: TimeInterval(meta.viewOffset ?? 0) / 1000,
            isFavorite: (meta.userRating ?? 0) > 0,
            lastViewedAt: meta.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    // MARK: - Artwork

    static func artwork(_ meta: PlexMetadata, serverURL: String, authToken: String) -> MediaArtwork {
        func url(_ path: String?) -> URL? {
            guard let path else { return nil }
            return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
        }
        return MediaArtwork(
            poster: url(meta.thumb ?? meta.bestThumb),
            backdrop: url(meta.bestArt),
            thumbnail: url(meta.thumb),
            logo: url(meta.clearLogoPath)
        )
    }

    // MARK: - Tracks

    static func videoTrack(_ stream: PlexStream) -> VideoTrack? {
        guard stream.streamType == 1 else { return nil }
        let range: VideoTrack.VideoRange = {
            if stream.DOVIPresent == true {
                return .dolbyVision(profile: stream.DOVIProfile ?? 0)
            }
            if stream.colorTrc == "smpte2084" && stream.colorPrimaries == "bt2020" {
                return .hdr10
            }
            if stream.colorTrc == "arib-std-b67" {
                return .hlg
            }
            return .sdr
        }()
        return VideoTrack(
            id: "\(stream.id)",
            codec: stream.codec ?? "unknown",
            profile: stream.profile,
            level: stream.level,
            width: stream.width,
            height: stream.height,
            frameRate: stream.frameRate,
            bitrate: stream.bitrate,
            videoRange: range,
            isDefault: stream.default ?? false
        )
    }

    static func audioTrack(_ stream: PlexStream) -> AudioTrack? {
        guard stream.streamType == 2 else { return nil }
        return AudioTrack(
            id: "\(stream.id)",
            index: stream.index ?? 0,
            codec: stream.codec ?? "unknown",
            channels: stream.channels,
            channelLayout: stream.audioChannelLayout,
            language: stream.language,
            title: stream.displayTitle ?? stream.title,
            bitrate: stream.bitrate,
            samplingRate: stream.samplingRate,
            isDefault: stream.default ?? false,
            isForced: stream.forced ?? false
        )
    }

    static func subtitleTrack(_ stream: PlexStream, serverURL: String? = nil, authToken: String? = nil) -> SubtitleTrack? {
        guard stream.streamType == 3 else { return nil }
        let codec = stream.codec ?? stream.format ?? "unknown"
        let isEmbedded = stream.key == nil
        let externalURL: URL? = {
            guard !isEmbedded, let key = stream.key, let serverURL, let authToken else { return nil }
            return URL(string: "\(serverURL)\(key)?X-Plex-Token=\(authToken)")
        }()
        return SubtitleTrack(
            id: "\(stream.id)",
            index: stream.index ?? 0,
            codec: codec,
            language: stream.language,
            title: stream.title ?? stream.displayTitle,
            isDefault: stream.default ?? false,
            isForced: stream.forced ?? false,
            isHearingImpaired: stream.hearingImpaired ?? false,
            isEmbedded: isEmbedded,
            externalURL: externalURL
        )
    }

    // MARK: - Item

    static func item(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MediaItem {
        let ref = MediaItemRef(providerID: providerID, itemID: meta.ratingKey ?? "")
        let runtime: TimeInterval? = meta.duration.map { TimeInterval($0) / 1000 }
        let parentRef: MediaItemRef? = meta.parentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        let grandparentRef: MediaItemRef? = meta.grandparentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        return MediaItem(
            ref: ref,
            kind: kind(meta.type),
            title: meta.title ?? "",
            sortTitle: nil,
            overview: meta.summary,
            year: meta.year,
            runtime: runtime,
            parentRef: parentRef,
            grandparentRef: grandparentRef,
            userState: userState(meta),
            artwork: artwork(meta, serverURL: serverURL, authToken: authToken)
        )
    }

    // MARK: - Media source

    static func mediaSource(
        _ media: PlexMedia,
        _ part: PlexPart,
        serverURL: String,
        authToken: String
    ) -> MediaSource {
        let videoTracks = (part.Stream ?? []).compactMap { videoTrack($0) }
        let audioTracks = (part.Stream ?? []).compactMap { audioTrack($0) }
        let subtitleTracks = (part.Stream ?? []).compactMap {
            subtitleTrack($0, serverURL: serverURL, authToken: authToken)
        }
        let url = URL(string: "\(serverURL)\(part.key)?X-Plex-Token=\(authToken)")
        let durationMs = part.duration ?? media.duration ?? 0
        return MediaSource(
            id: "\(media.id)",
            container: part.container ?? media.container,
            duration: TimeInterval(durationMs) / 1000,
            bitrate: media.bitrate.map { $0 * 1000 },     // Plex bitrate is kbps
            fileSize: part.size.map { Int64($0) },
            fileName: part.file,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            streamKind: .directPlay,
            streamURL: url
        )
    }

    // MARK: - Detail

    static func detail(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MediaItemDetail {
        func personURL(_ thumb: String?) -> URL? {
            guard let thumb else { return nil }
            return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
        }

        let cast = (meta.Role ?? []).map { role in
            MediaPerson(
                id: role.id,
                name: role.tag ?? "",
                role: role.role,
                imageURL: personURL(role.thumb)
            )
        }
        let directors = (meta.Director ?? []).map {
            MediaPerson(
                id: $0.id,
                name: $0.tag ?? "",
                role: nil,
                imageURL: personURL($0.thumb)
            )
        }
        let writers = (meta.Writer ?? []).map {
            MediaPerson(
                id: $0.id,
                name: $0.tag ?? "",
                role: nil,
                imageURL: personURL($0.thumb)
            )
        }
        let chapters = (meta.Chapter ?? []).map { ch in
            MediaChapter(
                id: "\(ch.id ?? 0)",
                title: ch.tag,
                start: TimeInterval(ch.startTimeOffset ?? 0) / 1000,
                end: ch.endTimeOffset.map { TimeInterval($0) / 1000 },
                thumbnailURL: personURL(ch.thumb)
            )
        }
        let mediaSources: [MediaSource] = (meta.Media ?? []).flatMap { media in
            (media.Part ?? []).map { part in
                mediaSource(media, part, serverURL: serverURL, authToken: authToken)
            }
        }
        // PlexExtra exposes only `key`/`ratingKey` — no nested Media. The trailer
        // URL is the extra's playback key, which the player resolves at play time.
        let trailerURL: URL? = meta.Extras?.Metadata?
            .first(where: { $0.subtype == "trailer" || $0.type == "clip" })
            .flatMap { $0.key }
            .flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)") }

        return MediaItemDetail(
            item: item(meta, providerID: providerID, serverURL: serverURL, authToken: authToken),
            tagline: meta.tagline,
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            studios: meta.studio.map { [$0] } ?? [],
            cast: cast,
            directors: directors,
            writers: writers,
            chapters: chapters,
            mediaSources: mediaSources,
            trailerURL: trailerURL,
            contentRating: meta.contentRating,
            rating: meta.rating
        )
    }

    // MARK: - Hub

    static func hub(
        _ hub: PlexHub,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MediaHub {
        let style: MediaHub.HubStyle = {
            switch hub.type {
            case "hero": return .hero
            case "clip": return .clip
            default: return .shelf
            }
        }()
        let items = (hub.Metadata ?? []).map {
            item($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
        }
        return MediaHub(
            id: hub.id,
            providerID: providerID,
            title: hub.title ?? "",
            style: style,
            items: items
        )
    }
}
