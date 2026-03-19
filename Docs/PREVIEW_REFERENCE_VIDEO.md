# Apple TV Preview Reference Video Notes

This document is the canonical visual and motion reference for the hub-row preview flow. It describes the target experience, not the current implementation.

Use this before changing the preview carousel, expanded hero, details fold, or backdrop-upgrade behavior. `Docs/PREVIEW_CARD_CAROUSEL.md` remains the implementation-history/status doc; this file is the fidelity spec.

## Source

- Primary reference: `/Users/bain/Downloads/IMG_4941.MOV`
- Clip metadata: `1920x1080`, `30 fps`, `24.46s`
- Analysis method: manual review plus still extraction across the first `0-7s` entry/paging segment and the later `10-17s` details segment
- Important note: the long holds/swells in the clip are manual pauses from the user and must not be treated as animation dwell time

## Core Phase Model

Future agents should model the preview flow as these distinct states:

1. `Home row`
2. `Poster selected`
3. `Carousel with focused metadata`
4. `Expanded hero card`
5. `Details fold`
6. `Paged hero / repeated cycle`

This clip shows more than one title transition, so do not treat it as a single straight-line “home -> detail” example.

## Timing Targets

These are implementation targets derived from the clip’s continuous motion, not the user’s pauses.

| Motion | Target |
|--------|--------|
| Poster morph to centered card | `~0.45s`, spring/ease-out, no bounce |
| Carousel paging | the reference handoff reads closer to roughly `12-14 frames` at `30 fps` from first drift to full stop (`~0.40s - 0.47s`), and the current Rivulet capture in `IMG_4951.MOV` is still visibly faster at about `5-6` obvious transition frames; most of the reference travel happens in the middle, with a noticeably longer ease-in and ease-out than a short spring |
| Focused-card metadata after settle | `~0.18s - 0.28s` opacity-only fade once centered motion finishes; page-to-page reveals can be slightly slower than initial entry |
| Background art during paging | delayed by about `~0.08s`, then settles over roughly `~0.38s`; stays attached to the selected card, starts from a larger opposite-direction offset, and lands at the same time as the card |
| Actions + cast reveal after focused info loads | present with the focused metadata state and fade in-place with the title/meta; expand mainly unlocks deeper continuity into details |
| Expanded hero to details fold | `~0.35s`, one continuous vertical move |
| Backdrop quality upgrade | only after `>=150ms` stable, `~0.22s` opacity crossfade |

## Observed Sequence

### 1. Home to Carousel

- The selected poster scales into a dominant centered card very quickly.
- The browse surface visually recedes and stops reading as the active stage.
- Once the centered item settles, its title/meta information fades in.
- The centered card keeps top-only rounded corners and extends below the visible bottom edge.
- Side neighbors sit beside the centered card rather than stacking behind it.
- The centered card remains dominant, but the neighboring cards should read as separate side-by-side surfaces.

### 2. Carousel Paging

- The user can page laterally while staying in the same carousel stage.
- The next item takes over the same dominant centered stage.
- Its metadata fades back in once the new item reaches focus.
- The card does not snap across in a quick `~0.3s` move; it starts gently, covers most of the distance through the middle of the span, then eases noticeably into the stop.
- The background art handoff is layered: it lags slightly and fades on a different cadence than the card frame movement.
- The selected backdrop image should read as a stage-owned layer behind the carousel, while the selected card still owns the metadata/logo/action layout that sits on top of that backdrop.
- Drive the selected hero backdrop on the stage layer behind the moving card so it can lag and scale independently without shrinking/clipping inside the card.
- Keep the moving carousel overlay on one consistent card/window surface during the lateral handoff, and keep the metadata/logo attached to that card overlay rather than the stage so positioning stays correct.
- The stage remains calm and image-led between lateral moves, with focused metadata only after settle.

### 3. Expanded Hero

- A second user interaction unlocks the expanded chrome over the same card.
- The card silhouette stays the same rounded-top stage; this is not a hard cut to a different page.
- Title/logo, metadata rows, and summary are already present from carousel focus.
- Buttons and cast treatment are already present with the focused info state.
- The title/logo block and the action row fade in where they live; they do not slide up or laterally on reveal.
- Expanded mode mainly deepens the connection to the fold and the below-fold content.
- The left column sits in the lower-left quadrant.
- Cast/starring text anchors in the lower-right quadrant.
- A teaser of the real below-fold shelves remains visible at the bottom edge.
- The shelf tease should be shallow; only the upper portion of the episode thumbnails should show before scroll.
- For shows, the same episode shelf the user will scroll into should be the one peeking into the expanded hero.

### 4. Details Fold

- A further user interaction moves the composition downward into the details content.
- The move reads as one continuous vertical fold, not a route push or page replacement.
- The same show art remains behind the details surface with heavier blur/dimming.
- The details state introduces a centered title/logo at the top, then shelves/rows below.
- On the way back up, that centered title/logo should fade away before the reverse fold fully finishes.
- Episode/trailer rows feel attached below the hero rather than injected over a blank background.

