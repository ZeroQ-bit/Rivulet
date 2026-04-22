//
//  TMDBItemDetailView.swift
//  Rivulet
//
//  Detail page for TMDB items not in the user's library. Visually mirrors
//  MediaDetailView's hero layout (full-bleed backdrop, left/bottom vignette,
//  bottom-left metadata block, pill action button, scroll-up-for-more).
//

import SwiftUI

struct TMDBItemDetailView: View {
    let item: TMDBListItem

    @StateObject private var watchlist = PlexWatchlistService.shared
    @State private var detail: TMDBItemDetail?
    @State private var libraryMatch: PlexMetadata?
    @State private var scrollProgress: CGFloat = 0
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedAction: ActionFocus?

    private enum ActionFocus: Hashable {
        case primary
    }

    private static let backdropBase = "https://image.tmdb.org/t/p/original"
    private static let posterBase = "https://image.tmdb.org/t/p/w500"

    private let pillButtonHeight: CGFloat = 66

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdropLayer(in: geo.size)
                vignetteLayers
                contentScroll(in: geo.size)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
        .task { await load() }
        .onExitCommand { dismiss() }
        .watchlistToast(message: watchlist.transientWriteError)
    }

    // MARK: - Backdrop

    @ViewBuilder
    private func backdropLayer(in size: CGSize) -> some View {
        if let path = (detail?.backdropPath ?? item.backdropPath),
           let url = URL(string: "\(Self.backdropBase)\(path)") {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color.black
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay {
                if scrollProgress > 0.01 {
                    Rectangle()
                        .fill(.regularMaterial)
                        .opacity(scrollProgress)
                }
            }
        } else {
            Color.black
        }
    }

    private var vignetteLayers: some View {
        ZStack {
            // Left-side gradient for text legibility
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.7), location: 0),
                    .init(color: .black.opacity(0.4), location: 0.25),
                    .init(color: .black.opacity(0.12), location: 0.42),
                    .init(color: .clear, location: 0.55),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Bottom gradient
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.25), location: 0.2),
                        .init(color: .black.opacity(0.55), location: 0.4),
                        .init(color: .black.opacity(0.8), location: 0.65),
                        .init(color: .black.opacity(0.95), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: UIScreen.main.bounds.height * 0.55)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: - Scroll content

    private func contentScroll(in size: CGSize) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                heroMetadataBlock
                    .frame(height: size.height)

                belowFold
                    .padding(.horizontal, 88)
                    .padding(.bottom, 80)
            }
        }
        .scrollClipDisabled()
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, offset in
            // Match MediaDetailView's blur-fade pacing: full blur after ~1 screen.
            scrollProgress = min(1, max(0, offset / max(size.height * 0.6, 1)))
        }
    }

    // MARK: - Hero metadata block (mirrors MediaDetailView.heroMetadataOverlay)

    private var heroMetadataBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                heroTitle

                heroMetadataRow

                if let overview = (detail?.overview ?? item.overview), !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                }

                heroQualityRow
            }
            .frame(maxWidth: 760, alignment: .leading)
            .opacity(1 - scrollProgress)

            actionButtons
                .padding(.top, 12)
        }
        .padding(.horizontal, 88)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroTitle: some View {
        Text(item.title)
            .font(.system(size: 52, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
            .lineLimit(2)
    }

    /// Type label · Genre · Genre  (matches Plex hero idiom)
    private var heroMetadataRow: some View {
        HStack(spacing: 8) {
            let parts = metadataParts
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·") }
                Text(part)
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }

    private var metadataParts: [String] {
        var parts: [String] = []
        parts.append(item.mediaType == .movie ? "Movie" : "TV Show")
        if let genres = detail?.genres.prefix(2) {
            for genre in genres {
                if let name = genre.name { parts.append(name) }
            }
        }
        return parts
    }

    /// Year · Duration · ★ rating
    private var heroQualityRow: some View {
        let yearText: String? = {
            guard let raw = item.releaseDate?.prefix(4), !raw.isEmpty else { return nil }
            return String(raw)
        }()
        let runtimeText: String? = detail?.runtime.map { "\($0) min" }

        return HStack(spacing: 8) {
            if let yearText { Text(yearText) }
            if yearText != nil && runtimeText != nil { Text("·") }
            if let runtimeText { Text(runtimeText) }

            if let vote = item.voteAverage ?? detail?.voteAverage {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(String(format: "%.1f", vote))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }

    // MARK: - Actions (pill button matching Plex Play button)

    private var actionButtons: some View {
        HStack(spacing: 18) {
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if libraryMatch != nil {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                    Text("Open in Library")
                }
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 32)
                .frame(height: pillButtonHeight)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedAction == .primary,
                cornerRadius: pillButtonHeight / 2
            ))
            .focused($focusedAction, equals: .primary)
        } else if isOnWatchlist {
            Button {
                Task { await removeFromWatchlist() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bookmark.fill")
                    Text("Remove from Watchlist")
                }
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 32)
                .frame(height: pillButtonHeight)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedAction == .primary,
                cornerRadius: pillButtonHeight / 2
            ))
            .focused($focusedAction, equals: .primary)
        } else {
            Button {
                Task { await addToWatchlist() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bookmark")
                    Text("Add to Watchlist")
                }
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 32)
                .frame(height: pillButtonHeight)
            }
            .buttonStyle(AppStoreActionButtonStyle(
                isFocused: focusedAction == .primary,
                cornerRadius: pillButtonHeight / 2
            ))
            .focused($focusedAction, equals: .primary)
        }
    }

    // MARK: - Below-fold (cast)

    @ViewBuilder
    private var belowFold: some View {
        if let cast = detail?.cast, !cast.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cast")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(cast.indices, id: \.self) { i in
                            castCard(cast[i])
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
            }
            .padding(.top, 32)
        }
    }

    private func castCard(_ credit: TMDBCredit) -> some View {
        VStack(spacing: 8) {
            Circle()
                .fill(LinearGradient(
                    colors: [Color(white: 0.18), Color(white: 0.10)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: 140, height: 140)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                }
            Text(credit.name ?? "")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let role = credit.character {
                Text(role)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(width: 160)
    }

    // MARK: - State helpers

    private var isOnWatchlist: Bool {
        watchlist.contains(tmdbId: item.id)
    }

    // MARK: - Actions

    private func load() async {
        detail = await TMDBDiscoverService.shared.fetchDetail(tmdbId: item.id, type: item.mediaType)
        libraryMatch = await LibraryGUIDIndex.shared.lookup(tmdbId: item.id, type: item.mediaType)
    }

    private func addToWatchlist() async {
        let guid = "tmdb://\(item.id)"
        let watchType: PlexWatchlistItem.WatchlistType = item.mediaType == .movie ? .movie : .show
        let yearInt: Int? = item.releaseDate
            .flatMap { $0.prefix(4).isEmpty ? nil : Int($0.prefix(4)) }
        let posterURL: URL? = item.posterPath.flatMap { URL(string: "\(Self.posterBase)\($0)") }
        let watchlistItem = PlexWatchlistItem(
            id: guid,
            title: item.title,
            year: yearInt,
            type: watchType,
            posterURL: posterURL,
            guids: [guid]
        )
        await watchlist.add(guid: guid, item: watchlistItem)
    }

    private func removeFromWatchlist() async {
        await watchlist.remove(guid: "tmdb://\(item.id)")
    }
}
