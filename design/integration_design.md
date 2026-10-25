# Integration design: a buildpower (BP) bar in a fork of the current stock Top Bar

Status: design for the implementer. Nothing in this document has been implemented yet.
Base: `stock_reference/gui_top_bar.lua` (2896 lines, BAR `f616bd604`, last top bar change `459f6a59c`, 2026-09-24).
Companion: `design/bp_feature_spec.md` (what the BP numbers mean, how they are computed, and how 0.4.010 drew them).

## How references are written

| Prefix | File |
|---|---|
| `S:123` | `stock_reference/gui_top_bar.lua`, line 123 (the base we fork) |
| `B:123` | `stock_reference/gui_top_bar_buttons.lua` |
| `C:123` | `stock_reference/gui_converter_usage.lua` |
| `F:123` | `gui_top_bar_alpha_0.4.010.lua` (the previous fork, 2024 base) |
| `W:123` | BAR repo `luaui/barwidgets.lua` at `f616bd604` (the widget handler and sandbox) |
| `O:123` | BAR repo `luaui/Widgets/gui_options.lua` at `f616bd604` |
| `UI:123` | BAR repo `luaui/Widgets/gui_flowui.lua` at `f616bd604` |
| spec §n | `design/bp_feature_spec.md`, section n |

## 0. Decisions at a glance

1. **One file, one insertion block, small hooks.** All BP code lives in one contiguous block inserted between `updateResbarValues` and `init` (after S:1437), plus 3 table declarations near S:207, plus one-line hooks in stock functions, plus new call-ins appended at the end of the file. Stock lines are changed only where a hook is needed. A 3-way merge with future stock versions then conflicts only at the hooks.
2. **Three new top-level locals, no more:** `bp` (published data + `bp.cfg` options), `bpTrack` (unit tracking state and its functions), `bpUi` (render caches, dlists bookkeeping and draw functions). Every new function is a field of one of these tables. The stock main chunk has 169 of 200 local slots in use (section 4).
3. **Zero changes to `widget:DrawScreen`** (47 of 60 upvalues). All BP drawing goes through functions that DrawScreen already calls: `drawUiBackground` (via `renderUiBackground`), `drawUi` (via `renderUi`), `drawResBars`.
4. **BP rendering follows the stock split:**
   * background element → `uiBgTex` (blurred by guishader automatically),
   * static bar frame, red idle background, small icon → `dlist.resbar.BP[1]`, baked into `uiTex` by `drawUi`,
   * used/reserved fill, eco-support markers, wind strip, stall tint, alert boxes → per-frame display lists drawn by `drawResBars` (like `dlist.resValuesBar[res]` and the sliders), rebuilt only when a quantized pixel value changes, at most every 0.05 s,
   * percent text → rendered into `uiTex` with a scissor, like `drawResbarValue`, only when the rounded percent changes.
5. **Layout:** metal + BP + energy keep exactly the stock metal + energy footprint, so wind, tidal, coms, buttons, `GetPosition()` and `GetFreeArea()` do not move (section 3).
6. **BP element is a plain rectangle** (no skew params) between the slanted metal and energy elements, separated by `widgetSpaceMargin` (section 2).
7. **WG.topbar is kept byte-for-byte compatible** with stock, including the button fallbacks. Name `"Top Bar with Buildpower"` (no version number), file name `gui_top_bar_bp.lua`, layer `-95000`. The player must disable the stock "Top Bar"; a user widget cannot do that for them (section 6).

---

## 1. Rendering architecture of the stock top bar

### 1.1 The pieces

| Piece | Where | What it is |
|---|---|---|
| `uiBgTex` | created S:2359-2363, filled by `renderUiBackground` S:2284-2289 → `drawUiBackground` S:2113-2235 | Texture the size of `topbarArea`. Holds the dark element backgrounds (`UiElement`) of metal, energy, wind, tidal, coms. Rebuilt only when `refreshUi` is true. |
| `uiTex` | created S:2364-2375, filled by `renderUi` S:2291-2301 → `drawUi` S:2237-2281 | Texture the size of `topbarArea`. Holds static foreground (`dlist.resbar[res][1]`: icon + bar frame, S:973-1134; "no wind" text; tidal text) **and** all text that changes at runtime (current value, pull/income, storage, wind speed, com counter), which is patched in with scissored render-to-texture calls. |
| `dlist.blendBg`, `dlist.blendUi` | S:2388-2409 | The two per-frame blits of the textures, baked into display lists (one `glCallList` each per frame). Rebaked together with the textures. |
| `uiBgList` + guishader | S:2411-2423 | A display list that draws `uiBgTex`; registered once per refresh as `"topbar_background"`. The blur shape is the alpha of `uiBgTex`, so anything drawn in `drawUiBackground` is blurred automatically. Removed in Shutdown S:2856-2858. `guishaderEnabled` is polled every 0.5 s (S:1788-1797); when guishader appears, `init()` runs so the list is registered. |
| `gl.R2tHelper.RenderToTexture(tex, fn, customBlend, scissors)` | used S:2107, 2378, 2381, 2490, 2507, 2529 | Clears each scissor rectangle of `tex` to transparent (or the whole texture if `scissors` is nil or empty), then calls `fn` **without** a scissor. So the scissor only limits the clear, not the drawing: whatever `fn` draws outside the cleared rectangles is blended on top of old content. `fn` must only draw items that lie inside their cleared rectangle. Scissor rectangles are `{x, y, w, h}` in texture pixels, i.e. relative to `topbarArea[1], topbarArea[2]` (S:2055-2060). |
| `renderResbarText` | S:1902-1934 | The RTT draw function for resource text. Sets up the screen→texture transform (S:1903-1905) and draws only the dirty items. |
| `dlist` table | S:175-187 | All display lists. `dlist.resbar[res]` slots: `[1]` icon + bar frame (static, baked into uiTex), `[2]` share/conversion slider knobs (per frame), `[4]` flash/tint shape (per frame, S:566-633), `[7]` overflow warning banner (per frame, S:715-802). Slots 3, 5, 6 are unused today. `dlist.resValuesBar[res]` is the value fill + glow (per frame, S:1304-1395). `dlist.energyGlow` holds 4 lists animated through the texture matrix (S:1397-1434, 2017-2041). |
| `updateRes[res]` | S:172, reset S:1541, forced S:2298-2300 | Dirty flags per resource: `[1]` current value text, `[2]` pull + income text, `[3]` storage text, `[4]` set but never read. Note that `init()` **replaces** the whole table (S:1541). |
| `refreshUi` (widget global) | set in `init` S:1440 and by the visibility setters S:2757, 2783; cleared at the end of DrawScreen S:2538 | When true, DrawScreen recreates both textures, re-renders them and rebakes the blits. `updateResbar`, `updateWind`, `updateTidal`, `updateComs` also use it to decide whether to (re)register tooltips and recompute text positions. |
| `timers` | S:240-252 | All periodic gates (see 1.3). |
| `smoothedResources`, `smoothResources()` | S:210-225 | Exponential smoothing (factor 0.5) of all 6 `GetTeamResources` values, run every 0.07 s (S:1858-1861). It snaps to the raw values when a big share transfer arrives (S:1875-1882) and on spectator team change (S:2667). The **displayed** fill and current value use the smoothed values (S:1284-1293, S:828). |
| `r` | S:75, replaced S:1442, S:1866, S:2663 | Raw `GetTeamResources` results (`current, storage, pull, income, expense, share, sent, received`), refreshed every 0.25 s. The table is replaced, never mutated, so never store anything else in it (0.4.010 did `r.BP = BP`, F:1606-1608; that would now be lost 4 times a second). |

### 1.2 The functions an implementer touches

