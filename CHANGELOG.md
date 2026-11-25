# Changelog

All notable changes to this project are recorded here. Dates are commit dates; the project has no tagged releases yet, so the version numbers below are provisional labels for the two milestones so far.

## [Unreleased]

### Removed

- The GitHub Pages demo in `docs/`. It served a pre-Phase-0 export (wrong prop classes, colliding HUD meters, tofu glyphs) while the project has no run loop to demonstrate. The export is still in git history; re-export and publish again when the loop exists.

### Added

- A hard cap on live props (`scripts/props/prop_manager.gd`). Spawns are refused once the arena holds 36 mascot-equivalents, weighted by the class's measured frame cost (mascot 1.0, anchor 0.6, crate 0.5, duck 0.4): that is 36 mascots, or a mixed pile of about 64 props, which is the top of the band the gameplay benchmark found safe (32 mascots 10.96 ms median / 13.27 ms p95 against a 6.14 ms empty frame; 32 crates 8.81 ms). Nothing limited spawns before, so gift spam could push the frame past 16.67 ms with no brake. A refused spawn builds nothing at all - no splash wave, no VFX, no tracking - and emits `prop_spawn_blocked`; the HUD answers with a `PROP LIMIT REACHED` toast (rate limited to once every 2 s so a gift burst cannot replace every other alert) and a `push_warning` line, and `GameManager.props_refused` counts every refusal, including the throttled ones. Props stop counting towards the cap once they have plunged, so the limit frees up as the arena sheds them.
- The streamer mascot plays its `Idle` clip. The GLB shipped five animations (Idle, Walk, Sprint, Attack_Hit, Browse_Carry) and nothing ever started one, so the mascot stood as a statue; the idle is now looped on spawn (an imported one-shot would drop it back to the rest pose mid-stream).
- `tests/boot_test.gd`: the lost windowed boot harness, re-authored headless and wired into `tools/check.sh` as the `== boot ==` step. It asserts `ability_1`/`ability_2`/`ability_3` exist and are bound to `1`/`2`/`3`, presses them through the real `InputMap` (so a rebind fails here, not mid-stream) and checks each starts its own cooldown, disables its HUD button with a countdown, refuses to re-fire while cooling with an `ABILITY RECHARGING` alert, and fires again once ready. It also lays the HUD out in a 1920x1080 SubViewport — the headless root viewport is not 16:9 — and asserts the water meter, drain meter and score box are all laid out, that neither meter intersects the score box or each other, and that the score box stays inside the frame; finally it walks every `Label`/`Button`/`Label3D` text plus the generated alert strings for non-ASCII characters.
- `tests/float_height.gd`: a headless float-height regression test, wired into `tools/check.sh`. The silhouette harness has to hide the water to get reproducible pixels, which left float height unmeasured, so this pins each class's submerge fraction, `_get_prop_y_offset()` and the resulting draft (`SUBMERGE_FRACTION * height - offset`), then puts every prop into a real 2 m basin of a real `FluidSim`, drives its own `_process` for 240 ticks and asserts the settled geometry sits where the tables say (origin at the offset, bottom `draft` under the waterline, freeboard above it). The heavy anchor follows a different rule in deep water — it rests 0.25 m above the bed — so that clearance is pinned from measurement instead.
- Donor-name display policy (`scripts/core/name_policy.gd`): control/zero-width/bidi characters stripped, whitespace collapsed, 16-character clamp, and a blocklist at `user://name_blocklist.txt` that folds case, punctuation, spacing, leet substitutions and repeated letters before matching. Blocked or empty names render as `Viewer`. Applied to prop nameplates, prop boil/plunge alerts, gift alerts and the VIP throne.
- `tests/sim_invariants.gd`: a seeded, scripted harness that drives piece drops, gifts and abilities through the real scene and asserts water mass conservation, finite field values, prop bookkeeping (no dead/plunged/untracked props) and the sim step cap. Wired into `tools/check.sh`, so CI runs it.
- Cumulative `total_added_water`, `total_evaporated_water` and `total_drained_water` counters so the conservation identity can be audited. `total_drained_water` is separate from the earthquake-resettable drain meter.
- A tracked 720p silhouette baseline (`tests/prop_silhouette_720p.json`) plus the windowed `tests/measure_props.gd` harness that produces it, so prop-size changes are measured against recorded numbers. The gate itself runs `tests/prop_size.gd` headless against `tests/prop_size_baseline.json` (target height, fitted scale, seating, projected extent), so a sizing regression fails CI; only the rendered silhouette still needs a window.

### Changed

