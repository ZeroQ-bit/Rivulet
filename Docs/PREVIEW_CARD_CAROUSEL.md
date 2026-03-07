# Preview Card Carousel + Detail View Redesign

Apple TV+ inspired preview card carousel and hero-overlay detail view.

## Current Status

Working implementation with known polish items remaining.

### What Works
- Click poster in hub row → fullScreenCover carousel opens
- Cards show PlexDetailView in cardMode (backdrop + overlaid metadata)
- Left/Right d-pad pages between cards with spring animation
- Select (tap) or Down expands current card to full-width scrollable detail
- Menu collapses back to carousel; Menu again dismisses to home
- Continue Watching rows still play directly (no preview)
- Sidebar is fully blocked (fullScreenCover presentation)
- Adjacent cards render full PlexDetailView; far-off cards use Color.clear
- Works from both PlexHomeView and PlexLibraryView

### Known Issues / Polish TODO
- [ ] Focus can be finicky when expanding/collapsing — needs refinement
- [ ] matchedGeometryEffect not yet wired (poster → card transition)
- [ ] No fade-in animation for metadata content on card appear
- [ ] Carousel doesn't wrap around at ends
- [ ] Debug logging still present (remove before ship)

### Animations
- **Paging** (left/right): `.easeInOut(duration: 0.4)` — no spring/bounce
- **Expand/collapse**: `.easeInOut(duration: 0.35)` — no spring/bounce
- **Parallax**: Inner content drifts at 30% of card travel speed (image lags behind card frame)

---

## Architecture

### Files

| File | Role |
|------|------|
| `Views/Plex/DetailCardCarousel.swift` | Full-screen carousel view |
| `Views/Plex/PreviewContext.swift` | `Identifiable` struct: items + selectedIndex |
| `Views/Plex/PlexDetailView.swift` | Redesigned hero, `cardMode` parameter |
| `Views/Plex/PlexHomeView.swift` | Opens carousel via `.fullScreenCover` |
| `Views/Plex/PlexLibraryView.swift` | Same pattern as home |
| `Views/Plex/MediaPosterCard.swift` | Unchanged (no internal changes needed) |

### Data Flow

```
PlexHomeView / PlexLibraryView
  │
  ├─ InfiniteContentRow (hub row)
  │    └─ onItemPreviewed: ([PlexMetadata], Int) → sets previewContext
  │
  ├─ .fullScreenCover(item: $previewContext)
  │    └─ DetailCardCarousel
  │         ├─ items: [PlexMetadata] (from the hub row)
  │         ├─ currentIndex (state, changes on L/R)
  │         ├─ isExpanded (state, toggles on Select/Down/Menu)
  │         └─ PlexDetailView(item:, cardMode:) per visible card
  │
  └─ onDismiss: sets previewContext = nil
```

### PreviewContext

```swift
struct PreviewContext: Identifiable {
    let id = UUID()
    let items: [PlexMetadata]
    let selectedIndex: Int
}
```

Stored as `@State private var previewContext: PreviewContext?` in home/library views.
Presented via `.fullScreenCover(item: $previewContext)`.

---

## DetailCardCarousel

### Layout

- **Card width**: 1600pt (on 1920pt screen → 160pt peek on each side for adjacent cards)
- **Card spacing**: 20pt
- **Top inset**: 50pt (card mode only)
- **Corner radius**: 40pt (card mode), 0 (expanded)
- **Parallax factor**: 0.3 (inner content moves at 30% of card travel speed)
- **Render range**: currentIndex ± 2 get full PlexDetailView; others get Color.clear
- **Background**: `Color(uiColor: .systemBackground)` — matches app launch background

### Offset Math

All cards in the HStack are `cardWidth` except the current card which may be `currentCardWidth` (either `cardWidth` or `screenWidth` when expanded).

```
offset = (screenWidth - currentCardWidth) / 2 - currentIndex * (cardWidth + spacing)
```

This centers the current card regardless of its width, because all cards *before* it are always `cardWidth`.

### Parallax

Each card's inner PlexDetailView content gets an `offset(x:)` based on its distance from the center card:

```
innerOffset = distanceFromCenter * parallaxFactor * cardStep
```

Where `parallaxFactor = 0.3` and `cardStep = cardWidth + cardSpacing`. This makes the backdrop image appear to drift at 30% of the card frame's travel speed — the image lags behind the card as you page. When expanded, parallax resets to 0.

### State Machine

