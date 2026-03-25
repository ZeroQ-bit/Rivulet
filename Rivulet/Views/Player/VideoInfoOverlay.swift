//
//  VideoInfoOverlay.swift
//  Rivulet
//
//  Apple-style overlay displaying detailed video file information
//

import SwiftUI

struct VideoInfoOverlay: View {
    let metadata: PlexMetadata
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            // Content card positioned in bottom-left
            VStack {
                Spacer()
                HStack {
                    contentCard
                        .padding(.leading, 60)
                        .padding(.bottom, 60)
                    Spacer()
                }
            }
        }
        // Dismiss on Menu button press
        .onExitCommand {
            isPresented = false
        }
    }

    private var contentCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                Divider()
                videoSection
                if hasAudioStreams {
                    Divider()
                    audioSection
                }
                if hasSubtitleStreams {
                    Divider()
                    subtitleSection
                }
                if metadata.Media?.first?.Part != nil {
                    Divider()
                    fileSection
                }
            }
            .padding(40)
        }
        .frame(maxWidth: 800, maxHeight: 800)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Media Info")
                    .font(.system(size: 42, weight: .bold))

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Title
            if let title = metadata.title {
                Text(title)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Video Section

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VIDEO")
                .font(.system(size: 20, weight: .bold))
                .tracking(2)
                .foregroundStyle(.secondary)

            // Use video stream's displayTitle if available, otherwise build from media info
            if let videoStream = primaryVideoStream {
                if let displayTitle = videoStream.displayTitle ?? videoStream.extendedDisplayTitle {
                    InfoRow(label: "Format", value: displayTitle)
                }

                // HDR/DV info
                if videoStream.isDolbyVision {
                    let dvInfo = "Profile \(videoStream.DOVIProfile ?? 0)" +
                        (videoStream.DOVIBLCompatID != nil ? " (CompatID \(videoStream.DOVIBLCompatID!))" : "")
                    InfoRow(label: "Dolby Vision", value: dvInfo)
                } else if videoStream.isHDR {
                    InfoRow(label: "HDR", value: "HDR10")
                }

                if let bitDepth = videoStream.bitDepth {
                    InfoRow(label: "Bit Depth", value: "\(bitDepth)-bit")
                }

                if let colorSpace = videoStream.colorSpace {
                    InfoRow(label: "Color Space", value: colorSpace)
                }
            } else if let media = metadata.Media?.first {
                // Fallback to media-level info
                if let codec = media.videoCodec {
                    InfoRow(label: "Codec", value: codec.uppercased())
                }
                if let res = media.videoResolution {
                    InfoRow(label: "Resolution", value: res)
                }
            }

            // Dimensions and frame rate from media
            if let media = metadata.Media?.first {
                if let width = media.width, let height = media.height {
                    InfoRow(label: "Dimensions", value: "\(width) × \(height)")
                }
                if let frameRate = media.videoFrameRate {
                    InfoRow(label: "Frame Rate", value: frameRate)
                }
                if let bitrate = media.bitrate {
                    InfoRow(label: "Bitrate", value: formatBitrate(bitrate))
                }
            }
        }
    }

    // MARK: - Audio Section

    private var hasAudioStreams: Bool {
        audioStreams.count > 0
    }

    private var audioStreams: [PlexStream] {
        metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isAudio } ?? []
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AUDIO")
                .font(.system(size: 20, weight: .bold))
                .tracking(2)
                .foregroundStyle(.secondary)

            if audioStreams.isEmpty {
                // Fallback to media-level audio info
                if let media = metadata.Media?.first {
                    if let codec = media.audioCodec, let channels = media.audioChannels {
                        InfoRow(label: "Track 1", value: "\(codec.uppercased()) \(channelLayout(channels))")
                    }
                }
            } else {
                ForEach(Array(audioStreams.enumerated()), id: \.element.id) { index, stream in
                    audioStreamRow(stream: stream, index: index)
                }
            }
        }
    }

    private func audioStreamRow(stream: PlexStream, index: Int) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(index + 1)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                // Use displayTitle which includes language and format
                Text(stream.displayTitle ?? stream.extendedDisplayTitle ?? "Unknown")
                    .font(.system(size: 26, weight: .medium))

                // Additional details
                if let detailsText = audioStreamDetails(stream) {
                    Text(detailsText)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Default indicator
            if stream.default == true {
                Text("DEFAULT")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Subtitle Section

    private var hasSubtitleStreams: Bool {
        subtitleStreams.count > 0
    }

    private var subtitleStreams: [PlexStream] {
        metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isSubtitle } ?? []
    }

    private var subtitleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SUBTITLES")
                .font(.system(size: 20, weight: .bold))
                .tracking(2)
                .foregroundStyle(.secondary)

            if subtitleStreams.isEmpty {
                Text("No subtitles available")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(subtitleStreams.enumerated()), id: \.element.id) { index, stream in
                    subtitleStreamRow(stream: stream, index: index)
                }
            }
        }
    }

    private func subtitleStreamRow(stream: PlexStream, index: Int) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text("\(index + 1)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 40)

            // Use displayTitle which includes language and format
            Text(stream.extendedDisplayTitle ?? stream.displayTitle ?? "Unknown")
                .font(.system(size: 26, weight: .medium))

            Spacer()

            // Badges
            HStack(spacing: 8) {
                if stream.forced == true {
                    badgeView("FORCED")
                }
                if stream.hearingImpaired == true {
                    badgeView("SDH")
                }
                if stream.default == true {
                    badgeView("DEFAULT")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func badgeView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.15), in: Capsule())
    }

    // MARK: - File Section

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FILE")
                .font(.system(size: 20, weight: .bold))
                .tracking(2)
                .foregroundStyle(.secondary)

            if let part = metadata.Media?.first?.Part?.first {
                if let file = part.file {
                    // Show just filename, not full path
                    let filename = (file as NSString).lastPathComponent
                    InfoRow(label: "Name", value: filename)
                }

                if let container = part.container ?? metadata.Media?.first?.container {
                    InfoRow(label: "Container", value: container.uppercased())
                }

                if let size = part.size {
                    InfoRow(label: "Size", value: formatFileSize(Int64(size)))
                }

                if let duration = metadata.duration ?? part.duration {
                    InfoRow(label: "Duration", value: formatDuration(duration))
                }
            }
        }
    }

    // MARK: - Helpers

    private var primaryVideoStream: PlexStream? {
        metadata.Media?.first?.Part?.first?.Stream?.first { $0.isVideo }
    }

    private func audioStreamDetails(_ stream: PlexStream) -> String? {
        var details: [String] = []
        if let bitrate = stream.bitrate {
            details.append(formatBitrate(bitrate))
        }
        if let sampleRate = stream.samplingRate {
            details.append("\(sampleRate / 1000) kHz")
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    private func formatBitrate(_ bitrate: Int) -> String {
        if bitrate >= 1000000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1000000.0)
        } else if bitrate >= 1000 {
            return String(format: "%.0f kbps", Double(bitrate) / 1000.0)
        } else {
            return "\(bitrate) bps"
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Info Row Component

struct InfoRow: View {
    let label: String
    let value: String
    var isFile: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(label)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)

            Text(value)
                .font(.system(size: isFile ? 22 : 26, weight: .regular, design: isFile ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(isFile ? 2 : nil)

            Spacer()
        }
    }
}

#Preview {
    let sampleMedia = PlexMedia(
        id: 1,
        duration: 7200000,
        bitrate: 15000000,
        width: 1920,
        height: 1080,
        aspectRatio: 1.78,
        audioChannels: 6,
        audioCodec: "ac3",
        videoCodec: "h264",
        videoResolution: "1080p",
        container: "mkv",
        videoFrameRate: "24p",
        Part: [
            PlexPart(
                id: 1,
                key: "/library/parts/1/file.mkv",
                duration: 7200000,
                file: "/path/to/movie.mkv",
                size: 8000000000,
                container: "mkv",
                Stream: nil
            )
        ]
    )

    let sampleMetadata = PlexMetadata(
        ratingKey: "123",
        type: "movie",
        title: "Sample Movie",
        year: 2024,
        Media: [sampleMedia]
    )

    VideoInfoOverlay(metadata: sampleMetadata, isPresented: .constant(true))
}
