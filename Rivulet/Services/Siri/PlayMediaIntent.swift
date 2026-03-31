//
//  PlayMediaIntent.swift
//  Rivulet
//
//  App Intent for "Play X on Rivulet" Siri commands.
//  Uses MediaItemEntity for disambiguation when multiple matches are found.
//

import AppIntents
import Foundation

struct PlayMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Media"
    static var description = IntentDescription("Play a movie or TV show on Rivulet")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Media", requestValueDialog: "What would you like to play?")
    var media: MediaItemEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        DeepLinkHandler.shared.handlePlay(ratingKey: media.id)
        return .result(dialog: "Playing \(media.title)")
    }
}
