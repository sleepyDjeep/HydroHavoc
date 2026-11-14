# HydroHavoc 🌊🎮

> A modern, fast-paced streaming puzzle game inspired by the N64 classic *Wetrix*, built from the ground up for live audience interaction, crowd disasters, and streamer engagement on Twitch, TikTok Live, Kick, and YouTube.

![HydroHavoc Gameplay](screenshot_props_slice.png)

---

## 🌟 Features

- **2.5D Shallow Water Equations (SWE) Physics**: Real-time fluid mass-conservation simulation running on a $32 \times 32$ heightfield grid at $<3\%$ CPU overhead.
- **Classic Polyomino Arcade Mechanics**: Rotating and slamming Uppers (walls), Downers (trenches), Water Drops (downpours), Fireballs (steam evaporation), Bombs (craters), and Sponges.
- **Dual-Mode Streaming Layouts**:
  - **16:9 Widescreen**: Tailored for Twitch, YouTube, and Kick.
  - **9:16 Vertical Portrait**: Optimized for TikTok Live Studio mobile streams (press `T` to toggle).
- **Interactive 3D Floating Props & Single-Point Buoyancy**:
  - 🐥 **Rubber Ducks**: Bobs and drifts with surface flow; awards bonus points when boiled in steam!
  - 📦 **Viewer Gift Crates**: Branded wooden crates displaying the donor's username and gift tier.
  - ⚓ **Heavy Sinking Anchors**: High-mass boulders that create impact waves and divert fluid currents.
  - 🏃 **Streamer Mascot**: 3D character ragdoll that reacts physically to incoming tsunamis and edge spills.
- **Audience Action Ingestion**:
  - Integrated mock stream test dock for Bits (100, 500, 1000) and TikTok Gifts (Rose, Doughnut, Galaxy, Lion).
  - On-screen VIP Gifter Throne, dynamic alert banners, and fail-state Earthquake collapses.

---

## 🕹️ Controls

| Action | Key / Input |
| :--- | :--- |
| **Move Cursor** | `W`, `A`, `S`, `D` or Arrow Keys |
| **Rotate Piece** | `R` or `E` |
| **Slam / Drop Piece** | `Space` or `Enter` |
| **Toggle 16:9 / 9:16 Mode** | `T` or HUD Button |
| **Emergency Ability 1** | `1` (Flash Freeze - 6s liquid stasis) |
| **Emergency Ability 2** | `2` (Solar Ray - lake vaporization) |
| **Emergency Ability 3** | `3` (Seismic Anchor - dam reinforcement) |

---

## 📦 Playable Builds

- **Windows Standalone (.exe)**: Located in [`build/windows/`](build/windows/) or download the packaged [`HydroHavoc-Windows-x64.zip`](build/windows/HydroHavoc-Windows-x64.zip) (37 MB).
- **Web Demo (HTML5 / WebAssembly)**: Located in [`build/web/index.html`](build/web/) or unpack [`HydroHavoc-Web-Demo.zip`](build/web/HydroHavoc-Web-Demo.zip) to play in any modern browser.

---

## 🛠️ Development & Engine

- **Engine**: Godot 4.7.2 (Forward+ / Mobile / Web)
- **Language**: Typed GDScript + GLSL Spatial Shaders
- **Architecture**:
  - `scripts/core/fluid_sim.gd`: 2.5D Shallow Water Equations & flux advection.
  - `scripts/core/terrain_mesh_builder.gd`: Dynamic procedural terrain mesh.
  - `scripts/core/water_mesh_builder.gd`: Dynamic fluid surface mesh.
  - `scripts/core/piece_manager.gd`: Polyomino queue and rotation state.
  - `scripts/props/prop_manager.gd`: 3D floating props & hydrodynamic surface clamping.
  - `scripts/ui/game_hud.gd`: Responsive dual-aspect ratio UI.
