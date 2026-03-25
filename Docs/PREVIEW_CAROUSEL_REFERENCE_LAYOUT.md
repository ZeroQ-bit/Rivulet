# Preview Carousel Layout Tokens (Companion)

This is a compact implementation-token companion to `Docs/PREVIEW_REFERENCE_VIDEO.md`.
Use this for constants and anchor math only. For behavior and sequencing, defer to the canonical spec.

## Canvas

- Reference canvas: `1920x1080`
- Scale all point values proportionally on other resolutions.

## Card Shell

| Token | Target |
|---|---:|
| `cardTopInset` | `50-55` |
| `cardHorizontalInset` | `80-90` |
| `cardCornerRadiusTop` | `24-28` |
| `cardGapSide` | `10-14` |
| `cardBottomOverflow` | bottom extends past viewport |

## Overlay Anchors

| Token | Target |
|---|---:|
| `metadataLeftInsetInCard` | `100-115` |
| `metadataRightInsetInCard` | `100-115` |
| `titleSlotMaxWidth` | `520-620` |
| `titleSlotHeight` | `120-132` |
| `descriptionMaxWidth` | `520-560` |
| `castBlockMaxWidth` | `380-460` |
| `metadataBlockHeight` | `~420` |
| `actionRowTopPadding` | `24-30` |

## Shelf Peek

| Token | Target |
|---|---:|
| `heroShelfPeekTV` | shallow; only top portion of thumbs visible |
| `heroShelfPeekMovie` | deeper than TV but still partial |

## Timing Tokens

| Token | Target |
|---|---:|
| `entryMorphDuration` | `~0.45s` |
| `pageCardDuration` | `~0.52-0.60s` |
| `pageBackdropDelay` | `~0.07-0.10s` |
| `pageBackdropDuration` | `~0.42-0.50s` |
| `metadataRevealDuration` | `~0.24-0.42s` |
| `expandDuration` | `~0.35s` |
| `detailFoldDuration` | `~0.35s` |

## Style Tokens

| Token | Target |
|---|---|
| `textColorPrimary` | white / near-white |
| `textColorSecondary` | white with reduced opacity |
| `gradientBottomCoverage` | lower-heavy, strong readability |
| `actionPillStyle` | soft material/glass look |
| `qualityBadgeStyle` | compact inline capsule |
| `separatorGlyph` | centered `·` |

## Invariants

- Center card owns visible metadata.
- Side cards are artwork-only.
- Parallax is internal selected-card backdrop lag.
- Metadata reveal is fade-only in-place.
- Single-season cases use one season pill and no `Episodes` heading.

## Anti-Tokens (Never)

- No stacked/overlapped side cards.
- No detached full-stage active backdrop during paging.
- No slide-in title/button reveals.
- No relayout jumps when logo/title source changes.
