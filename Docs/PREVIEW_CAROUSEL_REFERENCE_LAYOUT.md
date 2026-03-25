# Preview Carousel Reference Layout

Pixel-level description of the Apple TV+ preview carousel in its **settled/focused state** (metadata visible, not paging). Derived from a photograph of the TV+ app running on an Apple TV 4K displaying "Imperfect Women."

This is the target layout for Rivulet's `PreviewOverlayHost` carousel state.

> **Note**: Measurements are approximate — the source is a photo of a TV, not a screenshot. Percentages are relative to the 1920×1080 point canvas.

---

## Card Geometry

| Property | Apple TV+ | Notes |
|----------|-----------|-------|
| Top inset | ~50–55pt | Space between screen top edge and card top edge |
| Horizontal inset (card edge to screen edge) | ~80–90pt | The card is very wide, nearly full screen |
| Bottom edge | Extends below screen | Bottom corners are never visible |
| Top corner radius | ~24–28pt | Continuous (`.continuous` style) |
| Side card gap | ~10–14pt | Narrow gap; neighbor cards peek ~40–60pt of visible width |
| Side card appearance | Same height, same top alignment | Just the artwork, no metadata |

## Background (Behind Cards)

- The area visible around the card edges (top strip, left/right strips) is the **system translucent material** — a frosted-glass blur of whatever is behind the overlay (the home screen).
- It is NOT the poster image, NOT solid black, NOT a colored tint.
- The material reads as a neutral dark translucent wash.

## Backdrop Image (Inside Card)

- The show's hero artwork fills the entire card from edge to edge.
- The image is **aspect-fill** with no visible letterboxing or pillarboxing.
- The image has a strong **bottom-half gradient darkening**: the top ~45% of the card is relatively unobstructed artwork; the bottom ~55% progressively darkens to near-black at the very bottom.
- The darkening is smooth and gradual — no hard line. It reads as a single continuous vignette, not a layered stack of gradients.
- There is also a subtle **radial vignette** that darkens the edges/corners, keeping the center of the artwork brightest.

## Metadata Block — Left Column

All metadata anchors to the **lower-left** of the card. The left edge of all text content aligns to a single vertical line.

### Horizontal Inset (Metadata Left Edge to Card Left Edge)

- **~100–110pt** — this is significantly more than the card's own horizontal inset from the screen. The metadata text starts roughly **8–9% of screen width** from the card's left border.
- In Rivulet terms: if the card starts at x≈90 and the metadata starts at x≈200 on screen, the metadata inset within the card is ~110pt.

### Vertical Stack (Bottom to Top)

Listed from the **bottom of the visible area upward**:

1. **Action Buttons Row** (bottommost)
   - Two pill-shaped buttons ("Accept Free Trial", "Play Free Episode") + two circle icon buttons (+, bookmark)
   - Pill buttons: ~58pt tall, rounded-capsule shape, semi-transparent glass/material fill
   - Circle buttons: ~58pt diameter, same material treatment
   - Buttons sit on a shared horizontal baseline
   - Below the first button: a small caption ("7 days free, then $12.99/month.") in ~caption2 font, white at ~60% opacity
   - The button row bottom edge is approximately **~140–160pt from the screen bottom** (well above the episode shelf peek)

2. **Quality/Info Badge Row** (~20–24pt above buttons)
   - "2026 · 47 min" in caption text — year and duration separated by centered dot "·"
   - Then inline badge pills: age rating icon, "15+", "4K", "Dolby Vision", "Dolby Atmos", "CC", "SDH", "AD"
   - Badges are small inline pills (~22pt tall) with thin borders, tightly spaced
   - All on one horizontal line

3. **Description Text** (~12–16pt above badge row)
   - 3 lines max of body/caption text, white at ~85% opacity
   - Line length limited to roughly **left 55–60% of the card width** (~520–560pt max)
   - The text does NOT span the full card width

