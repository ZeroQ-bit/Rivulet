//
//  HeroBackdropSupport.swift
//  Rivulet
//
//  Shared hero/backdrop resolution and full-size crossfade rendering for
//  preview/detail/loading surfaces. Artwork URLs come from Plex metadata —
//  no external lookups.
//

import SwiftUI
import UIKit
import Combine

struct HeroBackdropRequest: Hashable {
    let cacheKey: String
    let plexBackdropURL: URL?
    let plexThumbnailURL: URL?
    let plexLogoURL: URL?
}

struct HeroBackdropResolution: Equatable {
    let displayedBackdropURL: URL?
    /// When true, the displayed URL is currently being rendered via the
    /// downsampled decode path. Once motion settles, the coordinator swaps
    /// to the full-size decode of the same URL.
    let hasPendingFullSizeUpgrade: Bool
    let logoURL: URL?
    let thumbnailURL: URL?
}

struct HeroBackdropSession: Equatable {
    var displayedBackdropURL: URL?
    /// Mirrors `HeroBackdropResolution.hasPendingFullSizeUpgrade`. Flips to
    /// false after `applyPendingUpgradeIfReady` promotes the displayed image
    /// from the downsampled variant to the full-size variant.
    var hasPendingFullSizeUpgrade: Bool = false
    var logoURL: URL?
    var thumbnailURL: URL?
    private(set) var motionLocked = false
    private(set) var lastUnlockedAt: Date? = Date()

    init() {}

    init(seed request: HeroBackdropRequest) {
        displayedBackdropURL = request.plexBackdropURL ?? request.plexThumbnailURL
        thumbnailURL = request.plexThumbnailURL
        logoURL = request.plexLogoURL
        // Seed session always starts on the downsampled path so the first
        // render never waits on a 3840×2160 decode.
        hasPendingFullSizeUpgrade = displayedBackdropURL != nil
    }

    var canUpgradeAfterSettle: Bool {
        hasPendingFullSizeUpgrade && displayedBackdropURL != nil
    }

    mutating func stage(_ resolution: HeroBackdropResolution) {
        logoURL = resolution.logoURL
        thumbnailURL = resolution.thumbnailURL
        displayedBackdropURL = resolution.displayedBackdropURL
        hasPendingFullSizeUpgrade = resolution.hasPendingFullSizeUpgrade
    }

    mutating func setMotionLocked(_ locked: Bool, now: Date = Date()) {
        guard motionLocked != locked else { return }
        motionLocked = locked
        lastUnlockedAt = locked ? nil : now
    }