| Function | Lines | Role |
|---|---|---|
| `updateResbar(res)` | S:857-1274 | Geometry of one resource section (`barArea`, `resbarDrawinfo[res]` text positions S:930-964), builds `dlist.resbar[res][1]` (icon + frame) and `[2]` (sliders), registers slider/pull/income/storage tooltips (S:1203-1273). Called from `init`, from the hover logic in `Update` (S:1802-1819) to enlarge the knobs, from slider dragging (S:2553, 2570), from `WG.topbar.updateTopBarEnergy`. |
| `updateResbarValues(res, update)` | S:1276-1437 | Called from `drawResBars` on the 0.05 s tick. Sets `updateRes[res][1]` when the shortened smoothed value changes (S:1284-1286). Rebuilds `dlist.resValuesBar[res]` only when the fill width in pixels changes (S:1297). |
| `updateResbarText(res, force)` | S:560-825 | Called every 0.25 s and from `init`. Builds the flash shape `[4]`, sets `updateRes[res][3]` / `[2]` when storage or pull/income text changes (S:636-650), and runs the overflow warning logic (S:652-824). |
| `drawResbarValue(res)` | S:827-846 | RTT draw of the current value. Remembers its text and width in `cache.lastDrawnValue` / `cache.lastResbarValueWidth` (used to size the scissor next time, S:2056-2058). |
| `drawResbarPullIncome(res)` | S:509-531 | RTT draw of `-pull` and `+income`. |
| `drawResbarStorage(res)` | S:533-552 | RTT draw of storage; draws nothing while the warning banner is showing (S:534-536). |
| `renderResbarText()` | S:1902-1934 | The RTT function that calls the three above for dirty items. |
| `drawResBars()` | S:1936-2110 | Per frame: flash tint (S:1952-1971), value fill, energy glow, sliders, warning banner. On the 0.05 s tick it also calls `updateResbarValues` and, if any text is dirty, builds the scissor list and calls `RenderToTexture(uiTex, renderResbarText, true, scissors)` (S:2051-2109). |
| `drawUiBackground()` | S:2113-2235 | All `UiElement` backgrounds, with skew params. |
| `drawUi()` | S:2237-2281 | Static foreground: `dlist.resbar.energy[1]`, `dlist.resbar.metal[1]`, no-wind text, tidal text. |
| `hoveringElement(x, y)` | S:1666-1693 | Returns `"metal"`, `"energy"`, `"wind"`, `"tidal"`, `"com"` or false. Feeds `hoveringTopbar`, which sets the normal cursor (S:2351-2353) and makes `MousePress` swallow clicks (S:2635-2637). |

### 1.3 Data flow per frame

`widget:Update(dt)` (S:1740-1898), every frame:

1. `now = os.clock()`, `provideButtonFallbacks()` (S:1743, see 6.4).
2. `timers.deferResourceUpdate` = a sim frame happened within the last 1/30 s (S:1744). Used by `drawResBars` to postpone the 0.05 s bar work away from sim frames.
3. Wind blade angle (S:1748).
4. Every 0.033 s (S:1750-1786): spectator team change → `checkSelfStatus(); init()`; mouse position → `hoveringTopbar = hoveringElement(mx, my)`; blink animation (`blinkProgress`).
5. Every 0.5 s (S:1788-1797): guishader appeared → `init()`.
6. Every 0.05 s (S:1799-1856): hover enter/leave on metal/energy → `updateResbar(res)` (bigger knobs); spectators: team change (S:1820-1829, note: changes `myTeamID` **without** calling `init()`) and slider sync; players: conversion/share slider sync.
7. Every 0.07 s: `smoothResources()` (S:1858-1861).
8. Every 0.25 s (S:1863-1897): new `r`, smoothing snap, `updateAllyTeamOverflowing()`, `updateResbarText("metal")`, `updateResbarText("energy")`, wind text, `countComs()`.

`widget:DrawScreen()` (S:2347-2539), every frame:

1. If `refreshUi`: recreate `uiBgTex` and `uiTex`, RTT `renderUiBackground` and `renderUi` (which also forces all `updateRes` text flags, S:2296-2300), rebake `dlist.blendBg`/`blendUi`, re-register guishader (S:2355-2424).
2. `glCallList(dlist.blendBg)`.
3. Wind blades, tidal waves (animated, drawn directly).
4. Once per warning activation: clear the storage text region of `uiTex` (S:2454-2492, see 1.4).
5. `glCallList(dlist.blendUi)`.
6. Wind speed text RTT when it changed (S:2498-2509).
7. `drawResBars()`: per-frame lists on top of `uiTex`; on the 0.05 s tick, scissored text RTT into `uiTex` (visible from the next frame on).
8. Com counter RTT when needed (S:2513-2531).
9. `refreshUi = false`.

`init()` (S:1439-1543, a widget global so it can be called from `ViewResize` before its definition): `refreshUi = true`; fresh `r`; `topbarArea`; areas and `updateResbar` per section; `updateWind/Tidal/Coms`; the `WG.topbar.GetPosition/GetFreeArea/GetSkewConfig` closures; `updateResbarText(res, true)`; all text flags true. It runs from `ViewResize` (also via `LanguageChanged`), `GameStart`, `GameFrame(2)`, spectator team change, guishader appearing, `PlayerChanged` when becoming a spectator, and `setResourceBarsVisible(true)`.

**Which function to touch for what:**

| You want to change | Touch |
|---|---|
| Position or size of a section | `init` |
| Background shape of a section | `drawUiBackground` |
| Icon, bar frame, anything static in a section | the `[1]` list in `updateResbar` (and `drawUi` to draw it) |
| Something that moves with the value | a per-frame list drawn in `drawResBars`, rebuilt from the 0.05 s tick |
| Text that changes | RTT: a dirty flag, a scissor in `drawResBars`, a draw in `renderResbarText` |
| Tooltips | `WG.tooltip.AddTooltip` in `updateResbar` (static) or in the 0.25 s block (dynamic, see 5.10) |
| Periodic data refresh | the 0.25 s block of `Update` |
| Sim-synchronous work | `widget:GameFrame` |

### 1.4 Warning banner mechanics

* Trigger (S:652-657): not spectating, past `cfg.spawnWarpInFrame` (90 frames), and own or ally-team overflow flags from `updateAllyTeamOverflowing` (S:1607-1664).
* Debounce: `showOverflowTooltip[res] = now + 1.1` on first detection (S:658-660); the banner appears only after that (S:662).
* On activation: `showingWarning[res] = true` and `updateRes[res][3] = true` (S:708-711). The storage text RTT then clears its scissor and `drawResbarStorage` draws nothing, which erases the storage number under the banner.
* Banner list `dlist.resbar[res][7]` (S:719-802) is rebuilt only when the text changes (`cache.lastWarning`, S:712). It sits at the **top right inside** the section (`resbarArea[4] - bannerH` to `resbarArea[4]`), shifted left by `bannerH * skewTan * 0.5` on energy so it stays inside the slanted edge (S:751-754). It is drawn per frame in `drawResBars` (S:1983-1985, 2046-2048).
* Because `drawResBars` patches `uiTex` after `blendUi` has been drawn, the old storage text would flash for up to 50 ms. DrawScreen therefore clears the storage regions once per activation with `storageScissors` and `clearFn` (S:2454-2492), guarded by `cache.warningCleared[res]`, which is reset when the warning ends (S:820).
* On deactivation everything is cleaned up and the storage text is redrawn (S:805-823).
* Also `WG.notifications.queueNotification(...)` events (S:671-705) with team-size and shared-frame suppression.
* Separate from the banner, the flash tint `dlist.resbar[res][4]` is drawn additively per frame while overflowing or when storage is almost empty (S:1952-1971, 1990-2009).

### 1.5 Hover, sliders, tooltips

* Hover: `hoveringTopbar` (every 0.033 s) and `resbarHover` (every 0.05 s, players only, not while the quit dialog is up via `showingQuitscreen()` S:556-558). `resbarHover == res` only enlarges `sliderHeightAdd` (S:888-892), and `updateResbar(res)` is re-run on enter/leave.
* Share slider (S:1163-1192): knob at `barArea[1] + r[res][6] * barWidth`, `UiSliderKnob(cx, cy, radius, {0.85,0,0,1})`, area kept in `shareIndicatorArea[res]` for `MousePress` (S:2585-2610). Hidden in single-player teams (`isSingle`).
* Conversion slider (energy only, S:1137-1161): knob at `mmLevel` (team rules param), area in `conversionIndicatorArea`, drag sends `Spring.SendLuaRulesMsg(char(137)..value)` clamped 12..88 (S:2556-2571).
* Dragging: `MousePress` S:2581-2638, `MouseMove` → `adjustSliders` S:2541-2572, `MouseRelease` S:2640-2649.
* Tooltips: `WG.tooltip.AddTooltip(name, area, text, delay, title)` (stock tooltip widget: same name updates; a call with a text deletes the cached tooltip display list, so do not re-add an unchanged text every tick). Registered in `updateResbar` (sliders S:1203-1251 every call; pull/income/storage only `if refreshUi`, S:1252-1272), `updateComs` S:385-393, `updateWind` S:446-458, `updateTidal` S:498-506; removed in Shutdown S:2860-2878.