4. **Genre/Type Row** (~10–12pt above description)
   - Apple TV+ icon · "TV Show · Thriller · Mystery" · [TV-MA] bordered badge
   - Items separated by centered dot "·" characters (not bullet, not dash)
   - Content rating badge sits at end, bordered pill style, no dot before it
   - Caption-sized text, white at ~85%

5. **Title Treatment / Logo** (~16–20pt above genre row)
   - Large white title text or TMDB logo image: "IMPERFECT WOMEN", "MONARCH LEGACY OF MONSTERS"
   - Title is the **largest visual element** in the metadata — roughly 50–60pt equivalent font weight
   - Max width ~520pt, wraps to 2 lines if needed
   - Bottom-aligned within its slot (if the logo is short, it sits at the bottom of the reserved space)

6. **"New" Badge** (~12pt above title)
   - Small pill badge with "New" text
   - Semi-transparent background, ~28pt tall
   - Only present for new/recently added content

### Total Metadata Block Height

From the top of the "New" badge to the bottom of the button caption: roughly **~420–450pt**. The metadata block occupies approximately the bottom 40% of the card.

## Starring Text — Right Column

- **"Starring Elisabeth Moss, Kerry Washington, Kate Mara"**
- Anchored to the **lower-right** of the card
- Right edge of text is inset **~100–110pt from the card's right edge** (mirrors the left metadata inset)
- Vertically aligned with the **action buttons row** — sits on the same baseline as the buttons
- Max width ~350–400pt, right-aligned, wraps to 2–3 lines
- Caption font, white at ~85% opacity
- The starring text does NOT extend to the center of the card — there's a clear gap between the left metadata column and the right starring column

## Shelf Peek (Below Card)

- Below the card's bottom edge, a row of episode/content thumbnails is partially visible
- Only the top ~60–80pt of the thumbnails shows (the "peek")
- The thumbnails sit on the main screen background (translucent material), not inside the card

## Starring Cast Count

Apple TV+ shows **3 actors** in the starring line, not 5. This keeps the text concise and avoids truncation at the card boundary. Example: "Starring Kurt Russell, Wyatt Russell, Anna Sawai" — clean two-line display.

## Bottom Gradient Detail

The gradient is aggressive — it covers the bottom **~60–65%** of the card height. The progression:
- Top of gradient: fully transparent
- ~15% into gradient: already ~35% black opacity
- ~35% into gradient: ~70% black opacity
- ~55% into gradient: ~88% black opacity
- Bottom: ~95% black

This creates a very dark lower zone where all text sits, ensuring legibility even over bright artwork. The upper ~40% of the card shows the artwork with minimal darkening (only the radial edge vignette).

## Key Differences from Current Rivulet

| Aspect | Apple TV+ | Rivulet (current) |
|--------|-----------|-------------------|
| Metadata horizontal inset | ~100–110pt from card edge | ~~60pt~~ Fixed to 110pt |
| Starring text max width | ~350–400pt (3 actors) | ~~700pt~~ Fixed to 380pt, 3 actors |
| Bottom gradient | Strong, covers bottom ~65%, 95% black at bottom | ~~Weaker, 55% coverage~~ Fixed to 65%, stronger stops |
| Background behind cards | Translucent material | ~~Poster image~~ Fixed to `.ultraThinMaterial` |
| Description line width | ~520–560pt | ~~760pt max~~ Fixed to 560pt |
| Title font size | ~50–60pt equivalent | ~~44pt~~ Fixed to 52pt |
| Genre row separators | Centered dot "·" between items | ~~No separators~~ Fixed with "·" dots |
| Genre row type label | "TV Show" | ~~"Series"~~ Fixed to "TV Show" |
| Quality row separators | "2023 · 49 min" with dot | ~~No separator~~ Fixed with "·" |
| Row spacing | ~12–16pt between rows | ~~10pt~~ Fixed to 14pt |
| Description line limit | 3 lines max | ~~4 lines~~ Fixed to 3 lines |
