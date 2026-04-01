# Apple Music tvOS — Library Main Menu Analysis

Photo of TV screen showing the Apple Music Library tab with "Recently Added" selected.

## Overall Layout

Three distinct zones arranged horizontally:

1. **Top tab bar** (system-level, not ours to replicate — our app uses sidebar tabs)
2. **Left sidebar** — category list
3. **Right content area** — grid of album artwork

The sidebar and content sit side-by-side. The sidebar takes roughly 15-18% of screen width. The content area fills the remaining ~82%.

## Top Tab Bar

- Horizontal row of text tabs: "Home", "Radio", "Library" (selected/highlighted), "Now Playing", magnifying glass icon
- "Library" appears bold/selected with a subtle pill highlight behind it
- This is the system `TabView` with `.sidebarAdaptable` — we don't need to replicate this since our app already has its own sidebar. Our music library is a tab content area within our existing sidebar.

## Left Sidebar

Two sections, vertically stacked:

### Categories Section (top)
- Rows: "Recently Added", "Playlists", "Artists", "Albums", "Songs", "Composers"
- Each row is plain text, left-aligned
- "Recently Added" is currently selected — it has a subtle rounded-rect highlight/focus indicator behind it (semi-transparent white pill)
- Row height: approximately 44-48pt per row
- Font size: approximately 17-18pt, system weight (regular, not bold)
- Left padding: ~20pt from sidebar edge
- Vertical spacing between rows: tight, roughly 4-6pt between items (they appear as a dense list)
- No icons next to the category names — pure text labels
- The bullet/dot before each item: appears to be a small filled circle (~6pt) to the left of each category name, acting as a list marker. The selected item's dot is slightly larger or highlighted.

### Genres Section (below categories)
- Separated by a "Genres" section header in slightly smaller or dimmer text
- Genre names listed below: "Alternative", "Christian", "Country", "House" (partially visible, list continues below fold)
- Same row style as categories — plain text, same font size
- The genres appear to be selectable filters, same visual treatment as categories
- "Genres" header is slightly bolder or in a different color to distinguish it as a section title

### Sidebar Visual Style
- Background: slightly darker than the content area, but translucent — you can see the blurred album art colors bleeding through
- No hard border between sidebar and content — the transition is soft
- Total sidebar width: roughly 200-220pt on a 1920px display

## Right Content Area — Album Grid

### Header
- No visible header text for "Recently Added" in the content area — the sidebar selection IS the header
- However, when "Albums" or "Artists" is selected in other screenshots, a header appears: "Albums" with "19 albums" count + Play/Shuffle buttons. So the header may only appear for certain categories.

### Grid Layout
- 4 columns of album artwork visible in the first row
- A second row is partially visible below (4 more albums)
- The grid appears to be a standard `LazyVGrid` with fixed column count

### Album Cards
- **Artwork size**: approximately 200-220pt square per card
- **Artwork shape**: rounded corners, roughly 8-10pt corner radius
- **Artwork shadow**: very subtle drop shadow beneath each card
- **Spacing between cards**: approximately 24-30pt horizontal gap, 30-40pt vertical gap (including text space)
- **Below artwork**:
  - Album title: ~15pt font, medium weight, white text, single line truncated
  - Artist name: ~13pt font, regular weight, secondary/dimmed gray text, single line truncated
  - Text is center-aligned beneath the artwork
  - Gap between artwork bottom edge and title: ~8-10pt
  - Gap between title and artist: ~2-4pt

### Card Focus State
- The first album ("Red Balloon") appears to be focused — it is slightly larger/elevated compared to the others, with a brighter appearance
- The focus scale is subtle, roughly 1.05-1.08x
- There's a soft white glow/shadow around the focused card
- The focused card's artwork appears slightly brighter

### Placeholder Art
- Albums without custom artwork show a gray gradient background with a large white music note icon centered (see "Cheerleader (Remixes)" and "iTunes Session")
- The placeholder is the same size and rounded corners as real artwork

### Content Area Background
- Dark, semi-transparent — album art colors from the focused item seem to subtly tint the background
- The overall background has a warm tone influenced by the focused album's artwork

## Grid Measurements (estimated at 1920x1080)

| Element | Size |
|---------|------|
| Sidebar width | ~200pt |
| Grid left margin (from sidebar edge) | ~40pt |
| Card artwork | ~200x200pt |
| Card corner radius | ~10pt |
| Horizontal gap between cards | ~28pt |
| Vertical gap between rows (art to art) | ~70pt (includes text) |
| Title font size | ~15pt medium |
| Artist font size | ~13pt regular |
| Title-to-art gap | ~8pt |
| Title-to-artist gap | ~3pt |
| Text alignment | center |
| Sidebar row height | ~44pt |
| Sidebar font size | ~17pt |
| Sidebar row spacing | ~4pt |
| Focus scale | ~1.05x |
