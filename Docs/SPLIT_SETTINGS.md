# Split Settings Layout

Apple TV-style split settings screen matching the native Settings app pattern.

## Layout

```
+---------------------------------------------------------------+
|                          Settings                             |
|                                                               |
|   +------------------------------+  +-----------------------+ |
|   |                              |  | APPEARANCE            | |
|   |      +--[SF Symbol]--+      |  |  Sidebar Libraries  > | |
|   |      |   (dynamic)   |      |  |  Display Size    Med  | |
|   |      +---------------+      |  |  Poster Depth    On   | |
|   |                              |  |  Home Hero       Off  | |
|   |  Description text updates    |  | PLAYBACK              | |
|   |  as focus moves between      |  |  Audio Language   En  | |
|   |  rows on the right panel.    |  |  Subtitles       Off  | |
|   |                              |  |  Show Skip       On   | |
|   +------------------------------+  +-----------------------+ |
|          ~55% width                      ~45% width           |
+---------------------------------------------------------------+
```

## Architecture

### SettingsPage enum
Replaces `NavigationStack` with custom state-based navigation:
```swift
enum SettingsPage: Hashable, CaseIterable {
    case root, plex, iptv, libraries, cache, userProfiles
}
```

### Split panels
- **Left (55%)**: Decorative SF Symbol icon + description text. No focusable elements. Updates reactively based on `focusedSettingId`.
- **Right (45%)**: Scrollable settings list. Rows use `onFocusChange` callbacks to drive the left panel.

### Focus tracking
Each row sets `focusedSettingId` when focused:
```swift
SettingsToggleRow(
    title: "Home Hero",
    subtitle: "",
    isOn: $showHomeHero,
    onFocusChange: { if $0 { focusedSettingId = "homeHero" } }
)
```

`SettingsDescriptorStore` maps IDs to `SettingDescriptor` (icon, color, description text). When a setting is focused, the left panel shows its descriptor. When none is focused or no descriptor exists, the page-level icon is shown.

### Navigation
Custom slide transitions instead of NavigationStack:
```swift
func navigate(to page: SettingsPage) {
    isForward = true
    currentPage = page
}

func goBack() {
    isForward = false
    currentPage = .root
}
```

Right panel uses `.id(currentPage)` with asymmetric move transitions and `.clipped()`. Menu button (`.onExitCommand`) calls `goBack()` on sub-pages.

`nestedNavState` is wired so the sidebar knows when we're in a sub-page and can intercept Menu for back navigation.

### Row components (SettingsComponents.swift)
All row components support:
- **Optional icons**: `icon: String? = nil, iconColor: Color = .clear` — omit for icon-free rows
- **Optional subtitles**: Empty string hides the subtitle line
- **Focus callback**: `onFocusChange: ((Bool) -> Void)? = nil`

### Sub-settings views
`PlexSettingsView`, `CacheSettingsView`, `IPTVSettingsView`, `LibrarySettingsView`, `UserProfileSettingsView` are embeddable:
- No outer `ScrollView`, header, or background — SettingsView provides those
- Accept `Binding<String?>` for `focusedSettingId` (default `.constant(nil)`)
- Keep all internal state, sheets, confirmation dialogs

### Descriptors (SettingsDescriptors.swift)
```swift
struct SettingDescriptor {
    let icon: String
    let iconColor: Color
    let description: String
}

enum SettingsDescriptorStore {
    static func descriptor(for id: String) -> SettingDescriptor?
    static func pageInfo(for page: SettingsPage) -> (icon: String, color: Color)
}
```

~35 entries for root settings. Sub-page settings can be added as needed.

## Files

| File | Role |
|------|------|
| `SettingsView.swift` | Split layout, root page content, navigation, help content |
| `SettingsComponents.swift` | Reusable row components (optional icons, onFocusChange) |
| `SettingsDescriptors.swift` | Per-setting icon/description data for left panel |
| `PlexSettingsView.swift` | Plex server sub-page (embeddable) |
| `CacheSettingsView.swift` | Cache management sub-page (embeddable) |
| `IPTVSettingsView.swift` | Live TV sources sub-page (embeddable) |
| `LibrarySettingsView.swift` | Library visibility sub-page (embeddable) |
| `UserProfileSettingsView.swift` | User profiles sub-page (embeddable) |
