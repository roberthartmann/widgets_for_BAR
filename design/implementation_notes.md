# Implementation notes: gui_top_bar_buildpower.lua

Implements `integration_design.md` and `bp_feature_spec.md`. These notes list only what the two documents leave open, or where the code does something different.

## File and merge base

* `gui_top_bar_buildpower.lua` = `stock_reference/gui_top_bar.lua` plus BP additions. It keeps the stock **CRLF** line endings, so `diff`/`git merge-file` against a future stock version stay clean. Editors and scripts must keep CRLF. (Python's universal-newline mode silently converts to LF.)
* Exactly 10 stock lines are changed: GetInfo (5), the three `BP = {}` table entries, and the metal and energy area lines in `init`. Every other change is an added line, and every hook line is marked `-- BP`.
* Lua 5.1 budget: the main chunk has 172 of 200 locals (stock 169, plus `bp`, `bpTrack`, `bpUi`). `widget:DrawScreen` has 47 upvalues, unchanged from stock.

## Decisions not fixed by the design

* **Nanos on FIGHT:** a nano whose only order is `CMD.FIGHT` counts as idle **only if it is not building**. A nano that auto-assists from its fight order is reserved and used. Otherwise its metal use would show up as non-builder expense.
* **Repair targets** (`GetUnitIsBuilding` returns a finished unit) count as reserved but not building (spec B27).
* **Command counts:** builders use `Spring.GetUnitCommandCount` (with `GetUnitCommands(id, 0)` as a fallback), factories use `Spring.GetFactoryCommands(id, 0)`.
* **Pass size:** `min(20, ceil(n / 3))` builders per GameFrame, then a 3-frame pause, with `finishPass` exactly once per pass.
* **Averages:** a ring of 40 samples, one per pass. Only the samples from the last 60 game frames (2 s) are read, so the window is set by time, not by unit count. Sums are recomputed on every pass, so there is no float drift. Series: reserved, used, non-builder M/E (weight 1); M/E support and the E support at min/max wind (weight = used BP of the pass).
* **Per-BP cost:** `metalPerBP = builderMetalExpense / usedInstant` (spec section 11 main formula), kept when `usedInstant < 1`.
* **Stale projections (B29):** when nothing has been built for 2 s, `mSupportRatio`/`eSupportRatio` keep their last value and `bp.supportStale` is true. The markers are then drawn greyed out, and the tooltip says so.
* **Wind strip:** uses the same model B denominator as the yellow marker (fixes B11). The wind income of `numWindGenerators` generators is swapped for `min(Game.windMin, cap)` and `min(Game.windMax, cap)`, where `cap` is the largest `windGenerator` among the tracked generators and the current wind comes from `select(4, Spring.GetWind())`.
* **Alerts:** the order from right to left is Need metal, Need energy, Idle buildpower, Need buildpower, Too much buildpower. "Too much buildpower" is hidden while a "Need metal/energy" box is shown, because they say the same thing and the row would run far under the metal bar. The boxes use the 1.1 s debounce of the stock banner, are hidden for spectators and before the warp-in frame, and can be turned off with the `alerts` option.
* **Stall tint:** additive flash on the BP element, `(1, 0.3, 0.3)` for a metal stall and `(1, 0.75, 0.2)` for an energy stall, alpha `0.1 * blinkProgress`.
* **Hover:** while the cursor is over BP, the markers grow by 1.25x (the counterpart of the stock knob enlargement), the cursor is reset and clicks are swallowed like on metal and energy.
* **No glow and no energy-style effect** on the BP fill (both optional in the design).
* **Options:** `enabled`, `widthFraction` (0.10 to 0.25), `indicators`, `windRange`, `alerts`, `icon`, `debugTooltip`. They are registered in one `WG.options.addOptions` call under ids `top_bar_bp_<key>` and persisted through `GetConfigData`/`SetConfigData`. `barScale`/`barWidth` are not ported.
* **Conflict warning:** at most one `Spring.Echo`. It fires from Initialize when `widgetHandler.orderList["Top Bar"] > 0` (only visible to archive widgets) or when the stock bar's `getResourceBarsVisible()` already exists, and from the 0.5 s check when `WG.topbar.GetPosition` is no longer ours.
* **WG.buildpower:** `{ GetData = function() return bp end, version = 1 }`. It is removed in Shutdown. `bp.cfg` is part of the returned table.

## Tests

* `tools/mock_env.lua`: added `Spring.GetUnitCurrentCommand`, `WG.options.addOptions` and `WG.options.removeOptions`.
* `tools/run_widget.py`: when `WG.buildpower` exists, it checks and prints the data after the 400 frames, and toggles every boolean option off and on. The stock widget still passes. The flags stay false in that run because the 1 s flag gate uses `os.clock`, and 400 frames take well under a second.