---

## 2. Skew geometry and the BP element

### 2.1 Stock skew

* `cfg.useSkew = true`, `cfg.skewAngleDeg = 20`, `cfg.smallElementHeightFraction = 0.85` (S:52-54). `skewTan = tan(20°) ≈ 0.364` (S:58, refreshed in `init` S:1465).
* FlowUI skew params (UI:308-322) are per-corner pixel offsets from the base rectangle: `blx` moves the bottom-left corner, `brx` the bottom-right, positive x to the right. `WG.FlowUI.Draw.RectRoundQuad(px,py,sx,sy,cs,tl,tr,br,bl,c1,c2,skew)` (UI:338) draws the chamfered quad; `WG.FlowUI.Draw.Element(...)` (UI:1020) takes `skew` as its 18th argument and derives the skew of every inner layer from the outer slopes (UI:1063-1085). Without `skew` it uses plain `RectRound`.
* With `H = area[4] - area[2]`:
  * **metal**: `{ blx = H * skewTan }` (S:2140, S:572). The bottom-left corner moves right, so the left edge runs from top-left down to the right: the outer left edge is slanted, the inner right edge is vertical.
  * **energy**: `{ brx = -(H * skewTan) }` (S:2116, S:602). The bottom-right corner moves left: outer right edge slanted, inner left edge vertical.
  * Metal + energy together form one inverted trapezoid hanging from the top of the screen, split by a vertical gap of `widgetSpaceMargin` (`WG.FlowUI.elementMargin` = `floor(0.0045 * vsy * scale)`, 4 px at 1080p).
  * **small elements** (wind, tidal, coms, and the buttons in the other widget): `{ blx = -(H*skewTan), brx = -(H*skewTan) }` (S:2165, 2189, 2213; C:136 does the same for Converter Usage), i.e. parallelograms leaning the same way as the energy edge, and shorter: top-aligned with `smallVPad = floor(H * (1 - 0.85))` added to their bottom (S:1466-1467).
* Content inset on slanted sides: `skewSideInset = floor(H * skewTan * 0.5)` (S:873), the shift of the slanted edge at mid-height (8 px at 1080p). Added to `barLeftPadding` for metal and to `barRightPadding` for energy (S:874-875); the metal icon is shifted by it too (S:989). The comment at S:872 still says 22.5°; the value is 20°.
* Centred content in parallelograms is shifted left by `H * skewTan * 0.5` (`skewCenterOffset`, S:351, 425, 2246, 2270, 2310).
* `GetPosition()` reports the left edge plus the full top-left skew offset (S:1509-1511), so widgets attached below start right of the slant. `GetSkewConfig()` (S:1529-1535) exposes `useSkew`, `skewTan`, `smallElementHeightFraction`.
* Drawing helpers bound in `ViewResize` (S:279-285): `RectRound` (bar frames, fills, banners: unskewed, the bars are inset enough), `RectRoundOutline` (bar outlines), `TexturedRectRound` (noise texture), `UiElement` = `FlowUI.Draw.Element` (backgrounds), `UiSliderKnob` = `FlowUI.Draw.SliderKnob(x, y, radius, color)` (knobs). `WG.FlowUI.Draw.RectRoundQuad` is called directly for the skewed flash shapes (S:573-630).

### 2.2 The BP element: a plain rectangle in the middle

```
 screen top ───────────────────────────────────────────────────────────────────
 \  [M icon]  -pull  12k   ▕ ▕   [b]   73%   ▕ ▕  [E icon]  -pull   3.4k  /  ⟋wind⟋
  \           +inc ▬▬▬▬▬▬  ▕ ▕   ▬▬▬▬▬▬▬▬▬   ▕ ▕            +inc ▬▬▬▬▬▬  /  ⟋    ⟋
   \___________________________▕ ▕_______________▕ ▕_________________________/
        metal (left slant)   gap     BP (rect)   gap    energy (right slant)
```

* The two edges of BP face the vertical inner edges of metal and energy, so BP has **no slanted edge**: pass **no skew** (`nil`), which also makes FlowUI use `RectRound`. A parallelogram would need matching slants on the metal and energy inner edges, which stock does not have; changing those would touch every metal/energy draw call.
* Same corners as metal/energy: `tl = 0, tr = 0, br = 1, bl = 1` (top corners square against the screen edge).
* Same full height as metal/energy (`topbarArea[2]` to `topbarArea[4]`), not `smallVPad`.
* `skewSideInset = 0` on both sides; no `skewCenterOffset`.
* The continuous dark strip stays continuous: metal | 4 px gap | BP | 4 px gap | energy, the same gap stock already has between metal and energy.
* Guishader blur follows automatically because the element is drawn into `uiBgTex`.

### 2.3 Every rectangle of the BP section

Let `A = resbarArea.BP = {x0, y0, x1, y1}` (from `init`, section 3), `ws = widgetScale`, `H = y1 - y0`. Numbers in brackets are for 1920×1080, `ui_scale 1` (`ws ≈ 0.998`, `H = 46`, `A` width 102).

| Rectangle | Definition | Notes |
|---|---|---|
| Element background | `UiElement(x0, y0, x1, y1, 0, 0, 1, 1)` in `drawUiBackground`, all later arguments nil | no skew argument (the 18th) |
| `barH` | `mathFloor((height * ws / 7) + 0.5)` [7] | identical to stock S:869 |
| `barPadY` | `mathFloor(((height / 4.4) * ws) + 0.5)` [10] | identical to stock S:870, so all three bars line up |
| `padX` | `mathFloor(12 * ws)` [11] | no icon column, no skew inset |
| `barArea` (`resbarDrawinfo.BP.barArea`) | `{ x0 + padX, y0 + barPadY, x1 - padX, y0 + barPadY + barH }` [80 × 7 px] | used by fill, markers, tooltip |
| Icon (optional, `bp.cfg.icon`) | size `iconS = mathFloor((height / 3.2) * ws)` [14]; rect `{ barArea[1], y1 - bgpadding - iconS, barArea[1] + iconS, y1 - bgpadding }` | static, in `dlist.resbar.BP[1]`; texture `":lr"..(2*iconS)..","..(2*iconS)..":LuaUI/Images/groupicons/builder.png"` (exists in the game), tinted `glColor(0.75, 0.9, 0.75, 1)`. 0.4.010 used `stripes.png` with a typo'd option string (spec §6.2, B23). |
| Percent text (`resbarDrawinfo.BP.textPct`) | `{ cx, barArea[2] + barH * 1.8, (height / 2.5) * ws, "ocd" }` with `cx = (barArea[1] + (iconShown and iconS + 2 or 0) + barArea[3]) / 2` [size 18.4] | same baseline and size as stock `textCurrent` (S:930-936) |
| `pctMaxW` | `font2:GetTextWidth("100%") * textPct[3]` | computed in `updateBar` |
| Text scissor (`bpUi.textScissor`, texture coords) | `{ sx - topbarArea[1], H * 0.48, sw, H }` with `sx = mathMax(x0, cx - pctMaxW/2 - 2)`, `sw = mathMin(x1, cx + pctMaxW/2 + 2) - sx` | 0.48·H is the stock lower bound for top-half text (S:2057), just above the bar frame outline. Must not overlap the icon: if `iconShown and barArea[1] + iconS >= sx`, drop the icon (set `iconShown = false`) and recompute `cx`. The clear erases whatever is in this rectangle of `uiTex`, so keep all static BP content out of it. |
| Red idle background | first `RectRound` of the frame (copy of S:1001-1013) with `{1,0,0,0.22}` / `{1,0,0,0.25}` instead of the black gradient | restores the regression documented in spec §6.2 |
| Used fill | `RectRound(barArea[1], barArea[2], barArea[1] + usedW, barArea[4], barH*0.2, 1,1,1,1, {0.2,0.65,0,1}, {0.5,0.75,0,1})` + inner shade (copy of S:1331-1344) | `usedW = max(ceil(barH*0.2), floor(usedRatio * barW))` |
| Reserved fill | `RectRound(barArea[1], ..., barArea[1] + reservedW, ..., {0.1,0.55,0,0.5}, {0.3,0.65,0,0.5})`, drawn after the used fill | `reservedW = floor(reservedRatio * barW)`; skip when `reservedW - usedW < ceil(barH*0.2)` |
| Glow (optional) | copy of S:1346-1373 with `barColor {0,1,0}` and a small constant alpha (0.035) | fixes spec B13 by using the BP `barArea` |
| Metal marker | bottom edge, pointing up: x centre `barArea[1] + mSupportRatio*barW`, y `barArea[2] + 0.4*barH - barH*mult` .. `barArea[2] + 0.4*barH`, half width `0.6*barH*mult`, corners `1,1,0,0`, `{0.6,0.6,0.6,1}`/`{1,1,1,1}` | `mult = 1.4` while `bp.stallingMetal` (spec §6.2) |
| Energy marker | top edge, pointing down: y `barArea[4] - 0.4*barH` .. `barArea[4] - 0.4*barH + barH*mult`, corners `0,0,1,1`, `{0.8,0.8,0,1}`/`{1,1,0.2,1}` | top reaches `y0 + 24` at 1080p when stalling, 1-2 px into the text band; acceptable because the per-frame list is drawn over `uiTex` |
| Wind range strip | x `eSupportMinWind*barW .. eSupportMaxWind*barW` (± half marker width), y `barArea[4] + 0.4*barH .. barArea[4] + 0.6*barH`, no corners, `{0.8,0.8,0,1}`/`{0.4,0.4,0,1}` | only if `bp.cfg.windRange and bp.numWindGenerators > 0` and both ends non-nil |
| Marker x clamp | all marker centres clamped to `[barArea[1], barArea[3]]` | |
| Stall tint (optional) | `dlist.resbar.BP[4]` = `RectRound(x0, y0, x1, y1, 5.5*ws, 0,0,1,1)`, drawn per frame with an **explicit** `glColor(1, 0.25, 0.25, 0.08 * blinkProgress)` and additive blending, like S:1952-1971 | fixes spec B12 |
| Alert boxes | below the section: y from `y0 - 15.5*ws` to `y0`, right-aligned at `x1`, stacked to the left in the order Need metal, Need energy, Idle buildpower; font size `(orgHeight*(1+(ui_scale-1)/1.33)/4)*ws`, text `"   "..text.."   "` (spec §5.3) | they extend under the metal section, and they cover the first console line of `gui_chat`, which positions itself right under `GetPosition()` (gui_chat.lua:4443-4449). Keep them optional (`bp.cfg.alerts`). |
| Tooltip area | `resbarArea.BP` (the whole section, including the percent text) | one tooltip `"BP_bar"`, title "Buildpower" |

