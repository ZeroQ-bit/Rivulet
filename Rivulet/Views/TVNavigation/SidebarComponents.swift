//
//  SidebarComponents.swift
//  Rivulet
//
//  Reusable UI components for the tvOS sidebar
//

import SwiftUI

#if os(tvOS)

// MARK: - Marquee Text (scrolls when truncated and focused)

struct MarqueeText: View {
    let text: String
    let font: Font
    let isFocused: Bool

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isAnimating = false

    /// How much the text overflows the container
    private var overflow: CGFloat {
        max(0, textWidth - containerWidth)
    }

    /// Whether the text needs to scroll
    private var needsScroll: Bool {
        overflow > 0
    }

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { textGeo in
                        Color.clear
                            .onAppear {
                                textWidth = textGeo.size.width
                            }
                            .onChange(of: text) { _, _ in
                                textWidth = textGeo.size.width
                            }
                    }
                )
                .offset(x: offset)
                .onAppear {
                    containerWidth = geo.size.width
                }
                .onChange(of: geo.size.width) { _, newWidth in
                    containerWidth = newWidth
                }
        }
        .clipped()
        .onChange(of: isFocused) { _, focused in
            if focused && needsScroll {
                startScrolling()
            } else {
                stopScrolling()
            }
        }
        .onChange(of: overflow) { _, _ in
            if isFocused && needsScroll && !isAnimating {
                startScrolling()
            }
        }
    }

    private func startScrolling() {
        guard !isAnimating else { return }
        isAnimating = true

        // Initial pause before scrolling
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard isFocused else {
                isAnimating = false
                return
            }
            scrollLeft()
        }
    }

    private func scrollLeft() {
        guard isFocused else {
            stopScrolling()
            return
        }

        // Scroll to show the end of the text
        withAnimation(.linear(duration: Double(overflow) / 40)) {
            offset = -overflow
        }

        // Pause at end, then scroll back
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(overflow) / 40 + 1.5) {
            guard isFocused else {
                stopScrolling()
                return
            }
            scrollRight()
        }
    }

    private func scrollRight() {
        guard isFocused else {
            stopScrolling()
            return
        }

        // Scroll back to start
        withAnimation(.linear(duration: Double(overflow) / 40)) {
            offset = 0
        }

        // Pause at start, then repeat
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(overflow) / 40 + 1.5) {
            guard isFocused else {
                stopScrolling()
                return
            }
            scrollLeft()
        }
    }

    private func stopScrolling() {
        isAnimating = false
        withAnimation(.easeOut(duration: 0.2)) {
            offset = 0
        }
    }
}

// MARK: - Focusable Sidebar Row

struct FocusableSidebarRow: View {
    let id: String
    let icon: String
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    var fontScale: CGFloat = 1.0

    @FocusState.Binding var focusedItem: String?

    // Base sizes (larger default to match poster cards)
    private let baseIconSize: CGFloat = 26
    private let baseTitleSize: CGFloat = 26
    private let baseIconWidth: CGFloat = 30
    private let baseSpacing: CGFloat = 16
    private let baseVerticalPadding: CGFloat = 15
    private let baseIndicatorSize: CGFloat = 7

    private var isFocused: Bool {
        focusedItem == id
    }

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: baseSpacing * fontScale) {
                Image(systemName: icon)
                    .font(.system(size: baseIconSize * fontScale, weight: .medium))
                    .frame(width: baseIconWidth * fontScale)

                MarqueeText(
                    text: title,
                    font: .system(size: baseTitleSize * fontScale, weight: isSelected ? .semibold : .regular),
                    isFocused: isFocused
                )
                .frame(height: baseTitleSize * fontScale * 1.2)  // Approximate line height

                Spacer(minLength: 4)

                if isSelected {
                    Circle()
                        .fill(.white)
                        .frame(width: baseIndicatorSize * fontScale, height: baseIndicatorSize * fontScale)
                }
            }
            .foregroundStyle(.white.opacity(isFocused || isSelected ? 1.0 : 0.6))
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, baseVerticalPadding * fontScale)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.15) : .clear)
            )
            .padding(.horizontal, 16)
        }
        .buttonStyle(SidebarRowButtonStyle())
        .focused($focusedItem, equals: id)
        .onMoveCommand { direction in
            // Right arrow acts as select (navigates and closes sidebar)
            if direction == .right {
                onSelect()
            }
        }
    }
}

/// Button style for sidebar rows - removes default focus ring
struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Sidebar Row (non-focusable, legacy)

struct SidebarRow: View {
    let icon: String
    let title: String
    let isHighlighted: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 26)

            Text(title)
                .font(.system(size: 21, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 4)

            if isSelected {
                Circle()
                    .fill(.white)
                    .frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(.white.opacity(isHighlighted || isSelected ? 1.0 : 0.6))
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHighlighted ? .white.opacity(0.15) : .clear)
        )
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.15), value: isHighlighted)
    }
}

// MARK: - Sidebar Button (focusable, legacy component)

struct SidebarButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    var onFocusChange: ((Bool) -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 24)

            Text(title)
                .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 4)

            if isSelected {
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
            }
        }
        .foregroundStyle(.white.opacity(isFocused || isSelected ? 1.0 : 0.7))
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .glassEffect(
            isFocused ? .regular.tint(.white.opacity(0.15)) : .identity,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.horizontal, 16)
        .focusable()
        .focused($isFocused)
        .onChange(of: isFocused) { _, newValue in
            // Navigate immediately when focus is gained
            // This happens instantly with cached data
            if newValue {
                onFocusChange?(newValue)
            }
        }
        .onTapGesture {
            // Tap just closes sidebar - navigation already happened on focus
            action()
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Left Edge Trigger (opens sidebar when focus reaches left edge)

struct LeftEdgeTrigger: View {
    let action: () -> Void
    var isDisabled: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            action()
        } label: {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 32)
                .frame(maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .focusable(!isDisabled)  // Prevent focus when disabled
        .focused($isFocused)
        .onChange(of: isFocused) { _, newValue in
            if newValue && !isDisabled {
                action()
            }
        }
    }
}

// MARK: - Sidebar Container Button Style (no focus highlight)

struct SidebarContainerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
        // No visual changes on focus or press - we handle highlighting manually via SidebarRow
    }
}

// MARK: - Conditional Exit Command Modifier

/// Conditionally attaches onExitCommand only when sidebar is visible
struct SidebarExitCommand: ViewModifier {
    let isSidebarVisible: Bool
    let closeAction: () -> Void

    func body(content: Content) -> some View {
        if isSidebarVisible {
            content.onExitCommand(perform: closeAction)
        } else {
            content
        }
    }
}

extension View {
    func ifSidebarVisible(_ isVisible: Bool, close: @escaping () -> Void) -> some View {
        self.modifier(SidebarExitCommand(isSidebarVisible: isVisible, closeAction: close))
    }
}

#endif