| State | Focusable | Cards | Current Card |
|-------|-----------|-------|-------------|
| Carousel | Yes (carousel view) | All cardWidth, clipped with cornerRadius | cardMode: true |
| Expanded | No (detail view owns focus) | Others stay cardWidth (off-screen) | Full screenWidth, cornerRadius 0, cardMode: false |

### Input Handling

| Input | Carousel Mode | Expanded Mode |
|-------|--------------|---------------|
| Left/Right | Page to adjacent card | Ignored (detail view handles) |
| Select (tap) | Expand current card | Detail view buttons |
| Down | Expand current card | Detail view scroll |
| Play/Pause | Expand current card | Detail view handles |
| Menu (exit) | Dismiss carousel | Collapse to carousel |

### Focus Strategy

- Carousel mode: `.focusable(true)` + `@FocusState isCarouselFocused`
- Expanded mode: `.focusable(false)` releases focus → PlexDetailView action buttons take over
- On collapse: `isCarouselFocused = true` after 0.1s delay to re-grab focus

### Presentation

Uses `.fullScreenCover` to:
1. Block sidebar/tab bar focus entirely
2. Present over the NavigationStack
3. Handle dismissal via `previewContext = nil`

The carousel wraps its content in a `NavigationStack` so PlexDetailView's `.navigationDestination` modifiers work.

---

## PlexDetailView Changes

### New Parameter

```swift
struct PlexDetailView: View {
    let item: PlexMetadata
    var cardMode: Bool = false  // New
```

### cardMode Behavior

| Feature | cardMode: true | cardMode: false |
|---------|---------------|----------------|
| Scroll | Disabled | Enabled |
| Hero height | Fills container (no fixed height) | 900pt |
| Action buttons | Hidden | Shown in hero |
| Cast info | Hidden | Shown in hero (bottom-right) |
| Below-fold content | Hidden | Seasons, episodes, collections, etc. |
| Summary | 2-line snippet | 3-line snippet |

### Hero Redesign (Apple TV+ Style)

The hero section now contains ALL metadata overlaid on the backdrop. No separate poster, no separate header section below.

```
ZStack(alignment: .bottom) {
    // Backdrop image (fills container in cardMode, 900pt otherwise)
    CachedAsyncImage(url: artURL)
        .overlay { gradient }

    // Metadata overlay at bottom
    HStack(alignment: .bottom) {
        VStack(alignment: .leading) {  // Left side
            TMDB logo or title text (48pt bold)
            Episode info (for episodes)
            Genre + content rating row
            Year · Duration · Quality badges (4K, DV, Atmos pills)
            Tagline (italic)
            Summary snippet (2-3 lines)
            Progress bar (if in-progress)
            Action buttons (if !cardMode)
        }
        Spacer
        VStack(alignment: .trailing) {  // Right side (if !cardMode)
            Starring: top 4 cast names
            Directed by: first director
        }
    }
}
```

### Removed Sections
- `headerSection` — merged into hero overlay
- `summarySection` — inline in hero; full expandable summary removed (hero snippet sufficient)
- Poster overlay in hero — removed entirely (no separate poster on right side)

### Quality Badges

New `QualityBadge` private view for 4K, Dolby Vision, Atmos, etc:
```swift
Text(text)
    .font(.caption).fontWeight(.semibold)
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(RoundedRectangle.fill(.white.opacity(0.15)))
    .overlay(RoundedRectangle.stroke(.white.opacity(0.3)))
```

---

## InfiniteContentRow Changes

Two new optional parameters:

```swift
var onItemPreviewed: (([PlexMetadata], Int) -> Void)?
var previewNamespace: Namespace.ID?
```

Button action priority:
1. Continue Watching → `onPlayItem` (direct playback)
2. `onItemPreviewed` set → opens preview carousel
3. Fallback → `onItemSelected` (original navigation)

---

## Integration Points

### PlexHomeView
- `@Namespace private var previewNamespace`
- `@State private var previewContext: PreviewContext?`
- `.fullScreenCover(item: $previewContext)` on the NavigationStack
- Non-CW rows pass `onItemPreviewed` + `previewNamespace`

### PlexLibraryView
- Same namespace + previewContext pattern
- Library grid items set previewContext on click
- Hub rows pass `onItemPreviewed` for non-CW hubs

---

## Debug Logging

Logger: `com.rivulet.app` / `DetailCardCarousel`

Key log messages:
- `Init:` — item count, initial index
- `Appeared:` — screen dimensions, item count
- `← idx` / `→ idx` — navigation
- `↓ expand idx` / `Select (tap) → expand idx` — expand triggers
- `Exit → collapse` / `Exit → dismiss` — back button
- `focused=` / `expanded=` — state changes
