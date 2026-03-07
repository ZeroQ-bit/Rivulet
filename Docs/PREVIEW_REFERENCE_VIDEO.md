# Apple TV Preview Reference Video Notes

This document captures the visual target from the sample clip, not the current Rivulet implementation.

Use this as the source-of-truth reference for future preview-flow iterations. `Docs/PREVIEW_CARD_CAROUSEL.md` describes implementation history/status. This file describes what the target experience should look like.

## Source

- Primary reference: `/Users/bain/Downloads/IMG_4815.MOV`
- Supplemental references: the still images provided with the same request
- Clip metadata: `1920x1080`, `30 fps`, `7.13s`
- Analysis method: manual review plus still extraction at `0.5s` and `0.25s` intervals

## Confidence Levels

- `Observed`: directly visible in the sample clip
- `User clarified`: explicitly provided by the user to disambiguate interactions that are not fully recoverable from the clip alone
- `Inferred`: not directly shown end-to-end in the clip, but consistent with the clip, the still images, and the user description

## Primary Phase Model

This is the corrected high-level phase sequence for the sample:

1. `Home screen`
2. `Poster selected`
3. `Poster expands into carousel view`
4. `Carousel expands on user interaction`
5. `Details view opens on user interaction`

Future agents should use this sequence instead of collapsing the clip into only "entry" and "details".

## Timeline

| Time | State | Notes |
|------|-------|-------|
| `0.0s` | Home row | Focus is on a landscape poster inside a standard browse row. No preview is active. |
| `0.0s` | Poster selected | `User clarified`: the transition begins because the user selects the poster. |
| `0.0s - 0.9s` | Poster to carousel | The selected poster rapidly grows into a dominant centered card. The browse surface recedes and the sidebar no longer reads as part of the interactive stage. |
| `0.9s - 2.5s` | Carousel settled | `Observed`: the carousel state is image-led. The centered card has rounded top corners, no visible bottom corners, and narrow neighboring cards visible at left and right. No metadata chrome is present yet. |
| `~2.5s` | Carousel expand input | `User clarified`: the next transition is triggered by another user interaction, not by passive autoplay. |
| `2.5s - 5.1s` | Expanded carousel card | Metadata, actions, and cast text appear over the same dominant card. The card still reads as the same rounded-top surface rather than a new full-screen page. A teaser of below-fold content remains visible at the bottom edge. |
| `~5.1s` | Details input | `User clarified`: the move into details is triggered by another user interaction. |
| `5.1s - 5.6s` | Transition to details | The composition moves downward into the attached details content. The motion reads as continuous vertical travel from the expanded card surface. |
| `5.6s - 6.5s` | Details stable | Season tabs, episode cards, and trailer rows are visible over the same art direction with heavier dimming/blur. |

## Frame-by-Frame Notes

These are the most useful checkpoints for future agents comparing implementation footage against the target clip.

| Time | What is visible | Why it matters |
|------|------------------|----------------|
| `0.00s` | Standard browse grid with the Monarch row item focused | Starting state is a normal hub row, not a pre-expanded hero. |
| `0.25s` | Browse view still mostly intact | Entry animation has not yet completed by the first quarter second. |
| `0.50s` | The selected item is already scaling into a large landscape surface | The home-to-preview move is fast and decisive. |
| `0.75s` | Dominant rounded-top card is nearly settled | By this point the poster has become the carousel’s centered card. |
| `1.00s` | Large image-only card with thin side neighbors visible | This is the clearest sampled frame for carousel geometry: rounded top corners, no visible bottom corners, narrow left/right peeks. |
| `1.00s - 2.25s` | Carousel art only, no metadata yet | The image is allowed to breathe before user-triggered expansion. |
| `2.50s` | Transition into expanded card state is beginning | This is the handoff between carousel-only and metadata-rich expanded card. |
| `2.67s` | Full title/metadata/action layout is visible over the same rounded-top card | This is the first clear expanded-card reference frame in the sampled set. |
| `3.00s - 5.00s` | Stable expanded card | This is the reference composition for title block, badges, controls, cast text, and bottom teaser content. |
| `5.25s` | Transition frame between expanded card and details | The details content is attached below the card surface and moves upward as one continuous sheet. |
| `5.50s - 6.50s` | Stable details layout | This is the reference composition for season tabs, episode row, and trailers row. |

## Visual Rules

### Stage Ownership

- `Observed`: once preview starts, the experience owns the full content stage.
- `Observed`: the left tvOS sidebar is not part of the preview composition.
- `Observed`: the preview states read as a dedicated scene, not as a small overlay floating above still-focusable browse content.

