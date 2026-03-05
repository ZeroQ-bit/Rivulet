//
//  LibrarySettingsView.swift
//  Rivulet
//
//  Library visibility and ordering settings
//

import SwiftUI

struct LibrarySettingsView: View {
    @Binding var focusedSettingId: String?
    @StateObject private var dataStore = PlexDataStore.shared
    @StateObject private var librarySettings = LibrarySettingsManager.shared
    @State private var reorderingLibrary: PlexLibrary?

    init(focusedSettingId: Binding<String?> = .constant(nil)) {
        self._focusedSettingId = focusedSettingId
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Choose which libraries appear in the sidebar. Click to toggle, long press to reorder.")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.5))

            if dataStore.libraries.isEmpty {
                // No libraries
                VStack(spacing: 32) {
                    Image(systemName: "folder")
                        .font(.system(size: 80, weight: .thin))
                        .foregroundStyle(.white.opacity(0.5))

                    Text("No Libraries")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("Connect to a Plex server to manage library visibility.")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 70)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                // Library list
                SettingsSection(title: "Sidebar") {
                    ForEach(orderedLibraries, id: \.key) { library in
                        LibraryVisibilityRow(
                            library: library,
                            isVisible: librarySettings.isLibraryVisible(library.key),
                            isShownOnHome: (library.isVideoLibrary || library.isMusicLibrary) ? librarySettings.isLibraryShownOnHome(library.key) : nil,
                            onToggle: {
                                librarySettings.toggleVisibility(for: library.key)
                            },
                            onLongPress: {
                                reorderingLibrary = library
                            }
                        )
                    }
                }

                // Reset button
                SettingsSection(title: "Reset") {
                    SettingsActionRow(
                        title: "Reset to Defaults",
                        isDestructive: false
                    ) {
                        librarySettings.resetToDefaults()
                    }
                }
            }
        }
        .sheet(item: $reorderingLibrary) { library in
            LibraryReorderSheet(
                library: library,
                librarySettings: librarySettings,
                allLibraries: orderedLibraries,
                onDismiss: { reorderingLibrary = nil }
            )
        }
    }

    // MARK: - Helpers

    /// Libraries sorted by user preference
    private var orderedLibraries: [PlexLibrary] {
        librarySettings.sortLibraries(dataStore.libraries.filter { $0.isVideoLibrary || $0.isMusicLibrary })
    }

    private func canMoveUp(_ library: PlexLibrary) -> Bool {
        guard let index = orderedLibraries.firstIndex(where: { $0.key == library.key }) else {
            return false
        }
        return index > 0
    }

    private func canMoveDown(_ library: PlexLibrary) -> Bool {
        guard let index = orderedLibraries.firstIndex(where: { $0.key == library.key }) else {
            return false
        }
        return index < orderedLibraries.count - 1
    }

    private func moveUp(_ library: PlexLibrary) {
        guard let orderIndex = librarySettings.libraryOrder.firstIndex(of: library.key) else {
            return
        }
        if orderIndex > 0 {
            librarySettings.moveLibrary(from: orderIndex, to: orderIndex - 1)
        }
    }

    private func moveDown(_ library: PlexLibrary) {
        guard let orderIndex = librarySettings.libraryOrder.firstIndex(of: library.key) else {
            return
        }
        if orderIndex < librarySettings.libraryOrder.count - 1 {
            librarySettings.moveLibrary(from: orderIndex, to: orderIndex + 2)
        }
    }
}

// MARK: - Library Visibility Row

struct LibraryVisibilityRow: View {
    let library: PlexLibrary
    let isVisible: Bool
    let isShownOnHome: Bool?
    let onToggle: () -> Void
    let onLongPress: () -> Void

    @FocusState private var isFocused: Bool

    private var iconName: String {
        switch library.type {
        case "movie": return "film.fill"
        case "show": return "tv.fill"
        case "artist": return "music.note"
        case "photo": return "photo.fill"
        default: return "folder.fill"
        }
    }

