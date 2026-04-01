//
//  MusicNowPlayingView.swift
//  Rivulet
//
//  Now Playing view matching Apple Music tvOS design.
//  Centered layout: album name top, large art center, track+artist below,
//  thin progress bar near bottom, action pills at bottom edges.
//

import SwiftUI

struct MusicNowPlayingView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var musicQueue = MusicQueue.shared
    @ObservedObject private var authManager = PlexAuthManager.shared

    @State private var showControls = false
    @State private var showQueue = false
    @State private var controlsTimer: Timer?

    @FocusState private var focusedControl: NowPlayingControl?

    enum NowPlayingControl: Hashable {
        case previous
        case playPause
        case next
        case shuffle
        case repeatMode
        case info
        case contextMenu
        case lyrics
        case queue
        case progressBar
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Blurred album art backdrop
            albumArtBackdrop

            // Main content
            VStack(spacing: 0) {
                // Album name — top center
                Text(albumName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .padding(.top, 50)

                Spacer()

                // Large centered album art
                albumArtView
                    .frame(width: 420, height: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 20)

                // Track title with playback indicator
                HStack(spacing: 12) {
                    if musicQueue.playbackState == .playing {
                        PlaybackIndicator(isPlaying: true, size: .medium)
                    }

                    Text(musicQueue.currentTrack?.title ?? "Not Playing")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.top, 28)

                // Artist name
                Text(artistName)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.top, 6)

                Spacer()

                // Transport controls (only when shown)
                if showControls {
                    transportControls
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .padding(.bottom, 10)
                }

                // Progress bar — near bottom
                MusicProgressBar(
                    currentTime: musicQueue.currentTime,
                    duration: musicQueue.duration,
                    isExpanded: showControls,
                    onSeek: { time in musicQueue.seek(to: time) }
                )
                .padding(.horizontal, 80)
                .padding(.bottom, 12)

                // Bottom bar: Info left, action icons right
                bottomBar
                    .padding(.horizontal, 80)
                    .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea()
        .onExitCommand {
            if showQueue {
                showQueue = false
            } else if showControls {
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
        .fullScreenCover(isPresented: $showQueue) {
            MusicQueueListView(isPresented: $showQueue)
                .presentationBackground(.clear)
        }
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
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
            controlButton(icon: "backward.fill", control: .previous) {
                musicQueue.skipToPrevious()
            }

            // Play/Pause
            controlButton(
                icon: musicQueue.playbackState == .playing ? "pause.fill" : "play.fill",
                control: .playPause,
                isLarge: true
            ) {
                musicQueue.togglePlayPause()
            }

            // Next
            controlButton(icon: "forward.fill", control: .next) {
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
        Button(action: {
            action()
            resetControlsTimer()
        }) {
            Image(systemName: icon)
                .font(.system(size: isLarge ? 36 : 24, weight: .medium))
                .foregroundStyle(
                    isActive ? .white : .white.opacity(focusedControl == control ? 1.0 : 0.6)
                )
                .frame(width: isLarge ? 72 : 48, height: isLarge ? 72 : 48)
                .background(
                    Circle()
                        .fill(focusedControl == control ? .white.opacity(0.2) : .clear)
                )
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: control)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Left: Info pill
            Button {
                // Info action (could show track details)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Info")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(focusedControl == .info ? .black : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(focusedControl == .info ? .white : .white.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .info)

            Spacer()

            // Right: Action circle buttons
            HStack(spacing: 16) {
                // Context menu (...)
                bottomCircleButton(icon: "ellipsis", control: .contextMenu)
                    .contextMenu {
                        if let track = musicQueue.currentTrack {
                            Button {
                                musicQueue.addNext(track: track)
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }

                            Button {
                                musicQueue.addToEnd(track: track)
                            } label: {
                                Label("Add to Queue", systemImage: "text.append")
                            }
                        }
                    }

                // Queue
                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(focusedControl == .queue ? .black : .white.opacity(0.6))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(focusedControl == .queue ? .white : .white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .queue)
            }
        }
    }

    private func bottomCircleButton(icon: String, control: NowPlayingControl) -> some View {
        Button {
            // No-op for buttons that use contextMenu
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(focusedControl == control ? .black : .white.opacity(0.6))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(focusedControl == control ? .white : .white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: control)
    }

    // MARK: - Album Art

    private var albumArtView: some View {
        Group {
            if let thumbURL = albumArtURL {
                CachedAsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty, .failure:
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
}