### Carousel Card Layout

- `Observed`: the selected card is very large and centered.
- `Observed`: only the top corners are clearly visible and rounded.
- `Observed`: the bottom corners are not visible because the card continues below the bottom edge of the visible stage.
- `Observed`: the card image is the first thing the user sees after the entry motion.
- `Observed`: narrow neighboring items are visible at the far left and right edges.
- `Inferred`: adjacent cards should read as edge peeks, not as full same-size sibling cards separated by obvious horizontal gaps.
- `Inferred`: the side peeks should share the same top alignment as the centered card and feel tucked behind it.
- `Observed`: the centered card has a large rounded radius on the top edge before the next interaction.

### Expanded Card Layout

- `User clarified`: this state is triggered by a second user interaction from the carousel.
- `Observed`: the same first image remains the dominant background during the expanded state.
- `Observed`: the expanded state still reads as the same rounded-top card stage, not as a separate zero-radius full-screen page.
- `Observed`: metadata is anchored in the lower-left quadrant.
- `Observed`: the lower-right area carries cast/starring text.
- `Observed`: the bottom edge shows a teaser of the content below the fold.
- `Observed`: the expanded card is still image-led. Text and actions are layered on top, not separated into a different panel.

### Details Layout

- `User clarified`: this state is triggered by another user interaction after the expanded card state.
- `Observed`: the details state keeps the same show art behind a heavier blur/gradient treatment.
- `Observed`: a centered show title/logo appears at the top of the details state.
- `Observed`: season tabs sit below that header.
- `Observed`: the first detail row is an episode row with landscape thumbnails.
- `Observed`: the selected episode includes an attached text block under its thumbnail.
- `Observed`: trailers appear as another row below the episode row.
- `Observed`: this is not a different detail page background. It is the same scene with the fold moved upward.

## Motion Notes

### 1. Home to Carousel

- `User clarified`: this move begins when the user selects the poster.
- `Observed`: the selected poster scales up into the preview card very quickly.
- `Observed`: the transition reads as a zoom/morph into the centered stage, not a hard cut to a new screen.
- `Observed`: the card art settles before metadata appears.
- `Inferred`: the underlying rows should fade and recede during the move so the card becomes the only clear focal plane.

#### Animation Breakdown

- `Observed`: the clip reaches a mostly-settled hero image by about `0.75s`.
- `Observed`: the move has no visible hard stop, snap, or black-frame interruption.
- `Observed`: the composition moves from "many small browse items" to "one dominant hero surface" in a single motion.
- `Observed`: by the settled carousel frame, thin neighboring cards are still visible at both edges.
- `Inferred`: the motion likely uses an ease-out or spring-like settle rather than a rigid linear slide. The clip does not show a large overshoot or bounce.
- `Inferred`: the source poster should visually own the transition. The result should feel like the selected poster has grown into the carousel’s dominant center card.

### 2. Carousel to Expanded Card

- `User clarified`: this move is triggered by user interaction.
- `Observed`: the clip shows an art-only carousel state followed by a metadata-rich expanded-card state.
- `Observed`: title, badges, summary, and controls arrive after the image-only carousel has settled.
- `Observed`: the state keeps the same rounded-top card silhouette and bottom teaser behavior.
- `Inferred`: this interaction should preserve the same image/card and unlock chrome over it, not swap to a different page composition.

#### Animation Breakdown

- `Observed`: there is a visible separation between image settle and metadata reveal.
- `Observed`: the title block, badges, summary, and buttons appear as chrome over the same card surface, not as a new page.
- `Observed`: the art does not jump or reframe aggressively during this reveal phase.
- `Observed`: bottom teaser content remains visible while the metadata settles in.
- `Inferred`: metadata likely fades in with a short stagger or delayed opacity ramp. The clip does not provide enough precision to recover exact per-element timings.
- `Inferred`: any geometry change during this phase should be subtle compared with the initial poster-to-carousel move.

### 3. Expanded Card to Details

- `User clarified`: this move is triggered by a further user interaction.
- `Observed`: the move into details is vertical and continuous.
- `Observed`: the same art persists behind the lower content.
- `Observed`: the details content appears attached below the expanded card, not pushed from a separate route.
- `Inferred`: the first downward move after card expansion should shift focus into the season picker or first detail row while scrolling the fold upward.

#### Animation Breakdown

- `Observed`: the transition happens quickly between `5.0s` and `5.5s` in the sampled clip.
- `Observed`: the composition keeps the same palette and same background art during the move.
- `Observed`: the centered show title/logo at the top of the details state fades or scrolls into place as the fold comes up.
- `Observed`: the details rows do not pop in over a blank background. They are already attached below the fold and become visible by scrolling upward.
- `Inferred`: this move should be driven by one vertical content translation/scroll animation, not by a crossfade between separate views.

