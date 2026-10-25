# Reviving the Buildpower Top Bar – comparison and plan

> **Decision (2026-10-25):** Robert chose option A after all, a full fork of the current stock top bar,
> because the data needed for the bar cannot be obtained from outside it and the bar has to sit between
> metal and energy. The fork is `gui_top_bar_buildpower.lua`; `stock_reference/` is its merge base and
> `design/integration_design.md` describes how the additions are kept mergeable. The rest of this file is
> the original comparison.

Date of analysis: 2026-10-25. Sources: `gui_top_bar_alpha_0.4.010.lua` (this repo),
`WybrenKoelmans/BAR-Widgets/gui_top_bar_extra/gui_top_bar_extra.lua` (uBdead, 2025-08-16) and
`beyond-all-reason/Beyond-All-Reason/luaui/Widgets/gui_top_bar.lua` at master (last top bar commit 2026-09-24).

## 1. The three widgets side by side

| | Your `Top Bar with Buildpower 0.4.010` | `Top Bar Extra` (uBdead) | Stock `Top Bar` today |
|---|---|---|---|
| Kind | Full **fork** of the stock top bar (3167 lines). User must disable the stock bar. | **Overlay** (206 lines). Runs next to the stock bar, draws text on top of it. | The official widget, plus `gui_top_bar_buttons.lua` (split off Sep 2026). |
| Question it answers | "Is my buildpower actually turning resources into units, and which resource is the bottleneck?" | "Am I in surplus or deficit right now, and how much do I overflow / receive?" | Storage, income, pull, expense, share sliders, warnings when overflowing or wasting. |
| Data | Tracks every own finished builder, nano, factory. Every 3 frames walks them (coroutine, 20 units per frame): total BP, reserved BP (has orders), used BP (metal pulled / metal-per-BP of the target), stall ratio (pulled vs wanted). Derives metal-per-BP and energy-per-BP of current builds, non-builder expense, and the share of total BP that current M income and E income could support. Wind min/max range for the E indicator. 30-sample moving averages. | `Spring.GetTeamResources` every `Update`. `income - pull` and `received - sent`, block-averaged over 10 s (the value jumps every 10 s rather than sliding). | `Spring.GetTeamResources` every 0.25 s, exponential smoothing of all 6 values, ally-team overflow detection. |
| Display | Third bar between metal and energy. Green = used BP, pale green = reserved, red background = idle. Grey triangle on the bottom edge = BP supported by metal income; yellow triangle on top = by energy income, with a wind range strip. Percent text colored red to green. Alerts "Need metal", "Need energy", "Idle buildpower". Tooltip with explanation and debug numbers. 5 options in the settings menu. | Signed green/red number at the left of the metal and energy bars; yellow/blue overflow number above the share slider in team games. No tooltip, no options. | Render-to-texture pipeline, skewed trapezoid bars (May 2026), localized strings, hide/show API for quick-start and base-build-budget. |
| Geometry | Owns the layout, so always consistent with itself. | Copies constants from the stock file (`relXpos 0.3`, `height 46`, width `/4.4`). Already slightly off since the skew change, and will drift with any stock layout change. | Exposes `WG.topbar.GetPosition()`, `GetFreeArea()`, `GetSkewConfig()`. Does **not** expose the resource bar rectangles. |
| Maintenance cost | Very high. Base was stock from spring/summer 2024 (closest match 2024-04 to 2024-08, about 1650 changed lines). Stock has had **103 commits** since Sep 2024; your fork vs current stock differs by about 4900 lines, so it is effectively a different file now. | Very low, until the stock layout moves. | n/a |
| Dead dependencies | `lowPrioNeededMetal/Energy` and `lowPrioExpenseMetal/Energy` team rules params (from your modified `unit_builder_priority` widget). The current stock gadget only sets `suspendbuilderpriority`, so this part silently does nothing. `Spring.I18N` was replaced by `BAR.I18N` in stock. | None. | n/a |

## 2. What changed in the stock top bar since your fork

Highlights from the commit history of `gui_top_bar.lua` (103 commits since 2024-09-01):