The section has no pull/income/storage text, no share slider and no conversion slider.

---

## 3. Layout change in `init()`

Stock (S:1446-1460): `width = floor(totalWidth / 4.4)`; metal `[x, x+width]`; energy `[x+width+m, x+2·width+m]`; `filledWidth = 2·width + 2·m` when wind starts. (`x = topbarArea[1]`, `m = widgetSpaceMargin`.)

New: keep `span = 2·width + m` (the outer extent of metal..energy) and split it into three. The energy right edge is computed from the span, not accumulated, so rounding can never shift wind.

```lua
-- replaces S:1449-1460
local width = mathFloor(totalWidth / 4.4)
local span = 2 * width + widgetSpaceMargin -- stock metal..energy footprint, never changes
local meW, bpW = width, 0
if bp.cfg.enabled then
	bpW = mathFloor(2 * width * bp.cfg.widthFraction) -- default 1/6, slider 0.10-0.25
	meW = mathFloor((span - 2 * widgetSpaceMargin - bpW) / 2)
	bpW = span - 2 * widgetSpaceMargin - 2 * meW -- rounding remainder goes to BP
end
local x = topbarArea[1]
resbarArea.metal = { x, topbarArea[2], x + meW, topbarArea[4] }
updateResbar("metal")
if bp.cfg.enabled then
	resbarArea.BP = { x + meW + widgetSpaceMargin, topbarArea[2], x + meW + widgetSpaceMargin + bpW, topbarArea[4] }
	updateResbar("BP") -- dispatches to bpUi.updateBar()
else
	resbarArea.BP = {} -- every BP code path checks resbarArea.BP[1]
end
resbarArea.energy = { x + span - meW, topbarArea[2], x + span, topbarArea[4] }
updateResbar("energy")
filledWidth = span + widgetSpaceMargin -- identical to stock: 2*width + 2*margin
```

With BP disabled, `meW = width` and the result is exactly stock.

Resulting sizes:

| | 1920×1080 | 2560×1440 |
|---|---|---|
| `topbarArea[1]`, `totalWidth` | 580, 1340 | 774, 1786 |
| stock metal / energy width | 304 / 304 | 405 / 405 |
| new metal / BP / energy width | 251 / 102 / 251 | 334 / 136 / 334 |
| metal fill bar width, stock → new | 185 → 132 px | 244 → 173 px |
| BP fill bar width | 80 px | 106 px |
| wind starts at | 1196 (unchanged) | 1590 (unchanged) |

Metal and energy bars lose about 29 % of their width. That is the same trade-off 0.4.010 made (spec §6.1). The `widthFraction` option lets the player pick.

**Check of everything that depends on the layout:**

* `wind`, `tidal`, `coms` areas start at `x + filledWidth` (S:1468, 1479, 1492): unchanged because `filledWidth` is unchanged.
* `GetPosition()` (S:1508-1518) uses only `topbarArea`, `skewTan`, `widgetSpaceMargin`, `widgetScale`, `buttonsBottom`: unchanged.
* `GetFreeArea()` (S:1520-1528) closes over the locals `filledWidth` and `width` of `init`. `width` must still be `mathFloor(totalWidth / 4)` when `init` returns (S:1504), so do **not** reuse `width` for the BP split after that line, and keep the names `meW`/`bpW` separate. `filledWidth` after coms is unchanged. Result unchanged, so Converter Usage (C:74-90) stays put.
* `GetSkewConfig()`: unchanged.
* `gui_top_bar_buttons` computes its own `topbarArea` and button area from the same constants (`relXpos 0.3`, height, `width = totalWidth/4`; B:45-50, 338-347). It does not read our areas, so it stays aligned as long as we keep `cfg.relXpos`, `orgHeight`, `ui_scale` handling and `totalWidth/4` unchanged. **Do not port** 0.4.010's `barScale` and `barWidth` options (F:66-84): they change `height`/`totalWidth` in our widget only and would misalign the buttons widget, chat, minimap, PIP and the other `WG.topbar` consumers (gui_chat, gui_converter_usage, gui_ecostats, gui_minimap, gui_pip, gui_spectator_hud, gui_vote_interface). Also do not port `autoHideButtons`: the buttons widget owns that now (`topbar_hidebuttons`, O:7268-7281).
* The 0.4.010 clamp against `maxTopBarWidth` (F:1620-1636) is not needed because the footprint does not grow.

---

## 4. Lua 5.1 limits

### 4.1 Measured state of the stock file

Measured by compiling the file with a real Lua 5.1 compiler (lupa `lua51`), dumping the bytecode and reading each prototype's `nups` and local-variable table:

* **Main chunk locals: 169 of 200.** There are 154 `^local ` statements at column 0; several declare more than one name (S:76, 87, 171 declares 7, 229, 230, 231 declares 4). Cross-check: appending 31 extra top-level locals compiles, 32 fails with `main function has more than 200 local variables`. **31 slots are free**, and upstream keeps adding locals (the September 2025 "Reduce # of local variables" commit shows they hit the cap before).
* **Upvalues (limit 60 per function)** of the functions that matter:

| Function | Lines | Upvalues |
|---|---|---|
| `widget:DrawScreen` | S:2347 | **47** |
| `updateResbar` | S:857 | 38 |
| `widget:Update` | S:1740 | 36 |
| `updateResbarText` | S:560 | 30 |
| `drawResBars` | S:1936 | 28 |
| `widget:Initialize` | S:2703 | 27 |
| `init` | S:1439 | 26 |
| `updateResbarValues` | S:1276 | 21 |
| `widget:ViewResize` | S:274 | 19 |
| `drawUi` | S:2237 | 14 |
| `widget:PlayerChanged` | S:2651 | 11 |
| `drawUiBackground` | S:2113 | 10 |
| `renderResbarText` | S:1902 | 7 |
| `hoveringElement` | S:1666 | 7 |
| `widget:UnitDestroyed` | S:2687 | 6 |
| `renderUi` | S:2291 | 5 |
| `widget:GameFrame` | S:1598 | 4 |
| `widget:Shutdown` | S:2812 | 3 |

  The stock comments call DrawScreen "at the Lua 5.1 upvalue cap" (S:2421) and avoid local gl aliases in it on purpose (S:2387). The compiler reports 47 today; treat the comments as upstream's reservation of that headroom. **DrawScreen gets no new upvalues.**

