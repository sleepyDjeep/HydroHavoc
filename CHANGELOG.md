# Changelog

All notable changes to this project are recorded here. Dates are commit dates; the project has no tagged releases yet, so the version numbers below are provisional labels for the two milestones so far.

## [Unreleased]

### Added

- `tests/sim_invariants.gd`: a seeded, scripted harness that drives piece drops, gifts and abilities through the real scene and asserts water mass conservation, finite field values, prop bookkeeping (no dead/plunged/untracked props) and the sim step cap. Wired into `tools/check.sh`, so CI runs it.
- Cumulative `total_added_water`, `total_evaporated_water` and `total_drained_water` counters so the conservation identity can be audited. `total_drained_water` is separate from the earthquake-resettable drain meter.

### Changed

- The fluid sim steps at most 4 fixed ticks per frame and drops any further backlog, so a single long frame can no longer put the sim into permanent catch-up.
- Prop visuals are normalised to per-class target heights (1.35 m crate, 1.7 m duck, 2.2 m mascot, 2.6 m anchor) instead of whatever their source mesh happened to be, so every class is identifiable at 720p from the default camera. The anchor gained a ring at its shank head so its silhouette reads as an anchor rather than a "T". Buoyancy, advection and bed-clamping offsets are unchanged.
- Donor nameplates scaled up to roughly 0.46 m per line (~23 px at 720p) with a heavier outline and no depth test.

### Fixed

- Nameplates inherited the prop's wave rocking and slid sideways off the prop they label; they are now top-level nodes pinned above it.

## [0.1.1] - 2026-11-24

Truth pass on what the prototype actually shows, plus the first script checks.

### Added

- `1` / `2` / `3` ability actions (Flash Freeze, Solar Ray, Seismic Anchor) with per-ability cooldowns, HUD buttons that display the remaining seconds, and a "recharging" alert when pressed early.
- `tools/check.sh`: imports the project and parses every script with a real Godot binary.
- GitHub Actions workflow that runs the same check on pushes and pull requests.

### Changed

- HUD top bar rebuilt: title, lake volume, spill drain and score in fixed boxes, with the water and drain meters scaled to a readable 240 px so they no longer collide with the score.
- Water mesh rebuilds only when the simulation revision changes, instead of every frame.
- Emoji removed from alerts, nameplates and status text so nothing renders as tofu glyphs.
- Solar Ray now counts as a hit only when it actually boils water.

### Fixed

- Every floating prop rendered as the rubber duck, because the prop class was assigned after the node entered the tree. Props are now configured before `add_child`, with a rebuild if the class changes later.
- Loose ends in the repo: README rewritten to state only verified behaviour, MIT `LICENSE`, this changelog, and build output removed from version control.

## [0.1.0] - 2026-11-14

First playable prototype.

### Added

- 32x32 shallow-water heightfield simulation with flux advection, rim spill accounting and dynamic terrain/water meshes.
- Polyomino queue with wall, trench, water drop, fireball, bomb and sponge pieces, plus a cursor preview.
- Floating props with buoyancy, drift and tilt: rubber duck, gift crate, heavy anchor, streamer mascot.
- Mock audience dock for Bits and TikTok gifts, VIP donor tracking, alert banners and an earthquake hazard on spill.
- 16:9 / 9:16 camera and HUD arrangement toggle.
- Windows and Web export presets, plus a web build in `docs/` for GitHub Pages.
