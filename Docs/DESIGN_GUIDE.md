# Rivulet Design Guide

A comprehensive guide to the UI/UX patterns, components, and styling conventions used throughout the Rivulet tvOS app.

---

## Table of Contents

1. [Design Philosophy](#design-philosophy)
2. [Focus & Selection Styling](#focus--selection-styling)
3. [Button Styles](#button-styles)
4. [Glass Row Components](#glass-row-components)
5. [Navigation Patterns](#navigation-patterns)
6. [Focus Management](#focus-management)
7. [Typography](#typography)
8. [Colors & Opacity](#colors--opacity)
9. [Animation Timings](#animation-timings)
10. [Layout Spacing](#layout-spacing)
11. [Component Reference](#component-reference)
12. [tvOS-Specific Considerations](#tvos-specific-considerations)

---

## Design Philosophy

### Core Principles

**Simplicity** and **Elegance** are the foundation of Rivulet's design. Every element should feel intentional, refined, and effortless. When in doubt, remove rather than add.

### Guidelines

- **Simplicity First**: If a feature can be accomplished with fewer UI elements, do it. Avoid clutter, excessive labels, and redundant controls. The interface should feel calm and unobtrusive.

- **Elegant Restraint**: Use subtle effects rather than flashy ones. A 2% scale is more elegant than 10%. A soft glow is more refined than a harsh border. Let the content be the star.

- **Native Components First**: Use system-provided tvOS components (`.glassEffect()`, `.hoverEffect()`, `fullScreenCover`, TabView with `sidebarAdaptable`) whenever possible. Custom implementations should only exist when no native equivalent works. The target aesthetic is Apple TV+ — clean, confident, and platform-native.

- **Liquid Glass**: Use native `.glassEffect()` for translucent containers. Avoid manual material/opacity stacks when the system glass effect is available. This is the tvOS 26 aesthetic.

- **Subtle Motion**: Small scale effects (1.02x) rather than dramatic zooms. Animations should feel natural, not performative.

- **Consistency**: Unified focus behavior across all interactive elements. Users should never wonder "how does this work?"

- **Spatial Clarity**: Clear visual hierarchy with appropriate spacing. Give elements room to breathe.

- **Invisible Complexity**: Complex features should feel simple to use. Hide the machinery, show the magic.

### The 10-Foot Experience

Remember: users view this on a TV from across the room. Design for:
- **Readability**: Large, clear text
- **Discoverability**: Obvious focus states
- **Forgiveness**: Easy navigation, hard to get lost

### Design Don'ts

- **Don't over-decorate**: No gradients where flat colors work. No shadows where elevation isn't needed. No borders where spacing provides separation.

- **Don't add unnecessary icons**: If text is clear, an icon is redundant. We removed play icons from track rows because the row itself is obviously playable.

- **Don't use aggressive animations**: No bouncing, no overshooting, no attention-grabbing effects. The UI should recede, not perform.

- **Don't duplicate information**: If something is shown in one place, don't show it again nearby. Trust users to find it.

- **Don't add "just in case" features**: Every element must earn its place. If users haven't asked for it, don't build it.

- **Don't use solid color backgrounds**: Always prefer translucent materials (`.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`, or `.glassEffect()`) over opaque fills like `Color.black` or `Color.gray` for overlay and container backgrounds. Solid colors feel flat and disconnected from the system aesthetic. The only exception is when an opaque background is explicitly required (e.g., behind video playback).

---

## Focus & Selection Styling

### Unified Focus Effect (Glass Rows)

All focusable list rows use this consistent styling:

```swift
// Button style - CRITICAL: removes tvOS default focus ring
.buttonStyle(SettingsButtonStyle())

// Background
.background(
    RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                    lineWidth: 1
                )
        )
)

// Focus binding
.focused($isFocused)

// Scale
.scaleEffect(isFocused ? 1.02 : 1.0)

// Animation
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
```

**Note:** Using `.buttonStyle(.plain)` on tvOS will NOT work correctly - it still shows the default white focus glow. You MUST use `SettingsButtonStyle()` from `SettingsComponents.swift`.

### Focus States

| State | Background | Border | Scale |
|-------|-----------|--------|-------|
| Unfocused | `white.opacity(0.08)` | `white.opacity(0.08)` | 1.0 |
| Focused | `white.opacity(0.18)` | `white.opacity(0.25)` | 1.02 |
| Destructive Focused | `red.opacity(0.25)` | `red.opacity(0.4)` | 1.02 |

### Poster Cards (MediaPosterCard)

Media poster cards use `.hoverEffect(.highlight)` on the poster image for native tvOS focus behavior, wrapped in `CardButtonStyle` which removes the default focus ring.

---

## Button Styles

Buttons on tvOS follow the **App Store button pattern**: solid white background with black text when focused, translucent glass when unfocused. This provides clear, consistent focus feedback across the app.

### Button Style Overview

| Style | Use Case | Location |
|-------|----------|----------|
| `AppStoreButtonStyle()` | Standalone action buttons (Refresh, Retry, Cancel, Dismiss) | `GlassRowStyle.swift` |
| `AppStoreActionButtonStyle(isFocused:)` | Inline action buttons on detail views (Play, Shuffle, etc.) | `GlassRowStyle.swift` |
| `SettingsButtonStyle()` | Glass rows in settings and lists | `SettingsComponents.swift` |
| `CardButtonStyle()` | Poster cards (removes focus ring) | `MediaPosterCard.swift` |
| `GlassRowButtonStyle()` | Generic glass row buttons | `GlassRowStyle.swift` |

### AppStoreButtonStyle (Standalone Buttons)

For standalone action buttons like Refresh, Retry, Try Again, Cancel, Dismiss. Has built-in padding.

```swift
Button("Refresh") {
    Task { await refresh() }
}
.buttonStyle(AppStoreButtonStyle())
```

**Behavior:**
- **Unfocused**: Glass background (15% white), white text
- **Focused**: Solid white background, black text, 1.1x scale
- **Pressed**: 0.95x scale

**Styling:**
- Corner radius: 16pt
- Padding: 24pt horizontal, 14pt vertical
- Animation: spring(response: 0.25, dampingFraction: 0.8)

### AppStoreActionButtonStyle (Detail View Buttons)

For inline action buttons on detail views (Play, Shuffle, Restart, Watched, etc.). Requires external focus state since ButtonStyle cannot track focus internally.

```swift
// Primary action (Play, Resume)
Button { ... } label: {
    HStack(spacing: 8) {
        Image(systemName: "play.fill")
        Text("Play")
    }
    .font(.system(size: 20, weight: .semibold))
    .frame(minWidth: actionButtonMinWidth, minHeight: actionButtonHeight)
}
#if os(tvOS)
.buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "play"))
.focused($focusedActionButton, equals: "play")
#else
.buttonStyle(.borderedProminent)
#endif

// Secondary action (Shuffle, Restart)
.buttonStyle(AppStoreActionButtonStyle(isFocused: focusedActionButton == "shuffle", isPrimary: false))
```

**Parameters:**
- `isFocused: Bool` - **Required**. Pass the focus state from the view.
- `isPrimary: Bool` - Optional (default: true). Primary actions have 20% opacity unfocused, secondary have 10%.
- `cornerRadius: CGFloat` - Optional (default: 16).

**Behavior:**
- **Unfocused**: Glass background (10-20% white), white text
- **Focused**: Solid white background, black text, 1.08x scale
- **Pressed**: 0.95x scale

**IMPORTANT:** The `isFocused` parameter is required because `@FocusState` inside a `ButtonStyle` does not work - it's not connected to the actual button focus. You must pass the focus state from your view's `@FocusState` variable.

### Detail View Action Button Constants

```swift
private let actionButtonHeight: CGFloat = 66
private let actionButtonMinWidth: CGFloat = 180
```

| Button | Width | Notes |
|--------|-------|-------|
| Play, Shuffle, Restart, Show, Info, Trailer | minWidth: 180 | Standard action buttons |
| Watched/Unwatched | 220 | Fixed width for text stability |
| Star | 80 | Icon-only button |

### Handling Custom Foreground Colors

When a button has semantic colors (green for "Watched", yellow for "Starred"), you must handle the focus state manually since the button style's `foregroundStyle` is overridden by content styling:

```swift
// Watched button - black on focus, green when watched, white when unwatched
.foregroundStyle(focusedActionButton == "watched" ? .black : (isWatched ? .green : .white))

// Star button - black on focus, yellow when starred, gray when not
.foregroundStyle(focusedActionButton == "star" ? .black : (isStarred ? .yellow : .secondary))
```

### Menu Label Styling (Sort Button)

`Menu` components don't use `ButtonStyle` for their label - they require inline styling:

```swift
@FocusState private var isSortButtonFocused: Bool

Menu {
    // Menu items...
} label: {
    HStack(spacing: 10) {
        Image(systemName: "arrow.up.arrow.down")
            .font(.system(size: 20, weight: .semibold))
        Text(currentSortOption.displayName)
            .font(.system(size: 20, weight: .medium))
    }
    .foregroundStyle(isSortButtonFocused ? .black : .white)
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isSortButtonFocused ? .white : .white.opacity(0.15))
    )
    .scaleEffect(isSortButtonFocused ? 1.1 : 1.0)
}
.buttonStyle(.plain)
.hoverEffectDisabled()
.focusEffectDisabled()
.focused($isSortButtonFocused)
.animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSortButtonFocused)
```

### Removing Default tvOS Focus Effects

To prevent the default tvOS focus halo/ring, always apply these modifiers:

```swift
.buttonStyle(.plain)       // or AppStoreButtonStyle, SettingsButtonStyle, etc.
.hoverEffectDisabled()     // Removes hover glow
.focusEffectDisabled()     // Removes focus ring
```

### Cross-Platform Considerations

Always wrap tvOS-specific button styles:

```swift
#if os(tvOS)
.buttonStyle(AppStoreButtonStyle())
#else
.buttonStyle(.borderedProminent)  // or .bordered for secondary
#endif
```

---

## Glass Row Components

### Settings Rows

Located in `Views/Settings/SettingsComponents.swift`:

- **SettingsRow** - Navigation row with icon, title, subtitle, chevron
- **SettingsToggleRow** - Toggle with On/Off indicator
- **SettingsPickerRow** - Cycles through options on tap
- **SettingsActionRow** - Centered action button (supports destructive style)
- **SettingsInfoRow** - Display-only information

### Content Rows

Located in `Views/Plex/PlexDetailView.swift`:

- **EpisodeRow** - TV show episodes with thumbnail, progress bar, metadata
- **AlbumTrackRow** - Music tracks with track number and duration
- **ArtistAlbumRow** - Album cards with artwork, year, track count

### Shared Components

Located in `Views/Components/GlassRowStyle.swift`:

- **GlassRowButtonStyle** - Minimal button style (removes focus ring)
- **GlassRowBackground** - Reusable glass background view
- **GlassRowModifier** - View modifier for applying glass styling
- **FocusableGlassRow** - Complete focusable row component

---

## Navigation Patterns

### Sidebar Navigation

- Main navigation via `TabView` with `.tabViewStyle(.sidebarAdaptable)`
- Account tab uses a custom `Binding` to intercept selection — never actually navigates to `.account`
- Profile switcher shown via `fullScreenCover` with `.presentationBackground(.clear)`
- Sidebar focus containment via UIKit swizzle on the sidebar's `UICollectionView` (blocks downward focus escape)
- Focus recovery watchdog monitors for lost focus and restores it to the content namespace

### Detail Navigation

- Value-based navigation for library items: `.navigationDestination(for: PlexMetadata.self)`
- Binding-based navigation for nested views: `.navigationDestination(item: $navigateToAlbum)`
- Prevents duplicate navigationDestination conflicts

### Back Navigation

Custom `goBackAction` in `NestedNavigationState`:
- Overridden when navigating into nested content (e.g., artist → album)
- Ensures Menu button returns to parent, not root

```swift
nestedNavState.goBackAction = { [weak nestedNavState] in
    navigateToAlbum = nil
    nestedNavState?.isNested = true  // Stay in parent view
}
```

---

## Focus Management

### Approach

Rivulet uses standard SwiftUI focus primitives (`@FocusState`, `.focused()`, `.focusSection()`) combined with `FocusMemory` for section-level focus restoration. There is no custom focus scope manager — focus isolation is handled by system mechanisms:

- **`fullScreenCover`** — provides automatic focus isolation. No `@Namespace`, `resetFocus`, `focusScope`, or `prefersDefaultFocus` needed. Just use `@FocusState` with `.onAppear` assignment.
- **`TabView` with `sidebarAdaptable`** — system manages sidebar/content focus transitions.
- **Focus recovery watchdog** — background task in `TVSidebarView` monitors for lost focus and restores it to the content namespace.

### Focus Restoration

Save and restore focus when navigating:

```swift
// Save focus before navigating
savedAlbumFocus = album.ratingKey

// Restore focus when returning
.onChange(of: navigateToAlbum) { oldAlbum, newAlbum in
    if oldAlbum != nil && newAlbum == nil, let savedFocus = savedAlbumFocus {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedAlbumId = savedFocus
        }
    }
}
```

---

## Typography

### tvOS Font Sizes

| Element | Size | Weight |
|---------|------|--------|
| Large Title | 56pt | Bold |
| Section Header | 21pt | Bold (with 2pt tracking) |
| Row Title | 29pt | Medium |
| Row Subtitle | 23pt | Regular |
| Body Text | 22pt | Medium |
| Caption/Secondary | 18pt | Regular |
| Track Number | 22pt | Medium, Monospaced |

### iOS Font Sizes

Use standard semantic fonts (`.headline`, `.caption`, etc.)

---

## Colors & Opacity

### Background Opacities

| Use Case | Opacity |
|----------|---------|
| Unfocused row background | 0.08 |
| Focused row background | 0.18 |
| Unfocused border | 0.08 |
| Focused border | 0.25 |
| Section header text | 0.5 |
| Secondary text | 0.6 |
| Chevron/icon unfocused | 0.4 |
| Chevron/icon focused | 0.8 |

### Semantic Colors

- **Green** - Watched indicator, toggle "On" state
- **Blue** - Primary actions, progress bars
- **Red** - Destructive actions
- **Yellow** - Star rating, critic ratings
- **Orange** - Director indicator

### Glass Effect

Use native tvOS 26 `.glassEffect()` for container backgrounds instead of manual material/opacity stacks:

```swift
// Preferred — native liquid glass
.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 58))

// For non-interactive containers
.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
```

Settings sections, popup cards, and overlays should all use `.glassEffect()` for consistent system-native appearance.

---

## Popup Sheets

### Glass Popup Sheet Pattern

Modal sheets (pickers, confirmations, info panels) use a centered glass container rather than full-screen backgrounds:

```swift
VStack(spacing: 24) {
    // Header
    Text(title)
        .font(.system(size: 36, weight: .bold))
        .foregroundStyle(.white)
        .padding(.top, 40)

    // Content (scrollable if needed)
    ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 8) {
            // Items...
        }
        .padding(.horizontal, 32)
    }
    .frame(maxHeight: 600)  // Constrain scroll height

    Spacer(minLength: 0)
}
.padding(.bottom, 40)
.frame(width: 500)  // Fixed width, not full-screen
.background(
    RoundedRectangle(cornerRadius: 32, style: .continuous)
        .fill(.black.opacity(0.3))
)
.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
.onExitCommand {
    dismiss()  // Menu button dismisses
}
```

### Popup Sheet Sizing

| Sheet Type | Width |
|------------|-------|
| Picker/List | 500pt |
| Reorder controls | 480pt |
| Confirmation | 450pt |

### Key Differences from Full-Screen Views

- **Fixed width** - centered on screen, not edge-to-edge
- **Glass background** - `.black.opacity(0.3)` + `.glassEffect()`
- **32pt corner radius** - larger than row backgrounds (16-18pt)
- **Constrained scroll height** - `maxHeight: 600` for long lists
- **Compact typography** - 36pt title, 26pt option text

---

## Animation Timings

### Standard Spring Animation

```swift
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
```

### Quick Transitions

```swift
.animation(.easeOut(duration: 0.15), value: someValue)
```

### Sidebar Animation

```swift
.animation(.spring(response: 0.18, dampingFraction: 0.9), value: isSidebarVisible)
```

---

## Layout Spacing

### Padding Values (tvOS)

| Context | Horizontal | Vertical |
|---------|------------|----------|
| Screen edge | 48-80pt | - |
| Row content | 20-24pt | 16-20pt |
| Section spacing | - | 24-32pt |
| Item spacing in rows | 16pt | - |
| Grid item spacing | 32pt | - |

### Corner Radii

| Element | Radius |
|---------|--------|
| Hero/backdrop | 32pt |
| Settings section | 24pt |
| Row backgrounds | 16-18pt |
| Thumbnails | 8pt |
| Poster cards | 12pt |
| Icon backgrounds | 14pt |

---

## Component Reference

### Button Styles

| Style | Use Case | Focus Behavior |
|-------|----------|----------------|
| `AppStoreButtonStyle()` | Standalone buttons (Refresh, Retry, Cancel) | White bg + black text on focus |
| `AppStoreActionButtonStyle(isFocused:)` | Detail view actions (Play, Shuffle) | White bg + black text on focus |
| `SettingsButtonStyle()` | Glass rows in settings/lists | Glass opacity change on focus |
| `CardButtonStyle()` | Poster cards | Removes focus ring (uses hoverEffect) |
| `GlassRowButtonStyle()` | Generic glass row buttons | Glass opacity change on focus |
| `.borderedProminent` | Non-tvOS primary actions | System styling |
| `.bordered` | Non-tvOS secondary actions | System styling |

**IMPORTANT:** On tvOS:
- Use `AppStoreButtonStyle()` for standalone action buttons (Refresh, Retry, Try Again, Cancel, Dismiss)
- Use `AppStoreActionButtonStyle(isFocused:)` for detail view action buttons (Play, Shuffle, Restart, Watched, etc.)
- Use `SettingsButtonStyle()` for glass rows in settings and lists
- Never use `.buttonStyle(.plain)` alone - it still shows tvOS's default focus glow
- Always add `.hoverEffectDisabled()` and `.focusEffectDisabled()` when using custom focus styling

See [Button Styles](#button-styles) section for detailed usage.

### Inline Toggle Pattern

For toggles within sheets or other views (not full settings rows), use this compact pattern:

```swift
private struct InlineToggle: View {
    @Binding var isOn: Bool
    let isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 16) {
                Text("Toggle Label")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()

                Text(isOn ? "On" : "Off")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(isOn ? .green : .white.opacity(0.5))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(SettingsButtonStyle())  // NOT .plain - removes tvOS focus ring
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}
```

**Key rules:**
- Use `SettingsButtonStyle()` - NEVER `.buttonStyle(.plain)` on tvOS
- Use "On"/"Off" text indicator (green/gray) - matches `SettingsToggleRow`
- Follow standard glass row opacities and corner radius (16pt)
- Apply standard scale (1.02) and spring animation

### Image Loading

Use `CachedAsyncImage` for all remote images:

```swift
CachedAsyncImage(url: imageURL) { phase in
    switch phase {
    case .success(let image):
        image.resizable().aspectRatio(contentMode: .fill)
    case .empty:
        Rectangle().fill(Color(white: 0.15))
            .overlay { ProgressView().tint(.white.opacity(0.3)) }
    case .failure:
        Rectangle().fill(Color(white: 0.15))
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.white.opacity(0.4))
            }
    }
}
```

### Progress Bars

Watch progress overlay on thumbnails:

```swift
GeometryReader { geo in
    VStack {
        Spacer()
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(height: 3)
            Rectangle()
                .fill(Color.blue)
                .frame(width: geo.size.width * progress, height: 3)
        }
    }
}
```

---

## tvOS-Specific Considerations

### Focus Scale Room

Add padding to containers for scale effect:

```swift
LazyVStack(spacing: 16) { ... }
    .padding(.horizontal, 8)  // Room for 1.02x scale
```

### Exit Command Handling

Handle Menu button presses at appropriate levels:

```swift
.onExitCommand {
    if isSidebarVisible {
        closeSidebar()
    } else if nestedNavState.isNested {
        nestedNavState.goBack()
    } else {
        openSidebar()
    }
}
```

### Focus State Tracking

Use `@FocusState` for individual items:

```swift
@FocusState private var isFocused: Bool
// or for collections:
@FocusState private var focusedItemId: String?

Button { ... }
    .focused($isFocused)
    // or:
    .focused($focusedItemId, equals: item.ratingKey)
```

### Conditional Compilation

Always wrap tvOS-specific code:

```swift
#if os(tvOS)
@FocusState private var isFocused: Bool
#endif

// In views:
#if os(tvOS)
.buttonStyle(SettingsButtonStyle())  // NOT .plain - removes tvOS focus ring
.focused($isFocused)
.scaleEffect(isFocused ? 1.02 : 1.0)
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
#else
.buttonStyle(.plain)
#endif
```

---

## Skeleton Loading Placeholders

When loading content that has a known count (e.g., episodes in a season), show skeleton placeholders immediately rather than a spinner. This prevents layout jank and gives users immediate feedback.

### Skeleton Row Pattern

```swift
struct SkeletonEpisodeRow: View {
    let episodeNumber: Int

    var body: some View {
        HStack(spacing: 16) {
            // Placeholder thumbnail with spinner
            Rectangle()
                .fill(Color(white: 0.15))
                .frame(width: 200, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    ProgressView()
                        .tint(.white.opacity(0.3))
                }

            VStack(alignment: .leading, spacing: 4) {
                // Known text (e.g., "Episode 1")
                Text("Episode \(episodeNumber)")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.3))

                // Placeholder bars for unknown content
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 200, height: 22)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 80, height: 18)
            }
            Spacer()
        }
        // Use dimmer glass styling than interactive rows
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}
```

### Usage Pattern

```swift
let episodeCount = selectedSeason?.leafCount ?? 0
if isLoadingEpisodes && episodeCount > 0 {
    // Show skeleton rows based on known count
    LazyVStack(spacing: 16) {
        ForEach(1...episodeCount, id: \.self) { index in
            SkeletonEpisodeRow(episodeNumber: index)
        }
    }
} else if isLoadingEpisodes {
    // Fallback to spinner if count unknown
    ProgressView("Loading episodes...")
} else if !episodes.isEmpty {
    // Show actual content
    LazyVStack(spacing: 16) {
        ForEach(episodes, id: \.ratingKey) { episode in
            EpisodeRow(episode: episode, ...)
        }
    }
}
```

### Skeleton Styling

| Element | Opacity |
|---------|---------|
| Background fill | 0.04 |
| Border | 0.06 |
| Placeholder bars | 0.08-0.1 |
| Known text | 0.3 |

---

## Profile Switcher Popup

The profile switcher uses `fullScreenCover` with a transparent background, triggered from the sidebar account tab via a custom binding that intercepts the tab selection.

### Architecture

The sidebar `TabView` uses a custom `Binding<SidebarTab>` instead of `$selectedTab` directly. When the user selects the account tab, the binding intercepts the value, shows the popup, and never stores `.account` — so the tab never actually changes:

```swift
private var tabSelection: Binding<SidebarTab> {
    Binding(
        get: { selectedTab },
        set: { newTab in
            if newTab == .account {
                if profileManager.hasMultipleProfiles {
                    showProfileSwitcher = true
                }
                return  // Never store .account
            }
            selectedTab = newTab
        }
    )
}
```

This avoids:
- **Content flash** — no tab switch means no view recreation
- **Focus conflicts** — `fullScreenCover` provides its own focus hierarchy
- **Home reload** — the presenting view stays untouched

### Presentation

```swift
.fullScreenCover(isPresented: $showProfileSwitcher) {
    ProfileSwitcherPopup(
        isPresented: $showProfileSwitcher,
        profileManager: profileManager
    )
    .presentationBackground(.clear)
}
```

- `.presentationBackground(.clear)` — home content shows through behind the popup
- `fullScreenCover` — automatic focus isolation, Menu button dismissal
- No `@Namespace`, `resetFocus`, or `focusScope` needed — the cover handles it

### Popup Styling

- Uses `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 58))` for native glass
- Positioned top-left with `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)`
- Profile avatars use `@FocusState` with simple `.onAppear` assignment (no `prefersDefaultFocus`)

### Badge Overlays (Checkmark, Lock)

Badge icons on avatar circles must be fully opaque — SF Symbols have inherent transparency. Use a solid backing circle:

```swift
.overlay(alignment: .topTrailing) {
    Circle()
        .fill(.white)
        .frame(width: 34, height: 34)
        .overlay {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
        }
        .offset(x: 8, y: -8)
}
```

**Key**: The white `Circle` behind the SF Symbol prevents the avatar from bleeding through the symbol's transparent regions.

---

## Horizontal Scroll Sections

### Full-Bleed Scrolling Pattern

For horizontal scroll sections that need to extend beyond parent padding while keeping content aligned:

```swift
ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 24) {
        ForEach(items) { item in
            ItemCard(item: item)
        }
    }
    .padding(.horizontal, 48)  // Match parent padding
    .padding(.vertical, 32)    // Room for shadow/focus overflow
}
.padding(.horizontal, -48)     // Extend beyond parent padding
.scrollClipDisabled()          // Allow shadow/scale overflow
```

### Focus Section with Default Focus

For sections that should always focus a specific item when entered:

```swift
ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 24) {
        ForEach(items) { item in
            ItemCard(item: item)
                .focused($focusedItemId, equals: item.id)
        }
    }
}
.focusSection()
#if os(tvOS)
.defaultFocus($focusedItemId, selectedItem?.id)
#endif
```

### Focus Binding Modifiers

When passing FocusState bindings to child views, use a helper modifier:

```swift
struct ItemFocusModifier: ViewModifier {
    var focusedItemId: FocusState<String?>.Binding?
    let itemId: String?

    func body(content: Content) -> some View {
        if let binding = focusedItemId, let id = itemId {
            content.focused(binding, equals: id)
        } else {
            content
        }
    }
}
```

---

## Poster Cards vs Glass Rows

### Poster Cards (MediaPosterCard, SeasonPosterCard)

Use `.hoverEffect(.highlight)` on the poster image only - NOT `.scaleEffect()` on the whole card:

```swift
CachedAsyncImage(url: posterURL) { ... }
    .frame(width: posterWidth, height: posterHeight)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    .hoverEffect(.highlight)  // Native tvOS focus on poster only
    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
    .padding(.bottom, 10)     // Space for hover scale effect

// Text labels below poster stay stationary
Text(title)
    .font(.system(size: 19, weight: .medium))
```

**Key differences from glass rows:**
- No manual `.scaleEffect()` - use `.hoverEffect(.highlight)` instead
- Add `.padding(.bottom, 10)` to poster for hover effect room
- Text below the poster remains stationary (doesn't scale)
- Use `CardButtonStyle()` to remove default focus ring

### Glass Rows (EpisodeRow, AlbumTrackRow)

Use manual `.scaleEffect()` on the whole button:

```swift
Button(action: onPlay) {
    HStack { ... }
    .background(GlassRowBackground(isFocused: isFocused))
}
.buttonStyle(CardButtonStyle())
.focused($isFocused)
.scaleEffect(isFocused ? 1.02 : 1.0)
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
```

---

## Focus Memory (Section Focus Restoration)

For sections within a view that need to remember and restore focus when navigating between them:

### Usage Pattern

```swift
@FocusState private var focusedItemId: String?

ScrollView(.horizontal) {
    HStack(spacing: 24) {
        ForEach(items, id: \.ratingKey) { item in
            ItemCard(item: item)
                .focused($focusedItemId, equals: item.ratingKey)
        }
    }
}
.focusSection()
.remembersFocus(key: "uniqueSectionKey", focusedId: $focusedItemId)
// NO .scrollPosition() - let focus engine handle scrolling
```

### Key Rules

1. **Never use `.scrollPosition()` with focus-managed sections** - causes scroll jumping
2. **Always use `.focusSection()`** - helps focus engine navigate between sections
3. **Use unique memory keys** - e.g., "detailSeasons", "librarySortOptions"
4. **Let focus engine scroll** - don't manually control scroll position; tvOS auto-scrolls to focused items

### When to Use FocusMemory

| System | Use Case |
|--------|----------|
| FocusMemory | Sections within a view (seasons, episodes, cast) |
| `fullScreenCover` | Isolating focus for overlays/popups (system-managed) |
| `@FocusState` + `.onAppear` | Setting initial focus in presented views |

### Why Not `.scrollPosition()`?

Using `.scrollPosition()` with `.focused()` creates race conditions:
- Multiple `onChange` handlers compete to set scroll position
- Focus engine tries to auto-scroll, but manual scroll overrides it
- Result: visible scroll jumping

The FocusMemory pattern is simpler: let tvOS focus engine handle scrolling automatically.

---

## File Locations

| Component Type | Location |
|----------------|----------|
| Shared UI components | `Views/Components/` |
| Settings components | `Views/Settings/SettingsComponents.swift` |
| Glass row styling | `Views/Components/GlassRowStyle.swift` |
| App Store button styles | `Views/Components/GlassRowStyle.swift` |
| Card button style | `Views/Plex/MediaPosterCard.swift` |
| Settings button style | `Views/Settings/SettingsComponents.swift` |
| Focus memory (section focus) | `Services/Focus/FocusMemory.swift` |
| Image caching | `Views/Components/CachedAsyncImage.swift` |

---

## Quick Reference: Adding a New List Row

1. Create the row view with `@FocusState private var isFocused: Bool`
2. Apply glass background with focus-aware styling:
   ```swift
   .background(
       RoundedRectangle(cornerRadius: 16, style: .continuous)
           .fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
           .overlay(
               RoundedRectangle(cornerRadius: 16, style: .continuous)
                   .strokeBorder(
                       isFocused ? .white.opacity(0.25) : .white.opacity(0.08),
                       lineWidth: 1
                   )
           )
   )
   ```
3. Wrap in Button with `SettingsButtonStyle()` (NOT `.plain`)
4. Add `.focused($isFocused)`
5. Add `.scaleEffect(isFocused ? 1.02 : 1.0)`
6. Add `.animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)`
7. Add `.padding(.horizontal, 8)` to parent container for scale room

---

## Simplicity Checklist

Before shipping any new UI, ask:

- [ ] Can any element be removed without losing function?
- [ ] Is every icon/label necessary, or is the context clear enough?
- [ ] Does the focus effect match our unified glass style?
- [ ] Are animations subtle (spring 0.3, scale 1.02)?
- [ ] Is spacing consistent with existing patterns?
- [ ] Would a first-time user understand this immediately?
- [ ] Does it look calm and refined, not busy or flashy?
- [ ] Is the content the hero, not the chrome?

**The goal**: Users should think about their media, not the interface.

---

*Last updated: March 2026*
