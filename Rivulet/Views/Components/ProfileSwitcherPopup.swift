//
//  ProfileSwitcherPopup.swift
//  Rivulet
//
//  Compact profile switcher popup for the sidebar account tab
//

import SwiftUI

#if os(tvOS)

struct ProfileSwitcherPopup: View {
    @Binding var isPresented: Bool
    @ObservedObject var profileManager: PlexUserProfileManager

    @State private var selectedUserForPin: PlexHomeUser?
    @State private var showPinEntry = false
    @State private var pinEntryError: String?
    @State private var isLoading = false
    @FocusState private var focusedUserId: Int?

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 8)
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Popup card — positioned top-left directly below sidebar pill
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(profileManager.homeUsers) { user in
                    profileButton(for: user)
                        .focused($focusedUserId, equals: user.id)
                }
            }
            .padding(28)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 58))
            .frame(maxWidth: 420)
            .padding(.top, 70)
            .padding(.leading, 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            focusedUserId = profileManager.selectedUser?.id ?? profileManager.homeUsers.first?.id
        }
        .onExitCommand {
            isPresented = false
        }
        .sheet(isPresented: $showPinEntry) {
            if let user = selectedUserForPin {
                PinEntrySheet(
                    user: user,
                    error: $pinEntryError,
                    onSubmit: { pin, rememberPin in
                        Task {
                            await verifyAndSwitch(user: user, pin: pin, rememberPin: rememberPin)
                        }
                    },
                    onCancel: {
                        showPinEntry = false
                        selectedUserForPin = nil
                        pinEntryError = nil
                    }
                )
            }
        }
    }

    private func profileButton(for user: PlexHomeUser) -> some View {
        let isCurrent = profileManager.selectedUser?.id == user.id
        let isFocused = focusedUserId == user.id
        let isLoadingThis = isLoading && selectedUserForPin?.id == user.id

        let firstName = user.displayName.split(separator: " ").first.map(String.init) ?? user.displayName
        let avatarSize: CGFloat = 140

        return Button {
            selectProfile(user)
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    avatarView(for: user)
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    isFocused ? .white.opacity(0.8) : .white.opacity(0.15),
                                    lineWidth: isFocused ? 3 : 1
                                )
                        )

                    if isLoadingThis {
                        Circle()
                            .fill(.black.opacity(0.5))
                            .frame(width: avatarSize, height: avatarSize)
                        ProgressView()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isCurrent && !isLoadingThis {
                        Circle()
                            .fill(.white)
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 38))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .green)
                            }
                            .offset(x: 8, y: -8)
                    } else if user.protected && !isCurrent && !isLoadingThis {
                        Image(systemName: profileManager.usersWithRememberedPins.contains(user.uuid)
                              ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(profileManager.usersWithRememberedPins.contains(user.uuid)
                                             ? .green : .white)
                            .padding(6)
                            .background(Circle().fill(.black.opacity(0.6)))
                            .offset(x: 4, y: -4)
                    }
                }

                Text(firstName)
                    .font(.system(size: 22, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isFocused ? 1.0 : 0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(ProfileSwitcherButtonStyle())
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    @ViewBuilder
    private func avatarView(for user: PlexHomeUser) -> some View {
        if let thumbURL = user.thumb, let url = URL(string: thumbURL) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    avatarPlaceholder(for: user)
                case .failure:
                    avatarPlaceholder(for: user)
                @unknown default:
                    avatarPlaceholder(for: user)
                }
            }
        } else {
            avatarPlaceholder(for: user)
        }
    }

    private func avatarPlaceholder(for user: PlexHomeUser) -> some View {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        let color = colors[abs(user.id) % colors.count]
        return ZStack {
            Circle().fill(color.gradient)
            Text(user.displayName.prefix(1).uppercased())
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Profile Selection

    private func selectProfile(_ user: PlexHomeUser) {
        // Already selected
        if profileManager.selectedUser?.id == user.id {
            isPresented = false
            return
        }

        if user.requiresPin {
            if profileManager.hasRememberedPin(for: user) {
                Task {
                    isLoading = true
                    selectedUserForPin = user
                    let (success, pinWasInvalid) = await profileManager.selectUserWithRememberedPin(user)
                    if success {
                        isLoading = false
                        selectedUserForPin = nil
                        isPresented = false
                    } else {
                        isLoading = false
                        pinEntryError = pinWasInvalid ? "Saved PIN is no longer valid. Please enter your PIN." : nil
                        showPinEntry = true
                    }
                }
            } else {
                selectedUserForPin = user
                pinEntryError = nil
                showPinEntry = true
            }
        } else {
            Task {
                isLoading = true
                selectedUserForPin = user
                let success = await profileManager.selectUser(user, pin: nil)
                isLoading = false
                selectedUserForPin = nil
                if success {
                    isPresented = false
                }
            }
        }
    }

    private func verifyAndSwitch(user: PlexHomeUser, pin: String, rememberPin: Bool) async {
        isLoading = true
        pinEntryError = nil

        let success = await profileManager.selectUser(user, pin: pin)

        if success {
            if rememberPin {
                profileManager.rememberPin(pin, for: user)
            }
            showPinEntry = false
            selectedUserForPin = nil
            isPresented = false
        } else {
            pinEntryError = "Incorrect PIN. Please try again."
        }

        isLoading = false
    }
}

// MARK: - Button Style

private struct ProfileSwitcherButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

#endif
