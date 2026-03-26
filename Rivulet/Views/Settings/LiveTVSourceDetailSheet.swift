//
//  LiveTVSourceDetailSheet.swift
//  Rivulet
//
//  Live TV source detail — inline settings page and full-screen sheet
//

import SwiftUI

// MARK: - Inline Settings View (navigated to within settings)

struct LiveTVSourceDetailView: View {
    let source: LiveTVDataStore.LiveTVSourceInfo
    @Binding var focusedSettingId: String?
    var onRemoved: (() -> Void)?

    @StateObject private var dataStore = LiveTVDataStore.shared
    @State private var isRefreshing = false
    @State private var showDeleteConfirmation = false

    init(source: LiveTVDataStore.LiveTVSourceInfo, focusedSettingId: Binding<String?> = .constant(nil), onRemoved: (() -> Void)? = nil) {
        self.source = source
        self._focusedSettingId = focusedSettingId
        self.onRemoved = onRemoved
    }

    var body: some View {
        Group {
            HStack {
                Text("Status")
                    .font(.system(size: 32))
                Spacer()
                Text(source.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 32))
                    .foregroundStyle(source.isConnected ? .green : .red)
            }
            .listRowBackground(Color.clear)

            HStack {
                Text("Channels")
                    .font(.system(size: 32))
                Spacer()
                Text("\(source.channelCount)")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)

            if let lastSync = source.lastSync {
                HStack {
                    Text("Last Synced")
                        .font(.system(size: 32))
                    Spacer()
                    Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }

            SettingsActionRow(
                title: isRefreshing ? "Refreshing..." : "Refresh Channels",
                action: { refreshSource() },
                onFocusChange: { if $0 { focusedSettingId = "refreshChannels" } }
            )
            .disabled(isRefreshing)

            SettingsActionRow(
                title: "Remove Source",
                isDestructive: true,
                action: { showDeleteConfirmation = true },
                onFocusChange: { if $0 { focusedSettingId = "removeSource" } }
            )
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
    }

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
                onRemoved?()
            }
        }
    }
}

// MARK: - Full-Screen Sheet (for presentation from non-settings contexts)

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
        VStack(spacing: 0) {
            // Header
            Text("Source Details")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .padding(.bottom, 24)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 40) {
                    sourceHeader
                    statusCard
                    actionsSection
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 60)
            }
        }
        .background(.clear)
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
        .onExitCommand {
            dismiss()
        }
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
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.55))
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
        .frame(maxWidth: 600)
    }

    private func statusRow(title: String, value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(valueColor)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 16) {
            Button {
                refreshSource()
            } label: {
                HStack(spacing: 20) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.blue.gradient)
                            .frame(width: 64, height: 64)

                        if isRefreshing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Refresh Channels")
                            .font(.system(size: 32))

                        Text("Reload channel list from source")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
            .disabled(isRefreshing)

            Button {
                showDeleteConfirmation = true
            } label: {
                HStack(spacing: 20) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.red.gradient)
                            .frame(width: 64, height: 64)

                        Image(systemName: "trash")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remove Source")
                            .font(.system(size: 32))
                            .foregroundStyle(.red)

                        Text("Disconnect this Live TV source")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
        }
        .frame(maxWidth: 600)
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