- 2025-04/05: everything is drawn through render-to-texture (`r2tHelper`), only dirty regions are re-rendered; `smoothedResources` with exponential smoothing.
- 2025-09: "Reduce # of local variables" – the file sits at the Lua 5.1 local/upvalue cap, comments in the file say so. Adding a third resource with its own display lists inside this file is hard.
- 2025-10/11: `setResourceBarsVisible`, `setIndicatorsVisible` API so other widgets can hide the bar (quick start, base build budget); lots of localization.
- 2026-03: old non-RTT render path removed; widget layer changed from -999999 to -95000.
- 2026-05: skewed/trapezoid resource bars (`cfg.useSkew`, `skewAngleDeg 20`), `GetSkewConfig()` for attachments; "Converter Usage" attachment also skewed.
- 2026-08: `Game.spawnWarpInFrame`, bar_codemod renames (`Spring.I18N` -> `BAR.I18N`, bracket-to-dot, detached modules).
- 2026-09: buttons and quit dialog extracted into `gui_top_bar_buttons.lua`; `WG.topbar` is now a table shared by both widgets with fallbacks.

Pattern that stock itself uses for extra top bar content: `gui_converter_usage.lua`. It takes its rectangle from
`WG.topbar.GetFreeArea()`, applies `GetSkewConfig()`, owns its own guishader display list and tooltip, and
publishes `WG.converter_usage.GetPosition()` so others can sit next to it. Layer 0, enabled by default.

## 3. Options for the revival

### A. Re-fork current stock and re-apply the BP changes
Rejected. Every stock change (about 5 per month on this file) has to be merged by hand, the file is at the
local-variable cap, the RTT pipeline makes a third bar invasive, and users lose the stock bar and the
buttons widget coordination. This is exactly why 0.4.010 died.

### B. Attachment widget in the stock style (recommended)
Two files, no change to the stock bar:

1. `api_buildpower.lua` – the tracking and averaging logic from 0.4.010 (TrackUnit/UntrackUnit, coroutine
   walk, weighted averages, M/E-supported ratios, wind range). Publishes `WG.buildpower` with
   `total, reserved, used, usedRatio, mSupportRatio, eSupportRatio, eSupportMinWind, eSupportMaxWind,
   stallingMetal, stallingEnergy, metalPerBP, energyPerBP`. No drawing. Other widgets (idle builders,
   a future stock feature) can reuse it.
2. `gui_top_bar_buildpower.lua` – modeled on `gui_converter_usage.lua`. Positions itself in
   `WG.topbar.GetFreeArea()`, to the right of `WG.converter_usage.GetPosition()` when that widget runs,
   honours `GetSkewConfig()`, hides with `getResourceBarsVisible()`/`getIndicatorsVisible()`.
   Draws your bar: used / reserved / idle fill, the two triangles, the wind range strip, the colored
   percent. Tooltip via `WG.tooltip.AddTooltip`, options via `WG.options.addOption`, alerts under the bar.

Space check: free area is roughly `0.7*vsx - metal - energy - wind - tidal - coms - buttons(0.7*vsx/4)`.
On 1920 px that leaves about 160 px times `widgetScale` after Converter Usage, about 300 px on 2560 px.
Enough for a compact bar; the width should scale with the free area and the bar should degrade to
"percent only" when narrow.

### C. Overlay like Top Bar Extra
Print "BP 73%" and the two markers directly over the stock metal and energy bars. Cheapest, but it needs
hardcoded geometry because stock exposes no bar rectangles. Worth doing only together with a small
upstream PR that adds `WG.topbar.GetResbarArea(res)`; that PR would also fix the drift in Top Bar Extra.

## 4. Logic fixes to carry over regardless of option

- Remove the `lowPrio*` team rules params; the pull correction is gone.
- Replace `commands[1].id == 16` with `CMD.FIGHT`, and `name:find("nano")` with
  `unitDef.isBuilder and not unitDef.isFactory and not unitDef.canMove`.
- Re-scan builders on `PlayerChanged` when spectating a different team.
- Guard `unitCostData[builtUnitDefID]` and division by zero `MperBP`.
- Keep the per-frame budget (20 units per frame, every 3 frames); stock reviewers care about this.
- Do not use `Spring.I18N`; plain strings or `BAR.I18N` guarded by `BAR and BAR.I18N`.

## 5. Relationship to Top Bar Extra

The two widgets are complementary, not competitors. uBdead's number tells you the sign of your balance
right now; your bar tells you whether the balance problem is too little buildpower or too little eco,
and which resource. Both can run at once because they occupy different screen areas.
