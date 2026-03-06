//
//  ChannelListView.swift
//  Rivulet
//
//  Live TV channel list view
//

import SwiftUI

struct ChannelListView: View {
    /// Optional source ID to filter channels. nil = show all sources.
    var sourceIdFilter: String?

    @StateObject private var dataStore = LiveTVDataStore.shared
    @State private var searchText = ""
    @State private var selectedChannel: UnifiedChannel?

    /// Channels filtered by source (if specified)
    private var sourceChannels: [UnifiedChannel] {
        if let sourceId = sourceIdFilter {
            return dataStore.channels.filter { $0.sourceId == sourceId }
        }
        return dataStore.channels
    }

    private var filteredChannels: [UnifiedChannel] {
        if searchText.isEmpty {
            return sourceChannels
        }
        let query = searchText.lowercased()
        return sourceChannels.filter { channel in
            channel.name.lowercased().contains(query) ||
            (channel.callSign?.lowercased().contains(query) ?? false) ||
            (channel.channelNumber.map { String($0).contains(query) } ?? false)
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()

            if dataStore.isLoadingChannels && sourceChannels.isEmpty {
                loadingView
            } else if sourceChannels.isEmpty {
                emptyView
            } else {
                channelGrid
            }

            // Player overlay - using ZStack instead of fullScreenCover to control dismissal
            if let channel = selectedChannel {
                LiveTVPlayerView(channel: channel, onDismiss: {
                    selectedChannel = nil
                })
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: selectedChannel != nil)
        .task {
            // Load channels if not already loaded
            if dataStore.channels.isEmpty && !dataStore.isLoadingChannels {
                await dataStore.loadChannels()
            }
            // Load EPG data for current programs
            if dataStore.epg.isEmpty && !dataStore.isLoadingEPG {
                await dataStore.loadEPG(startDate: Date(), hours: 6)
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Loading channels...")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 24) {
            Image(systemName: "tv.slash")
                .font(.system(size: 72, weight: .thin))
                .foregroundStyle(.white.opacity(0.3))

            VStack(spacing: 12) {
                Text("No Channels")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Add a Live TV source in Settings to see channels here.")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
        }
    }

    // MARK: - Channel Grid

    private var channelGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                VStack(alignment: .leading, spacing: 12) {
                    Text("Live TV")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)

                    Text("\(dataStore.channels.count) channels available")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 80)
                .padding(.top, 60)

                // Channel grid
                LazyVGrid(columns: gridColumns, spacing: 24) {
                    ForEach(filteredChannels) { channel in
                        ChannelCard(channel: channel) {
                            selectedChannel = channel
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 80)
            }
        }
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 280, maximum: 350), spacing: 24)
        ]
    }
}

// MARK: - Channel Card

struct ChannelCard: View {
    let channel: UnifiedChannel
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @StateObject private var dataStore = LiveTVDataStore.shared

    private var currentProgram: UnifiedProgram? {
        dataStore.getCurrentProgram(for: channel)
    }

    var body: some View {
        Button {
            action()
        } label: {
            cardContent
        }
        .buttonStyle(ChannelCardButtonStyle(isFocused: isFocused))
        .focused($isFocused)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Logo area
            ZStack {
                Rectangle()
                    .fill(Color(white: 0.15))

                if let logoURL = channel.logoURL {
                    CachedAsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(20)
                        case .failure:
                            channelPlaceholder
                        case .empty:
                            ProgressView()
                        @unknown default:
                            channelPlaceholder
                        }
                    }
                } else {
                    channelPlaceholder
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Channel info
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if let number = channel.channelNumber {
                        Text("\(number)")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Text(channel.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if channel.isHD {
                        Text("HD")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(.white.opacity(0.8))
                            )
                    }
                }

                if let program = currentProgram {
                    Text(program.title)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                } else if let callSign = channel.callSign {
                    Text(callSign)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isFocused ? .white.opacity(0.15) : .white.opacity(0.05))
        )
    }

    private var channelPlaceholder: some View {
        Image(systemName: "tv")
            .font(.system(size: 40, weight: .light))
            .foregroundStyle(.white.opacity(0.3))
    }
}

// MARK: - Channel Card Button Style

private struct ChannelCardButtonStyle: ButtonStyle {
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 20, y: 10)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#Preview {
    ChannelListView()
}
