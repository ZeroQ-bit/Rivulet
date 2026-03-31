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
                "Play something on \(.applicationName)",
                "Watch something on \(.applicationName)"
            ],
            shortTitle: "Play Media",
            systemImageName: "play.fill"
        )
    }
}
