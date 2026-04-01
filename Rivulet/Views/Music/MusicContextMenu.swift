//
//  MusicContextMenu.swift
//  Rivulet
//
//  Native tvOS context menu modifier for music items.
//  Replaces the old fullScreenCover-based custom context menu.
//

import SwiftUI

// MARK: - Context Menu Styles

/// Determines which context menu options to show
enum MusicContextMenuStyle {
    case track
    case album
}

// MARK: - View Modifier

/// Adds a native tvOS `.contextMenu` to a music item view.
struct MusicItemContextMenuModifier: ViewModifier {
    let item: PlexMetadata
    let style: MusicContextMenuStyle

    @ObservedObject private var musicQueue = MusicQueue.shared

    func body(content: Content) -> some View {
        content.contextMenu {
            switch style {
            case .track:
                trackMenu
            case .album:
                albumMenu
            }
        }
    }

    // MARK: - Track Menu

    @ViewBuilder
    private var trackMenu: some View {
        Button {
            musicQueue.addNext(track: item)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            musicQueue.addToEnd(track: item)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
    }

    // MARK: - Album Menu

    @ViewBuilder
    private var albumMenu: some View {
        Button {
            Task { await playAlbum(shuffled: false) }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            Task { await playAlbum(shuffled: true) }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Divider()

        Button {
            Task { await addAlbumToQueue(next: true) }
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            Task { await addAlbumToQueue(next: false) }
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
    }

    // MARK: - Album Actions

    private func playAlbum(shuffled: Bool) async {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken,
              let ratingKey = item.ratingKey else { return }

        do {
            var tracks = try await PlexNetworkManager.shared.getChildren(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            )
            if shuffled { tracks.shuffle() }
            if !tracks.isEmpty {
                musicQueue.playAlbum(tracks: tracks, startingAt: 0)
            }
        } catch {
            print("MusicContextMenu: Failed to load tracks: \(error)")
        }
    }

    private func addAlbumToQueue(next: Bool) async {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken,
              let ratingKey = item.ratingKey else { return }

        do {
            let tracks = try await PlexNetworkManager.shared.getChildren(
                serverURL: serverURL, authToken: token, ratingKey: ratingKey
            )
            if next {
                for track in tracks.reversed() {
                    musicQueue.addNext(track: track)
                }
            } else {
                musicQueue.addToEnd(tracks: tracks)
            }
        } catch {
            print("MusicContextMenu: Failed to load tracks: \(error)")
        }
    }
}

// MARK: - View Extension

extension View {
    /// Adds a native tvOS context menu for music items.
    func musicItemContextMenu(item: PlexMetadata, style: MusicContextMenuStyle) -> some View {
        modifier(MusicItemContextMenuModifier(item: item, style: style))
    }
}
