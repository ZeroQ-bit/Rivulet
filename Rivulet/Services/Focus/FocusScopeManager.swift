//
//  FocusScopeManager.swift
//  Rivulet
//
//  Manages focus scopes for tvOS to provide precise control over focus navigation.
//  Solves SwiftUI's limitations with spatial focus navigation in overlays.
//

import SwiftUI
import Combine

// MARK: - Focus Scope

/// Defines an isolated focus context. Views in inactive scopes cannot receive focus.
/// Extensible via static properties - add new scopes as needed.
struct FocusScope: Hashable, Equatable, CustomStringConvertible {
    let rawValue: String

    var description: String { rawValue }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: - Standard Scopes

    /// Main content area (home, library, search results)
    static let content = FocusScope("content")

    /// Sidebar navigation menu
    static let sidebar = FocusScope("sidebar")

    /// Video player controls
    static let player = FocusScope("player")

    /// Player info bar overlay
    static let playerInfoBar = FocusScope("player.infoBar")

    /// Modal dialogs and sheets
    static let modal = FocusScope("modal")

    /// Settings screens
    static let settings = FocusScope("settings")

    /// Detail view (show/movie details)
    static let detail = FocusScope("detail")

    /// Channel picker in live TV
    static let channelPicker = FocusScope("channelPicker")

    /// TV Guide layout
    static let guide = FocusScope("guide")

    /// Post-video summary overlay
    static let postVideo = FocusScope("postVideo")
}

// MARK: - Focus Item Identifier

/// Uniquely identifies a focusable item within its scope and context.
/// Using context prevents focus jumping between items with the same ID in different rows.
struct FocusItemId: Hashable, Equatable, CustomStringConvertible {
    /// The scope this item belongs to
    let scope: FocusScope

    /// Additional context (e.g., row title, section name) to disambiguate items
    let context: String?

    /// The item's identifier (e.g., ratingKey, button name)
    let itemId: String

    /// Unique string identifier combining all components
    var uniqueId: String {
        if let context {
            return "\(scope.rawValue):\(context):\(itemId)"
        }
        return "\(scope.rawValue):\(itemId)"
    }

    var description: String { uniqueId }

    init(scope: FocusScope, context: String? = nil, itemId: String) {
        self.scope = scope
        self.context = context
        self.itemId = itemId
    }

    /// Convenience initializer for content scope items
    static func content(_ itemId: String, context: String? = nil) -> FocusItemId {
        FocusItemId(scope: .content, context: context, itemId: itemId)
    }

    /// Convenience initializer for sidebar items
    static func sidebar(_ itemId: String) -> FocusItemId {
        FocusItemId(scope: .sidebar, context: nil, itemId: itemId)
    }

    /// Convenience initializer for player items
    static func player(_ itemId: String) -> FocusItemId {
        FocusItemId(scope: .player, context: nil, itemId: itemId)
    }
}

// MARK: - Focus Scope Manager

/// Central manager for focus scope control on tvOS.
/// Provides scope isolation, focus saving/restoration, and programmatic focus control.
@MainActor
class FocusScopeManager: ObservableObject {

    // MARK: - Published State

    /// The currently active scope - only views in this scope can receive focus
    @Published private(set) var activeScope: FocusScope = .content

    /// The currently focused item (if tracked)
    @Published private(set) var focusedItem: FocusItemId?

    /// Trigger that increments when focus should be restored (observed by views)
    @Published private(set) var restoreTrigger: Int = 0

    // MARK: - Internal State

    /// Stack of scopes for nested navigation (e.g., content -> player -> infoBar)
    private var scopeStack: [FocusScope] = [.content]

    /// Saved focus positions per scope
    private var savedFocus: [FocusScope: FocusItemId] = [:]

    /// Focus history for back navigation within a scope
    private var focusHistory: [FocusScope: [FocusItemId]] = [:]

    /// Maximum history size per scope
    private let maxHistorySize = 10

    /// Throttle history updates during rapid scrolling
    private var lastHistoryUpdate: Date = .distantPast
    private let historyThrottleInterval: TimeInterval = 0.3  // Only update history every 300ms

    // MARK: - Scope Activation

