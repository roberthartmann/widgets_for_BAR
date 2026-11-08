# Attack Range GL4 – performance fork

Performance fork of the game widget `gui_attackrange_gl4.lua` (version 1.2, BAR `stable`/`master`,
identical at the time of forking). `gui_attackrange_gl4_original.lua` is the unmodified reference copy.

The fork comes as four versions that build on each other. Each version contains everything from the
previous one, so you can bisect: if a version misbehaves, step back one.

| File | Contains | Expected effect (early game, 1–3 rings) |
|---|---|---|
| `gui_attackrange_gl4_perf_v1.lua` | **Time-based 30 Hz Update throttle.** The original gates `widget:Update` with `gameFrame % 3`, but `gameFrame` only advances 30×/s while Update runs every render frame, so the cursor `TraceScreenRay` ran on every render frame of every third sim frame (~48×/s at 144 fps) and never while paused. Now all Update work runs on a wall-clock 30 Hz tick; the trace is skipped while mouse and camera are unchanged (5 Hz fallback so a unit driving under a still cursor is still picked up). | Allocations 5.2 kB/s → well under 1 kB/s; Update time −60–80 %. Also fixes cursor ranges while paused. |
| `gui_attackrange_gl4_perf_v2.lua` | v1 + **zero-ring early-out.** A running instance counter lets `DrawWorld`/`DrawInMiniMap` return immediately when the selection produced no ring (eco buildings, toggled-off weapons, selection above threshold). Previously shader activations, uniforms, stencil clears and the three `DRAWRINGS` loops ran anyway. | Near 100 % of the widget's draw cost whenever only ring-less units are selected. |
| `gui_attackrange_gl4_perf_v3.lua` | v2 + **draw-path cleanups.** No unused `$info` texture bind, no leftover sine `glLineWidth`, no `drawcounts` debug writes, view geometry cached via `ViewResize` instead of `GetViewGeometry` every frame. | ~3–5 % of the widget's per-frame call count. No visual change. |
| `gui_attackrange_gl4_perf_v4.lua` | v3 + **merged ring passes / fewer state changes.** Outer and inner rings are drawn with one shader activation, per-frame uniforms are set once, line width and depth test are only changed when they differ, empty class loops are skipped. | ~20–25 % of the world draw path's Lua→GL calls. |

All numbers are estimates derived from per-frame call counts, not in-game measurements. Please measure
with the widget profiler (F11 → "By cost") and report back.

## Installation

1. Copy **one** of the `gui_attackrange_gl4_perf_vN.lua` files into `your_bar_folder/data/luaui/widgets`.
2. In game press F11, **disable the original "Attack Range GL4"** and enable "Attack Range GL4 (perf vN)".
   Both use `WG.attackrange` and the config file `LuaUI/config/AttackRangeConfig2.lua`, so only one may be active.
3. The shaders (`LuaUI/Shaders/weapon_range_rings_unified_gl4.*`, `weapon_range_fill_composite_gl4.*`) and the
   includes (`luaui/Include/range_coverage_mask_gl4.lua`, `minimap_utils`) come from the game itself; the fork
   needs the game version that ships widget 1.2 (anything from autumn 2025 on).

## What changed, where

Every edited region is marked with a comment `-- perf vN:` so the diff against the original can be reviewed with
`grep -n "perf v" gui_attackrange_gl4_perf_v4.lua` or `diff -u gui_attackrange_gl4_original.lua gui_attackrange_gl4_perf_v4.lua`.
