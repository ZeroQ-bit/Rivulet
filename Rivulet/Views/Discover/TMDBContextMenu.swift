//
//  TMDBContextMenu.swift
//  Rivulet
//
//  Long-press context menu for tiles in Discover. Offers Watchlist add/remove
//  for every item; when the item is in the user's library, also surfaces a
//  Play action that jumps straight into the matched Plex item's player.
//

import SwiftUI
import os.log

private let tmdbMenuLog = Logger(subsystem: "com.rivulet.app", category: "TMDBContextMenu")

struct TMDBContextMenu: ViewModifier {
    let item: TMDBListItem
    let isInLibrary: Bool
    let libraryMatch: (TMDBListItem) async -> PlexMetadata?
    var onInfo: (() -> Void)?

    @ObservedObject private var watchlist = PlexWatchlistService.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            if isInLibrary {
                Button {
                    Task { await playMatched() }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
            }

            Button {
                Task { await toggleWatchlist() }
            } label: {
                if isOnWatchlist {
                    Label("Remove from Watchlist", systemImage: "bookmark.slash")
                } else {
                    Label("Add to Watchlist", systemImage: "bookmark")
                }
            }

            if let onInfo {
                Button {
                    onInfo()
                } label: {
                    Label("More Info", systemImage: "info.circle")
                }
            }
        }
    }

    private var isOnWatchlist: Bool {
        watchlist.contains(tmdbId: item.id)
    }

    private func toggleWatchlist() async {
        let guid = "tmdb://\(item.id)"
        if watchlist.contains(guid: guid) {
            tmdbMenuLog.info("Watchlist remove \(guid, privacy: .public)")
            await watchlist.remove(guid: guid)
        } else {
            let watchType: PlexWatchlistItem.WatchlistType = item.mediaType == .movie ? .movie : .show
            let yearInt: Int? = {
                guard let raw = item.releaseDate?.prefix(4), !raw.isEmpty else { return nil }
                return Int(raw)
            }()
            let posterURL: URL? = item.posterPath.flatMap {
                URL(string: "https://image.tmdb.org/t/p/w500\($0)")
            }
            let wli = PlexWatchlistItem(
                id: guid,
                title: item.title,
                year: yearInt,
                type: watchType,
                posterURL: posterURL,
                guids: [guid]
            )
            tmdbMenuLog.info("Watchlist add \(guid, privacy: .public)")
            await watchlist.add(guid: guid, item: wli)
        }
    }

    private func playMatched() async {
        guard let plex = await libraryMatch(item),
              let ratingKey = plex.ratingKey else {
            tmdbMenuLog.warning("Play requested but no library match for tmdb://\(item.id, privacy: .public)")
            return
        }
        await DiscoverPlaybackRouter.shared.play(ratingKey: ratingKey)
    }
}

extension View {
    /// Attach a Discover-flavored long-press context menu to a TMDB tile.
    func tmdbContextMenu(
        item: TMDBListItem,
        isInLibrary: Bool,
        libraryMatch: @escaping (TMDBListItem) async -> PlexMetadata?,
        onInfo: (() -> Void)? = nil
    ) -> some View {
        modifier(TMDBContextMenu(
            item: item,
            isInLibrary: isInLibrary,
            libraryMatch: libraryMatch,
            onInfo: onInfo
        ))
    }
}

/// Centralised "start playback for a Plex ratingKey" so the Discover context
/// menu can reach the same player path the rest of the app uses without
/// coupling the menu to any one view's presentation state.
///
/// Current implementation: presents the matched item's detail via the top VC
/// modally, which gives the user a one-tap path to Play. A future iteration
/// can launch the player directly.
@MainActor
final class DiscoverPlaybackRouter {
    static let shared = DiscoverPlaybackRouter()

    func play(ratingKey: String) async {
        let auth = PlexAuthManager.shared
        guard let serverURL = auth.selectedServerURL,
              let token = auth.selectedServerToken else { return }

        // Resolve the Plex metadata (context menu only had a ratingKey) so we
        // can present `PlexDetailView`.
        guard let metadata = try? await PlexNetworkManager.shared.getMetadata(
            serverURL: serverURL,
            authToken: token,
            ratingKey: ratingKey
        ) else { return }

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else { return }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let detail = PlexDetailView(item: metadata)
            .presentationBackground(.black)
        let host = UIHostingController(rootView: detail)
        host.modalPresentationStyle = .fullScreen
        topVC.present(host, animated: true)
    }
}