    /// Activate a new scope, optionally saving the current focus position.
    /// - Parameters:
    ///   - scope: The scope to activate
    ///   - savingCurrent: Whether to save the current focus position for restoration
    ///   - pushToStack: Whether to push this scope onto the stack (for nested navigation)
    func activate(_ scope: FocusScope, savingCurrent: Bool = true, pushToStack: Bool = true) {
        #if DEBUG
        #endif

        // Save current focus if requested
        if savingCurrent, let currentFocus = focusedItem {
            savedFocus[activeScope] = currentFocus
        }

        // Push to stack if this is nested navigation
        if pushToStack && scope != activeScope {
            scopeStack.append(scope)
        }

        // Activate the new scope
        activeScope = scope

        // Restore saved focus for this scope if available
        if let saved = savedFocus[scope] {
            focusedItem = saved
            restoreTrigger += 1
        } else {
            focusedItem = nil
        }
    }

    /// Deactivate the current scope and return to the previous one.
    /// Restores focus to the saved position in the previous scope.
    func deactivate() {
        guard scopeStack.count > 1 else {
            return
        }

        // Save current focus before leaving
        if let currentFocus = focusedItem {
            savedFocus[activeScope] = currentFocus
        }

        // Pop current scope
        scopeStack.removeLast()

        // Activate previous scope
        let previousScope = scopeStack.last ?? .content
        activeScope = previousScope

        // Restore focus for previous scope
        if let saved = savedFocus[previousScope] {
            focusedItem = saved
            restoreTrigger += 1
        }
    }

    /// Switch to a scope without pushing to stack (replaces current scope).
    /// Use for lateral navigation (e.g., switching between libraries).
    func switchTo(_ scope: FocusScope, savingCurrent: Bool = true) {
        activate(scope, savingCurrent: savingCurrent, pushToStack: false)
    }

    // MARK: - Focus Control

    /// Set the currently focused item.
    /// Called by views when they receive focus.
    /// Optimized for rapid focus changes during scrolling - skips expensive operations.
    func setFocus(_ item: FocusItemId) {
        guard item.scope == activeScope else {
            #if DEBUG
            print("🎯 [FOCUS] ⚠️ Rejecting focus for \(item) - scope \(item.scope) is not active (active: \(activeScope))")
            #endif
            return
        }

        // Skip if already focused on this item (avoid unnecessary work)
        guard focusedItem != item else { return }

        // Add to history if different from current, but throttled during rapid scrolling
        // History is for back-navigation, not needed for every intermediate focus during fast scrolling
        let now = Date()
        if let current = focusedItem, now.timeIntervalSince(lastHistoryUpdate) >= historyThrottleInterval {
            addToHistory(current)
            lastHistoryUpdate = now
        }

        focusedItem = item
    }

    /// Set focus using individual components.
    func setFocus(itemId: String, context: String? = nil, scope: FocusScope? = nil) {
        let item = FocusItemId(scope: scope ?? activeScope, context: context, itemId: itemId)
        setFocus(item)
    }

    /// Clear the current focus (e.g., when leaving a scope).
    func clearFocus() {
        if let current = focusedItem {
            addToHistory(current)
        }
        focusedItem = nil
    }

    /// Request focus restoration (triggers views to restore their saved focus).
    func requestFocusRestore() {
        restoreTrigger += 1
    }

    // MARK: - Focus History

    /// Go back to the previous focus position within the current scope.
    /// Returns true if there was a previous position to restore.
    @discardableResult
    func focusBack() -> Bool {
        guard let history = focusHistory[activeScope], !history.isEmpty else {
            return false
        }

        var mutableHistory = history
        let previous = mutableHistory.removeLast()
        focusHistory[activeScope] = mutableHistory

        focusedItem = previous
        restoreTrigger += 1
        return true
    }

    private func addToHistory(_ item: FocusItemId) {
        var history = focusHistory[item.scope] ?? []

        // Remove if already in history (will re-add at end)
        history.removeAll { $0 == item }

        // Add to end
        history.append(item)

        // Trim if too large
        if history.count > maxHistorySize {
            history.removeFirst(history.count - maxHistorySize)
        }

        focusHistory[item.scope] = history
    }

    // MARK: - Scope Queries

    /// Check if a scope is currently active.
    func isScopeActive(_ scope: FocusScope) -> Bool {
        return activeScope == scope
    }

    /// Check if a scope is in the current stack (active or a parent).
    func isScopeInStack(_ scope: FocusScope) -> Bool {
        return scopeStack.contains(scope)
    }

