//
//  SettingsComponents.swift
//  Rivulet
//
//  Reusable settings UI components for tvOS
//

import SwiftUI

// MARK: - Settings Section

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title.uppercased())
                .font(.system(size: 21, weight: .bold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 12)

            VStack(spacing: 12) {
                content
            }
            .padding(8)  // Room for scale effect
        }
    }
}

// MARK: - Settings Row (Navigation)

struct SettingsRow: View {
    var icon: String? = nil
    var iconColor: Color = .clear
    let title: String
    let subtitle: String
    let action: () -> Void
    var focusTrigger: Int? = nil  // When non-nil and changes, claim focus
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                // Icon
                if let icon {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(iconColor.gradient)
                            .frame(width: 64, height: 64)

                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                // Text - white for dark glass background
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 23))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .white.opacity(0.8) : .white.opacity(0.4))
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
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .onChange(of: focusTrigger) { _, newValue in
            if newValue != nil {
                isFocused = true
            }
        }
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

/// Button style that removes tvOS default focus ring
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Settings Info Row (Display Only)

struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Text(value)
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

// MARK: - Settings Toggle Row

struct SettingsToggleRow<HelpContent: View>: View {
    let icon: String?
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let helpTitle: String?
    let helpContent: HelpContent?
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool
    @State private var showHelp = false

    /// Initialize with help content
    init(
        icon: String? = nil,
        iconColor: Color = .clear,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        helpTitle: String?,
        onFocusChange: ((Bool) -> Void)? = nil,
        @ViewBuilder helpContent: () -> HelpContent
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
        self.helpTitle = helpTitle
        self.helpContent = helpContent()
        self.onFocusChange = onFocusChange
    }

    var body: some View {
        Button {
            // Action handled by LongPressButtonStyle to prevent toggle on long press
        } label: {
            HStack(spacing: 20) {
                // Icon
                if let icon {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(iconColor.gradient)
                            .frame(width: 64, height: 64)

                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                // Text - white for dark glass background
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 2) {
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 23))
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        // Show help hint if help is available
                        if helpContent != nil {
                            Text("Press & hold to learn more")
                                .font(.system(size: 19))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }

                Spacer()

                // On/Off text
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(isOn ? .green : .white.opacity(0.5))
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
        }
        .buttonStyle(LongPressButtonStyle(
            onTap: { isOn.toggle() },
            onLongPress: helpContent != nil ? { showHelp = true } : nil
        ))
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        #if os(tvOS)
        .sheet(isPresented: $showHelp) {
            if let helpContent, let helpTitle {
                SettingsHelpSheet(title: helpTitle, isPresented: $showHelp) {
                    helpContent
                }
            }
        }
        #endif
    }
}

// Extension for SettingsToggleRow without help content
extension SettingsToggleRow where HelpContent == EmptyView {
    init(
        icon: String? = nil,
        iconColor: Color = .clear,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onFocusChange: ((Bool) -> Void)? = nil
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
        self.helpTitle = nil
        self.helpContent = nil
        self.onFocusChange = onFocusChange
    }
}

// MARK: - Long Press Button Style

/// Button style that detects long press and calls a separate action.
/// When using this style, pass an empty action to Button and provide onTap here instead.
/// This prevents the button from toggling when a long press is performed.
struct LongPressButtonStyle: ButtonStyle {
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    private let longPressThreshold: TimeInterval = 0.5

    func makeBody(configuration: Configuration) -> some View {
        LongPressButtonContent(
            configuration: configuration,
            onTap: onTap,
            onLongPress: onLongPress,
            longPressThreshold: longPressThreshold
        )
    }
}

private struct LongPressButtonContent: View {
    let configuration: ButtonStyleConfiguration
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    let longPressThreshold: TimeInterval

    @State private var pressStartTime: Date?
    @State private var longPressTriggered = false
    @State private var holdProgress: CGFloat = 0
    @State private var progressTimer: Timer?

