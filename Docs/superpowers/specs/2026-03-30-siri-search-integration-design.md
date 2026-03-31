# Siri Search Integration — Design Spec

**Date:** 2026-03-30
**Scope:** Plex content only (movies, shows, episodes). IPTV/Live TV excluded.
**Platform:** tvOS 26+

## Overview

Add Siri voice search and playback to Rivulet via App Intents, plus automatic Siri Suggestions via NSUserActivity. Three capabilities:

1. **"Play X on Rivulet"** — searches Plex library, disambiguates if needed, starts playback
2. **"Search Rivulet for X"** — queries Plex library, shows rich results in Siri UI, tap to open detail view
3. **Siri Suggestions** — recently watched/browsed content surfaces automatically in system search

## Architecture: Shared AppEntity

All three features share a single `MediaItemEntity` (conforming to `AppEntity`) that wraps `PlexMetadata` for the system. This entity is used for disambiguation in PlayMediaIntent, result display in SearchMediaIntent, and deep link resolution from NSUserActivity.

```
┌──────────────────────────────────────────────────┐
│                    Siri / System                  │
│  "Play Inception on Rivulet"                      │
│  "Search Rivulet for Batman"                      │
│  Siri Suggestions (recently watched)              │
└────────┬──────────────────┬──────────────────┬────┘
         │                  │                  │
    PlayMediaIntent   SearchMediaIntent   NSUserActivity
         │                  │                  │
         └──────────┬───────┘                  │
                    │                          │
             MediaItemEntity                   │
             (AppEntity)                       │
                    │                          │
             MediaItemQuery                    │
             (EntityQuery)                     │
                    │                          │
         PlexNetworkManager.search()           │
         PlexNetworkManager.getMetadata()      │
                    │                          │
                    └──────────┬───────────────┘
                               │
                        DeepLinkHandler
                    rivulet://play?ratingKey=X
                    rivulet://detail?ratingKey=X
                               │
                        App Navigation
                    (playback or detail view)
```

## Component Details

### MediaItemEntity

**File:** `Rivulet/Services/Siri/MediaItemEntity.swift`

An `AppEntity` representing a Plex media item for the Siri system.

```swift
struct MediaItemEntity: AppEntity {
    var id: String              // ratingKey
    var title: String
    var subtitle: String?       // "2024 · Movie" or "S02E05 · Breaking Bad"
    var mediaType: String       // "movie", "show", "episode"
    var thumbURL: URL?          // Poster thumbnail for Siri display

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle ?? "")",
            image: thumbURL.map { .init(url: $0) }
        )
    }

    static var defaultQuery = MediaItemQuery()
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media")
}
```

**Initialization from PlexMetadata:**

A convenience initializer converts `PlexMetadata` → `MediaItemEntity`:
- `id` = `metadata.ratingKey`
- `title` = `metadata.title`
- `subtitle` = computed from type:
  - Movie: `"2024 · Movie"`
  - Episode: `"S02E05 · Breaking Bad"` (using `parentIndex`, `index`, `grandparentTitle`)
  - Show: `"2024 · TV Show"`
- `mediaType` = `metadata.type`
- `thumbURL` = full URL built from `serverURL + metadata.bestThumb + auth token`

### MediaItemQuery

**File:** `Rivulet/Services/Siri/MediaItemEntity.swift` (same file)

An `EntityQuery` conforming to `EntityStringQuery` for string-based search.

Three required methods:

1. **`entities(for ids: [String])`** — Resolve ratingKeys back to entities.
   - Calls `PlexNetworkManager.shared.getMetadata(ratingKey:)` for each ID
   - Used by Siri when re-resolving a previously seen entity

2. **`entities(matching query: String)`** — String search.
   - Calls `PlexNetworkManager.shared.search(query:, size: 10)`
   - Maps results to `MediaItemEntity` array
   - Used by both PlayMediaIntent (for disambiguation) and SearchMediaIntent

3. **`suggestedEntities()`** — Returns recently watched items.
   - Fetches the Plex "Continue Watching" hub via `PlexNetworkManager.shared.getHubItems()`
   - Falls back to empty array if hub unavailable or unauthenticated
   - Provides default suggestions when Siri needs options

**Auth handling:** All methods check `PlexAuthManager.shared` for credentials. If not authenticated, return empty arrays (no crash, no error dialog from query level).

### PlayMediaIntent

**File:** `Rivulet/Services/Siri/PlayMediaIntent.swift`

```swift
struct PlayMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Media"
    static var description = IntentDescription("Play a movie or TV show on Rivulet")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Media", requestValueDialog: "What would you like to play?")
    var media: MediaItemEntity

    func perform() async throws -> some IntentResult {
        await DeepLinkHandler.shared.handlePlayback(ratingKey: media.id)
        return .result(dialog: "Playing \(media.title)")
    }
}
```

**Disambiguation flow:**
1. User says "Play Batman on Rivulet"
2. System calls `MediaItemQuery.entities(matching: "Batman")`
3. If 1 result → auto-selects, calls `perform()`
4. If 2+ results → Siri shows disambiguation list using `DisplayRepresentation` (title, subtitle, thumbnail)
5. User picks one → calls `perform()` with selected entity
6. `perform()` deep links via `DeepLinkHandler` → app opens → playback starts