### 4.2 How stock stays under the limits

* Tables instead of locals: `sp` for Spring functions (S:29-42), `cfg` (S:45-55), `textures` (S:140-148), `dlist` (S:175-187), `cache` (S:190-200), `timers` (S:240-252); per-resource tables keyed by `res` (`resbarArea`, `resbarDrawinfo`, `shareIndicatorArea`, `updateRes`, `showingWarning`, `smoothedResources`). The comments at S:28, 44, 174, 189, 237 say "save local slots".
* Widget-environment globals instead of locals: `init` (S:1439 `function init()`), `refreshUi`, `uiTex`, `uiBgTex`, `uiBgList`, `comsDlistUpdate` (S:344), `prevComAlert` (S:1542). They live in the widget's own environment table, cost no local slot and no upvalue. Do not add more of these for BP: in a widget the environment is the `widget` table itself (W:1316-1317), so a global name can silently overwrite a call-in or a handler field.
* Raw `gl.*` globals inside DrawScreen's list bakes (S:2391-2420) and `self` instead of `widget` (S:2422) to avoid upvalues.
* Pre-declared draw functions and scratch tables (`clearFn`, `render*`, `windTextScissor`, `storageScissors`; S:202-207, 1900-1901, 2283) to avoid closures and garbage.

### 4.3 Rules for the BP code

1. **Exactly three new top-level locals**, declared together in one block right after S:207:
   ```lua
   -- Buildpower (all BP state lives in these three tables; see design/integration_design.md)
   local bp = { cfg = { enabled = true, widthFraction = 1 / 6, indicators = true, windRange = true,
   	alerts = true, icon = true, debugTooltip = false } } -- data fields: spec §11
   local bpTrack = { ids = {}, rec = {}, pass = {}, passCount = 0, cursor = 1, nextFrame = 0,
   	perFrame = 20, frameStep = 3 }
   local bpUi = { last = {}, textDirty = false, textScissor = nil, pct = nil }
   ```
   That leaves 28 free slots for upstream.