## Layout Rules

### Stage Ownership

- Once preview starts, it owns the full stage.
- The tvOS sidebar must not remain visually active or focusable.
- The preview should not feel like a floating overlay above live browse content.

### Carousel Geometry

- The centered card is large, high, and visually dominant.
- Only the top corners should be clearly visible and rounded.
- The bottom corners should not read as exposed in the settled carousel state.
- Side cards should share the same top alignment as the centered card.
- Side cards should sit next to the centered card with a clear gap, not overlap it.
- The visible portions of the neighboring cards can be narrow, but they must still read as separate adjacent cards rather than stacked layers.

### Expanded Hero Layout

- The same image remains the dominant background.
- Metadata anchors lower-left with fixed boxes so title/logo swaps do not move the rest of the overlay.
- Buttons sit on a stable lower-left baseline.
- Cast/starring anchors lower-right on the same baseline.
- Focused title/logo and action buttons should reveal via opacity only; keep their geometry fixed during the reveal.
- Summary and badges should not cause the entire overlay to jump vertically.
- The action row should sit slightly lower, with clearer separation from the summary block above it.

### Details Layout

- Keep the same art and palette behind the fold.
- Center the title/logo above the details shelves.
- Do not reserve that centered-header space before scroll; the first shelf should be able to peek naturally at rest.
- Season/episode/trailer rows should feel physically attached under the hero.
- For single-season shows, keep the season-pill pattern with one pill instead of replacing it with an `Episodes` title block, including on season-detail surfaces.
- Keep season pills visually hidden until the user actually scrolls into the below-fold shelf.
- Once settled, details should be mostly static outside of focus effects.

## Artwork Upgrade Policy

Apple TV+ in this clip sometimes updates the active backdrop after the motion settles. That is allowed here, but only under these rules:

- Choose one visible hero backdrop for the active motion phase.
- Do not swap the visible backdrop during poster morph, paging, expand, or fold motion.
- If a higher-quality backdrop becomes available after settle, update with a fixed-geometry opacity crossfade only.
- The crossfade must not resize, reframe, or expose two differently cropped hero images at once.
- If the replacement would materially change crop/framing, defer it until the next page or next session instead of swapping live.
- The same policy applies to preview, standard detail hero, and other hero/loading surfaces that share this backdrop logic.
- Current Rivulet simplification: live backdrop replacement is disabled for now; keep Plex-provided art in place until this behavior is intentionally revisited.

## Motion Constraints

- Do not reveal metadata at the same instant the poster begins scaling.
- Do not keep the selected card mounted as both a side-card art layer and a hero/detail art layer at the same time.
- Do not introduce a second background image during expand or fold.
- Do not let the expanded hero snap to a zero-radius full-screen page before the details fold.
- Do not crossfade to a better backdrop while geometry is still moving.
- Do not drive the backdrop on the exact same timing/value track as the card frame during paging; the card should lead and the internal backdrop image should trail.
- Do not detach the active backdrop into a separate stage layer during carousel paging; the parallax should come from the image lag inside the selected card.
- Do not let the details state feel like a route push to a different page.
- Do not show wide gaps that make the side cards look like equal siblings.
- Do not overlap or stack neighboring carousel cards behind the centered card.
- Do not leave the sidebar focusable once preview owns the stage.

## Styling Notes

- Title/logo should be bright, high-contrast, large, and given a slightly more generous slot than the current Rivulet default.
- Metadata text is white or near-white over darkened art.
- Action buttons are pill-shaped with soft material/glass treatment.
- Quality/rating badges are compact inline pills.
- Details use stronger blur/dim treatment than the expanded hero, but the same underlying art.

## Practical Comparison Anchors

These are the most useful checkpoints when comparing Rivulet footage against the clip.

- `0.0s - 2.0s`: browse row -> poster morph -> art-only carousel
- `3.5s - 5.5s`: lateral item change followed by metadata-rich expanded hero
- `10.0s - 12.0s`: stable expanded hero composition over the same background
- `12.5s - 13.5s`: centered top title/logo plus details shelves after the vertical fold

## Future Agent Workflow

1. Read this file first.
2. Compare current footage against `IMG_4941.MOV`.
3. Fix stage ownership first: sidebar, focus fencing, background continuity.
4. Fix geometry second: card size, top-only radius, peeks, bottom-edge continuity.
5. Fix animation ordering third: morph, then expand chrome, then fold.
6. Fix backdrop upgrade behavior last: only post-settle, crossfade-only, no crop jump.

## Scope Boundary

This reference is for the hub-row preview flow and the shared hero/backdrop behavior it depends on. It is not a generic spec for every detail screen layout in the app.
