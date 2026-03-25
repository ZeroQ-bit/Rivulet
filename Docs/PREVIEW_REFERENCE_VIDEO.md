# Apple TV+ Preview Fidelity Spec (Canonical)

This is the single source of truth for matching the Apple TV+ preview carousel and hero/detail flow.
If implementation behavior conflicts with this file, this file wins.

## Goal

Match Apple TV+ behavior as closely as practical in:

- motion timing and easing
- spatial composition and anchoring
- visual style and surface treatment
- focus/input behavior
- state transitions (carousel -> expanded hero -> details fold -> return)

## Reference Inputs

- Apple reference clip: `/Users/bain/Downloads/IMG_4941.MOV`
- Current app capture: `/Users/bain/Desktop/Simulator Screen Recording - Apple TV 4K (3rd generation) - 2026-03-24 at 19.42.45.mov`
- Paging-only current capture: `/Users/bain/Desktop/Simulator Screen Recording - Apple TV 4K (3rd generation) - 2026-03-25 at 07.10.26.mov`
- Apple clip metadata: `1920x1080`, `30fps`, `24.463s`
- Current clip metadata: `3840x2160` source, normalized to `1920x1080 @ 30fps`, `19.332s`
- Manual holds in the Apple clip are user pauses and must be ignored for timing.

## What The Apple Clip Is Doing (End-To-End)

## 1. Entry (home row to preview ownership)

- Selected poster morphs to a dominant centered card.
- Sidebar/home context visually recedes; preview owns the stage.
- No metadata on initial movement.
- Card settles first, then overlay elements appear.

## 2. Carousel stable (focused item)

- Center card is dominant and tall, with top corners visible and rounded.
- Side cards are adjacent siblings (no stacking/overlap reads).
- Focused metadata is present on the center card only.
- Buttons are present with metadata (not gated to expanded-only).

## 3. Carousel paging (left/right)

- Card translation is smooth and longer than a short snap.
- Metadata fades out before/at motion start.
- New item metadata fades in after settle.
- Backdrop inside the selected card exhibits lag/parallax:
  - starts offset opposite travel direction
  - moves on its own track
  - still stays attached to selected card geometry
  - lands at the same end beat as the card

## 4. Expanded hero

- Same visual card/hero composition continues.
- No hard route push.
- Metadata and buttons already exist; reveal is mostly opacity, not slide.
- Episode shelf from below-fold context peeks at bottom.

## 5. Details fold

- One continuous vertical move into detail content.
- Same backdrop persists with stronger dim/blur.
- Centered title/logo appears above shelves in folded state.
- On return upward, centered header fades out before fold ends.

## Motion Spec (Target)

| Motion | Target | Notes |
|---|---:|---|
| Entry morph | `~0.45s` | spring/ease-out, no bounce |
| Carousel page (card frame) | `~0.72s - 0.82s` | long ease-in/out, no snap read |
| Backdrop lag start delay | `0s` (already offset at page start) | backdrop begins from offset inside card |
| Backdrop lag travel | same total page duration | separate curve, same stop beat as card |
| Metadata fade-out on page start | `~0.10s - 0.16s` | near-immediate |
| Metadata fade-in after settle | `~0.24s - 0.42s` | opacity-only, no lateral/vertical travel |
| Expand to hero | `~0.35s` | single continuity move |
| Expand chrome stagger | `0.16s` delay + `0.22s` text + `0.06s` controls | fade-in-place |
| Fold to details | `~0.35s` | one vertical continuity move |
| Backdrop upgrade crossfade | `~0.22s` | opacity-only, post-settle only |

## Parallax Model (Required)

- The selected card owns visible backdrop + overlays during carousel.
- Parallax is implemented as internal backdrop image lag inside each carousel card.
- Do not detach active backdrop to a separate stage layer during paging.
- Do not run backdrop on the exact same transform curve as the card frame.
- Card and backdrop must finish together.
- Offset should be noticeable but subtle (image does not look detached).
- The image must not teleport when paging starts; offset is continuous from frame 0.

## Carousel Composition Model (Required)

- During `.carouselStable`, all visible cards render through the same card surface path.
- A card becoming centered must not switch from a different art surface type mid-travel.
- Each card's backdrop image is wider than its mask (`~115% - 125%` of card width).
- The card mask clips overflow; no background resize during paging.
- Inner parallax is driven from continuous page progress, not step state changes:
  - `cardX = lerp(fromIndexX, toIndexX, progress)`
  - `imageX = cardX * parallaxFactor` where `parallaxFactor` is typically `0.35 - 0.55`
  - equivalent counter-offset form is acceptable as long as it is continuous and monotonic
- Expanded transition reveals more of the same already-sized image; no scale jump at expand start.

## Geometry & Layout

All values are for 1920x1080 reference canvas and should scale proportionally.

## Carousel Card Geometry

- Top inset: `~50-55`
- Horizontal inset: `~80-90` each side
- Side gap: `~10-14`
- Top corner radius: `~24-28`, continuous
- Bottom edge extends below viewport; bottom corners should not read in carousel stable
- Carousel cards must remain on a single visual z-plane while paging (no selected-card over/under pass).

## Overlay Anchors

- Left metadata column anchored bottom-left with fixed slots.
- Right cast/starring block anchored bottom-right on same baseline as actions.
- Description max width constrained (does not span full card).
- Title/logo slot fixed height so rows below do not jump when source swaps.
- Action row baseline stable across logo/title/source changes.