    var body: some View {
        configuration.label
            .overlay(alignment: .bottom) {
                // Progress indicator during hold (only if long press is available)
                if onLongPress != nil && holdProgress > 0 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(.white.opacity(0.4))
                            .frame(width: geo.size.width * holdProgress, height: 3)
                            .animation(.linear(duration: 0.05), value: holdProgress)
                    }
                    .frame(height: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    // Press started
                    pressStartTime = Date()
                    longPressTriggered = false
                    holdProgress = 0

                    // Start progress animation if long press is available
                    if onLongPress != nil {
                        // Update progress every 50ms
                        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                            guard let startTime = pressStartTime else {
                                progressTimer?.invalidate()
                                progressTimer = nil
                                return
                            }

                            let elapsed = Date().timeIntervalSince(startTime)
                            holdProgress = min(1.0, CGFloat(elapsed / longPressThreshold))

                            if elapsed >= longPressThreshold && !longPressTriggered {
                                longPressTriggered = true
                                progressTimer?.invalidate()
                                progressTimer = nil
                                holdProgress = 0
                                onLongPress?()
                            }
                        }
                    }
                } else {
                    // Press ended
                    // Only trigger tap if it wasn't a long press
                    if !longPressTriggered {
                        onTap?()
                    }

                    // Reset state
                    pressStartTime = nil
                    progressTimer?.invalidate()
                    progressTimer = nil
                    holdProgress = 0
                    longPressTriggered = false
                }
            }
    }
}

// MARK: - Settings Help Sheet

struct SettingsHelpSheet<Content: View>: View {
    let title: String
    @Binding var isPresented: Bool
    @ViewBuilder let content: Content

    @FocusState private var isDismissButtonFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            // Header
            Text(title)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 40)

            // Scrollable content area with focusable sections
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .padding(.horizontal, 32)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 500)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 16)

            // Dismiss button
            Button {
                isPresented = false
            } label: {
                Text("Got it")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isDismissButtonFocused ? .white.opacity(0.25) : .white.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        isDismissButtonFocused ? .white.opacity(0.35) : .white.opacity(0.15),
                                        lineWidth: 1
                                    )
                            )
                    )
            }
            .buttonStyle(SettingsButtonStyle())
            .focused($isDismissButtonFocused)
            .scaleEffect(isDismissButtonFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDismissButtonFocused)
            .padding(.bottom, 32)
        }
        .frame(width: 650)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.black.opacity(0.3))
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        #if os(tvOS)
        .onExitCommand {
            isPresented = false
        }
        #endif
    }
}

// MARK: - Help Text Components

struct HelpSection: View {
    let title: String
    let content: String
    let id: String

    @FocusState private var isFocused: Bool

    init(title: String, content: String, id: String? = nil) {
        self.title = title
        self.content = content
        self.id = id ?? title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)

            Text(content)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? .white.opacity(0.08) : .clear)
        )
        .focusable()
        .focused($isFocused)
        .id(id)
    }
}

struct HelpFormatTable: View {
    let title: String
    let rows: [(format: String, supported: Bool)]
    let id: String

    @FocusState private var isFocused: Bool

    init(title: String, rows: [(format: String, supported: Bool)], id: String? = nil) {
        self.title = title
        self.rows = rows
        self.id = id ?? title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)

            VStack(spacing: 6) {
                ForEach(rows, id: \.format) { row in
                    HStack {
                        Text(row.format)
                            .font(.system(size: 21))
                            .foregroundStyle(.white.opacity(0.75))

                        Spacer()

                        Image(systemName: row.supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(row.supported ? .green : .red.opacity(0.7))
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? .white.opacity(0.08) : .clear)
        )
        .focusable()
        .focused($isFocused)
        .id(id)
    }
}

// MARK: - Settings Action Row (Button)

struct SettingsActionRow: View {
    let title: String
    var isDestructive: Bool = false
    let action: () -> Void
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                Text(title)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(isDestructive ? .red : .white)
                Spacer()
            }
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? (isDestructive ? .red.opacity(0.25) : .white.opacity(0.18)) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? (isDestructive ? .red.opacity(0.4) : .white.opacity(0.25)) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Settings Picker Row

struct SettingsPickerRow<T: Hashable & CustomStringConvertible>: View {
    var icon: String? = nil
    var iconColor: Color = .clear
    let title: String
    let subtitle: String
    @Binding var selection: T
    let options: [T]
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            cycleToNextOption()
        } label: {
            HStack(spacing: 20) {
                // Icon
                if let icon {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(iconColor.gradient)
                            .frame(width: 64, height: 64)

                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 23))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Spacer()

                // Current selection
                Text(selection.description)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
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
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }

    private func cycleToNextOption() {
        guard let currentIndex = options.firstIndex(of: selection) else { return }
        let nextIndex = (currentIndex + 1) % options.count
        selection = options[nextIndex]
    }
}

// MARK: - Settings List Picker Row (Popup Selection)

struct SettingsListPickerRow<T: Hashable & CustomStringConvertible>: View {
    var icon: String? = nil
    var iconColor: Color = .clear
    let title: String
    let subtitle: String
    @Binding var selection: T
    let options: [T]
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 20) {
                // Icon
                if let icon {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(iconColor.gradient)
                            .frame(width: 64, height: 64)

                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 23))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                Spacer()

                // Current selection with chevron
                HStack(spacing: 12) {
                    Text(selection.description)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isFocused ? .white.opacity(0.8) : .white.opacity(0.4))
                }
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
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .sheet(isPresented: $showPicker) {
            ListPickerSheet(
                title: title,
                selection: $selection,
                options: options,
                isPresented: $showPicker
            )
        }
    }
}

// MARK: - List Picker Sheet

struct ListPickerSheet<T: Hashable & CustomStringConvertible>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    @Binding var isPresented: Bool

    @FocusState private var focusedOption: T?

    var body: some View {
        VStack(spacing: 24) {
            // Header
            Text(title)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 40)

            // Options list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        ListPickerOptionRow(
                            option: option,
                            isSelected: selection == option,
                            isFocused: focusedOption == option,
                            onSelect: {
                                selection = option
                                isPresented = false
                            }
                        )
                        .focused($focusedOption, equals: option)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 600)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 40)
        .frame(width: 500)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.black.opacity(0.3))
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onAppear {
            // Focus the currently selected option
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedOption = selection
            }
        }
        #if os(tvOS)
        .onExitCommand {
            isPresented = false
        }
        #endif
    }
}

// MARK: - List Picker Option Row

