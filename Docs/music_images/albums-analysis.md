# Apple Music tvOS — Albums View Analysis

Photo of TV screen showing the Library tab with "Albums" selected in the sidebar.

## Differences from "Recently Added" View

This view is nearly identical to the Recently Added view but adds:
1. A **content header** with title, count, and action buttons
2. Additional **sort buttons** in the header row

## Content Header

Located at the top of the content area (right of sidebar), horizontally aligned:

### Left Side of Header
- **"Albums"** — large bold text, approximately 28-32pt, white, semibold/bold weight
- **"19 albums"** — directly below "Albums", smaller text ~15pt, gray/secondary color
- These two lines are left-aligned, stacked vertically with ~4pt gap

### Right Side of Header (action buttons)
- Horizontally arranged buttons, right-aligned in the header row:
  - **"▶ Play"** — pill button, dark/translucent background with white text and play icon, ~100pt wide, ~36pt tall
  - **"⇄ Shuffle"** — pill button, same style as Play, slightly wider to fit text
  - **"⊕"** — small circular button (add to library?), ~36pt diameter
  - **"↕"** — small circular button (sort direction), ~36pt diameter
- Buttons have rounded-pill shape (fully rounded ends)
- The pill buttons appear to use a glassy/translucent dark material background
- Icon + text layout inside pills: icon left, text right, ~8pt gap
- The circular buttons are just icons, no text

### Header Spacing
- Header sits approximately 20-30pt below the top edge of the content area
- Gap between header bottom and first row of album art: ~24-30pt
- The header row is vertically centered — the "Albums" title and count are vertically centered with the action buttons

## Sidebar State

- "Albums" is selected/focused — it has a visible rounded-rect highlight (semi-transparent white pill background)
- The highlight appears to be the standard tvOS focus indicator on a List row
- Other categories are plain text without highlight
- The sidebar categories visible: Recently Added, Playlists, Artists, **Albums** (selected), Songs, Composers
- Genres section below: Alternative, Christian, Country

## Album Grid

Identical layout to the Recently Added grid:
- 4 columns visible
- Same ~200x200pt cards with ~10pt corner radius
- Same center-aligned title + artist text below
- Second row partially visible
- First album ("Red Balloon") appears focused (slightly elevated/scaled)

## Key Implementation Notes

- The header only appears when a specific category is selected (Albums, Artists, Songs) — NOT for Recently Added
- The Play and Shuffle buttons are the standard pill action buttons (AppStoreActionButtonStyle)
- The sort/add buttons are small circular buttons, not pills
- The sidebar "Albums" selection has a rounded highlight that matches tvOS standard List focus/selection
