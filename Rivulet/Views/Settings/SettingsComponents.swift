//
//  SettingsComponents.swift
//  Rivulet
//
//  Reusable settings UI components for tvOS
//  Uses native tvOS Button styling for system-matching focus effects
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
    var focusTrigger: Int? = nil
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
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

                Text(title)
                    .font(.system(size: 36))

                Spacer()

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .focused($isFocused)
        .onChange(of: focusTrigger) { _, newValue in
            if newValue != nil {
                isFocused = true
            }
        }
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
    }
}

/// Button style that removes tvOS default focus ring — used by non-settings views
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

            Spacer()

            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.12))
        )
    }
}

// MARK: - Settings Toggle Row

struct SettingsToggleRow: View {
    var icon: String? = nil
    var iconColor: Color = .clear
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 20) {
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

                Text(title)
                    .font(.system(size: 32))

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(isOn ? "On" : "Off")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
        }
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
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
                    .font(.system(size: 32))
                    .foregroundStyle(isDestructive ? .red : .primary)
                Spacer()
            }
        }
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
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

                Text(title)
                    .font(.system(size: 32))

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(selection.description)
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }
        }
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
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

                Text(title)
                    .font(.system(size: 32))

                Spacer()

                HStack(spacing: 8) {
                    Text(selection.description)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
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
            Text(title)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 40)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            selection = option
                            isPresented = false
                        } label: {
                            HStack {
                                Text(option.description)

                                Spacer()

                                if selection == option {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundStyle(.green)
                                }
                            }
                        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedOption = selection
            }
        }
        .onExitCommand {
            isPresented = false
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
            Text(title)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 40)

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

            Button {
                isPresented = false
            } label: {
                Text("Got it")
                    .font(.system(size: 26, weight: .semibold))
                    .padding(.horizontal, 48)
                    .padding(.vertical, 16)
            }
            .focused($isDismissButtonFocused)
            .padding(.bottom, 32)
        }
        .frame(width: 650)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.black.opacity(0.3))
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onExitCommand {
            isPresented = false
        }
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

// MARK: - Connect Button

struct ConnectButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "link")
                    .font(.system(size: 26, weight: .semibold))
                Text("Connect to Plex")
                    .font(.system(size: 28, weight: .semibold))
            }
        }
        .tint(.blue)
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

                Text(title)
                    .font(.system(size: 32))

                Spacer()

                Text(value.isEmpty ? (placeholder.isEmpty ? "Not set" : placeholder) : value)
                    .font(.system(size: 32))
                    .foregroundStyle(value.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
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

/// Apple TV-style text entry — clean centered layout with system keyboard
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

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Text field
            VStack(spacing: 20) {
                Text(title)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))

                TextField(placeholder, text: $editingText)
                    .font(.system(size: 36))
                    .focused($isTextFieldFocused)
                    .autocorrectionDisabled()
                    .keyboardType(keyboardType)
                    .frame(maxWidth: 700)
                    .onSubmit {
                        text = editingText
                        isPresented = false
                    }

                if let hint {
                    Text(hint)
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Spacer()

            // Suggestions
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(suggestions) { suggestion in
                            Button {
                                editingText = suggestion.value
                            } label: {
                                Text(suggestion.label)
                                    .font(.system(size: 24, weight: .medium))
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
                .focusSection()
                .padding(.bottom, 24)
            }

            // Actions
            HStack(spacing: 40) {
                Button("Cancel") {
                    isPresented = false
                }

                Button("Done") {
                    text = editingText
                    isPresented = false
                }
            }
            .font(.system(size: 28, weight: .semibold))
            .padding(.bottom, 80)
        }
        .padding(.horizontal, 80)
        .background(.ultraThinMaterial)
        .onAppear {
            editingText = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTextFieldFocused = true
            }
        }
        .onExitCommand {
            isPresented = false
        }
    }
}


// MARK: - Settings Back Row

/// A back-navigation row for sub-pages (chevron.left + title)
struct SettingsBackRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(title)

                Spacer()
            }
        }
    }
}
