//
//  WhatsNewView.swift
//  Rivulet
//
//  Shows a one-time "What's New" overlay when the app updates
//  to a version with a changelog entry.
//

import SwiftUI


struct WhatsNewView: View {
    @Binding var isPresented: Bool
    let version: String

    @FocusState private var isContinueFocused: Bool

    private var features: [String] {
        Self.features(for: version) ?? []
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ScrollView {
                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 8) {
                        Text("What's New")
                            .font(.system(size: 46, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Version \(version)")
                            .font(.system(size: 23, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.top, 40)

                    // Feature list
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                            HStack(alignment: .top, spacing: 14) {
                                Circle()
                                    .fill(.white.opacity(0.4))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 10)

                                Text(feature)
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, 40)

                    // Continue button
                    Button {
                        isPresented = false
                    } label: {
                        Text("Continue")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(isContinueFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(
                                                isContinueFocused ? .white.opacity(0.3) : .white.opacity(0.1),
                                                lineWidth: 1
                                            )
                                    )
                            )
                    }
                    .buttonStyle(GlassRowButtonStyle())
                    .focused($isContinueFocused)
                    .scaleEffect(isContinueFocused ? 1.02 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isContinueFocused)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 36)
                }
            }
            .frame(width: 520)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.black.opacity(0.3))
            )
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))

            Spacer()
        }
        .onExitCommand {
            isPresented = false
        }
    }

    // MARK: - Changelog Data

    static let changelogs: [(version: String, features: [String])] = [
        ("1.0.0 (44)", [
            "Built a completely custom video player using ffmpeg and internal tvOS tools. The end-goal is playback as smooth as Infuse. Its working well in all my tests, but please open any issues if you experience them",
            "Re-styled many GUI elements to match Apple TV+ style and functionality",
            "Apples built-in player (AVPlayer) can be used if desired. Toggle in settings.",
            "Currently re-working the music library style to match the Apple Music app, and am working on functionality to match PlexAmp. Its a WIP now but wanted to get something out.",
        ]),
        ("1.0.0 (40)", [
            "Fun depth effects on posters, because why not",
            "Redesigned season and episode navigation for TV shows",
            "Sort libraries by title, date added, rating, and more",
            "Option to hide recently added from library views",
            "Smoother video playback when Match Content is off",
            "Continuing Dolby Vision improvements",
            "General performance and stability improvements",
        ]),
        ("1.0.0 (38)", [
            "Faster video startup",
            "Default sizing is slightly larger",
            "Display Size setting now affects all sizes",
            "Improved Dolby Vision support for more video formats",
            "Playback now integrates with Apple's Now Playing for control from other Apple devices",
            "Scroll down an episode details page to get to Seasons and episode list",
        ]),
        ("1.0.0 (37)", [
            "You can now save your PIN for Plex Home profiles",
            "Live TV is more reliable with automatic stream recovery",
            "Support for more controller types",
            "PIP now works in Live TV",
            "Better multiview handling in Live TV",
            "Live TV scrubbing controls",
            "Continuuing efforts to stop audio buffer on HomePods",
            "Only show Post Video screen on tv shows with a next up episode",
        ]),
        ("1.0.0 (36)", [
            "Trying an experimental Dolby Vision player; If DV does not work, or works well, let me know",
            "Added Plex Home Account support. Enable it in settings",
            "Added shuffle buttons to Seasons and Series",
            "Library sections now appear individually on Home - Long-press libraries to toggle Home visibility",
            "Fixed navigation bugs",
            "Fixed some Add Live TV GUI issues",
            "Fixed some Live TV endpoint issues and added more error logging to pinpoint more",
            "Fixed audio not stopping",
            "Added Changelog popup and section in settings",
            "Removed percentage from Post Video summary",
            "Added background to post video summary"
        ]),
    ]

    static func features(for version: String) -> [String]? {
        changelogs.first(where: { $0.version == version })?.features
    }
}