    private var iconColor: Color {
        switch library.type {
        case "movie": return .blue
        case "show": return .purple
        case "artist": return .pink
        case "photo": return .green
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 20) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(iconColor.gradient)
                    .frame(width: 64, height: 64)

                Image(systemName: iconName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            // Library info
            VStack(alignment: .leading, spacing: 4) {
                Text(library.title)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.white)

                if let showOnHome = isShownOnHome {
                    Text(showOnHome ? "On Home" : "Hidden from Home")
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Text(library.type.capitalized)
                        .font(.system(size: 23))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()

            // On/Off indicator
            Text(isVisible ? "On" : "Off")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(isVisible ? .green : .white.opacity(0.5))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
        .focusable()
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .onTapGesture { onToggle() }
        .onLongPressGesture(minimumDuration: 0.5) {
            onLongPress()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .animation(.easeOut(duration: 0.2), value: isVisible)
    }
}

// MARK: - Library Reorder Sheet

struct LibraryReorderSheet: View {
    let library: PlexLibrary
    @ObservedObject var librarySettings: LibrarySettingsManager
    let allLibraries: [PlexLibrary]
    let onDismiss: () -> Void

    @FocusState private var focusedButton: ReorderButton?

    private enum ReorderButton: Hashable {
        case up, down, home, done
    }

    private var supportsHomeScreen: Bool {
        library.isVideoLibrary || library.isMusicLibrary
    }

    private var isShownOnHome: Bool {
        librarySettings.isLibraryShownOnHome(library.key)
    }

    private var iconName: String {
        switch library.type {
        case "movie": return "film.fill"
        case "show": return "tv.fill"
        case "artist": return "music.note"
        case "photo": return "photo.fill"
        default: return "folder.fill"
        }
    }

    private var iconColor: Color {
        switch library.type {
        case "movie": return .blue
        case "show": return .purple
        case "artist": return .pink
        case "photo": return .green
        default: return .gray
        }
    }

    private var currentIndex: Int? {
        let sortedLibraries = librarySettings.sortLibraries(allLibraries)
        return sortedLibraries.firstIndex(where: { $0.key == library.key })
    }

    private var canMoveUp: Bool {
        guard let index = currentIndex else { return false }
        return index > 0
    }

    private var canMoveDown: Bool {
        guard let index = currentIndex else { return false }
        let sortedLibraries = librarySettings.sortLibraries(allLibraries)
        return index < sortedLibraries.count - 1
    }

    private var positionText: String {
        let sortedLibraries = librarySettings.sortLibraries(allLibraries)
        guard let index = currentIndex else { return "Reorder Library" }
        return "Position \(index + 1) of \(sortedLibraries.count)"
    }

    private func moveUp() {
        guard let orderIndex = librarySettings.libraryOrder.firstIndex(of: library.key),
              orderIndex > 0 else { return }
        librarySettings.moveLibrary(from: orderIndex, to: orderIndex - 1)
    }

    private func moveDown() {
        guard let orderIndex = librarySettings.libraryOrder.firstIndex(of: library.key),
              orderIndex < librarySettings.libraryOrder.count - 1 else { return }
        librarySettings.moveLibrary(from: orderIndex, to: orderIndex + 2)
    }

    var body: some View {
        VStack(spacing: 36) {
            // Header
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(iconColor.gradient)
                        .frame(width: 88, height: 88)

                    Image(systemName: iconName)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(library.title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)

                Text(positionText)
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 48)

            // Reorder buttons
            VStack(spacing: 18) {
                Button {
                    moveUp()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Move Up")
                            .font(.system(size: 28, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(focusedButton == .up ? .white.opacity(0.18) : .white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(
                                        focusedButton == .up ? .white.opacity(0.25) : .white.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                    )
                }
                .buttonStyle(SettingsButtonStyle())
                .focused($focusedButton, equals: .up)
                .scaleEffect(focusedButton == .up ? 1.02 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedButton)
                .disabled(!canMoveUp)
                .opacity(canMoveUp ? 1.0 : 0.4)

                Button {
                    moveDown()
                } label: {
                    HStack {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Move Down")
                            .font(.system(size: 28, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(focusedButton == .down ? .white.opacity(0.18) : .white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(
                                        focusedButton == .down ? .white.opacity(0.25) : .white.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                    )
                }
                .buttonStyle(SettingsButtonStyle())
                .focused($focusedButton, equals: .down)
                .scaleEffect(focusedButton == .down ? 1.02 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedButton)
                .disabled(!canMoveDown)
                .opacity(canMoveDown ? 1.0 : 0.4)

                if supportsHomeScreen {
                    Button {
                        let allMediaKeys = allLibraries
                            .filter { $0.isVideoLibrary || $0.isMusicLibrary }
                            .map { $0.key }
                        librarySettings.toggleHomeVisibility(for: library.key, allLibraryKeys: allMediaKeys)
                    } label: {
                        HStack {
                            Image(systemName: isShownOnHome ? "house.fill" : "house")
                                .font(.system(size: 26, weight: .semibold))
                            Text(isShownOnHome ? "Hide from Home" : "Show on Home")
                                .font(.system(size: 28, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(focusedButton == .home ? .white.opacity(0.18) : .white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(
                                            focusedButton == .home ? .white.opacity(0.25) : .white.opacity(0.08),
                                            lineWidth: 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .focused($focusedButton, equals: .home)
                    .scaleEffect(focusedButton == .home ? 1.02 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedButton)
                }
            }
            .padding(.horizontal, 56)

            Spacer()

            // Done button
            Button {
                onDismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(focusedButton == .done ? .blue : .blue.opacity(0.8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(
                                        focusedButton == .done ? .white.opacity(0.3) : .clear,
                                        lineWidth: 1
                                    )
                            )
                    )
            }
            .buttonStyle(SettingsButtonStyle())
            .focused($focusedButton, equals: .done)
            .scaleEffect(focusedButton == .done ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedButton)
            .padding(.horizontal, 56)
            .padding(.bottom, 48)
        }
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.black.opacity(0.3))
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .foregroundStyle(.white)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if canMoveUp {
                    focusedButton = .up
                } else if canMoveDown {
                    focusedButton = .down
                } else {
                    focusedButton = .done
                }
            }
        }
    }
}

#Preview {
    LibrarySettingsView()
}
