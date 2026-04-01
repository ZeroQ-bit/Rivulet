//
//  MusicNowPlayingView.swift
//  Rivulet
//
//  Full-screen Now Playing view matching Apple Music tvOS patterns.
//  Centered album art, controls on demand, horizontal queue carousel.
//

import SwiftUI

struct MusicNowPlayingView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var musicQueue = MusicQueue.shared
    @ObservedObject private var authManager = PlexAuthManager.shared
    @State private var showControls = false
    @State private var controlsTimer: Timer?
    @FocusState private var focusedControl: NowPlayingControl?

    enum NowPlayingControl: Hashable {
        case previous
        case playPause
        case next
        case shuffle
        case repeatMode
        case progressBar
        case queueItem(String) // ratingKey
    }

    var body: some View {
        ZStack {
            // Blurred album art backdrop
            albumArtBackdrop

            // Content
            VStack(spacing: 0) {
                Spacer()

                if showControls {
                    controlsView
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    ambientView
                        .transition(.opacity)
                }

                Spacer()

                // Progress bar (always visible, thin when ambient)
                MusicProgressBar(
                    currentTime: musicQueue.currentTime,
                    duration: musicQueue.duration,
                    isExpanded: showControls,
                    onSeek: { time in musicQueue.seek(to: time) }
                )
                .padding(.horizontal, 80)
                .padding(.bottom, showControls ? 40 : 20)
            }
        }
        .ignoresSafeArea()
        .onExitCommand {
            if showControls {
                hideControls()
            } else {
                isPresented = false
            }
        }
        .onPlayPauseCommand {
            musicQueue.togglePlayPause()
        }
        .onMoveCommand { direction in
            switch direction {
            case .down:
                if !showControls {
                    revealControls()
                }
            case .up:
                if showControls {
                    hideControls()
                }
            case .left:
                if !showControls {
                    musicQueue.skipToPrevious()
                }
            case .right:
                if !showControls {
                    musicQueue.skipToNext()
                }
            @unknown default:
                break
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showControls)
        .onChange(of: musicQueue.currentTrack?.ratingKey) { _, _ in
            // Reset controls visibility on track change
        }
    }

    // MARK: - Ambient View (Controls Hidden)

    private var ambientView: some View {
        VStack(spacing: 24) {
            // Large centered album art
            albumArtView
                .frame(width: 500, height: 500)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)

            // Track info
            VStack(spacing: 8) {
                Text(musicQueue.currentTrack?.title ?? "Not Playing")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(artistName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)

                Text(albumName)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Controls View (Revealed)

    private var controlsView: some View {
        VStack(spacing: 32) {
            HStack(spacing: 60) {
                // Album art (smaller when controls shown)
                albumArtView
                    .frame(width: 340, height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 10)

                // Track info + controls
                VStack(alignment: .leading, spacing: 24) {
                    // Track metadata
                    VStack(alignment: .leading, spacing: 6) {
                        Text(musicQueue.currentTrack?.title ?? "Not Playing")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(artistName)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)

                        Text(albumName)
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    // Playback controls
                    playbackControls

                    // Up Next
                    if !musicQueue.queue.isEmpty {
                        upNextSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 80)
        }
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 40) {
            // Shuffle
            controlButton(
                icon: "shuffle",
                isActive: musicQueue.isShuffled,
                control: .shuffle
            ) {
                musicQueue.toggleShuffle()
            }

            // Previous
            controlButton(
                icon: "backward.fill",
                control: .previous
            ) {
                musicQueue.skipToPrevious()
            }

            // Play/Pause (larger)
            controlButton(
                icon: musicQueue.playbackState == .playing ? "pause.fill" : "play.fill",
                control: .playPause,
                isLarge: true
            ) {
                musicQueue.togglePlayPause()
            }

            // Next
            controlButton(
                icon: "forward.fill",
                control: .next
            ) {
                musicQueue.skipToNext()
            }

            // Repeat
            controlButton(
                icon: repeatIcon,
                isActive: musicQueue.repeatMode != .off,
                control: .repeatMode
            ) {
                musicQueue.cycleRepeatMode()
            }
        }
    }

    private func controlButton(
        icon: String,
        isActive: Bool = false,
        control: NowPlayingControl,
        isLarge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: isLarge ? 36 : 24, weight: .medium))
                .foregroundStyle(isActive ? .white : .white.opacity(focusedControl == control ? 1.0 : 0.6))
                .frame(width: isLarge ? 72 : 48, height: isLarge ? 72 : 48)
                .background(
                    Circle()
                        .fill(focusedControl == control ? .white.opacity(0.2) : .clear)
                )
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: control)
        .scaleEffect(focusedControl == control ? 1.15 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedControl == control)
    }

    // MARK: - Up Next Section

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up Next")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            VStack(spacing: 8) {
                ForEach(Array(musicQueue.queue.prefix(3).enumerated()), id: \.element.ratingKey) { index, track in
                    queueTrackRow(track: track, index: index)
                }
            }
        }
    }

    private func queueTrackRow(track: PlexMetadata, index: Int) -> some View {
        Button {
            musicQueue.jumpToQueueItem(at: index)
        } label: {
            HStack(spacing: 12) {
                // Small album art
                queueArtView(for: track)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title ?? "Unknown")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)

                    Text(track.grandparentTitle ?? track.parentTitle ?? "")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }

                Spacer()

                if let duration = track.duration {
                    Text(formatDuration(duration))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(focusedControl == .queueItem(track.ratingKey ?? "") ? .white.opacity(0.15) : .white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .queueItem(track.ratingKey ?? ""))
    }

    // MARK: - Album Art

    private var albumArtView: some View {
        Group {
            if let thumbURL = albumArtURL {
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        artPlaceholder
                    case .failure:
                        artPlaceholder
                    @unknown default:
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
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.3))
            }
    }

    private func queueArtView(for track: PlexMetadata) -> some View {
        Group {
            if let url = artURL(for: track) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color(white: 0.15))
                    }
                }
            } else {
                Rectangle().fill(Color(white: 0.15))
            }
        }
    }

    // MARK: - Backdrop

    private var albumArtBackdrop: some View {
        Group {
            if let thumbURL = albumArtURL {
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 60)
                            .scaleEffect(1.3)
                            .overlay(Color.black.opacity(0.5))
                    default:
                        Color.black
                    }
                }
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Helpers

    private var artistName: String {
        musicQueue.currentTrack?.grandparentTitle ?? musicQueue.currentTrack?.parentTitle ?? "Unknown Artist"
    }

    private var albumName: String {
        musicQueue.currentTrack?.parentTitle ?? ""
    }

    private var albumArtURL: URL? {
        guard let thumb = musicQueue.currentTrack?.thumb ?? musicQueue.currentTrack?.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private func artURL(for track: PlexMetadata) -> URL? {
        guard let thumb = track.thumb ?? track.parentThumb,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private var repeatIcon: String {
        switch musicQueue.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func revealControls() {
        showControls = true
        focusedControl = .playPause
        resetControlsTimer()
    }

    private func hideControls() {
        showControls = false
        focusedControl = nil
        controlsTimer?.invalidate()
        controlsTimer = nil
    }

    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            Task { @MainActor in
                hideControls()
            }
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
