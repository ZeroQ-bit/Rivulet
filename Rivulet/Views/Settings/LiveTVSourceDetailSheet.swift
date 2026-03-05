//
//  LiveTVSourceDetailSheet.swift
//  Rivulet
//
//  Full-screen detail view for managing an individual Live TV source
//

import SwiftUI

struct LiveTVSourceDetailSheet: View {
    let source: LiveTVDataStore.LiveTVSourceInfo

    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataStore = LiveTVDataStore.shared
    @State private var isRefreshing = false
    @State private var showDeleteConfirmation = false

    private var iconName: String {
        switch source.sourceType {
        case .plex: return "play.rectangle.fill"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        case .genericM3U: return "list.bullet.rectangle"
        }
    }

    private var iconColor: Color {
        switch source.sourceType {
        case .plex: return .orange
        case .dispatcharr: return .blue
        case .genericM3U: return .green
        }
    }

    private var sourceTypeLabel: String {
        switch source.sourceType {
        case .plex: return "Plex Live TV"
        case .dispatcharr: return "Dispatcharr"
        case .genericM3U: return "M3U Playlist"
        }
    }

    var body: some View {
        ZStack {
            // Solid black background
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header bar
                headerBar

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 40) {
                        // Source icon and name
                        sourceHeader

                        // Status card
                        statusCard

                        // Actions
                        actionsSection
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 60)
                }
            }
        }
        .confirmationDialog(
            "Remove Source?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                removeSource()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(source.displayName)\" and all its channels from Live TV.")
        }
        // Use system appearance
        #if os(tvOS)
        .onExitCommand {
            dismiss()
        }
        #endif
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        Text("Source Details")
            .font(.system(size: 32, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 60)
            .padding(.top, 50)
        .padding(.bottom, 24)
    }

    // MARK: - Source Header

    private var sourceHeader: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(iconColor.gradient)
                    .frame(width: 120, height: 120)

                Image(systemName: iconName)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                Text(source.displayName)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)

                Text(sourceTypeLabel)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.top, 24)
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(spacing: 0) {
            statusRow(title: "Status", value: source.isConnected ? "Connected" : "Disconnected", valueColor: source.isConnected ? .green : .red)

            Divider()
                .background(.white.opacity(0.15))
                .padding(.horizontal, 20)

            statusRow(title: "Channels", value: "\(source.channelCount)")

            if let lastSync = source.lastSync {
                Divider()
                    .background(.white.opacity(0.15))
                    .padding(.horizontal, 20)

                statusRow(title: "Last Synced", value: lastSync.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.08))
        )
    }

    private func statusRow(title: String, value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 16) {
            // Refresh button
            SourceActionButton(
                icon: "arrow.clockwise",
                iconColor: .blue,
                title: "Refresh Channels",
                subtitle: "Reload channel list from source",
                isLoading: isRefreshing
            ) {
                refreshSource()
            }

            // Remove button
            SourceActionButton(
                icon: "trash",
                iconColor: .red,
                title: "Remove Source",
                subtitle: "Disconnect this Live TV source",
                isDestructive: true
            ) {
                showDeleteConfirmation = true
            }
        }
    }

    // MARK: - Actions

    private func refreshSource() {
        isRefreshing = true

        Task {
            await dataStore.refreshChannels()

            await MainActor.run {
                isRefreshing = false
            }
        }
    }

    private func removeSource() {
        Task {
            await dataStore.removeSource(id: source.id)

            await MainActor.run {
                dismiss()
            }
        }
    }
}

// MARK: - Source Action Button

private struct SourceActionButton: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    var isLoading: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 20) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 64, height: 64)

                if isLoading {
                    ProgressView()
                        .tint(iconColor)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }

            // Text
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(isDestructive ? .red : .white)

                Text(subtitle)
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? (isDestructive ? .red.opacity(0.15) : .white.opacity(0.15)) : .white.opacity(0.08))
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .focusable()
        .focused($isFocused)
        .onTapGesture {
            if !isLoading {
                action()
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

#Preview {
    LiveTVSourceDetailSheet(source: LiveTVDataStore.LiveTVSourceInfo(
        id: "test",
        sourceType: .dispatcharr,
        displayName: "Test Source",
        channelCount: 42,
        isConnected: true,
        lastSync: Date()
    ))
}
