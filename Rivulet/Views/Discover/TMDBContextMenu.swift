//
//  TMDBContextMenu.swift
//  Rivulet
//
//  Long-press context menu for tiles in Discover. Offers Watchlist add/remove
//  for every item; "Details" opens the unified carousel rooted at the tapped
//  item with the rest of the row as side cards.
//

import SwiftUI
import os.log

private let tmdbMenuLog = Logger(subsystem: "com.rivulet.app", category: "TMDBContextMenu")

struct TMDBContextMenu: ViewModifier {
    let item: MediaItem
    /// Full row context — passed in so the "Details" action can build a
    /// PreviewRequest with paging intact (single-item carousels feel broken).
    let rowItems: [MediaItem]
    let rowID: String
    /// Emits a PreviewRequest when the user picks "Details".
    let onSelect: (PreviewRequest) -> Void

    @ObservedObject private var watchlist = PlexWatchlistService.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                emitDetails()
            } label: {
                Label("Details", systemImage: "info.circle")
            }

            if let tmdbId = item.tmdbId {
                Button {
                    Task { await toggleWatchlist(tmdbId: tmdbId) }
                } label: {
                    if watchlist.contains(tmdbId: tmdbId) {
                        Label("Remove from Watchlist", systemImage: "bookmark.slash")
                    } else {
                        Label("Add to Watchlist", systemImage: "bookmark")
                    }
                }
            }
        }
    }

    private func emitDetails() {
        let idx = rowItems.firstIndex(where: { $0.id == item.id }) ?? 0
        onSelect(PreviewRequest(
            items: rowItems,
            selectedIndex: idx,
            sourceRowID: rowID,
            sourceItemID: item.id
        ))
    }

    private func toggleWatchlist(tmdbId: Int) async {
        let guid = "tmdb://\(tmdbId)"
        if watchlist.contains(guid: guid) {
            tmdbMenuLog.info("Watchlist remove \(guid, privacy: .public)")
            await watchlist.remove(guid: guid)
        } else {
            let watchType: PlexWatchlistItem.WatchlistType = item.kind == .movie ? .movie : .show
            let wli = PlexWatchlistItem(
                id: guid,
                title: item.title,
                year: item.year,
                type: watchType,
                posterURL: item.posterURL,
                guids: [guid]
            )
            tmdbMenuLog.info("Watchlist add \(guid, privacy: .public)")
            await watchlist.add(guid: guid, item: wli)
        }
    }
}

extension View {
    /// Attach a Discover-flavored long-press context menu to a TMDB tile.
    func tmdbContextMenu(
        item: MediaItem,
        rowItems: [MediaItem],
        rowID: String,
        onSelect: @escaping (PreviewRequest) -> Void
    ) -> some View {
        modifier(TMDBContextMenu(
            item: item,
            rowItems: rowItems,
            rowID: rowID,
            onSelect: onSelect
        ))
    }
}

/// Centralised "present MediaDetailView for a ratingKey" so the Discover
/// context menu can reach the detail path without coupling to any one view's
/// presentation state. (Retained for code paths that resolve a ratingKey
/// asynchronously after a context-menu action; the row-tile flow now goes
/// through the unified carousel via `onSelect` above.)
@MainActor
final class DiscoverPlaybackRouter {
    static let shared = DiscoverPlaybackRouter()

    func presentDetails(ratingKey: String) async {
        let auth = PlexAuthManager.shared
        guard let serverURL = auth.selectedServerURL,
              let token = auth.selectedServerToken else { return }

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

        let detail = MediaDetailView(item: MediaItem.from(plex: metadata))
            .presentationBackground(.black)
        let host = UIHostingController(rootView: detail)
        host.modalPresentationStyle = .fullScreen
        topVC.present(host, animated: true)
    }
}