**Cold launch:** `openAppWhenRun = true` ensures the app launches. `PlexAuthManager` loads credentials from Keychain/UserDefaults on init. `DeepLinkHandler` fetches full metadata and triggers playback.

### SearchMediaIntent

**File:** `Rivulet/Services/Siri/SearchMediaIntent.swift`

```swift
struct SearchMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Media"
    static var description = IntentDescription("Search for movies and TV shows on Rivulet")

    @Parameter(title: "Query")
    var query: String

    func perform() async throws -> some IntentResult & ReturnsValue<[MediaItemEntity]> {
        let authManager = PlexAuthManager.shared
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            return .result(value: [], dialog: "Please sign in to Rivulet first")
        }

        let results = try await PlexNetworkManager.shared.search(
            serverURL: serverURL,
            authToken: token,
            query: query,
            size: 10
        )

        let entities = results.map { MediaItemEntity(from: $0, serverURL: serverURL) }

        if entities.isEmpty {
            return .result(value: [], dialog: "No results found for \"\(query)\"")
        }
        return .result(
            value: entities,
            dialog: "Found \(entities.count) results for \"\(query)\""
        )
    }
}
```

Siri displays the returned entities as a list with thumbnails. Tapping a result opens the app via `rivulet://detail?ratingKey=X` to the detail view.

### RivuletShortcuts (AppShortcutsProvider)

**File:** `Rivulet/Services/Siri/RivuletShortcuts.swift`

Registers voice phrases so intents work without user configuration:

```swift
struct RivuletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMediaIntent(),
            phrases: [
                "Play \(\.$media) on \(.applicationName)",
                "Watch \(\.$media) on \(.applicationName)"
            ],
            shortTitle: "Play Media",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SearchMediaIntent(),
            phrases: [
                "Search \(.applicationName) for \(\.$query)",
                "Find \(\.$query) on \(.applicationName)"
            ],
            shortTitle: "Search Media",
            systemImageName: "magnifyingglass"
        )
    }
}
```

### NSUserActivity Integration

No new files — added to existing views.

**PlexDetailView** (on appear/item change):
```swift
let activity = NSUserActivity(activityType: "com.rivulet.viewMedia")
activity.title = metadata.title
activity.isEligibleForSearch = true
activity.isEligibleForPrediction = false  // Browsed only — lower priority
activity.userInfo = ["ratingKey": metadata.ratingKey]
activity.targetContentIdentifier = "rivulet://detail?ratingKey=\(metadata.ratingKey)"
self.userActivity = activity
```

**UniversalPlayerViewModel** (on playback start):
```swift
let activity = NSUserActivity(activityType: "com.rivulet.playMedia")
activity.title = metadata.title
activity.isEligibleForSearch = true
activity.isEligibleForPrediction = true  // Watched — surfaces in Siri Suggestions
activity.userInfo = ["ratingKey": metadata.ratingKey]
activity.targetContentIdentifier = "rivulet://play?ratingKey=\(metadata.ratingKey)"
self.userActivity = activity
```

**Activity types registered in Info.plist:**
```
NSUserActivityTypes: ["com.rivulet.viewMedia", "com.rivulet.playMedia"]
```

### DeepLinkHandler Extensions

**File:** `Rivulet/Services/DeepLinkHandler.swift` (existing, extended)

Add support for `rivulet://detail?ratingKey=X`:

- New `@Published pendingDetail: PlexMetadata?` property
- `handle(url:)` parses the `detail` host and fetches metadata via `getMetadata(ratingKey:)`
- `TVSidebarView` observes `pendingDetail` and navigates to `PlexDetailView`

Existing `rivulet://play?ratingKey=X` handling remains unchanged.

## File Structure

```
Rivulet/Services/Siri/
├── MediaItemEntity.swift       # AppEntity + MediaItemQuery
├── PlayMediaIntent.swift       # "Play X on Rivulet"
├── SearchMediaIntent.swift     # "Search Rivulet for X"
└── RivuletShortcuts.swift      # AppShortcutsProvider (voice phrases)
```

Modified existing files:
- `DeepLinkHandler.swift` — add `detail` route + `pendingDetail` property
- `PlexDetailView.swift` — emit NSUserActivity on appear
- `UniversalPlayerViewModel.swift` — emit NSUserActivity on playback
- `TVSidebarView.swift` — observe `pendingDetail` for navigation
- `Info.plist` — register NSUserActivityTypes

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Not authenticated | Intents return empty results; SearchMediaIntent shows "Please sign in to Rivulet first" dialog |
| Server unreachable | Search returns empty; dialog: "Couldn't reach your Plex server" |
| Cold launch + play | App opens → auth loads from Keychain → DeepLinkHandler fetches metadata → playback starts |
| Single search result | PlayMediaIntent auto-selects (no disambiguation) |
| Multiple results | Siri shows disambiguation list with title, subtitle, thumbnail |
| No results | Dialog: "No results found for [query]" |
| Episode ambiguity | Subtitle shows "S02E05 · Show Name" for clear disambiguation |

## Out of Scope

- IPTV / Live TV channel intents (future work)
- Offline indexing / Core Spotlight persistent index
- Shortcuts app automation beyond play/search
- Multi-server support (uses currently selected server)
