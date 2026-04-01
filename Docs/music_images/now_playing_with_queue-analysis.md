# Apple Music tvOS — Now Playing with Queue Analysis

Photo of TV screen showing the Now Playing screen with the queue/carousel visible.

## What Changed from Default Now Playing

The queue carousel has been activated (likely by pressing the queue button at bottom-right, or swiping). The layout shifts to accommodate the queue.

## Queue Carousel Layout

The album art area has transformed into a **horizontal carousel of album art cards**:

### Current Track (left, larger)
- The currently playing track's album art is on the **left side** of the carousel
- Size: approximately the same as the default Now Playing art (~300-320pt)
- Below it: track title with playing indicator bars + artist name (same as default)
- This card has the "current" treatment — full size, sharp

### Next Track (right)
- The next track's album art appears to the **right** of the current track
- Size: approximately the same size as the current track — NOT smaller
- Below it: track title + artist name
- Gap between current and next card: approximately 30-40pt

### Further Tracks (peeking)
- A third track's album art is partially visible at the right edge ("Blindin..." text visible)
- This creates the carousel scrolling effect — more items exist to the right

### Key Observation
- The current and next cards appear to be the **same size** — this is NOT a "current is bigger, next is smaller" pattern. It's a flat horizontal scroll where the current track is simply positioned first.
- The carousel appears to be a standard horizontal `ScrollView` or paging view

## Controls Row (between carousel and progress bar)

A row of circular buttons appears in the middle-right area:
- **Shuffle** — two crossing arrows icon, ~40pt circle
- **Share/repeat** — share or repeat icon, ~40pt circle
- **Star/favorite** — star outline, ~40pt circle
- **"•••" (more)** — three-dot ellipsis, ~40pt circle

These are horizontally arranged with ~12pt gaps, positioned to the right of center.

## Bottom Area (unchanged from default)

- **Progress bar**: same thin line, "0:10" left, "-3:47" right
- **Info button**: bottom-left pill
- **Bottom-right icons**: pin, lyrics, queue (same three icons)

## Album Name

- **"Vice Re-Verses"** — still at top center, same position and style as default Now Playing

## Background

- Same color-extracted/blurred background from album art
- Warm golden/olive tones from the Switchfoot artwork

## Key Measurements

| Element | Value |
|---------|-------|
| Carousel card size | ~300x300pt each |
| Card gap | ~35pt |
| Cards visible | 2 full + 1 peeking |
| Control buttons | ~40pt circles |
| Control button gap | ~12pt |
| Control row position | Below carousel, above progress bar |

## Key Implementation Notes

- The queue is a **horizontal ScrollView** with album art cards, NOT a list
- Current track and next tracks are the SAME SIZE — no scale difference
- The playing indicator bars appear inline with the current track's title
- When queue is shown, the controls (shuffle, star, more) appear in a row between the carousel and progress bar — they were hidden in default Now Playing
- The transition between "default" (single centered art) and "queue" (carousel) should be animated
- Swiping left/right in the carousel moves between tracks
- Pressing select on a queue item jumps to that track
- This appears to be triggered by pressing the queue/list button at bottom-right
