# Preview Carousel Implementation Tracker

This file tracks implementation status against the canonical fidelity spec:

- `Docs/PREVIEW_REFERENCE_VIDEO.md` (behavior + style + flow)
- `Docs/PREVIEW_CAROUSEL_REFERENCE_LAYOUT.md` (tokens/constants)

## Current Intent

Implement Apple TV+ style preview flow exactly enough that side-by-side playback is difficult to distinguish for:

- entry morph
- carousel paging + parallax
- expanded hero continuity
- details fold and return

## Active Requirements

- One shared phase model controls motion lock, metadata reveal, focus handoff, and backdrop policy.
- Selected card must never show duplicate hero layers.
- Carousel siblings remain side-by-side only.
- Metadata/buttons reveal via opacity-in-place only.
- Backdrop lag must be visible, attached, and same-stop as card.
- Single-season handling must not show `Episodes` heading.

## Verification Protocol

1. Record current app clip at each meaningful change.
2. Compare with Apple clip in frame strips and full timeline map.
3. Run checklist in `PREVIEW_REFERENCE_VIDEO.md`.
4. Reject if any checklist item fails.

## Known Drift Risks

- “Feels smoother” edits that are not measured against clip timing.
- Reintroducing detached backdrop stage ownership.
- Reintroducing slide offsets for title/buttons.
- Unintended layout movement when logo source changes.
- Season/shelf logic branching differently for `season` metadata variants.

## Done Criteria

All ship-gate checklist items in canonical spec pass on latest capture, and docs remain internally consistent (no contradictory guidance across files).
