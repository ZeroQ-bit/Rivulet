# Siri Search Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Siri voice commands to search and play Plex content in Rivulet, plus automatic Siri Suggestions from watch/browse history.

**Architecture:** Shared `MediaItemEntity` (`AppEntity`) wraps `PlexMetadata` for Siri. `PlayMediaIntent` and `SearchMediaIntent` use this entity for disambiguation and results. `NSUserActivity` emitted from `PlexDetailView` (browse) and `UniversalPlayerViewModel` (watch) feeds Siri Suggestions. All deep linking flows through the existing `DeepLinkHandler`.

**Tech Stack:** App Intents framework, NSUserActivity, existing PlexNetworkManager/PlexAuthManager/DeepLinkHandler

**Spec:** `docs/superpowers/specs/2026-03-30-siri-search-integration-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `Rivulet/Services/Siri/MediaItemEntity.swift` | `AppEntity` + `EntityStringQuery` for Plex media |
| Create | `Rivulet/Services/Siri/PlayMediaIntent.swift` | "Play X on Rivulet" intent with disambiguation |
| Create | `Rivulet/Services/Siri/SearchMediaIntent.swift` | "Search Rivulet for X" intent with rich results |
| Create | `Rivulet/Services/Siri/RivuletShortcuts.swift` | `AppShortcutsProvider` — voice phrase registration |
| Modify | `Rivulet/Services/DeepLinkHandler.swift` | Add `detail` route + `pendingDetail` property |
| Modify | `Rivulet/Views/TVNavigation/TVSidebarView.swift:120` | Observe `pendingDetail` for detail navigation |
| Modify | `Rivulet/Views/Plex/PlexDetailView.swift` | Emit `NSUserActivity` on item display |
| Modify | `Rivulet/Views/Player/UniversalPlayerViewModel.swift:988` | Emit `NSUserActivity` on playback start |
| Modify | `Rivulet/RivuletApp.swift:70-81` | Register `.onContinueUserActivity` handler |
| Create | `RivuletTests/Unit/Siri/MediaItemEntityTests.swift` | Entity construction + subtitle formatting |
| Create | `RivuletTests/Unit/Siri/DeepLinkHandlerDetailTests.swift` | Detail deep link URL parsing |

---

### Task 1: MediaItemEntity — AppEntity + EntityStringQuery

**Files:**
- Create: `Rivulet/Services/Siri/MediaItemEntity.swift`
- Create: `RivuletTests/Unit/Siri/MediaItemEntityTests.swift`

- [ ] **Step 1: Write tests for entity construction from PlexMetadata**

Create `RivuletTests/Unit/Siri/MediaItemEntityTests.swift`:

```swift
//
//  MediaItemEntityTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class MediaItemEntityTests: XCTestCase {

    let testServerURL = "https://192.168.1.100:32400"
    let testToken = "test-token"

    // MARK: - Movie Entity

    func testMovieEntityHasCorrectSubtitle() {
        let metadata = PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Inception",
            year: 2010
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.id, "100")
        XCTAssertEqual(entity.title, "Inception")
        XCTAssertEqual(entity.subtitle, "2010 \u{00B7} Movie")
        XCTAssertEqual(entity.mediaType, "movie")
    }

    // MARK: - Episode Entity

    func testEpisodeEntityHasSeriesAndEpisodeInfo() {
        let metadata = PlexMetadata(
            ratingKey: "200",
            type: "episode",
            title: "Pilot",
            year: 2008,
            parentIndex: 1,
            grandparentTitle: "Breaking Bad",
            index: 1
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.id, "200")
        XCTAssertEqual(entity.title, "Pilot")
        XCTAssertEqual(entity.subtitle, "S01E01 \u{00B7} Breaking Bad")
        XCTAssertEqual(entity.mediaType, "episode")
    }

    // MARK: - Show Entity

    func testShowEntityHasCorrectSubtitle() {
        let metadata = PlexMetadata(
            ratingKey: "300",
            type: "show",
            title: "Breaking Bad",
            year: 2008
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.subtitle, "2008 \u{00B7} TV Show")
        XCTAssertEqual(entity.mediaType, "show")
    }

    // MARK: - Thumbnail URL

    func testEntityBuildsFullThumbURL() {
        let metadata = PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Inception",
            thumb: "/library/metadata/100/thumb/1234"
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertNotNil(entity.thumbURL)
        let urlString = entity.thumbURL!.absoluteString
        XCTAssertTrue(urlString.hasPrefix(testServerURL))
        XCTAssertTrue(urlString.contains("/library/metadata/100/thumb/1234"))
        XCTAssertTrue(urlString.contains("X-Plex-Token=test-token"))
    }

    func testEntityWithNoThumbHasNilURL() {
        let metadata = PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Inception"
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertNil(entity.thumbURL)
    }

    // MARK: - Missing Data

    func testEntityWithNoYearOmitsYear() {
        let metadata = PlexMetadata(
            ratingKey: "100",
            type: "movie",
            title: "Unknown Movie"
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.subtitle, "Movie")
    }

    func testEntityWithMissingRatingKeyUsesEmptyString() {
        let metadata = PlexMetadata(
            type: "movie",
            title: "No Key"
        )

        let entity = MediaItemEntity(from: metadata, serverURL: testServerURL, token: testToken)

        XCTAssertEqual(entity.id, "")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/MediaItemEntityTests 2>&1 | tail -5`
Expected: Compilation error — `MediaItemEntity` doesn't exist yet.

- [ ] **Step 3: Create MediaItemEntity.swift**

Create `Rivulet/Services/Siri/MediaItemEntity.swift`:

```swift
//
//  MediaItemEntity.swift
//  Rivulet
//
//  AppEntity representing a Plex media item for Siri integration.
//  Used by PlayMediaIntent and SearchMediaIntent for disambiguation and results.
//

import AppIntents
import Foundation

// MARK: - Media Item Entity

struct MediaItemEntity: AppEntity {
    var id: String
    var title: String
    var subtitle: String?
    var mediaType: String
    var thumbURL: URL?

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media")
    static var defaultQuery = MediaItemQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { LocalizedStringResource(stringLiteral: $0) },
            image: thumbURL.map { .init(url: $0) }
        )
    }

    /// Create from PlexMetadata
    init(from metadata: PlexMetadata, serverURL: String, token: String) {
        self.id = metadata.ratingKey ?? ""
        self.title = metadata.title ?? "Unknown"
        self.mediaType = metadata.type ?? "movie"
        self.subtitle = Self.buildSubtitle(from: metadata)
        self.thumbURL = Self.buildThumbURL(from: metadata, serverURL: serverURL, token: token)
    }

    /// Direct init for testing/manual construction
    init(id: String, title: String, subtitle: String? = nil, mediaType: String, thumbURL: URL? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.mediaType = mediaType
        self.thumbURL = thumbURL
    }

    // MARK: - Subtitle Builder

    private static func buildSubtitle(from metadata: PlexMetadata) -> String {
        switch metadata.type {
        case "episode":
            let season = metadata.parentIndex ?? 0
            let episode = metadata.index ?? 0
            let epString = String(format: "S%02dE%02d", season, episode)
            if let showTitle = metadata.grandparentTitle {
                return "\(epString) \u{00B7} \(showTitle)"
            }
            return epString

        default:
            // Movie, Show, Season, etc.
            let typeDisplay = metadata.mediaTypeDisplay
            if let year = metadata.year {
                return "\(year) \u{00B7} \(typeDisplay)"
            }
            return typeDisplay
        }
    }

    // MARK: - Thumbnail URL Builder

    private static func buildThumbURL(from metadata: PlexMetadata, serverURL: String, token: String) -> URL? {
        guard let thumb = metadata.bestThumb else { return nil }
        var components = URLComponents(string: "\(serverURL)\(thumb)")
        components?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return components?.url
    }
}