    /// Flag-only promotion. The URL does not change — what changes is the
    /// decode path `HeroBackdropImage` uses for this URL next time it
    /// reloads. `HeroBackdropImage` observes `hasPendingFullSizeUpgrade` via
    /// the coordinator's `@Published session` and re-runs its load task when
    /// the flag flips.
    @discardableResult
    mutating func applyPendingUpgradeIfReady(
        now: Date = Date(),
        minimumStableDuration: TimeInterval = 0.15
    ) -> Bool {
        guard !motionLocked,
              hasPendingFullSizeUpgrade,
              let lastUnlockedAt,
              now.timeIntervalSince(lastUnlockedAt) >= minimumStableDuration else {
            return false
        }

        hasPendingFullSizeUpgrade = false
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

actor HeroBackdropResolver {
    static let shared = HeroBackdropResolver()

    func resolveAssets(for request: HeroBackdropRequest) async -> HeroBackdropResolution {
        // Always start on the downsampled decode path — ~4× cheaper during
        // the entry/paging animation. The coordinator's
        // `schedulePendingUpgradeIfNeeded` path flips the flag off ~150ms
        // after motion settles, and `HeroBackdropImage` re-loads the same
        // URL via the full-size decode path at that point.
        let displayURL = request.plexBackdropURL ?? request.plexThumbnailURL
        return HeroBackdropResolution(
            displayedBackdropURL: displayURL,
            hasPendingFullSizeUpgrade: displayURL != nil,
            logoURL: request.plexLogoURL,
            thumbnailURL: request.plexThumbnailURL
        )
    }

    func playerLoadingImages(for request: HeroBackdropRequest) async -> (UIImage?, UIImage?) {
        let resolution = await resolveAssets(for: request)
        let backdropURL = resolution.displayedBackdropURL

        async let backdropTask: UIImage? = backdropURL != nil
            ? ImageCacheManager.shared.imageFullSize(for: backdropURL!)
            : nil
        async let thumbnailTask: UIImage? = resolution.thumbnailURL != nil
            ? ImageCacheManager.shared.image(for: resolution.thumbnailURL!)
            : nil

        return await (backdropTask, thumbnailTask)
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

/// Max pixel size used for the downsampled hero decode path. 1920 is the
/// long-edge resolution of a 1080p tvOS stage; at 4K mode the backdrop is
/// upsampled by 2× briefly before the full-size upgrade swaps in.
private let heroDownsampleMaxPixelSize: CGFloat = 1920

struct HeroBackdropImage<Placeholder: View>: View {
    let url: URL?
    /// When true, decode at full resolution via `imageFullSize`. When false,
    /// decode via `imageDownsampled(maxPixelSize: 1920)` for ~4× cheaper
    /// decode during motion. Callers in the carousel flow pass `false`
    /// initially and flip to `true` after motion settles.
    var useFullSize: Bool = true
    var animationDuration: Double = 0.22
    @ViewBuilder let placeholder: () -> Placeholder

    /// Identity of the currently-displayed variant — (URL, isFullSize).
    /// Distinct from just the URL because the same URL can be displayed at
    /// two different decode qualities and we want the upgrade to crossfade.
    private struct LoadIdentity: Equatable {
        let url: URL?
        let fullSize: Bool
    }

    @State private var currentIdentity: LoadIdentity?
    @State private var currentImage: UIImage?
    @State private var previousImage: UIImage?
    @State private var revealOpacity: Double = 1
    @State private var clearPreviousTask: Task<Void, Never>?

    private var requestedIdentity: LoadIdentity {
        LoadIdentity(url: url, fullSize: useFullSize)
    }

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
        .task(id: requestedIdentity) {
            await loadImage(for: requestedIdentity)
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
    private func loadImage(for identity: LoadIdentity) async {
        guard identity != currentIdentity else { return }

        clearPreviousTask?.cancel()

        guard let url = identity.url else {
            currentIdentity = LoadIdentity(url: nil, fullSize: identity.fullSize)
            currentImage = nil
            previousImage = nil
            revealOpacity = 1
            return
        }

        let image: UIImage?
        if identity.fullSize {
            image = await ImageCacheManager.shared.imageFullSize(for: url)
        } else {
            image = await ImageCacheManager.shared.imageDownsampled(
                for: url,
                maxPixelSize: heroDownsampleMaxPixelSize
            )
        }

        guard !Task.isCancelled, currentIdentity != identity else { return }

        guard let image else {
            if currentImage == nil {
                currentIdentity = identity
            }
            return
        }

        if let currentImage {
            previousImage = currentImage
        }

        currentIdentity = identity
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
    /// Builds a `HeroBackdropRequest` from this item's Plex artwork.
    ///
    /// For episodes/seasons, the clearLogo isn't carried on the item itself —
    /// callers that want the show's logo should pass `logoPathOverride` after
    /// fetching the parent show's metadata.
    func heroBackdropRequest(
        serverURL: String,
        authToken: String,
        logoPathOverride: String? = nil
    ) -> HeroBackdropRequest {
        let backdropPath = bestArt
        let thumbnailPath = thumb ?? bestThumb
        let logoPath = logoPathOverride ?? clearLogoPath

        let plexBackdropURL = backdropPath.flatMap {
            URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)")
        }
        let plexThumbnailURL = thumbnailPath.flatMap {
            URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)")
        }
        let plexLogoURL = logoPath.flatMap {
            URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)")
        }

        return HeroBackdropRequest(
            cacheKey: ratingKey ?? "\(type ?? "item"):\(title ?? "unknown")",
            plexBackdropURL: plexBackdropURL,
            plexThumbnailURL: plexThumbnailURL,
            plexLogoURL: plexLogoURL
        )
    }
}