    /// Get the saved focus for a scope (if any).
    func getSavedFocus(for scope: FocusScope) -> FocusItemId? {
        return savedFocus[scope]
    }

    /// Get the current scope stack depth.
    var scopeDepth: Int {
        return scopeStack.count
    }

    /// Get the parent scope (if any).
    var parentScope: FocusScope? {
        guard scopeStack.count > 1 else { return nil }
        return scopeStack[scopeStack.count - 2]
    }

    // MARK: - Focus Queries

    /// Check if a specific item is currently focused.
    func isFocused(_ itemId: String, context: String? = nil, scope: FocusScope? = nil) -> Bool {
        guard let current = focusedItem else { return false }
        let targetScope = scope ?? activeScope
        return current.scope == targetScope &&
               current.context == context &&
               current.itemId == itemId
    }

    /// Check if a FocusItemId is currently focused.
    func isFocused(_ item: FocusItemId) -> Bool {
        focusedItem == item
    }

    // MARK: - Debug

    /// Print current focus state for debugging.
    func debugPrint() {
    }
}

// MARK: - Environment Key

private struct FocusScopeManagerKey: EnvironmentKey {
    static let defaultValue: FocusScopeManager = FocusScopeManager()
}

extension EnvironmentValues {
    var focusScopeManager: FocusScopeManager {
        get { self[FocusScopeManagerKey.self] }
        set { self[FocusScopeManagerKey.self] = newValue }
    }
}

// MARK: - View Modifiers

#if os(tvOS)

/// Modifier that makes a view focusable only when its scope is active.
struct ScopedFocusModifier: ViewModifier {
    let scope: FocusScope
    let context: String?
    let itemId: String

    @Environment(\.focusScopeManager) private var focusManager
    @FocusState private var isFocused: Bool

    private var focusItemId: FocusItemId {
        FocusItemId(scope: scope, context: context, itemId: itemId)
    }

    private var shouldBeFocused: Bool {
        focusManager.focusedItem == focusItemId
    }

    func body(content: Content) -> some View {
        content
            .focusable(focusManager.isScopeActive(scope))
            .focused($isFocused)
            .onChange(of: isFocused) { _, newValue in
                if newValue {
                    focusManager.setFocus(focusItemId)
                }
            }
            .onChange(of: focusManager.restoreTrigger) { _, _ in
                // Restore focus if this is the saved item
                if focusManager.focusedItem == focusItemId {
                    isFocused = true
                }
            }
    }
}

/// Modifier for Button that integrates with focus scope system.
struct ScopedButtonModifier: ViewModifier {
    let scope: FocusScope
    let context: String?
    let itemId: String

    @Environment(\.focusScopeManager) private var focusManager

    private var focusItemId: FocusItemId {
        FocusItemId(scope: scope, context: context, itemId: itemId)
    }

    func body(content: Content) -> some View {
        content
            .disabled(!focusManager.isScopeActive(scope))
            .onChange(of: focusManager.restoreTrigger) { _, _ in
                // Views handle their own restoration via @FocusState bindings
            }
    }
}

/// Modifier that disables a view hierarchy when its scope is not active.
struct ScopeDisabledModifier: ViewModifier {
    let scope: FocusScope

    @Environment(\.focusScopeManager) private var focusManager

    func body(content: Content) -> some View {
        content
            .disabled(!focusManager.isScopeActive(scope))
    }
}

extension View {
    /// Make this view focusable only when the specified scope is active.
    /// - Parameters:
    ///   - scope: The scope this item belongs to
    ///   - context: Additional context to disambiguate items (e.g., row title)
    ///   - itemId: The item's identifier
    func focusableInScope(_ scope: FocusScope, context: String? = nil, itemId: String) -> some View {
        self.modifier(ScopedFocusModifier(scope: scope, context: context, itemId: itemId))
    }

    /// Apply scope-aware behavior to a Button.
    func scopedButton(_ scope: FocusScope, context: String? = nil, itemId: String) -> some View {
        self.modifier(ScopedButtonModifier(scope: scope, context: context, itemId: itemId))
    }

    /// Disable this view hierarchy when the scope is not active.
    func disabledOutsideScope(_ scope: FocusScope) -> some View {
        self.modifier(ScopeDisabledModifier(scope: scope))
    }
}

#endif