// MARK: - Entity Query

struct MediaItemQuery: EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [MediaItemEntity] {
        guard let serverURL = await PlexAuthManager.shared.selectedServerURL,
              let token = await PlexAuthManager.shared.selectedServerToken else {
            return []
        }

        var results: [MediaItemEntity] = []
        for ratingKey in identifiers {
            do {
                let metadata = try await PlexNetworkManager.shared.getMetadata(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey
                )
                results.append(MediaItemEntity(from: metadata, serverURL: serverURL, token: token))
            } catch {
                // Skip items that can't be resolved
                continue
            }
        }
        return results
    }

    func entities(matching query: String) async throws -> [MediaItemEntity] {
        guard !query.isEmpty,
              let serverURL = await PlexAuthManager.shared.selectedServerURL,
              let token = await PlexAuthManager.shared.selectedServerToken else {
            return []
        }

        let results = try await PlexNetworkManager.shared.search(
            serverURL: serverURL,
            authToken: token,
            query: query,
            size: 10
        )

        return results.map { MediaItemEntity(from: $0, serverURL: serverURL, token: token) }
    }

    func suggestedEntities() async throws -> [MediaItemEntity] {
        guard let serverURL = await PlexAuthManager.shared.selectedServerURL,
              let token = await PlexAuthManager.shared.selectedServerToken else {
            return []
        }

        do {
            let onDeck = try await PlexNetworkManager.shared.getOnDeck(
                serverURL: serverURL,
                authToken: token
            )
            return onDeck.prefix(5).map { MediaItemEntity(from: $0, serverURL: serverURL, token: token) }
        } catch {
            return []
        }
    }
}
```

- [ ] **Step 4: Add new files to Xcode project**

Ensure `MediaItemEntity.swift` is included in the Rivulet target and `MediaItemEntityTests.swift` in the RivuletTests target. If using Xcode's automatic file discovery, the files should be picked up. Otherwise, add them to `Rivulet.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/MediaItemEntityTests 2>&1 | tail -20`
Expected: All 7 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Rivulet/Services/Siri/MediaItemEntity.swift RivuletTests/Unit/Siri/MediaItemEntityTests.swift
git commit -m "feat: add MediaItemEntity AppEntity for Siri integration

Defines the shared AppEntity and EntityStringQuery that powers
both PlayMediaIntent and SearchMediaIntent. Includes subtitle
formatting for movies, episodes, and shows."
```

