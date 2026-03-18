//
//  HeroBackdropSupport.swift
//  Rivulet
//
//  Shared hero/backdrop resolution, deferred-upgrade coordination, and
//  full-size crossfade rendering for preview/detail/loading surfaces.
//

import SwiftUI
import UIKit
import Combine

struct HeroBackdropRequest: Hashable {
    let cacheKey: String
    let plexBackdropURL: URL?
    let plexThumbnailURL: URL?
    let tmdbId: Int?
    let tvdbId: Int?
    let mediaType: TMDBMediaType?
    let preferredBackdropSize: String
}

struct HeroBackdropResolution: Equatable {
    let displayedBackdropURL: URL?
    let pendingUpgradeURL: URL?
    let logoURL: URL?
    let thumbnailURL: URL?

    var canUpgradeAfterSettle: Bool {
        pendingUpgradeURL != nil && pendingUpgradeURL != displayedBackdropURL
    }
}

struct HeroBackdropSession: Equatable {
    var displayedBackdropURL: URL?
    var pendingUpgradeURL: URL?
    var logoURL: URL?
    var thumbnailURL: URL?
    private(set) var motionLocked = false
    private(set) var lastUnlockedAt: Date? = Date()

    init() {}

    init(seed request: HeroBackdropRequest) {
        displayedBackdropURL = request.plexBackdropURL ?? request.plexThumbnailURL
        thumbnailURL = request.plexThumbnailURL
    }

    var canUpgradeAfterSettle: Bool {
        pendingUpgradeURL != nil && pendingUpgradeURL != displayedBackdropURL
    }

    mutating func stage(_ resolution: HeroBackdropResolution) {
        logoURL = resolution.logoURL
        thumbnailURL = resolution.thumbnailURL

        if resolution.pendingUpgradeURL == nil {
            displayedBackdropURL = resolution.displayedBackdropURL
        } else if displayedBackdropURL == nil {
            displayedBackdropURL = resolution.displayedBackdropURL
        }

        pendingUpgradeURL = resolution.pendingUpgradeURL
    }

    mutating func setMotionLocked(_ locked: Bool, now: Date = Date()) {
        guard motionLocked != locked else { return }
        motionLocked = locked
        lastUnlockedAt = locked ? nil : now
    }

    @discardableResult
    mutating func applyPendingUpgradeIfReady(
        now: Date = Date(),
        minimumStableDuration: TimeInterval = 0.15
    ) -> Bool {
        guard !motionLocked,
              let pendingUpgradeURL,
              let lastUnlockedAt,
              now.timeIntervalSince(lastUnlockedAt) >= minimumStableDuration else {
            return false
        }

        displayedBackdropURL = pendingUpgradeURL
        self.pendingUpgradeURL = nil
        return true
    }
}

struct HeroBackdropLoadGate {
    private(set) var generation = 0

    @discardableResult
    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}

enum HeroBackdropSelection {
    nonisolated static func compose(
        request: HeroBackdropRequest,
        tmdbBackdropURL: URL?,
        logoURL: URL?,
        needsUpgrade: Bool
    ) -> HeroBackdropResolution {
        let displayedBackdropURL = request.plexBackdropURL ?? tmdbBackdropURL ?? request.plexThumbnailURL

        let pendingUpgradeURL: URL?
        if needsUpgrade,
           let tmdbBackdropURL,
           request.plexBackdropURL != nil,
           tmdbBackdropURL != displayedBackdropURL {
            pendingUpgradeURL = tmdbBackdropURL
        } else {
            pendingUpgradeURL = nil
        }

        return HeroBackdropResolution(
            displayedBackdropURL: displayedBackdropURL,
            pendingUpgradeURL: pendingUpgradeURL,
            logoURL: logoURL,
            thumbnailURL: request.plexThumbnailURL
        )
    }
}

