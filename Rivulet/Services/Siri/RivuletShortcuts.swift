//
//  RivuletShortcuts.swift
//  Rivulet
//
//  Registers Siri voice phrases so intents work without prior user setup.
//

import AppIntents

struct RivuletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMediaIntent(),
            phrases: [
                "Play \(\.$media) on \(.applicationName)",
                "Watch \(\.$media) on \(.applicationName)",
                "Play \(\.$media) in \(.applicationName)"
            ],
            shortTitle: "Play Media",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SearchMediaIntent(),
            phrases: [
                "Search \(.applicationName) for \(\.$query)",
                "Find \(\.$query) on \(.applicationName)",
                "Look up \(\.$query) on \(.applicationName)"
            ],
            shortTitle: "Search Media",
            systemImageName: "magnifyingglass"
        )
    }
}
