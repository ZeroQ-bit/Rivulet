# Apple Music tvOS — Album Context Menu Analysis

Photo of TV screen showing the context menu triggered from the "•••" button on the album detail page.

## Context Menu Appearance

This is a **native tvOS context menu** — the standard system `.contextMenu { }` popup. NOT a custom overlay.

### Position
- The menu appears anchored to the "•••" button, floating to the right of the button
- It overlays the track list, partially obscuring it
- The album detail content behind is dimmed/blurred

### Menu Style
- **White/light background** — standard tvOS context menu material (system material, not custom)
- **Rounded corners** — approximately 12-14pt corner radius
- **Shadow** — soft drop shadow around the menu
- **Width**: approximately 240-260pt

### Menu Items

From top to bottom:
1. **"▶ Play"** — play icon + text (currently focused/highlighted with blue background)
2. **"🗑 Delete from Library"** — trash icon + text
3. **"👤 Go to Artist"** — person icon + text
4. **"＋ Add to Library"** — plus icon + text
5. **"📋 Add to a Playlist..."** — list icon + text + chevron (submenu indicator "›")
6. **"⇄ Shuffle"** — shuffle icon + text
7. **"⏭ Play Next"** — skip forward icon + text
8. **"⏭ Play After"** — similar icon + text, with a small gray subtitle below ("Red Balloon" — showing what it will play after)

### Menu Item Style
- Each item: icon (SF Symbol) left, label text right
- Font: ~17pt, system weight
- Icon size: ~20pt
- Row height: ~44pt
- The focused item ("Play") has a blue/accent-colored background fill with white text
- Unfocused items have dark text on the light background
- "Add to a Playlist..." has a chevron "›" on the right edge indicating a submenu
- "Play After" has a small secondary gray text below the label showing context

## Context Menu Behavior

- Triggered by pressing the "•••" button OR long-pressing on an album/track
- This is the NATIVE tvOS `.contextMenu { }` — we do NOT build this ourselves
- SwiftUI handles the presentation, dismissal, focus management, and animation
- Menu dismisses on: pressing Menu button, selecting an item, or navigating away

## Implementation

```swift
.contextMenu {
    Button { } label: { Label("Play", systemImage: "play.fill") }
    Button { } label: { Label("Delete from Library", systemImage: "trash") }
    Button { } label: { Label("Go to Artist", systemImage: "person") }
    Button { } label: { Label("Add to Library", systemImage: "plus") }
    // Submenu not directly available in basic contextMenu — would need Menu { } for nested
    Button { } label: { Label("Shuffle", systemImage: "shuffle") }
    Button { } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
    Button { } label: { Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward") }
}
```

## Key Notes
- This is 100% native — no custom UI needed
- The menu items should map to `MusicQueue` operations (playNow, addNext, addToEnd, etc.)
- "Go to Artist" should navigate to the artist detail page
- "Add to a Playlist..." would need the playlist API
- We should NOT try to replicate this visually — just use `.contextMenu { }`
