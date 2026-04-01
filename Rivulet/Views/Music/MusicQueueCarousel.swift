//
//  MusicQueueCarousel.swift
//  Rivulet
//
//  Horizontal queue carousel for the Now Playing screen.
//  Current track centered (larger), previous left, upcoming right.
//

import SwiftUI

struct MusicQueueCarousel: View {
    @ObservedObject var musicQueue: MusicQueue

    private let cardSize: CGFloat = 120
    private let currentCardSize: CGFloat = 160
    private let spacing: CGFloat = 24

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: spacing) {
                // History (previous tracks)
                ForEach(Array(musicQueue.history.enumerated()), id: \.element.ratingKey) { index, track in
                    carouselCard(track: track, isCurrent: false)
                        .onSubmit {
                            jumpToHistoryItem(at: index)
                        }
                }

                // Current track (larger)
                if let current = musicQueue.currentTrack {
                    carouselCard(track: current, isCurrent: true)
                }

                // Queue (upcoming tracks)
                ForEach(Array(musicQueue.queue.enumerated()), id: \.element.ratingKey) { index, track in
                    carouselCard(track: track, isCurrent: false)
                        .onSubmit {
                            musicQueue.jumpToQueueItem(at: index)
                        }
                }
            }
            .padding(.horizontal, 80)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .frame(height: currentCardSize + 60)
    }

    // MARK: - Card

    @ViewBuilder
    private func carouselCard(track: PlexMetadata, isCurrent: Bool) -> some View {
        let size = isCurrent ? currentCardSize : cardSize

        Button {
            // No-op for current, jump for others handled via onSubmit
        } label: {
            VStack(spacing: 10) {
                // Album art
                ZStack {
                    trackArtView(for: track)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    isCurrent ? .white.opacity(0.5) : .clear,
                                    lineWidth: isCurrent ? 2 : 0
                                )
                        )
                        .shadow(
                            color: isCurrent ? .white.opacity(0.15) : .clear,
                            radius: isCurrent ? 12 : 0
                        )

                    // Playback indicator on current track
                    if isCurrent && musicQueue.playbackState == .playing {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                PlaybackIndicator(isPlaying: true, size: .small)
                                    .padding(8)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .frame(width: size, height: size)
                        .padding(6)
                    }
                }

                // Title
                Text(track.title ?? "Unknown")
                    .font(.system(size: isCurrent ? 16 : 14, weight: .medium))
                    .foregroundStyle(.white.opacity(isCurrent ? 0.9 : 0.7))
                    .lineLimit(1)

                // Artist
                Text(track.grandparentTitle ?? track.parentTitle ?? "")
                    .font(.system(size: isCurrent ? 14 : 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: size + 20)
        }
        .buttonStyle(.plain)
        .opacity(isCurrent ? 1.0 : 0.7)
    }

    // MARK: - Art

    private func trackArtView(for track: PlexMetadata) -> some View {
        Group {
            if let url = artURL(for: track) {
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
            .fill(Color(white: 0.15))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 32, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }

    private func artURL(for track: PlexMetadata) -> URL? {
        guard let thumb = track.thumb ?? track.parentThumb,
              let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    // MARK: - Actions

    private func jumpToHistoryItem(at index: Int) {
        guard let current = musicQueue.currentTrack else { return }

        // Put current track back at front of queue
        var newQueue = [current] + musicQueue.queue

        // Put tracks after this history item back into queue
        let skipped = Array(musicQueue.history.suffix(from: index + 1))
        newQueue = skipped + newQueue

        let track = musicQueue.history[index]

        // Update state
        musicQueue.history = Array(musicQueue.history.prefix(index))
        musicQueue.queue = newQueue
        musicQueue.playNow(track: track)
    }
}
