# Apple Music tvOS — Album Detail View Analysis

Photo of TV screen showing the detail page for "Vice Re-Verses" by Switchfoot.

## Overall Layout

Full-screen view (no sidebar visible — this is pushed into the NavigationStack, hiding the sidebar). Two-column layout:

- **Left column**: Album artwork, vertically centered
- **Right column**: Metadata + action buttons + track list

No background blur of the album art — the background is a plain dark gradient/solid dark.

## Left Column — Album Artwork

- **Size**: Large square, approximately 280-320pt width/height
- **Corner radius**: approximately 8-10pt (subtle rounding, not aggressive)
- **Position**: Left-aligned with ~60-80pt left margin from screen edge, vertically centered in the visible area
- **Shadow**: Very subtle, barely visible
- **No additional elements** around the artwork — no border, no glow

## Right Column — Metadata

### Album Title
- **"Vice Re-Verses"** — bold, approximately 28-32pt, white
- Top of the right column, aligned with the top edge of the album art approximately
- Left margin: ~40pt from the right edge of the album art

### Artist Name
- **"Switchfoot"** — regular weight, approximately 20-22pt, slightly dimmer white (not fully secondary gray — still readable)
- Directly below album title, ~4pt gap

### Genre · Year
- **"Alternative · 2011"** — smaller text, approximately 16-18pt, secondary gray
- Below artist name, ~4pt gap
- The separator is a middle-dot (·), not a bullet or dash

### Action Buttons Row
- Below the genre/year line, approximately 20-24pt gap
- Three elements horizontally:
  - **"▶ Play"** — pill button, translucent dark background, white icon + text, ~110pt wide, ~40pt tall, fully rounded ends
  - **"⇄ Shuffle"** — pill button, same style, ~130pt wide
  - **"•••"** — circular button, ~40pt diameter, three-dot ellipsis icon, same translucent style
- Gap between buttons: ~12-16pt
- The Play button appears to be the "primary" style (maybe slightly brighter/more opaque background)
- The Shuffle button is "secondary" (slightly more transparent)

## Track List

### Layout
- Below the action buttons, ~24-30pt gap
- Each track row spans the full width of the right column
- Track rows are **plain text** — NO individual backgrounds, NO glass rows, NO rounded rectangles per row
- Rows separated by **subtle horizontal dividers** (very thin, ~0.5pt, translucent gray lines)

### Track Row Structure
Each row contains, left to right:
1. **Track number** — ~16pt, monospaced or tabular, secondary gray, right-aligned in a ~24pt wide column
2. **Gap** — ~12-16pt between number and title
3. **Track title** — ~18-20pt, regular/medium weight, white, left-aligned, takes up remaining space, truncates with ellipsis if needed
4. **Duration** — ~16pt, secondary gray, right-aligned at the right edge, tabular/monospaced figures (e.g., "3:58", "5:00")

### Row Height
- Each row is approximately 44-48pt tall (total including padding)
- Vertical padding within each row: ~12pt top and bottom

### Currently Playing Indicator
- Track 3 ("Blinding Light") has a small filled circle/dot (~6-8pt) to the LEFT of the track number
- This replaces or supplements the track number to indicate it's the currently playing track
- The dot appears to be white or slightly colored

### Track List Scrolling
- 7 tracks visible, the list appears to extend below the visible area
- The track list is scrollable within the right column

## Key Measurements (estimated at 1920x1080)

| Element | Value |
|---------|-------|
| Album art size | ~300x300pt |
| Album art left margin | ~70pt |
| Album art corner radius | ~8pt |
| Art-to-metadata gap | ~40pt |
| Title font | ~30pt bold |
| Artist font | ~20pt regular |
| Genre/year font | ~17pt regular, gray |
| Metadata vertical gaps | ~4pt between lines |
| Button row gap from genre | ~22pt |
| Play button | ~110x40pt pill |
| Shuffle button | ~130x40pt pill |
| More button | ~40pt circle |
| Button gap | ~14pt |
| Track list gap from buttons | ~28pt |
| Track row height | ~46pt |
| Track number width | ~24pt |
| Track number font | ~16pt gray |
| Track title font | ~19pt white |
| Duration font | ~16pt gray |
| Divider opacity | very low, ~0.15 |

## Key Implementation Notes

- This is a PUSHED view in NavigationStack, not a fullScreenCover
- The sidebar is HIDDEN (via `nestedNavState.isNested = true` + `toolbarVisibility(.hidden, for: .tabBar)`)
- Track rows are extremely simple — no per-row backgrounds, just text + divider
- The "•••" button triggers a native `.contextMenu` (see context menu screenshot)
- The album art does NOT blur into the background — background is just dark
- The track list and metadata are in a single scrollable VStack (the whole right column scrolls if there are many tracks)
- Menu button goes back to the library grid
