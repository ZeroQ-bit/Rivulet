# Apple Music tvOS — Artists View Analysis

Photo of TV screen showing the Library tab with "Artists" selected in the sidebar.

## Layout Structure

Same three-zone layout as Albums view: sidebar left, content right, with a header row.

## Content Header

- **"Artists"** — large bold text, ~28-32pt, white
- **"13 artists"** — below, ~15pt, gray/secondary
- Right side: **"▶ Play"** and **"⇄ Shuffle"** pill buttons (same as Albums)
- No sort/add circular buttons visible for Artists (unlike Albums)

## Artist Grid — KEY DIFFERENCES FROM ALBUMS

### Photo Shape
- **Circular** — artist photos are clipped to perfect circles, not rounded rectangles
- This is the major visual differentiator from the album grid
- Circle diameter: approximately 180-200pt (same width as album cards)

### Photo Treatment
- Photos fill the circle with aspect-fill (cropped to circle)
- Artists without photos would presumably get a placeholder (person silhouette)
- The first artist ("Emily Hearn") appears focused — the circle is slightly larger (~1.05x scale) with a subtle glow/shadow

### Grid Layout
- 4 columns visible in first row, 4 more partially visible in second row
- Same horizontal spacing as albums (~28pt between circles)
- Vertical spacing appears similar to albums

### Text Below Circle
- **Artist name only** — single line of text, center-aligned
- No subtitle line (no second line like albums have for artist name)
- Font: ~15pt, medium weight, white
- Gap between circle bottom and name: ~10-12pt
- Names that are too long truncate with ellipsis ("John Michael Montgom...")

## Sidebar State
- "Artists" is selected with the rounded highlight
- Same category list as other views

## Key Implementation Notes

- The ONLY difference from Albums view is: circular clips instead of rounded-rect, single line of text (name only, no subtitle)
- Same grid columns, same spacing, same header layout
- This means `MusicPosterCard` needs a `style` parameter: `.square` for albums, `.circular` for artists
- When an artist is selected/tapped, it should push into an artist detail page showing their albums