actor HeroBackdropResolver {
    static let shared = HeroBackdropResolver()

    func resolveAssets(for request: HeroBackdropRequest) async -> HeroBackdropResolution {
        async let needsUpgradeTask = plexBackdropNeedsUpgrade(request.plexBackdropURL)
        async let tmdbIdentityTask = resolvedTMDBIdentity(for: request)

        let (needsUpgrade, tmdbIdentity) = await (needsUpgradeTask, tmdbIdentityTask)

        var logoURL: URL?
        var tmdbBackdropURL: URL?

        if let tmdbIdentity {
            async let logoTask = TMDBClient.shared.fetchLogoURL(tmdbId: tmdbIdentity.id, type: tmdbIdentity.type)
            async let backdropTask = TMDBClient.shared.fetchBackdropURL(
                tmdbId: tmdbIdentity.id,
                type: tmdbIdentity.type,
                size: request.preferredBackdropSize
            )

            let (resolvedLogoURL, resolvedBackdropURL) = await (logoTask, backdropTask)
            logoURL = resolvedLogoURL
            tmdbBackdropURL = resolvedBackdropURL

            if let resolvedBackdropURL {
                _ = await ImageCacheManager.shared.imageFullSize(for: resolvedBackdropURL)
            }
        }

        return HeroBackdropSelection.compose(
            request: request,
            tmdbBackdropURL: tmdbBackdropURL,
            logoURL: logoURL,
            needsUpgrade: needsUpgrade
        )
    }

    func playerLoadingImages(for request: HeroBackdropRequest) async -> (UIImage?, UIImage?) {
        let resolution = await resolveAssets(for: request)
        let backdropURL = resolution.pendingUpgradeURL ?? resolution.displayedBackdropURL

        async let backdropTask: UIImage? = backdropURL != nil
            ? ImageCacheManager.shared.imageFullSize(for: backdropURL!)
            : nil
        async let thumbnailTask: UIImage? = resolution.thumbnailURL != nil
            ? ImageCacheManager.shared.image(for: resolution.thumbnailURL!)
            : nil

        return await (backdropTask, thumbnailTask)
    }

    private func resolvedTMDBIdentity(for request: HeroBackdropRequest) async -> (id: Int, type: TMDBMediaType)? {
        guard let mediaType = request.mediaType else { return nil }

        if let tmdbId = request.tmdbId {
            return (tmdbId, mediaType)
        }

        guard let tvdbId = request.tvdbId,
              let tmdbId = await TMDBClient.shared.findTmdbId(tvdbId: tvdbId, type: mediaType) else {
            return nil
        }

        return (tmdbId, mediaType)
    }

    private func plexBackdropNeedsUpgrade(_ plexBackdropURL: URL?) async -> Bool {
        guard let plexBackdropURL else {
            return true
        }

        guard let image = await ImageCacheManager.shared.imageFullSize(for: plexBackdropURL) else {
            return true
        }

        return image.size.width * image.scale < 1280
    }
}

@MainActor
final class HeroBackdropCoordinator: ObservableObject {
    @Published private(set) var session = HeroBackdropSession()

    private var request: HeroBackdropRequest?
    private var loadGate = HeroBackdropLoadGate()
    private var loadTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?

    deinit {
        loadTask?.cancel()
        upgradeTask?.cancel()
    }

    func load(request: HeroBackdropRequest?, motionLocked: Bool) {
        if request == self.request {
            setMotionLocked(motionLocked)
            return
        }

        self.request = request
        loadTask?.cancel()
        upgradeTask?.cancel()

        guard let request else {
            session = HeroBackdropSession()
            return
        }

        var seededSession = HeroBackdropSession(seed: request)
        seededSession.setMotionLocked(motionLocked)
        session = seededSession

        let token = loadGate.begin()
        loadTask = Task { [weak self] in
            let resolution = await HeroBackdropResolver.shared.resolveAssets(for: request)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.loadGate.isCurrent(token), self.request == request else { return }

                var nextSession = self.session
                nextSession.stage(resolution)
                self.session = nextSession
                self.schedulePendingUpgradeIfNeeded()
            }
        }
    }

    func setMotionLocked(_ locked: Bool) {
        var nextSession = session
        nextSession.setMotionLocked(locked)
        session = nextSession
        schedulePendingUpgradeIfNeeded()
    }

    private func schedulePendingUpgradeIfNeeded() {
        upgradeTask?.cancel()
        guard session.canUpgradeAfterSettle, !session.motionLocked else { return }

        upgradeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }

                var nextSession = self.session
                guard nextSession.applyPendingUpgradeIfReady() else { return }
                self.session = nextSession
            }
        }
    }
}