struct ListPickerOptionRow<T: CustomStringConvertible>: View {
    let option: T
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Text(option.description)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Connect Button

struct ConnectButton: View {
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "link")
                .font(.system(size: 26, weight: .semibold))
            Text("Connect to Plex")
                .font(.system(size: 28, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? Color.blue : Color.blue.opacity(0.85))
        )
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(color: .blue.opacity(isFocused ? 0.4 : 0), radius: 12, y: 4)
        .focusable()
        .focused($isFocused)
        .onTapGesture {
            action()
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Settings Text Entry Row

/// A row that displays a title and current value, tapping opens a text entry sheet
struct SettingsTextEntryRow: View {
    var icon: String? = nil
    var iconColor: Color = .clear
    let title: String
    @Binding var value: String
    var placeholder: String = ""
    var hint: String? = nil
    var suggestions: [TextEntrySuggestion] = []
    var keyboardType: UIKeyboardType = .default
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool
    @State private var showEntrySheet = false

    var body: some View {
        Button {
            showEntrySheet = true
        } label: {
            HStack(spacing: 20) {
                // Icon
                if let icon {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(iconColor.gradient)
                            .frame(width: 64, height: 64)

                        Image(systemName: icon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(.white)

                    // Show value or placeholder
                    if value.isEmpty {
                        Text(placeholder.isEmpty ? "Not set" : placeholder)
                            .font(.system(size: 23))
                            .foregroundStyle(.white.opacity(0.35))
                    } else {
                        Text(value)
                            .font(.system(size: 23))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .white.opacity(0.8) : .white.opacity(0.4))
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
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .fullScreenCover(isPresented: $showEntrySheet) {
            TextEntrySheet(
                title: title,
                text: $value,
                placeholder: placeholder,
                hint: hint,
                suggestions: suggestions,
                keyboardType: keyboardType,
                isPresented: $showEntrySheet
            )
        }
    }
}

// MARK: - Text Entry Suggestion

/// A suggestion option for text entry (label + value)
struct TextEntrySuggestion: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }
}

// MARK: - Text Entry Sheet

/// A dedicated sheet for text entry with title, text field, hint, and action buttons
struct TextEntrySheet: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var hint: String? = nil
    var suggestions: [TextEntrySuggestion] = []
    var keyboardType: UIKeyboardType = .default
    @Binding var isPresented: Bool

    @State private var editingText: String = ""
    @FocusState private var isTextFieldFocused: Bool
    @FocusState private var focusedButton: ButtonType?
    @FocusState private var focusedSuggestion: UUID?

    enum ButtonType: Hashable {
        case cancel, done
    }

    var body: some View {
        ZStack {
            // Solid black background - no transparency to avoid blur effects
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Suggestions (if any)
                if !suggestions.isEmpty {
                    VStack(spacing: 12) {
                        Text("Quick Select")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(suggestions) { suggestion in
                                    SuggestionChip(
                                        label: suggestion.label,
                                        isFocused: focusedSuggestion == suggestion.id
                                    ) {
                                        editingText = suggestion.value
                                    }
                                    .focused($focusedSuggestion, equals: suggestion.id)
                                }
                            }
                            .padding(.horizontal, 80)
                        }
                    }
                    .padding(.top, 40)
                    #if os(tvOS)
                    .onMoveCommand { direction in
                        if direction == .down {
                            // Move focus from any suggestion to the text field
                            focusedSuggestion = nil
                            isTextFieldFocused = true
                        }
                    }
                    #endif
                }

                Spacer()

                // Title
                Text(title)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)

                // Text field container
                VStack(spacing: 16) {
                    ZStack(alignment: .leading) {
                        // Placeholder
                        if editingText.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 24)
                        }

                        TextField("", text: $editingText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 20)
                            .focused($isTextFieldFocused)
                            .autocorrectionDisabled()
                            .keyboardType(keyboardType)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            // Solid dark background for better text readability
                            .fill(Color(white: isTextFieldFocused ? 0.18 : 0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(
                                        isTextFieldFocused ? .blue.opacity(0.7) : .white.opacity(0.2),
                                        lineWidth: isTextFieldFocused ? 3 : 1
                                    )
                            )
                    )
                    .scaleEffect(isTextFieldFocused ? 1.01 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTextFieldFocused)

                    // Hint
                    if let hint = hint {
                        Text(hint)
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 700)

                Spacer()

                // Buttons
                HStack(spacing: 24) {
                    // Cancel button
                    Button {
                        isPresented = false
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 180)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(focusedButton == .cancel ? .white.opacity(0.25) : .white.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(
                                                focusedButton == .cancel ? .white.opacity(0.35) : .white.opacity(0.15),
                                                lineWidth: 1
                                            )
                                    )
                            )
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .focused($focusedButton, equals: .cancel)
                    .scaleEffect(focusedButton == .cancel ? 1.05 : 1.0)

                    // Done button
                    Button {
                        text = editingText
                        isPresented = false
                    } label: {
                        Text("Done")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 180)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(focusedButton == .done ? .blue : .blue.opacity(0.85))
                            )
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .focused($focusedButton, equals: .done)
                    .scaleEffect(focusedButton == .done ? 1.05 : 1.0)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedButton)
                .padding(.bottom, 60)
            }
            .padding(.horizontal, 80)
        }
        // Use system appearance
        .onAppear {
            editingText = text
            // Focus the first suggestion if available, otherwise the text field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let first = suggestions.first {
                    focusedSuggestion = first.id
                } else {
                    isTextFieldFocused = true
                }
            }
        }
        #if os(tvOS)
        .onExitCommand {
            isPresented = false
        }
        #endif
    }
}

// MARK: - Settings Back Row

/// A back-navigation row for sub-pages (chevron.left + title)
struct SettingsBackRow: View {
    let title: String
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFocused ? .white.opacity(0.8) : .white.opacity(0.4))

                Text(title)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()
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
        }
        .buttonStyle(SettingsButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Suggestion Chip

/// A small tappable chip for quick-select suggestions
private struct SuggestionChip: View {
    let label: String
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isFocused ? .blue : Color(white: 0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    isFocused ? .blue.opacity(0.8) : .white.opacity(0.15),
                                    lineWidth: 1
                                )
                        )
                )
                .scaleEffect(isFocused ? 1.05 : 1.0)
        }
        .buttonStyle(SettingsButtonStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}
