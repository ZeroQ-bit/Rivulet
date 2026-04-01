# Apple Music tvOS — Now Playing View Analysis

Photo of TV screen showing the Now Playing screen for "The Original" by Switchfoot from the album "Vice Re-Verses".

## Overall Layout

Full-screen view. Everything is centered. The background is a warm-toned blur derived from the album art colors.

### Vertical stacking (top to bottom):
1. Album name (top center)
2. Large album art (centered)
3. Track title with playing indicator
4. Artist name
5. (large gap)
6. Progress bar
7. Bottom bar with Info button and action icons

## Background

- Full-screen blurred and color-extracted from the album art
- The dominant colors from "Vice Re-Verses" artwork create a warm olive/golden tone
- This is NOT just a simple gaussian blur of the art — it appears to be a color extraction that fills the screen with the artwork's dominant colors, heavily blurred and dimmed
- Slightly darker at the edges (vignette effect)

## Top — Album Name

- **"Vice Re-Verses"** — centered, approximately 20-22pt, regular weight, white
- Position: approximately 40-50pt from top safe area edge
- This is the ALBUM name, not the track name

## Center — Album Art

- **Large square**, approximately 320-360pt per side
- Horizontally and vertically centered in the upper-center area of the screen (not dead-center of screen — shifted slightly upward)
- **Corner radius**: approximately 8-10pt
- **Shadow**: subtle drop shadow
- Gap from album name to art top: approximately 16-20pt

## Below Art — Track Info

- **Track title**: "The Original (JT Daly of Paper Rou..." — approximately 20-22pt, medium weight, white, truncated with ellipsis
- The track title has a **small playing indicator** (animated bars icon, ~12pt) to the LEFT of the title text, inline
- **Artist name**: "Switchfoot" — approximately 16-18pt, regular weight, secondary gray
- Gap from art bottom to track title: approximately 12-16pt
- Gap from track title to artist: approximately 4pt
- Both lines are center-aligned

## Right Side — Action Buttons

Two rows of buttons on the right side of the screen:

### Upper-right buttons (vertically aligned with track info area):
- **Star/favorite** — circular button, ~40pt diameter, translucent gray/glassy background, star outline icon
- **"•••" (more)** — circular button, same style, three-dot ellipsis icon
- These are positioned at the right edge, approximately 60pt from right screen edge
- Vertical gap between them: ~12pt

### Lower-right buttons (at the very bottom-right):
- **Pin/thumbtack icon** — small circular button, ~36pt
- **Speech bubble/lyrics icon** — small circular button, ~36pt
- **List/queue icon** — small circular button, ~36pt
- These are horizontally arranged with ~12pt gaps
- Positioned at the bottom-right, aligned vertically with the progress bar area

## Progress Bar

- **Thin line** — approximately 2-3pt height, spanning most of the screen width
- **Position**: near bottom, approximately 60-70pt from bottom safe area
- **Fill**: white filled portion (elapsed), translucent gray (remaining)
- **Time labels**:
  - Left: "0:04" — small text, ~14pt, monospaced, white
  - Right: "-3:54" — small text, ~14pt, monospaced, white (negative = remaining)
- The progress bar appears to be a simple geometric shape, not a system slider
- Gap between progress bar and time labels: ~4pt (labels are directly below the bar, or alongside it)

## Bottom-Left — Info Button

- **"Info"** — pill-shaped button, translucent background, ~70pt wide, ~36pt tall
- White text, approximately 16pt
- Positioned at bottom-left, approximately 60pt from left edge
- Vertically aligned with the progress bar area

## Key Measurements (estimated at 1920x1080)

| Element | Value |
|---------|-------|
| Album name top margin | ~45pt |
| Album name font | ~21pt regular |
| Art width/height | ~340pt |
| Art corner radius | ~8pt |
| Art to track title gap | ~14pt |
| Track title font | ~21pt medium |
| Artist font | ~17pt regular, gray |
| Track-to-artist gap | ~4pt |
| Progress bar Y from bottom | ~65pt |
| Progress bar height | ~2pt |
| Progress bar horizontal margins | ~50pt each side |
| Time label font | ~14pt monospaced |
| Info button | ~70x36pt pill |
| Star/more buttons | ~40pt circle |
| Bottom-right buttons | ~36pt circle |
| Button gap | ~12pt |

## Key Implementation Notes

- The background color extraction is important — it's NOT a blurred version of the artwork image, it's the dominant colors expanded to fill the screen
- No transport controls (play/pause/next/prev) are visible by default — they only appear on interaction
- The playing indicator bars are INLINE with the track title text, not separate
- The progress bar is at the bottom of the screen, NOT in the middle
- The "Info" button is a tvOS standard pill button at bottom-left
- This is presented as a fullScreenCover (it takes over the entire screen, no sidebar)
- Menu button dismisses back to whatever was showing before