struct HeroBackdropImage<Placeholder: View>: View {
    let url: URL?
    var animationDuration: Double = 0.22
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var currentURL: URL?
    @State private var currentImage: UIImage?
    @State private var previousImage: UIImage?
    @State private var revealOpacity: Double = 1
    @State private var clearPreviousTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let previousImage {
                imageView(previousImage)
                    .opacity(1 - revealOpacity)
            }

            if let currentImage {
                imageView(currentImage)
                    .opacity(revealOpacity)
            } else if previousImage == nil {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage(for: url)
        }
        .onDisappear {
            clearPreviousTask?.cancel()
        }
    }

    private func imageView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
    }

    @MainActor
    private func loadImage(for url: URL?) async {
        guard url != currentURL else { return }

        clearPreviousTask?.cancel()

        guard let url else {
            currentURL = nil
            currentImage = nil
            previousImage = nil
            revealOpacity = 1
            return
        }

        let image = await ImageCacheManager.shared.imageFullSize(for: url)
        guard !Task.isCancelled, currentURL != url else { return }

        guard let image else {
            if currentImage == nil {
                currentURL = url
            }
            return
        }

        if let currentImage {
            previousImage = currentImage
        }

        currentURL = url
        currentImage = image
        revealOpacity = previousImage == nil ? 1 : 0

        guard previousImage != nil else { return }

        withAnimation(.easeInOut(duration: animationDuration)) {
            revealOpacity = 1
        }

        clearPreviousTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(animationDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                previousImage = nil
            }
        }
    }
}

extension PlexMetadata {
    func heroBackdropRequest(
        serverURL: String,
        authToken: String,
        tmdbIdOverride: Int? = nil,
        tvdbIdOverride: Int? = nil,
        mediaTypeOverride: TMDBMediaType? = nil,
        preferredBackdropSize: String = "original"
    ) -> HeroBackdropRequest {
        let backdropPath = bestArt
        let thumbnailPath = thumb ?? bestThumb

        let plexBackdropURL = backdropPath.flatMap {
            URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)")
        }
        let plexThumbnailURL = thumbnailPath.flatMap {
            URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)")
        }

        let mediaType: TMDBMediaType?
        if let mediaTypeOverride {
            mediaType = mediaTypeOverride
        } else {
            switch type {
            case "movie":
                mediaType = .movie
            case "show", "episode":
                mediaType = .tv
            default:
                mediaType = nil
            }
        }

        let resolvedTMDBId: Int?
        if let tmdbIdOverride {
            resolvedTMDBId = tmdbIdOverride
        } else if type == "episode" {
            resolvedTMDBId = showTmdbId
        } else {
            resolvedTMDBId = tmdbId
        }

        let resolvedTVDBId: Int?
        if let tvdbIdOverride {
            resolvedTVDBId = tvdbIdOverride
        } else if type == "episode" {
            resolvedTVDBId = nil
        } else {
            resolvedTVDBId = tvdbId
        }

        return HeroBackdropRequest(
            cacheKey: ratingKey ?? "\(type ?? "item"):\(title ?? "unknown")",
            plexBackdropURL: plexBackdropURL,
            plexThumbnailURL: plexThumbnailURL,
            tmdbId: resolvedTMDBId,
            tvdbId: resolvedTVDBId,
            mediaType: mediaType,
            preferredBackdropSize: preferredBackdropSize
        )
    }
}
