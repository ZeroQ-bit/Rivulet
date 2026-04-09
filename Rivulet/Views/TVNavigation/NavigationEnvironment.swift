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

/// Observable object to track nested navigation state across views.
/// `isNested` is set true while a child view has pushed a detail view;
/// the sidebar reads it to hide the tab bar and block tab switches.
@MainActor
class NestedNavigationState: ObservableObject {
    @Published var isNested: Bool = false
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

