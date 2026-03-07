//
//  NavigationEnvironment.swift
//  Rivulet
//
//  Environment keys and state objects for tvOS navigation
//

import SwiftUI
import Combine


// MARK: - Sidebar Tab

/// Tab selection type for the system TabView sidebar
enum SidebarTab: Hashable {
    case account
    case search
    case home
    case library(key: String)
    case liveTV(sourceId: String?)
    case settings
}

// MARK: - Nested Navigation State

/// Preference key for nested navigation state (bubbles up from child views)
struct IsInNestedNavigationKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()  // True if any child is in nested nav
    }
}

/// Observable object to track nested navigation state across views
@MainActor
class NestedNavigationState: ObservableObject {
    @Published var isNested: Bool = false

    /// Global flag readable from the sidebar focus guard swizzle (non-isolated)
    nonisolated(unsafe) static var isCurrentlyNested: Bool = false

    /// Action to go back from nested navigation (set by child views)
    var goBackAction: (() -> Void)?

    func goBack() {
        goBackAction?()
    }
}

/// Environment key for nested navigation state
private struct NestedNavigationStateKey: EnvironmentKey {
    static let defaultValue: NestedNavigationState = NestedNavigationState()
}

extension EnvironmentValues {
    var nestedNavigationState: NestedNavigationState {
        get { self[NestedNavigationStateKey.self] }
        set { self[NestedNavigationStateKey.self] = newValue }
    }
}