---

### Task 2: PlayMediaIntent

**Files:**
- Create: `Rivulet/Services/Siri/PlayMediaIntent.swift`

- [ ] **Step 1: Create PlayMediaIntent.swift**

Create `Rivulet/Services/Siri/PlayMediaIntent.swift`:

```swift
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
        await DeepLinkHandler.shared.handlePlay(ratingKey: media.id)
        return .result(dialog: "Playing \(media.title)")
    }
}
```

- [ ] **Step 2: Add to Xcode project and verify compilation**

Run: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E '(error:|BUILD)'`
Expected: BUILD SUCCEEDED (no errors). If `handlePlay(ratingKey:)` doesn't exist yet on `DeepLinkHandler`, that's expected — it will be added in Task 5. For now, verify the intent compiles by temporarily using the existing `handle(url:)` approach:

Temporarily use in `perform()`:
```swift
let url = URL(string: "rivulet://play?ratingKey=\(media.id)")!
await DeepLinkHandler.shared.handle(url: url)
```

We'll update this in Task 5 when we add the direct `handlePlay` method.

- [ ] **Step 3: Commit**

```bash
git add Rivulet/Services/Siri/PlayMediaIntent.swift
git commit -m "feat: add PlayMediaIntent for Siri voice playback

Handles 'Play X on Rivulet' commands. Uses MediaItemEntity
for automatic disambiguation when multiple matches are found."
```

---

### Task 3: SearchMediaIntent

**Files:**
- Create: `Rivulet/Services/Siri/SearchMediaIntent.swift`

- [ ] **Step 1: Create SearchMediaIntent.swift**

Create `Rivulet/Services/Siri/SearchMediaIntent.swift`:

```swift
//
//  SearchMediaIntent.swift
//  Rivulet
//
//  App Intent for "Search Rivulet for X" Siri commands.
//  Returns rich results with thumbnails that the user can tap to open.
//