2. **Every new function is a field** of `bp`, `bpTrack` or `bpUi` (`function bpUi.updateBar() ... end`). No new `local function` at top level. Field calls cost one table lookup; that is fine at the cadences below.
3. **Do not add fields to stock tables that are re-created at runtime:** `r` (S:1442, 1866, 2663), `smoothedResources` (aliased to `r`, S:1881, 2667), `updateRes` (S:1541), `cache.lastValueWidth` (S:300). BP caches go to `bpUi`. Fields in stable containers are fine: `resbarArea.BP`, `resbarDrawinfo.BP`, `dlist.resbar.BP`, `dlist.resValuesBar.BP`.
4. **Do not add Spring functions to `sp`** (that is a stock line, merge conflicts). Put the ones BP needs into `bpTrack` (`bpTrack.GetUnitCommands = Spring.GetUnitCommands`, ...).
5. **Upvalue budget for hooks:** each hook adds 1 (`bpUi` or `bpTrack`) to the stock function. DrawScreen: 0. The new functions themselves start empty and have plenty of room, but `bpUi.updateBar` will reference about 25 stock locals (fonts, FlowUI helpers, gl aliases, geometry); keep it below 50 by splitting the frame drawing into `bpUi.drawFrame` (section 5.4).
6. The BP block must be placed **after** S:1437 because its functions reference `fillRatio` (S:850), `short` (S:308), `DrawRect` (S:270), the FlowUI helpers and gl aliases. The three tables must be declared **before** the first stock function that hooks into them (`updateResbar`, S:857), hence after S:207.
7. Verify after every change: compile with Lua 5.1 and check the main chunk count (≤ 172) and DrawScreen (47). In this session a checker exists at `/tmp/claude-0/-home-user-widgets-for-BAR/2298421d-2cd4-596c-a559-05ae08eced61/scratchpad/tools/lua51_protos.py` (run with the scratchpad venv's python and `-I`); it is temporary, so copy it into the repo (e.g. `tools/`) if it should be kept. `luac5.1 -l -l` gives the same information where available.

---

## 5. Ordered list of edits

Each item: where, what, upvalue effect. "BP block" means the insertion after S:1437.

### 5.1 `GetInfo` (S:3-14)

```lua
name = "Top Bar with Buildpower", -- no version number: config data is stored by name (W:1428-1431)
desc = "The stock top bar plus a buildpower bar. Disable the stock \"Top Bar\" when using this.",
author = "Floris, Robert82",
layer = -95000, -- same as stock and Top Bar Buttons
enabled = false, -- see 6.6: avoids drawing on top of the stock bar on first launch
handler = true, -- ignored for user widgets (W:1416), kept for a smaller diff
```

### 5.2 Table declarations

* After S:207: the three tables from 4.3 rule 1.
* S:153 `resbarArea = { metal = {}, energy = {}, BP = {} }`.
* S:154 `resbarDrawinfo = { metal = {}, energy = {}, BP = {} }`.
* S:179 `resbar = { metal = {}, energy = {}, BP = {} }`.
* Do **not** add BP to `shareIndicatorArea`, `updateRes`, `cache`, `showingWarning`, `smoothedResources` (reasons in 4.3 rule 3). `updateRes.BP` would have to be added in three places (S:172, S:1541, S:2298-2300); a single `bpUi.textDirty` flag does the same job with one hook.

### 5.3 `updateResbar` (S:857)

After the `showResourceBars` check (S:858-860):
```lua
if res == "BP" then
	return bpUi.updateBar()
end
```
38 → 39 upvalues. Nothing else in `updateResbar` changes, so the 400-line stock function merges cleanly. `updateResbarText` and `updateResbarValues` are **never** called with `"BP"`.

### 5.4 BP block (new, after S:1437)

Functions and what each does:

* `bpUi.updateBar()`, called from `init` via `updateResbar("BP")`:
  * computes every rectangle of section 2.3 into `resbarDrawinfo.BP` (`barArea`, `textPct`, `iconRect`, `iconShown`) and `bpUi.textScissor`,
  * resets `bpUi.last` (forces fill and alert lists to rebuild; required after `ViewResize`, which deletes `dlist.resValuesBar.*`, S:295-297),
  * rebuilds `dlist.resbar.BP[1]` = `bpUi.drawFrame` (icon, red idle background, copy of the stock frame, outline, noise, gloss from S:998-1133 with BP colours; mark the copy `-- copied from updateResbar S:998-1133, keep in sync`),
  * rebuilds `dlist.resbar.BP[4]` (stall tint shape),
  * registers the tooltip `"BP_bar"` over `resbarArea.BP` (the area table is replaced on every `init`, so it must be registered here),
  * sets `bpUi.textDirty = true`.
* `bpUi.refreshValues()`, from `drawResBars` on the 0.05 s tick:
  * optionally smooths the displayed ratios: `s = s + 0.5 * (target - s)`, same factor as S:214,
  * quantizes to pixels: `usedW`, `reservedW`, `mX`, `eX`, `wMinX`, `wMaxX`, `stallM`, `stallE`,
  * compares each with `bpUi.last.*` field by field (no key strings, no garbage), and only on a change rebuilds `dlist.resValuesBar.BP` with `bpUi.buildValueList`,
  * computes `pct = mathFloor(usedRatio * 100 + 0.5)` clamped to 0..100; if `pct ~= bpUi.pct`, sets `bpUi.pct`, the colour (`<40` `{0.82,0.39,0.39}`, `<60` `{1,0.6,0.2}`, `<80` `{1,1,0.39}`, else `{0.47,0.92,0.47}`, spec §6.2/B25) and `bpUi.textDirty = true`. Shows no text while `bp.total == 0` or `not bp.hasData`.
* `bpUi.buildValueList()`: one display list with used fill, reserved fill, optional glow, wind strip, then metal and energy markers (only if `bp.cfg.indicators`). It replaces the single list in `dlist.resValuesBar.BP`, which `ViewResize` and `Shutdown` already delete. Never key lists by value (spec B17).
* `bpUi.drawText()`, called from `renderResbarText` inside the RTT transform:
  ```lua
  function bpUi.drawText()
  	local t = resbarDrawinfo.BP.textPct
  	if not t or not bpUi.pct then return end -- the clear already removed the old text
  	local c = bpUi.pctColor
  	font2:Begin(true)
  	font2:SetOutlineColor(0, 0, 0, 1)
  	font2:SetTextColor(c[1], c[2], c[3], 1)
  	font2:Print(bpUi.pctStrings[bpUi.pct], t[1], t[2], t[3], t[4]) -- pctStrings[i] = i .. "%", filled lazily
  	font2:End()
  end
  ```
* `bpUi.drawBars(update)`, from `drawResBars` every frame:
  ```lua
  function bpUi.drawBars(update)
  	if not resbarArea.BP[1] or not dlist.resbar.BP[1] then return end
  	if update then bpUi.refreshValues() end
  	if (bp.stallingMetal or bp.stallingEnergy) and not spec and gameFrame > cfg.spawnWarpInFrame and dlist.resbar.BP[4] then
  		glBlending(GL.SRC_ALPHA, GL.ONE)
  		glColor(1, 0.25, 0.25, 0.08 * blinkProgress)
  		glCallList(dlist.resbar.BP[4])
  		glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
  	end
  	if dlist.resValuesBar.BP then glCallList(dlist.resValuesBar.BP) end
  	if bpUi.alertsShown and dlist.resbar.BP[7] then glCallList(dlist.resbar.BP[7]) end
  end
  ```
* `bpUi.slowUpdate()`, from the 0.25 s block of `Update`:
  * `bpTrack.checkTeam()` (see 5.13),
  * `bpTrack.updateFlags()` once per second (`stallingMetal`, `stallingEnergy`, `idleAlert`, spec §5.1-5.2), reading `r.metal[1]`, `r.metal[3]`, `r.metal[4]` (current, pull, income) from the stock `r`, which was just refreshed at S:1866. No second `GetTeamResources` call.
  * alerts: `want = bp.cfg.alerts and not spec and gameFrame > cfg.spawnWarpInFrame and (bp.stallingMetal or bp.stallingEnergy or bp.idleAlert)`; same 1.1 s debounce as S:658-662 (`bpUi.alertSince`); rebuild `dlist.resbar.BP[7]` only when the set of active alerts (a 3-bit number) changes; `bpUi.alertsShown` true after the debounce. No `WG.notifications` events: the game has none for BP.
  * tooltip: only while `hoveringTopbar == "BP"` (or once after `updateBar`), build the text (spec §7, without the debug block unless `bp.cfg.debugTooltip`) and call `WG.tooltip.AddTooltip("BP_bar", resbarArea.BP, text, nil, "Buildpower")` only if `text ~= bpUi.lastTooltip`.
* `bpUi.checkConflict()`, from the 0.5 s block of `Update`: if `WG.topbar and WG.topbar.GetPosition ~= bpUi.ownGetPosition`, another resource top bar (the stock one) has overwritten our closures. `Spring.Echo` one warning ("disable the stock Top Bar") and set `bpUi.warned`. The buttons widget never does this, because its fallbacks only fill nil fields (B:1101-1108).
* `bpTrack.*`: `track(unitID, unitDefID, teamID)`, `untrack(unitID)`, `rescan(teamID)`, `checkTeam()`, `gameFrame(n)`, `inspect(unitID)`, `finishPass(n)`, `updateFlags()`: the data model from spec §1-§5 and §11. Rules that affect integration:
  * builders in an array `bpTrack.ids` plus `bpTrack.rec[unitID] = {pos, buildSpeed, unitDefID, kind}` (swap-remove, O(1) untrack, fixes spec B3/B4),
  * a pass works on the snapshot `bpTrack.pass` (copied into a reused array, not a new table), `bpTrack.perFrame` units per call, a pause of `bpTrack.frameStep` frames, and `finishPass` exactly once per pass (spec §11, B9),
  * no per-call table creation: `Spring.GetUnitCommands(id, 0)` and `Spring.GetFactoryCommands(id, 0)` return counts; use `Spring.GetUnitCurrentCommand(id)` instead of `GetUnitCommands(id, 1)` for the nano-only-FIGHT test; no coroutine per pass,
  * wind min/max from the stock locals `minWind`/`maxWind` (S:96-97), wind speed from `select(4, Spring.GetWind())` or the stock `currentWind` string converted once,
  * `bp.hasData`, `bp.total` etc. are written only in `finishPass`, `track`, `untrack`, `rescan`, `updateFlags`.
* Optional: publish read-only data for other widgets as `WG.buildpower = { GetData = function() return bp end, version = 1 }` (spec §11). It must be removed in Shutdown.

### 5.5 `init` (S:1439-1543)

* Replace S:1449-1460 with the layout code of section 3.
* After the `WG.topbar.GetSkewConfig` assignment (S:1529-1535), still inside `if WG.topbar`: `bpUi.ownGetPosition = WG.topbar.GetPosition`.
* Before `updateResbarText("metal", true)` (S:1538): `bpTrack.checkTeam()` (rescans when the watched team changed or BP was just enabled).
* Keep the final `updateRes = {...}` line (S:1541) as it is.
* Upvalues 26 → 28 (`bp`, `bpUi`; `bpTrack` makes 29).

### 5.6 `widget:GameFrame` (S:1598-1605)

Append `bpTrack.gameFrame(n)`. Inside: `if not bp.cfg.enabled or not bpTrack.teamID or n < bpTrack.nextFrame then return end`. 4 → 5 upvalues.

### 5.7 `hoveringElement` (S:1666-1693)

Between the metal and energy checks:
```lua
local a = resbarArea.BP
if a[1] and mathIsInRect(x, y, a[1], a[2], a[3], a[4]) then
	return "BP"
end
```
No new upvalues. The cursor resets over BP and clicks on it are swallowed (S:2635-2637), like the other sections (fixes spec B24). The hover blocks of `Update` (S:1801-1819) need no change: nothing on the BP bar reacts to `resbarHover`.

### 5.8 `widget:Update` (S:1740-1898)

* In the 0.5 s guishader block (S:1788-1797): `bpUi.checkConflict()`.
* In the 0.25 s block, after `updateResbarText("energy")` (S:1887): `if bp.cfg.enabled then bpUi.slowUpdate() end`.
* 36 → 38 upvalues.

### 5.9 `renderResbarText` (S:1902-1934)

Append at the end:
```lua
if bpUi.textDirty then
	bpUi.textDirty = false
	bpUi.drawText()
end
```
7 → 8 upvalues.

### 5.10 `drawResBars` (S:1936-2110)

* After the energy block (after S:2049): `bpUi.drawBars(update)`. It runs after the energy glow and sliders and before the scissor block, so `textDirty` set by `refreshValues` is seen in the same frame.
* In the scissor block, after the energy entries (after S:2102):
  ```lua
  if bpUi.textDirty and bpUi.textScissor then
  	scissors[#scissors + 1] = bpUi.textScissor -- stable table, rebuilt in bpUi.updateBar
  end
  ```
* The existing `if scissors[1]` guard (S:2106) then also covers BP-only updates.
* 28 → 29 upvalues. `showResourceBars` already gates the whole function (S:1937).

### 5.11 `drawUiBackground` (S:2113-2162) and `drawUi` (S:2237-2241)

* In `drawUiBackground`, inside `if showResourceBars then`, between the energy and metal elements:
  ```lua
  local a = resbarArea.BP
  if a[1] then
  	UiElement(a[1], a[2], a[3], a[4], 0, 0, 1, 1) -- no skew: both edges face vertical inner edges
  end
  ```
* In `drawUi`, inside the `showResourceBars` block (S:2238-2241): `if dlist.resbar.BP[1] then glCallList(dlist.resbar.BP[1]) end`.
* No new upvalues in either.

### 5.12 `renderUi` (S:2291-2301)

After S:2300: `bpUi.textDirty = true` (`uiTex` was just recreated blank). 5 → 6 upvalues.

### 5.13 `widget:DrawScreen` (S:2347-2539)

**No change.** Everything above is reached through `renderUiBackground`, `renderUi` and `drawResBars`.

### 5.14 Team changes

`bpTrack.checkTeam()` compares `bpTrack.teamID` with `myTeamID` (or with `nil` while `bp.cfg.enabled` is false) and rescans via `Spring.GetTeamUnits` on a change. It is called from:
* `init` (5.5), which covers S:1755-1760 and `PlayerChanged` → `init` (S:2671-2673),
* `widget:PlayerChanged`: append `bpTrack.checkTeam()` after S:2673 (11 → 12 upvalues),
* `bpUi.slowUpdate` (5.4), because the spectator branch at S:1820-1829 changes `myTeamID` without calling `init`, so the check in `init` alone can miss a team switch (spec B6). `Update` runs while paused; `GameFrame` does not.

### 5.15 Unit call-ins

* `widget:UnitDestroyed` (S:2687): first line `bpTrack.untrack(unitID)` (6 → 7 upvalues). Keep the commander logic.
* New, appended at the end of the file (no stock counterpart, so no merge conflicts):
  ```lua
  function widget:UnitFinished(unitID, unitDefID, unitTeam)
  	if unitTeam == bpTrack.teamID then bpTrack.track(unitID, unitDefID, unitTeam) end
  end
  function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
  	if oldTeam == bpTrack.teamID then bpTrack.untrack(unitID) end
  	if newTeam == bpTrack.teamID then bpTrack.track(unitID, unitDefID, newTeam) end
  end
  function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
  	if oldTeam == bpTrack.teamID then bpTrack.untrack(unitID) end
  end
  ```
  `track` must ignore units still under construction (`Spring.GetUnitIsBeingBuilt`) and must be idempotent, because both `UnitGiven` and `UnitTaken` fire for one transfer.

### 5.16 `widget:Initialize` (S:2703-2810)

* After the `WG.topbar` functions (after S:2788) and before `widget:ViewResize()` (S:2796):
  * conflict check: `if WG.topbar.getResourceBarsVisible and WG.topbar.getResourceBarsVisible() then Spring.Echo(...) end`. The buttons fallback returns false (B:1139), the stock bar returns true unless quick start hid it. This must run **before** our own assignments at S:2773-2775, so put it right after `WG.topbar = WG.topbar or {}` (S:2744).
  * options registration (5.17).
* `bp.cfg` has already been filled by `SetConfigData`, which the handler calls before `Initialize` (W:1428-1431).
* 27 → 29 upvalues.

### 5.17 Options through `WG.options`

Stock `gui_top_bar.lua` has no options at all. Stock widgets get their settings entries inside `gui_options.lua` itself: `widget = "Converter Usage"` toggles a widget (O:7331-7339), `widgetConfig = { "Top Bar Buttons", "autoHideButtons", api = "topbar", get = ..., set = ... }` binds to a `WG` API (O:7268-7281). A user widget cannot add entries there. It uses the public API instead:

* `WG.options.addOptions(list)` / `addOption(option)` (O:12684-12704) append to `customOptions`, force `option.group = "custom"`, clear `option.widget`, and re-run the options widget's `init()` once per call. So register all BP options in **one** `addOptions` call.
* An option with `option.widgetname == <our widget name>` is nested under the toggle of our user widget in the Custom group, with parent id `"widget_" .. basename` (O:12236-12292). Without `widgetname` it lands under a generic "Options" label (O:12299-12318).
* `onchange(option, value, force)` is the call signature (O:3275-3277).
* Values are not persisted by the options widget for custom options (the restore at O:12895-12897 is commented out). Persist through our own `GetConfigData`.
* `gui_options` has layer -99990 (O:12), lower than ours, so it is initialized first and `WG.options` exists in our `Initialize`. If the options widget is reloaded later our entries are gone until our widget restarts; that is acceptable.

0.4.010 did it the same way (F:98-121 `addOptionFromSpec`, F:2955-2959 registration, F:3086-3090 removal), one `addOption` call per option.

Sketch (in the BP block, called from `Initialize`):
```lua
bpUi.optionSpecs = {
	{ key = "enabled", type = "bool", name = "Buildpower bar", relayout = true,
		description = "Show the buildpower bar between metal and energy" },
	{ key = "widthFraction", type = "slider", min = 0.10, max = 0.25, step = 0.01, relayout = true,
		name = "Buildpower bar width", description = "Share of the metal and energy width given to the buildpower bar" },
	{ key = "indicators", type = "bool", name = "Eco support markers",
		description = "How much buildpower your metal and energy income could support" },
	{ key = "windRange", type = "bool", name = "Wind range strip",
		description = "How energy-supported buildpower varies with wind speed" },
	{ key = "alerts", type = "bool", name = "Buildpower alerts", description = "Need metal / Need energy / Idle buildpower" },
	{ key = "icon", type = "bool", name = "Buildpower icon", relayout = true, description = "" },
	{ key = "debugTooltip", type = "bool", name = "Debug data in tooltip", description = "" },
}
function bpUi.addOptions()
	if not (WG.options and WG.options.addOptions) then return end
	local list, ids = {}, {}
	for i, s in ipairs(bpUi.optionSpecs) do
		ids[i] = "top_bar_bp_" .. s.key -- same prefix as 0.4.010
		list[i] = { id = ids[i], name = s.name, description = s.description, type = s.type,
			min = s.min, max = s.max, step = s.step, value = bp.cfg[s.key],
			widgetname = widget:GetInfo().name,
			onchange = function(_, value)
				bp.cfg[s.key] = value
				if s.relayout then init() else bpUi.last = {}; bpUi.lastTooltip = nil end
			end }
	end
	bpUi.optionIds = ids
	WG.options.addOptions(list)
end
```
Shutdown: `if WG.options and bpUi.optionIds then WG.options.removeOptions(bpUi.optionIds) end`.

### 5.18 `GetConfigData` / `SetConfigData` (new, end of file)

Stock has neither, so these do not conflict with stock changes.
```lua
function widget:GetConfigData()
	return { bp = bp.cfg }
end
function widget:SetConfigData(data)
	if type(data) == "table" and type(data.bp) == "table" then
		for k, v in pairs(data.bp) do
			if bp.cfg[k] ~= nil and type(v) == type(bp.cfg[k]) then bp.cfg[k] = v end
		end
	end
	bp.cfg.widthFraction = math.min(0.25, math.max(0.10, bp.cfg.widthFraction))
end
```

### 5.19 `widget:Shutdown` (S:2812-2895)

* Inside `if dlist.blendBg then` after S:2838: the same loop as S:2833-2838 for `dlist.resbar.BP`. `dlist.resValuesBar.BP` is already covered by S:2842-2844.
* Inside `if WG.tooltip then` (S:2860-2878): `WG.tooltip.RemoveTooltip("BP_bar")` (spec B19).
* Options removal (5.17), `WG.buildpower = nil` if published.
* Keep `removeButtonFallbacks()` and the `WG.topbar` cleanup (S:2880-2894) exactly as stock.

### 5.20 Things that stay as they are

`ViewResize`, `updateResbarText`, `updateResbarValues`, `drawResbarValue`, `drawResbarPullIncome`, `drawResbarStorage`, `updateAllyTeamOverflowing`, the slider code, `MousePress`/`MouseMove`/`MouseRelease`, `LanguageChanged`, `GameStart`, the button fallbacks, the `WG.topbar` functions, `require("common/wind_functions")` (S:102, works in a user widget, see 6.2).

---

## 6. Compatibility notes

### 6.1 Running as a user widget in the current sandbox

The fork is loaded from the player's `LuaUI/Widgets` (raw file system), so it is a **user widget** (`fromZip = false`), unlike the stock bar. The current handler sandboxes user widgets:

| Item | Stock use | In a user widget | Evidence |
|---|---|---|---|
| `BAR.I18N` | S:100-101, 109-110, everywhere | available: `BAR` is in `System` (system.lua:81), copied into `SandboxedSystem` | init.lua:105; W:964-966 |
| `Spring.I18N` | not used | removed by the bar_codemod; use `BAR.I18N` for stock keys only. BP strings have no translation keys in the game, so keep them as plain English in `bpUi` | revival notes §2 |
| `BAR.Lava.isLavaMap` | S:91 | available | init.lua:114 |
| `require("common/wind_functions")` | S:102 | `SandboxedSystem.require` is refused (W:978), but every user widget gets its own `widget.require` (W:1625-1630). It includes `path .. ".lua"` into the widget's environment with the read mode reduced to archives, because the path is outside `luaui/` (W:648-658). So it works and always reads the game's copy. The module only defines locals and returns a table (wind_functions.lua:697-752), so nothing leaks into our environment. | |
| `gl.R2tHelper` | S:137 | available: `modules/graphics/init.lua` sets `gl.R2tHelper = require("modules/graphics/r2thelper")`, run from init.lua:118 when LuaUI starts, before `CreateSandboxedSystem` copies `gl` (W:804, called at W:1000) | |
| `Game.spawnWarpInFrame` | S:51 | available (`3 * Game.gameSpeed` = 90), common/constants.lua:51 via init.lua:101 | |
| `WG.FlowUI`, `WG.fonts`, `WG.tooltip`, `WG.guishader`, `WG.options`, `WG.notifications`, `WG.topbar` | | shared: `widget.WG = self.WG` (W:1537) | |
| `Spring.SendCommands("resbar 0")` | S:2705 | allowed (only enable/disable/toggle widget, execute, key binding, option and similar commands are filtered, W:544-560) | |
| `Spring.SendLuaRulesMsg`, `Spring.SetShareLevel`, `Spring.PlaySoundFile` | S:2568, 2551, 2628 | allowed (not overridden in `sandboxedSpring`) | W:891-950 |
| `handler = true` / `widgetHandler` | S:12; stock never calls `widgetHandler` | the real handler is only given to archive widgets (W:1414-1418); a user widget gets a proxy. **The fork cannot disable the stock "Top Bar"** (no `DisableWidget`, and the `disablewidget` console command is dropped, W:544-560, 905-917). | |
| Memory guard | n/a for stock | every call-in of a user widget is wrapped and its allocations are counted (W:1958-1975, W:1989-2003). One call-in allocating 256 MB is stopped, a widget holding 400 MB is turned off, sustained growth over 8 MB/s for 10 s is reported (`luaui/Include/memory_guard.lua:19-46`). The whole fork, stock code included, is measured. | |
| User widgets disabled | | `allowuserwidgets` modoption off, or anonymous team colours (W:112-131): the fork does not load at all. A player who disabled the stock bar then has **no** top bar in those games and must re-enable it there. Put this in the README. | |

### 6.2 Layer and load order

* Layer `-95000`, the same as stock (S:10) and Top Bar Buttons (B:10). The stock layer moved from -999999 to -95000 in March 2026; 0.4.010 still has -999999 (F:10). Do not keep that value.
* Startup order is by layer, then order number, then name (W:1021-1035). `gui_options` (-99990) and `gui_tooltip` (-1200000) initialize before us.

### 6.3 Name and file name

* Name `"Top Bar with Buildpower"`. It must differ from `"Top Bar"`: with the same name, the handler treats the second one as a duplicate (W:1357-1361), shares one order entry and one config entry (`configData[name]`, W:1428), and the player cannot run the two in a controlled way. Leave the version out of the name (0.4.010 had it) so settings and the enabled state survive updates.
* File name `gui_top_bar_bp.lua` (anything but `gui_top_bar.lua`). The handler keys its error log by basename (`RecordError(basename, ...)`, W:1106; `errorLog[basename]`, W:1435), so a crash of the fork would be filed under the stock widget. The options toggle id is `"widget_" .. basename` (O:12272). A raw file at the same VFS path as the game's file also makes raw-first reads ambiguous (FIXME at init.lua:35).

### 6.4 WG.topbar contract (must stay exactly like stock)

Shared with `gui_top_bar_buttons.lua`, which fills the other half and provides fallbacks for ours when we do not run (B:1095-1153).

| Keys | Owner | Set where |
|---|---|---|
| `GetPosition`, `GetFreeArea`, `GetSkewConfig` | us | `init`, S:1507-1536 (re-assigned on every `init`) |
| `updateTopBarEnergy`, `setResourceBarsVisible`, `getResourceBarsVisible`, `setIndicatorsVisible`, `getIndicatorsVisible` | us | `Initialize`, S:2744-2788 |
| `showingQuit`, `hideWindows`, `buttonAt`, `GetButtonsPosition`, `setAutoHideButtons`, `getAutoHideButtons`, `getShowButtons` | buttons widget | B:1272-1310; our fallbacks via `provide()` S:1699-1738, refreshed every `Update` (S:1743), removed in Shutdown (S:2880) |

* Assign our keys directly, as stock does (not through `provide`). The buttons widget sees a non-nil value that is not its own fallback and drops its fallback (B:1106-1107).
* Keep `WG.topbar = WG.topbar or {}` (S:2744), the nil-ing of our keys and `if next(WG.topbar) == nil then WG.topbar = nil end` in Shutdown (S:2881-2894).
* `setResourceBarsVisible(false)` (used by quick start, `luaui/RmlWidgets/gui_quick_start/gui_quick_start.lua`) must hide BP too. That works automatically, because every BP path sits behind `showResourceBars` (`updateResbar` S:858, `drawResBars` S:1937, `drawUiBackground` S:2114, `drawUi` S:2238). `setIndicatorsVisible` only covers wind/tidal/coms and does not affect BP.
* Running next to the stock bar does not work, and hiding it is not a way out: hiding it through its own `setResourceBarsVisible(false)` leaves its stale `shareIndicatorArea` active in its `MousePress` (S:2585-2610), so it would capture share-slider clicks with the wrong bar width. The player has to disable the stock "Top Bar"; the fork only warns (5.4 `checkConflict`, 5.16).

### 6.5 Other carry-overs

* Do not read the `lowPrio*` team rules params (spec §2.4).
* `CMD.FIGHT` instead of `16`, static assist turrets by UnitDef fields, wind generators by `windGenerator > 0` (spec §10, B1, B5, B14).
* The old fork's `Spring.I18N`, `WG['options']` bracket style, `notifications.addEvent` (F:928) are outdated; stock now uses `BAR.I18N`, dot access and `queueNotification` (S:679).

### 6.6 `enabled = false` by default

A user widget with `enabled = true` is switched on as soon as it is first seen (W:1400-1403), while the stock bar is still on, so both would draw on first launch. With `false` the player enables the fork in the same place where they disable the stock bar. This is a recommendation; 0.4.010 used `true`.

---

## 7. Performance budget

### 7.1 What stock does to stay cheap

* Static UI is baked into two textures only when `refreshUi` is set; a normal frame costs two `glCallList` blits (S:2384-2409, 2426-2428, 2494-2496).
* Text is patched into `uiTex` only when a dirty flag is set, with scissors limiting the clear, and the FBO pass is skipped when nothing is dirty (S:2104-2108). Text dirtiness is decided by comparing the formatted string (`short()`), not the number (S:647, 1284).
* Value bars rebuild their list only when the fill width in whole pixels changes (S:1297).
* The energy glow is animated through the texture matrix instead of rebuilding lists (S:1397-1399, 2017-2041).
* Cadences: bars and text 0.05 s, postponed while a sim frame just ran (S:1744, 1944-1948); smoothing 0.07 s; resources, overflow, wind, coms 0.25 s; hover and state 0.033 s; guishader 0.5 s.
* Memoized `short()` with a size cap (S:305-333); reused scratch tables (S:202-207); pre-declared RTT functions instead of closures (S:1900-1901, 2283); state toggles only when something is drawn (S:1953, 1965-1970).

### 7.2 Rules for BP

1. **Sim work only in `GameFrame`**, with a fixed budget: at most `bpTrack.perFrame` (20) builders per call, then a pause of `bpTrack.frameStep` (3) frames; a full pass over N builders takes about `3·ceil(N/20)` frames. Averages and published `bp` fields are updated once per pass (`finishPass`), not per frame (spec B9). When the game catches up (several `GameFrame` calls per draw frame), the cost per call stays bounded.
2. **Events are O(1):** `track`/`untrack` touch one record; only a team change rescans (`Spring.GetTeamUnits`).
3. **No garbage in hot paths:** no tables, closures, coroutines or string concatenation per frame or per inspected unit. Reuse the pass array and the accumulator fields. Strings are built only when a value shown on screen changes (percent strings cached in `bpUi.pctStrings`) or while the tooltip is hovered. The memory guard measures the whole fork (6.1).
4. **BP visuals at most every 0.05 s**, on the same `update` tick as metal and energy (so they share the sim-frame deferral). Rebuild `dlist.resValuesBar.BP` only when one of the quantized pixel values or a stall flag changes. One list, never a cache keyed by value (spec B17); never a list rebuilt every frame (spec B18).
5. **Percent text only when the rounded percent changes**, through the fixed `bpUi.textScissor`; it then rides in the same `RenderToTexture` call as the metal/energy text.
6. **Alerts and flags every 0.25 s / 1 s**, alert list rebuilt only when the active set changes, debounced 1.1 s like the stock banner.
7. **Tooltip text only while hovered**, and `AddTooltip` only when the text changed (the tooltip widget throws away its cached list on every call with a text).
8. **Per frame BP adds at most three `glCallList`s** (tint, fill, alerts) and nothing to `DrawScreen` itself.
9. **Nothing on `refreshUi` beyond stock:** the BP background and frame are part of the existing texture re-renders.