### 4. Details Idle State

- `Observed`: once the details state settles, there is no visible residual motion.
- `Observed`: episode cards and trailer cards sit on a darker, more diffused version of the same art.
- `Inferred`: any remaining motion in this state should be limited to focus effects, not layout shifts.

## Animation Constraints

These are the most important motion constraints for future agents.

- Do not reveal metadata at the same instant the poster starts scaling.
- Do not leave the sidebar focusable or visually active once preview begins.
- Do not switch to a second background image when the hero expands or when the fold moves.
- Do not replace the rounded-top card stage with an unrelated full-screen zero-radius layout during the expanded-card state.
- Do not treat details as a pushed route with a different backdrop.
- Do not make side cards look like evenly spaced siblings if the reference is supposed to read as a dominant center card with narrow peeks.
- Do not make the bottom edge of the centered card fully visible if the reference state is supposed to imply more content below.
- Do not use a blank interstitial frame between home, hero, and details.

## Styling Notes

### Typography

- `Observed`: the show title/logo is large, bright, and high-contrast.
- `Observed`: metadata text is white or near-white over darkened art.
- `Observed`: section headers in details are clean and minimal, not heavily decorated.

### Buttons and Pills

- `Observed`: hero actions are pill-shaped with soft material/glass treatment.
- `Observed`: there is a clear primary action on the left side of the button row.
- `Observed`: quality/rating badges are compact inline pills.

### Background Treatment

- `Observed`: the hero art is bright but darkened enough for readability.
- `Observed`: the details view uses stronger blur/dimming than the hero state.
- `Observed`: there is no second background image introduced at the fold.

## Inferred Interaction Model

These items are not all shown directly in the sample clip, but they fit the clip and the supplied stills.

- `Inferred`: selecting a non-Continue Watching poster opens the carousel stage.
- `Inferred`: `Left` and `Right` should page sibling cards while in carousel mode.
- `User clarified`: a distinct user interaction expands the carousel into the metadata-rich expanded-card state.
- `Inferred`: the next `Down` should move focus into the details content below the fold.
- `User clarified`: details are reached by another user interaction after the expanded-card state.
- `Inferred`: `Menu` should step back one layer at a time rather than dismiss everything at once.

## What The Clip Does Not Prove

Future agents should avoid over-claiming these points because they are not directly demonstrated in `IMG_4815.MOV`.

- Exact spring constants or easing curves
- Exact left/right carousel spacing during paging
- Exact focus restoration behavior on `Menu`
- Exact stagger order for title vs summary vs buttons
- Whether the long art-only interval is entirely animation or partly user dwell

Those details should be treated as implementation choices constrained by the broader visual rules above.

## Future Agent Workflow

When continuing preview-flow work:

1. Read this file first.
2. Compare the current app footage against the timeline and frame-by-frame checkpoints above.
3. Fix stage ownership first:
   Sidebar, background dimming, and focus fencing.
4. Fix geometry second:
   Card size, top-only radius, peeks, bottom edge, and continuity.
5. Fix animation ordering third:
   Poster morph, then user-triggered expanded-card reveal, then user-triggered vertical fold motion.
6. If fidelity is still off, record a new current-state clip and compare it side-by-side against `IMG_4815.MOV`.

## Practical Summary

If a future implementation is close but still feels wrong, the most likely misses are:

- The preview still shares focus or visual ownership with the sidebar.
- The center card is too small or too low.
- The side cards are too visible and too separate.
- The card shows fully rounded corners on all sides instead of only the visible top corners.
- Metadata appears too early or without a distinct expand state.
- The expanded card switches backgrounds before the fold moves.
- The details state feels like navigation to a new page instead of the same surface continuing downward.

## Fidelity Checklist

- Hide or fence off the tvOS sidebar while preview owns the stage.
- Keep the settled carousel card dominant, with visible top radius and no visible bottom corners.
- Show only narrow side peeks, not separated same-size side cards.
- Delay metadata until after the initial poster-to-carousel motion settles.
- Keep the first image as the background for both expanded card and details.
- Make the details state feel attached below the expanded card, not routed to a new page.
- Preserve a bottom teaser of below-fold content while the expanded card is visible.
- Avoid blank frames, hard cuts, or a second background image during expand.

## Scope Boundary

This reference describes the target behavior for the hub-row preview flow only. It should not be treated as a generic detail-page spec for every browse surface in the app.