- The streamer mascot now renders as one surface of 6041 triangles instead of eight mesh instances carrying thirteen surfaces. Its five body surfaces were the same material (one 1024px albedo, roughness 1.0, metallic 0) split across five parts, and the other eight surfaces - goggles, headphones, hoodie - sit inside the body: painted and counted, they cover 100 px of visible surface with the mascot 450 px tall and 111 px at the shipped 95 px framing, so every mascot paid draw calls for geometry nobody saw. `scripts/props/mascot_mesh_merge.gd` merges the body surfaces into one, and the buried meshes are gone from `streamer_mascot.glb` itself - five meshes and five materials instead of eight and thirteen, 1.08 MB instead of 1.28 MB - so no name list survives in the runtime. It puts the result on the first mesh instance (keeping that instance's skin and skeleton binding untouched) and hides the rest; the mesh is built once per model and shared by every mascot. The 720p silhouette still matches the baseline exactly (73x95 px, 1551 px2, 0.0%), and the merged mesh is a plain ArrayMesh, so it no longer inherits the import's generated LODs. At 32 mascots under the benchmark load, frame draw calls fall from 1401 to 196-230 (about 42 per mascot down to 4.5) and the mascots' cost above a hidden-prop baseline falls from 1.65 ms to 0.24 ms - roughly 0.01 ms per mascot, down from 0.05 ms.
- The rendered silhouette baseline now records the environment that produced it — engine build, renderer (method/driver), GPU and vendor, MSAA level — and the harness asserts pixels strictly only where the current run matches. Elsewhere it prints a `SOFT COMPARISON` header naming each differing field (e.g. `gpu: baseline AMD Radeon RX 7900 XTX, this run NVIDIA GeForce RTX 4060 Laptop GPU`) and reports `SOFT-PASS`/`SOFT-DIFF` for the size, area and nameplate-line comparisons without failing the gate. Geometry-only assertions (in frame, plate layout, legibility, tier colour) stay strict on every machine because they do not depend on the renderer.
- The rendered silhouette harness is deterministic and its baseline was regenerated. Three separate sources of drift were fixed: the settle ticks now run from a seeded RNG (unseeded stream events moved the water level by ~4 cm, shifting every prop a pixel or two and swinging the mascot's keyed area between 1603 and 1816 px2 at an identical bounding box); the translucent water is hidden for the keyed captures (the surface shader displaces vertices by `TIME` and the waterline clipped partly-submerged props at a level that differed every run, which is why the mascot sat 10% inside its band); and the mascot's Idle pose is pinned (seek to frame 0, pause) before any silhouette is captured, with the harness asserting both that the clip is running and that it is pinned — and a capture now waits for three identical frames and fails rather than measuring one that never settles. Stream events are also stopped before the first frame elapses: they fire on their own real-time timer, and one landing during launch moved the water level by a centimetre even with the RNG seeded, which flipped the marginal huddle-plate assertion on roughly one run in four. The first frame's sim ticks are pinned the same way (two ticks before the harness owns the clock): left automatic it ran a launch-dependent one to four ticks and settled the water anywhere between 2.21 and 2.45 m, which is what turned 73x95/1551 px2 into 74x96/1545. Each prop's settled height is recorded in the baseline and compared to within 5 mm, so world drift fails by name instead of slipping inside the area tolerance. Area tolerance tightened 15% -> 5%, since four consecutive runs now agree to 0.0%.
- `tools/check.sh` runs the rendered silhouette harness (`tests/measure_props.gd`) whenever a display is available, so a prop-size regression is caught on a developer machine as well as by the headless gate; without a display it prints `SKIP prop silhouettes: no display available` and stays green, which is what headless CI sees. `MEASURE_PROPS=0`/`=1` overrides the detection.
- The fluid sim steps at most 4 fixed ticks per frame and drops any further backlog, so a single long frame can no longer put the sim into permanent catch-up.
- Prop visuals are normalised to per-class target heights (1.35 m crate, 1.7 m duck, 2.2 m mascot, 2.6 m anchor) instead of whatever their source mesh happened to be, so every class is identifiable at 720p from the default camera. The anchor gained a ring at its shank head so its silhouette reads as an anchor rather than a "T". Buoyancy, advection and bed-clamping offsets are unchanged.
- Donor nameplates scaled up to roughly 0.46 m per line (~23 px at 720p) with a heavier outline and no depth test.
- Donor nameplates are now one line instead of two: the `[Rose]` line repeated a tier the plate colour already carries, and it was what covered the neighbouring prop when two gifts drifted close. A screen-space layout then keeps each plate off other plates and off the neighbouring prop's body, shrinking the text (to 60% at worst) before lifting it far from its prop, and it remembers last frame's choice so a plate does not hop rows as props drift past each other.

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