## Below-Fold Peek

- The real below-fold shelf must peek in expanded hero.
- Peek depth should show upper portion of thumbnails only.
- This is not a synthetic/non-interactive fake strip.

## Visual Style Spec

## Color / Contrast / Layering

- Backdrop is dominant image-led surface.
- Left and bottom gradients provide readability, with stronger darkening in lower zone.
- Text mostly white/near-white, high contrast.
- Details fold applies heavier dim/blur over same art.

## Typography

- Title/logo is the largest left-column element.
- Metadata rows use compact caption/body styles.
- Dot separators are centered `·`, not dashes.
- Cast line is concise and right-aligned.

## Buttons and Chips

- Primary actions are pill-shaped, glass/material look.
- Secondary circular icon actions match same visual system.
- Quality/rating badges are compact inline pills.
- Action row appears with metadata state, not only after expansion.

## Content/Logic Rules

- Focused item metadata appears only for centered card.
- Metadata reveal is opacity-only in-place.
- No duplicate selected-card artwork layers at once.
- No mid-motion artwork replacement.
- Single-season behavior:
  - if only one season, keep season-pill pattern with one pill
  - do not show `Episodes` heading in that case
- Season entities in recently-added rails should normalize into same overlay structure as episode/show hero style.
- Keep unwanted `Show` action removed where not part of Apple-style target behavior.

## Asset Resolution Rules

- One chosen displayed backdrop per active motion phase.
- Better backdrop replacement allowed only after motion is stable (`>=150ms`).
- Live replacement must be fixed-geometry opacity crossfade only.
- If framing/crop would materially change, defer replacement to next page/session.
- Current simplification: keep Plex default backdrop stable unless upgrade policy is explicitly re-enabled with safeguards.

## Focus / Input Rules

- During carousel stable: left/right pages, down/select expands.
- During expanded/detail: focus ownership transfers to detail content.
- Menu from detail:
  1. pop internal nested level if present
  2. otherwise collapse to carousel
  3. next menu dismisses overlay
- Sidebar/home focus cannot leak while preview owns stage.

## Current Gap Snapshot (From 2026-03-24 Capture)

- Paging feel improved but still drifts when easing becomes too short.
- Parallax readability regresses when backdrop and card are coupled too tightly.
- Metadata can appear too eager in some transitions; must stay settle-gated.
- Overlay margin and title/logo scale still need strict lock to avoid near-edge clipping on some assets.

## Paging Calibration Update (2026-03-25 Capture)

- New paging-only capture confirms prior tuning still felt too fast and mid-clustered.
- Target was adjusted to a slower full transition window with stronger ease-in/ease-out.
- Required parallax behavior for this implementation cycle:
  - backdrop offset is continuous from first frame (no hard jump)
  - backdrop follows a slower inner-parallax curve while remaining card-attached
  - backdrop and card must end on the same frame/beat
  - no backdrop scale pop or size shift at settle

## Do Not Do This

- Do not stack/overlap carousel siblings behind selected card.
- Do not elevate selected card z-order during carousel paging; all carousel items must move inline on the same z level.
- Do not detach active backdrop into a full-stage independent surface while paging.
- Do not hard-set per-page backdrop offset (single-frame jump) before running animation.
- Do not switch incoming centered card from side-art path to hero-art path mid-motion.
- Do not animate metadata with slide offsets when revealing.
- Do not mount selected hero as both side-card art and hero art simultaneously.
- Do not relayout overlay when logo/title/source changes.
- Do not show season pills at top state if scroll-gated behavior is expected.
- Do not reintroduce `Episodes` title for single-season case.
- Do not live-swap backdrop during motion.

## Acceptance Checklist (Ship Gate)

Every item must pass in side-by-side playback against `IMG_4941.MOV`.

1. Entry morph reads as one smooth ownership transfer.
2. Carousel siblings are side-by-side, not stacked.
3. Focused metadata is center-card only.
4. Metadata appears after settle, not during main card travel.
5. Metadata reveal is fade-in-place only.
6. Buttons appear with focused info state.
7. Card paging has long ease-in and ease-out (no snap read).
8. Backdrop lag is visible and opposite-direction at page start.
9. Backdrop remains attached to selected card geometry while lagging.
10. Card and backdrop end at same stop beat.
11. No backdrop size pop at settle.
12. No text/logo clipping during page/expand/fold.
13. Expanded hero maintains continuity from carousel.
14. Below-fold shelf peek is real, not fake.
15. Details fold is one continuous vertical move.
16. Return-to-top fades centered header out early.
17. Single-season show does not show `Episodes` heading.
18. Season pill behavior matches scroll-gated expectation.
19. No duplicate artwork layers visible during any phase.
20. No mid-motion backdrop swap.
21. Carousel paging has no over/under pass; cards stay on one z plane.
22. No first-frame backdrop teleport on page-out/page-in.
23. Incoming card art remains attached and slides in with the card.
24. Expand transition has no backdrop resize pop.

## Workflow For Future Changes

1. Capture current app video first.
2. Compare against Apple reference in frame strips.
   Always verify z-plane behavior in strips: selected card must not pass over/under siblings during paging.
3. Update this spec before coding if any new visual truth is discovered.
4. Implement changes against this file only.
5. Re-record and verify all checklist items.

## Scope Boundary

This file governs preview carousel + expanded hero + details fold behavior and shared hero/backdrop policy for those surfaces. It is not a full global style guide for every screen in the app.
