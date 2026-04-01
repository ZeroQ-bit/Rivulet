//
//  MusicContextMenu.swift
//  Rivulet
//
//  Context menu for music items, presented as a fullScreenCover with glass background.
//  Options differ by item type (track, album, artist).
//

import SwiftUI

/// Actions that can be performed from the context menu
enum MusicContextAction {
    case playNext
    case addToQueue
    case playAlbum
    case shuffleAlbum
    case goToAlbum(ratingKey: String)
    case goToArtist(ratingKey: String)
}

struct MusicContextMenu: View {
    let item: PlexMetadata
    @Binding var isPresented: Bool
    var onAction: ((MusicContextAction) -> Void)?

    @FocusState private var focusedOption: MenuOption?
    @ObservedObject private var authManager = PlexAuthManager.shared

    private enum MenuOption: Hashable {
        case playNext
        case addToQueue
        case playAlbum
        case shuffleAlbum
        case goToAlbum
        case goToArtist
    }

    /// Whether this item is a track (vs album/playlist)
    private var isTrack: Bool {
        item.type == "track"
    }

    /// Whether this item is an album
    private var isAlbum: Bool {
        item.type == "album"
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            HStack(spacing: 48) {
                // Item preview
                itemPreview
                    .frame(width: 300)

                // Menu options
                VStack(alignment: .leading, spacing: 8) {
                    if isTrack {
                        trackOptions
                    } else if isAlbum {
                        albumOptions
                    } else {
                        // Fallback: generic options
                        genericOptions
                    }
                }
                .frame(width: 360)
            }
            .padding(60)
        }
        .onAppear {
            focusedOption = .playNext
        }
        .onExitCommand {
            isPresented = false
        }
    }

    // MARK: - Item Preview

    private var itemPreview: some View {
        VStack(spacing: 16) {
            // Artwork
            itemArtView
                .frame(width: 240, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)

            // Title
            Text(item.title ?? "Unknown")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Subtitle
            if isTrack {
                VStack(spacing: 4) {
                    Text(item.grandparentTitle ?? "Unknown Artist")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)

                    Text(item.parentTitle ?? "")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            } else if isAlbum {
                Text(item.parentTitle ?? "Unknown Artist")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Track Options

    private var trackOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            menuButton(
                icon: "text.line.first.and.arrowtriangle.forward",
                label: "Play Next",
                option: .playNext
            ) {
                MusicQueue.shared.addNext(track: item)
                onAction?(.playNext)
                isPresented = false
            }

            menuButton(
                icon: "text.append",
                label: "Add to Queue",
                option: .addToQueue
            ) {
                MusicQueue.shared.addToEnd(track: item)
                onAction?(.addToQueue)
                isPresented = false
            }

            if let albumKey = item.parentRatingKey {
                Divider()
                    .background(.white.opacity(0.1))
                    .padding(.vertical, 4)

                menuButton(
                    icon: "square.stack",
                    label: "Go to Album",
                    option: .goToAlbum
                ) {
                    onAction?(.goToAlbum(ratingKey: albumKey))
                    isPresented = false
                }
            }

            if let artistKey = item.grandparentRatingKey {
                menuButton(
                    icon: "music.mic",
                    label: "Go to Artist",
                    option: .goToArtist
                ) {
                    onAction?(.goToArtist(ratingKey: artistKey))
                    isPresented = false
                }
            }
        }
    }

    // MARK: - Album Options

    private var albumOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            menuButton(
                icon: "play.fill",
                label: "Play",
                option: .playAlbum
            ) {
                onAction?(.playAlbum)
                isPresented = false
            }

            menuButton(
                icon: "shuffle",
                label: "Shuffle",
                option: .shuffleAlbum
            ) {
                onAction?(.shuffleAlbum)
                isPresented = false
            }

            Divider()
                .background(.white.opacity(0.1))
                .padding(.vertical, 4)

            menuButton(
                icon: "text.line.first.and.arrowtriangle.forward",
                label: "Play Next",
                option: .playNext
            ) {
                onAction?(.playNext)
                isPresented = false
            }

            menuButton(
                icon: "text.append",
                label: "Add to Queue",
                option: .addToQueue
            ) {
                onAction?(.addToQueue)
                isPresented = false
            }
        }
    }

    // MARK: - Generic Options

    private var genericOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            menuButton(
                icon: "text.line.first.and.arrowtriangle.forward",
                label: "Play Next",
                option: .playNext
            ) {
                MusicQueue.shared.addNext(track: item)
                onAction?(.playNext)
                isPresented = false
            }

            menuButton(
                icon: "text.append",
                label: "Add to Queue",
                option: .addToQueue
            ) {
                MusicQueue.shared.addToEnd(track: item)
                onAction?(.addToQueue)
                isPresented = false
            }
        }
    }

    // MARK: - Menu Button

    private func menuButton(
        icon: String,
        label: String,
        option: MenuOption,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedOption == option
        return Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 28)
                    .foregroundStyle(isFocused ? .black : .white.opacity(0.8))

                Text(label)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isFocused ? .black : .white.opacity(0.9))

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? .white : .white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isFocused ? .clear : .white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .focused($focusedOption, equals: option)
        .scaleEffect(isFocused ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    // MARK: - Artwork

    private var itemArtView: some View {
        Group {
            if let url = itemArtURL {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        artPlaceholder
                    }
                }
            } else {
                artPlaceholder
            }
        }
    }

    private var artPlaceholder: some View {
        Rectangle()
            .fill(Color(white: 0.12))
            .overlay {
                Image(systemName: isAlbum ? "square.stack" : "music.note")
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }

    private var itemArtURL: URL? {
        guard let thumb = item.thumb ?? item.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }
}