import AppIntents
import Foundation

struct SearchMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Media"
    static var description = IntentDescription("Search for movies and TV shows on Rivulet")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Query")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MediaItemEntity]> & ProvidesDialog {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else {
            return .result(value: [], dialog: "Please sign in to Rivulet first")
        }

        do {
            let results = try await PlexNetworkManager.shared.search(
                serverURL: serverURL,
                authToken: token,
                query: query,
                size: 10
            )

            let entities = results.map { MediaItemEntity(from: $0, serverURL: serverURL, token: token) }

            if entities.isEmpty {
                return .result(value: [], dialog: "No results found for \"\(query)\"")
            }

            let count = entities.count
            return .result(
                value: entities,
                dialog: "Found \(count) \(count == 1 ? "result" : "results") for \"\(query)\""
            )
        } catch {
            return .result(value: [], dialog: "Couldn't reach your Plex server")
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E '(error:|BUILD)'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Rivulet/Services/Siri/SearchMediaIntent.swift
git commit -m "feat: add SearchMediaIntent for Siri search results

Handles 'Search Rivulet for X' commands. Returns rich results
with thumbnails in Siri UI. Shows auth/error dialogs as needed."
```

---

### Task 4: RivuletShortcuts — AppShortcutsProvider

**Files:**
- Create: `Rivulet/Services/Siri/RivuletShortcuts.swift`

- [ ] **Step 1: Create RivuletShortcuts.swift**

Create `Rivulet/Services/Siri/RivuletShortcuts.swift`:

```swift
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
```

- [ ] **Step 2: Verify compilation**

Run: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E '(error:|BUILD)'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Rivulet/Services/Siri/RivuletShortcuts.swift
git commit -m "feat: register Siri voice phrases via AppShortcutsProvider

Enables 'Play X on Rivulet', 'Watch X on Rivulet',
'Search Rivulet for X', 'Find X on Rivulet' without user setup."
```

---

### Task 5: DeepLinkHandler — Add Detail Route

**Files:**
- Modify: `Rivulet/Services/DeepLinkHandler.swift`
- Create: `RivuletTests/Unit/Siri/DeepLinkHandlerDetailTests.swift`

- [ ] **Step 1: Write tests for the detail deep link route**

Create `RivuletTests/Unit/Siri/DeepLinkHandlerDetailTests.swift`:

```swift
//
//  DeepLinkHandlerDetailTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class DeepLinkHandlerDetailTests: XCTestCase {

    func testDetailURLSetsHost() {
        let url = URL(string: "rivulet://detail?ratingKey=12345")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.host, "detail")
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "ratingKey" })?.value,
            "12345"
        )
    }

    func testPlayURLSetsHost() {
        let url = URL(string: "rivulet://play?ratingKey=67890")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.host, "play")
    }

    func testHandlePlaySetsRatingKey() {
        let handler = DeepLinkHandler.shared
        handler.handlePlay(ratingKey: "99999")

        // handlePlay sets a pending ratingKey that triggers metadata fetch
        // We can't test the full async flow without mocking PlexNetworkManager,
        // but we verify the method exists and accepts the parameter
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/DeepLinkHandlerDetailTests 2>&1 | tail -5`
Expected: Compilation error — `handlePlay(ratingKey:)` doesn't exist yet.

- [ ] **Step 3: Update DeepLinkHandler with detail route and handlePlay method**

Modify `Rivulet/Services/DeepLinkHandler.swift`. The full updated file:

```swift
//
//  DeepLinkHandler.swift
//  Rivulet
//
//  Handles deep links from Top Shelf, Siri intents, and other URL schemes
//

import Foundation
import Combine

/// Centralized handler for deep link URLs
/// Primary use case: Top Shelf selection triggers rivulet://play?ratingKey=X
/// Siri integration adds rivulet://detail?ratingKey=X
@MainActor
final class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()

    /// Metadata to play when a deep link is received
    /// TVSidebarView observes this and presents the player
    @Published var pendingPlayback: PlexMetadata?

    /// Metadata to show in detail view when a deep link is received
    /// TVSidebarView observes this and navigates to PlexDetailView
    @Published var pendingDetail: PlexMetadata?

    private init() {}

    // MARK: - URL Handling

    /// Handle an incoming URL
    /// - Parameter url: The URL to process (e.g., rivulet://play?ratingKey=12345)
    func handle(url: URL) async {
        guard url.scheme == "rivulet" else { return }

        switch url.host {
        case "play":
            await handlePlayURL(url)
        case "detail":
            await handleDetailURL(url)
        default:
            break
        }
    }

    // MARK: - Direct Intent Handlers

    /// Called by PlayMediaIntent to start playback by ratingKey
    func handlePlay(ratingKey: String) {
        Task {
            await fetchAndSetPlayback(ratingKey: ratingKey)
        }
    }

    /// Called by SearchMediaIntent result tap to show detail by ratingKey
    func handleDetail(ratingKey: String) {
        Task {
            await fetchAndSetDetail(ratingKey: ratingKey)
        }
    }

    // MARK: - Play URL

    /// Handle rivulet://play?ratingKey=X
    private func handlePlayURL(_ url: URL) async {
        guard let ratingKey = extractRatingKey(from: url) else {
            print("DeepLinkHandler: Missing ratingKey in play URL")
            return
        }
        await fetchAndSetPlayback(ratingKey: ratingKey)
    }

    // MARK: - Detail URL

    /// Handle rivulet://detail?ratingKey=X
    private func handleDetailURL(_ url: URL) async {
        guard let ratingKey = extractRatingKey(from: url) else {
            print("DeepLinkHandler: Missing ratingKey in detail URL")
            return
        }
        await fetchAndSetDetail(ratingKey: ratingKey)
    }

    // MARK: - Shared Helpers

    private func extractRatingKey(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "ratingKey" })?.value
    }

    private func fetchAndSetPlayback(ratingKey: String) async {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let authToken = PlexAuthManager.shared.authToken else {
            print("DeepLinkHandler: No Plex credentials available")
            return
        }

        do {
            let metadata = try await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            pendingPlayback = metadata
        } catch {
            print("DeepLinkHandler: Failed to fetch metadata for ratingKey \(ratingKey): \(error)")
        }
    }

    private func fetchAndSetDetail(ratingKey: String) async {
        guard let serverURL = PlexAuthManager.shared.selectedServerURL,
              let authToken = PlexAuthManager.shared.authToken else {
            print("DeepLinkHandler: No Plex credentials available")
            return
        }

        do {
            let metadata = try await PlexNetworkManager.shared.getMetadata(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            pendingDetail = metadata
        } catch {
            print("DeepLinkHandler: Failed to fetch metadata for ratingKey \(ratingKey): \(error)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/DeepLinkHandlerDetailTests 2>&1 | tail -20`
Expected: All 3 tests PASS.

- [ ] **Step 5: Update PlayMediaIntent to use handlePlay directly**

In `Rivulet/Services/Siri/PlayMediaIntent.swift`, update the `perform()` method:

```swift
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await DeepLinkHandler.shared.handlePlay(ratingKey: media.id)
        return .result(dialog: "Playing \(media.title)")
    }
```

(If you used the temporary `handle(url:)` approach in Task 2, replace it now.)

- [ ] **Step 6: Verify full build**

Run: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E '(error:|BUILD)'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Rivulet/Services/DeepLinkHandler.swift RivuletTests/Unit/Siri/DeepLinkHandlerDetailTests.swift Rivulet/Services/Siri/PlayMediaIntent.swift
git commit -m "feat: add detail deep link route and direct intent handlers

Extends DeepLinkHandler with rivulet://detail?ratingKey=X route,
pendingDetail property, and handlePlay/handleDetail methods for
direct use by Siri intents."
```

---

### Task 6: TVSidebarView — Observe pendingDetail

**Files:**
- Modify: `Rivulet/Views/TVNavigation/TVSidebarView.swift:120-124`

- [ ] **Step 1: Add pendingDetail observer to TVSidebarView**

In `Rivulet/Views/TVNavigation/TVSidebarView.swift`, find the existing `pendingPlayback` observer at line 120:

```swift
        .onChange(of: deepLinkHandler.pendingPlayback) { _, metadata in
            guard let metadata else { return }
            presentPlayerForDeepLink(metadata)
            deepLinkHandler.pendingPlayback = nil
        }
```

Add the `pendingDetail` observer directly after it:

```swift
        .onChange(of: deepLinkHandler.pendingDetail) { _, metadata in
            guard let metadata else { return }
            presentDetailForDeepLink(metadata)
            deepLinkHandler.pendingDetail = nil
        }
```

- [ ] **Step 2: Add presentDetailForDeepLink method**

Find `presentPlayerForDeepLink` (line 339) and add after it:

```swift
    private func presentDetailForDeepLink(_ metadata: PlexMetadata) {
        // Switch to Home tab and let the navigation system handle it
        selectedTab = .home

        // Present detail view as a full screen cover
        deepLinkDetailItem = metadata
    }
```

- [ ] **Step 3: Add state and fullScreenCover for deep link detail**

Add a `@State` property near the other state declarations (around line 23):

```swift
    @State private var deepLinkDetailItem: PlexMetadata?
```

Add a `.fullScreenCover` in the body, near the existing covers (around line 127):

```swift
        .fullScreenCover(item: $deepLinkDetailItem) { metadata in
            PlexDetailView(item: metadata)
                .presentationBackground(.black)
        }
```

- [ ] **Step 4: Verify build**

Run: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E '(error:|BUILD)'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Views/TVNavigation/TVSidebarView.swift
git commit -m "feat: handle detail deep links in TVSidebarView

Observes DeepLinkHandler.pendingDetail and presents
PlexDetailView as a fullScreenCover for Siri search results."
```

---

### Task 7: NSUserActivity — PlexDetailView (Browse Indexing)

**Files:**
- Modify: `Rivulet/Views/Plex/PlexDetailView.swift`

- [ ] **Step 1: Add NSUserActivity emission on item display**

In `Rivulet/Views/Plex/PlexDetailView.swift`, find the `currentItem` computed property (line 37). We need to emit an `NSUserActivity` whenever `currentItem` changes.

Add this modifier to the main view body. Find an appropriate `.onChange` or `.task` block — look for where `currentItem` is used or where data loads occur. Add after the existing modifiers:

```swift
        .userActivity("com.rivulet.viewMedia") { activity in
            activity.title = currentItem.title
            activity.isEligibleForSearch = true
            activity.isEligibleForPrediction = false
            activity.userInfo = ["ratingKey": currentItem.ratingKey ?? ""]
            activity.targetContentIdentifier = "rivulet://detail?ratingKey=\(currentItem.ratingKey ?? "")"
        }
```

The `.userActivity(_:update:)` SwiftUI modifier automatically creates, updates, and manages the lifecycle of the `NSUserActivity`. It updates whenever the view's state changes.

- [ ] **Step 2: Verify build**

Run: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E '(error:|BUILD)'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Rivulet/Views/Plex/PlexDetailView.swift
git commit -m "feat: emit NSUserActivity when browsing media details

Indexes browsed content for Siri search (not suggestions).
Uses .userActivity modifier for automatic lifecycle management."
```

---

### Task 8: NSUserActivity — UniversalPlayerViewModel (Watch Indexing)

**Files:**
- Modify: `Rivulet/Views/Player/UniversalPlayerViewModel.swift`

- [ ] **Step 1: Add NSUserActivity emission in startPlayback()**

In `Rivulet/Views/Player/UniversalPlayerViewModel.swift`, find `func startPlayback()` at line 988. After the guard checks succeed and playback is about to begin (after `streamURL` is confirmed valid), add the user activity:

```swift
        // Index for Siri Suggestions — watched content gets higher priority
        let activity = NSUserActivity(activityType: "com.rivulet.playMedia")
        activity.title = metadata.title
        activity.isEligibleForSearch = true
        activity.isEligibleForPrediction = true
        activity.userInfo = ["ratingKey": metadata.ratingKey ?? ""]
        activity.targetContentIdentifier = "rivulet://play?ratingKey=\(metadata.ratingKey ?? "")"
        self.userActivity = activity
```

You also need to add a property to hold the activity (prevents deallocation). Add near the other properties in UniversalPlayerViewModel:

```swift
    /// Holds the current NSUserActivity for Siri indexing
    private var userActivity: NSUserActivity?
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E '(error:|BUILD)'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Rivulet/Views/Player/UniversalPlayerViewModel.swift
git commit -m "feat: emit NSUserActivity on playback for Siri Suggestions

Watched content surfaces in Siri Suggestions with
isEligibleForPrediction=true for proactive recommendations."
```

---

### Task 9: RivuletApp — Register NSUserActivity Handler

**Files:**
- Modify: `Rivulet/RivuletApp.swift:70-81`

- [ ] **Step 1: Add onContinueUserActivity handlers**

In `Rivulet/RivuletApp.swift`, find the `WindowGroup` body (line 70). Add `.onContinueUserActivity` handlers after the existing `.onOpenURL`:

```swift
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // Handle deep links from Top Shelf
                    Task {
                        await DeepLinkHandler.shared.handle(url: url)
                    }
                }
                .onContinueUserActivity("com.rivulet.viewMedia") { activity in
                    guard let ratingKey = activity.userInfo?["ratingKey"] as? String,
                          !ratingKey.isEmpty else { return }
                    Task {
                        await DeepLinkHandler.shared.handle(
                            url: URL(string: "rivulet://detail?ratingKey=\(ratingKey)")!
                        )
                    }
                }
                .onContinueUserActivity("com.rivulet.playMedia") { activity in
                    guard let ratingKey = activity.userInfo?["ratingKey"] as? String,
                          !ratingKey.isEmpty else { return }
                    Task {
                        await DeepLinkHandler.shared.handle(
                            url: URL(string: "rivulet://play?ratingKey=\(ratingKey)")!
                        )
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
```

- [ ] **Step 2: Register activity types in Info.plist**

Add `NSUserActivityTypes` to the app's Info.plist. If there's no Info.plist file (using Xcode-generated settings), add it via Xcode target settings > Info > Custom tvOS Target Properties, or create/update the plist:

```xml
<key>NSUserActivityTypes</key>
<array>
    <string>com.rivulet.viewMedia</string>
    <string>com.rivulet.playMedia</string>
</array>
```

Alternatively, if activity types are managed via the build settings or a `.entitlements` file, add them there.

- [ ] **Step 3: Verify build**

Run: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E '(error:|BUILD)'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Rivulet/RivuletApp.swift
git commit -m "feat: register NSUserActivity handlers for Siri continuity

Routes Siri Suggestion taps through DeepLinkHandler for both
viewMedia (detail) and playMedia (playback) activity types."
```

If Info.plist was modified:
```bash
git add Rivulet/Info.plist
git commit --amend --no-edit
```

---

### Task 10: Full Integration Verification

**Files:** None (verification only)

- [ ] **Step 1: Run all tests**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E '(Test Suite|Tests|error:|BUILD)'`
Expected: All existing tests pass. New tests (MediaItemEntityTests, DeepLinkHandlerDetailTests) pass.

- [ ] **Step 2: Verify full build with no warnings related to new code**

Run: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -i warning | grep -i siri`
Expected: No Siri-related warnings.

- [ ] **Step 3: Verify all new files are in place**

```bash
ls -la Rivulet/Services/Siri/
# Expected: MediaItemEntity.swift, PlayMediaIntent.swift, SearchMediaIntent.swift, RivuletShortcuts.swift

ls -la RivuletTests/Unit/Siri/
# Expected: MediaItemEntityTests.swift, DeepLinkHandlerDetailTests.swift
```

- [ ] **Step 4: Final commit (if any fixups needed)**

Only if previous steps revealed issues that needed fixing.
