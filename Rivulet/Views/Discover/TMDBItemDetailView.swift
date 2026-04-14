//
//  TMDBItemDetailView.swift
//  Rivulet
//
//  Detail page for TMDB items not in the user's library. Shows TMDB metadata
//  with primary actions Add/Remove Watchlist and (if matched) Play.
//

import SwiftUI

struct TMDBItemDetailView: View {
    let item: TMDBListItem

    @StateObject private var watchlist = PlexWatchlistService.shared
    @State private var detail: TMDBItemDetail?
    @State private var libraryMatch: PlexMetadata?
    @Environment(\.dismiss) private var dismiss

    private static let backdropBase = "https://image.tmdb.org/t/p/original"
    private static let posterBase = "https://image.tmdb.org/t/p/w500"

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                backdrop
                content
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task { await load() }
        .onExitCommand { dismiss() }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack(alignment: .bottomLeading) {
            if let path = (detail?.backdropPath ?? item.backdropPath),
               let url = URL(string: "\(Self.backdropBase)\(path)") {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                    default: Color.black
                    }
                }
                .frame(height: 600)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.6), .black],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            } else {
                Color.black.frame(height: 200)
            }

            VStack(alignment: .leading, spacing: 16) {
                Text(item.title)
                    .font(.system(size: 56, weight: .bold))
                metadataLine
            }
            .padding(60)
        }
    }

    private var metadataLine: some View {
        HStack(spacing: 16) {
            if let yearText = item.releaseDate?.prefix(4), !yearText.isEmpty {
                Text(String(yearText)).foregroundStyle(.white.opacity(0.7))
            }
            if let runtime = detail?.runtime {
                Text("\(runtime) min").foregroundStyle(.white.opacity(0.7))
            }
            if let vote = item.voteAverage {
                Label(String(format: "%.1f", vote), systemImage: "star.fill")
                    .foregroundStyle(.yellow)
            }
        }
        .font(.system(size: 22))
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 32) {
            actionRow
            if let overview = detail?.overview ?? item.overview {
                Text(overview)
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(6)
            }
            if let cast = detail?.cast, !cast.isEmpty {
                castRow(cast)
            }
        }
        .padding(.horizontal, 60)
    }

    private var actionRow: some View {
        HStack(spacing: 24) {
            if libraryMatch != nil {
                Button("Open in Library") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.extraLarge)
                    .accessibilityHint("Closes this screen; use the tile to navigate to Plex detail")
            } else if isOnWatchlist {
                Button {
                    Task { await removeFromWatchlist() }
                } label: {
                    Label("Remove from Watchlist", systemImage: "bookmark.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.extraLarge)
            } else {
                Button {
                    Task { await addToWatchlist() }
                } label: {
                    Label("Add to Watchlist", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.extraLarge)
            }
        }
    }

    private func castRow(_ cast: [TMDBCredit]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast").font(.system(size: 28, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(cast.indices, id: \.self) { i in
                        let credit = cast[i]
                        VStack(spacing: 4) {
                            Circle().fill(.white.opacity(0.1)).frame(width: 100, height: 100)
                            Text(credit.name ?? "")
                                .font(.system(size: 18, weight: .semibold))
                                .lineLimit(1)
                            if let role = credit.character {
                                Text(role)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 140)
                    }
                }
            }
        }
    }

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
