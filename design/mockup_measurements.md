# Top-bar mockup: pixel measurements

Source: `images/2.png` (session upload). Everything below was measured with Python (Pillow + numpy)
by tracing edges row by row and column by column, fitting lines and circles by least squares,
and sampling colours with medians. The numbers do not come from eyeballing. Helper crops and
annotated overlays are in the session scratchpad (`.../scratchpad/measure/`).

**Image size correction:** the file is **1106 x 100 px**, not 1105 x 79.

## 0. Conventions

* **Pixel index** `(x, y)` names a pixel. The origin is the top-left pixel and y grows downwards.
* **Edge coordinate**: a continuous coordinate in which pixel `(x, y)` covers `[x, x+1) x [y, y+1)`.
  Fitted lines, circles and sub-pixel boxes use edge coordinates.
* **Reference height H = 64 px.** This is the metal/energy panel height, from the top edge
  y = 4.0 to the bottom edge y = 68.0, including the 1 px bottom outline on row 67. Without
  the outline it is 63 px.
  Rows 0-3 are a flat `#1E1E1E` band above everything, probably the screen edge or the
  mockup canvas. The panels start at row 4.
* A normalised value is written `n = value / H`. For a y position, `n = (y - 4) / 64`.
* Angles of slanted edges are given in degrees from vertical, with `dx/dy` = horizontal run
  per pixel of height. Gauge angles use 0 deg = 3 o'clock with counter-clockwise positive,
  and screen y is flipped for this.
* Uncertainties: fitted geometry ±0.2 px, single-edge positions ±0.5 px, colours ±2/255
  (the panels carry a faint noise texture of about ±4 L).

---

## 1. Main strip: extents, heights, gaps

| element | top (edge) | bottom (edge) | height | n (height/H) | notes |
|---|---|---|---|---|---|
| metal panel | 4.0 | 68.0 | 64 | 1.000 | bottom outline row 67 |
| energy panel | 4.0 | 68.0 | 64 | 1.000 | bottom outline row 67 |
| gauge panel | 4.0 | 81.0 | 77 | 1.203 | bottom outline row 80; **hangs 13 px = 0.203 H below the strip** |
| wind + "20" panel (one panel) | 4.0 | 45.0 | 41 | 0.641 | bottom outline row 44 |
| recycle panel (ignored) | 4.0 | ~45.5 | ~41.5 | 0.65 | outline row 44/45 |

Horizontal extents (edge coords, from line fits at the top edge y = 4 and the bottom edge):

| edge | x at top (y = 4) | x at bottom | bottom y |
|---|---|---|---|
| metal left (slanted `\`) | 103.7 | 164.5 | 68 |
| gauge left (vertical) | 420.0 | 420.0 (until y 67.5, then chamfer) | 81 |
| gauge right (vertical) | 533.0 | 533.0 (until y 67.5, then chamfer) | 81 |
| energy right (slanted `/`) | 838.4 | 781.6 | 68 |
| wind panel left (slanted `/`) | 852.5 | ~821 (vertical stub from y 40 to 45, see section 2) | 45 |
| "20" panel right (slanted `/`) | 1084.4 | 1048.7 | 45 |
| recycle panel left / right | 24.9 / 86.7 | ~64 / ~123 | ~45 |

* **Overall strip** (metal to last panel): x 103.7 to 1084.4 at the top, which is 980.7 px = 15.3 H.
  With the recycle panel the strip starts at 24.9.
* The strip **is not mirror-symmetric** about the gauge. The gauge centre is x = 476.5 (panel)
  or 477.2 (ring). The metal reaches 373 px left of it at the top and 312 px at the bottom.
  The energy reaches 362 px right at the top and 305 px at the bottom. Metal is about 7-11 px longer.
* The two resource bars **are** symmetric about x = 476.0-476.75 (see section 4).

### Joints and gaps

| joint | type | measured |
|---|---|---|
| metal / gauge | **no water gap**; the gauge sits directly against the metal | gauge outline 1 px at col 420 = `#3E3E3E` (62,62,62), with anti-aliased cols 419 and 421 ≈ (55,57,55). On the metal side, cols 417-418 are a faint 2 px lighter strip (43,48,46) against the metal fill (36,38,37) |
| gauge / energy | no water gap | gauge outline 1 px at col 532 = `#363636` (54,54,54), col 531 ≈ (54,57,55). On the energy side, cols 533-535 are a **2-3 px dark shadow** (32,35,33) against the energy fill (35-41): the gauge casts a shadow to the right |
| energy / wind | diagonal gap, parallel edges | **14.3 px horizontal (≈10.7 px perpendicular)**: energy outline 1 px (62,62,62), then a 9 px shadow band (water × 0.77), then about 5 px of clear water, then the wind outline |
| recycle / metal | diagonal gap, edges not quite parallel (45.0° vs 43.5°) | 16.9 px horizontal at y = 4, 15.2 px at y = 40: recycle outline, about 6 px of water, a 9 px shadow band hugging the metal edge, then the metal outline |
| wind / "20" | same panel, internal divider | 2 px darker line at cols 976-977 (+ col 978 anti-aliased), (43,47,45) against the panel (51,57,54). Strongest at the top (ΔL ≈ -13 at y 6, -7 at y 20, -4 at y 38) and gone by y ≈ 42, i.e. a vertical alpha fade |

---

## 2. Angles, corners, straightness

All slanted edges are **straight**. A line fit to the 1 px outline gives residual σ = 0.18-0.35 px,
and the quadratic term is ≤ 0.002 px/px², so there is no curvature.

| edge | dx/dy | angle from vertical | x offset over the panel height |
|---|---|---|---|
| metal left `\` | **0.950** | **43.5°** | 60.8 px over 64 = **0.950 H** |
| energy right `/` | **0.8875** | **41.6°** | 56.8 px over 64 = **0.888 H** |
| wind panel left `/` | 0.876 | 41.2° | 35.9 px over 41 |
| "20" panel right `/` | 0.871 | 41.0° | 35.7 px over 41 |
| recycle left / right | 0.976 / 0.998 | 44.3° / 45.0° | |
| gauge left / right | 0.000 | **0° (vertical)** | constant at col 420 / 532 from y 4 to 67 (±0.5) |
| inner edges of metal/energy next to the gauge | not visible | | they end under or against the gauge; treat them as vertical |
| dark bar-zone boundary inside metal (see section 3) | 0.706 | 35.2° | |
| dark bar-zone boundary inside energy | 0.673 | 33.9° | |

Mean slant of the main panels ≈ **42.5°, tan ≈ 0.92**. Metal is 2° steeper than energy, probably an
inaccuracy in the mockup. Stock BAR uses `cfg.skewAngleDeg = 20`, i.e. tan 0.364, so the mockup
slant is about **2.5x stronger**. To reproduce it, use `skewAngleDeg ≈ 42.5` (tan 0.916), or 43.5
for metal and 41.6 for energy.

**Corners**

* All slanted-panel corners, top and bottom, are **sharp** (radius ≤ 1 px). Two exceptions:
  * Wind panel bottom-left: the slanted edge stops at x ≈ 821 at y = 40, and the edge then runs
    **vertically for about 4 px** (y 40-44) before the bottom outline. This is a small blunted corner,
    about 4 px or 0.06 H.
  * The top corners touch the y = 4 line, so they are flush with the screen top and need no rounding.
* **Gauge bottom corners: straight chamfers, not arcs.**
  * Left chamfer: from (420.5, 67.5) to (430.5, 80.5). Run 10 px over 13 px height (dx/dy 0.75, 37° from vertical).
  * Right chamfer: from (532.5, 67.5) to (523, 80.5). Run 9.5 px over 13 px.
  * Chamfer ≈ **10 × 13 px ≈ 0.16 H × 0.20 H**. A symmetric FlowUI chamfer of cs ≈ 11.5 px = 0.18 H is the closest match.
  * Gauge top corners: square.
* Bar ends: the inner ends (toward the gauge) are square, with ≤ 1 px rounding. On the outer ends the
  top half is square and the **bottom outer corner has a chamfer of about 3.5 × 4 px**: metal track
  left end goes 228.0 → 231.5 between y 22 and 27; energy right end goes 723.5 → 720.5.

---

## 3. Shading, outlines, shadows

### Panel fills (median RGB; the texture adds about ±4)

The metal and energy panels have **two fill zones**:

* a darker **"bar zone"** in the top part, a parallelogram holding the bar, from y 4.0 to ≈ 32.0
  (28 px = 0.44 H; the bottom transition is ±1 px and soft near the gauge);
* a lighter **lower zone**, plus a lighter **"income zone"** outside the slanted bar-zone boundary.

Bar-zone boundary lines (edge coordinates):

| panel | boundary x at y = 4 | boundary x at y = 32 | dark zone runs to |
|---|---|---|---|
| metal | 213.1 | 232.9 | the gauge |
| energy | 740.6 | 721.8 | from the gauge |

| sample | top (y 4 / 5-10) | middle | bottom | notes |
|---|---|---|---|---|
| metal bar zone | (35,36,35) row 4 → (38,40,39) y 5-10 → (41,44,42) y 11-16 | | | darkest area, almost neutral |
| energy bar zone | (34,36,35) → (38,40,39) → (40,43,41) | | | same as metal |
| metal income zone (x < boundary, y < 32) | (60-62, 66-69, 63-65) | | | the lighter zone left of the bar |
| energy income zone (x > boundary) | (55,61,58) | | | |
| metal lower zone y 32-66 | (46,51,48) y 32 | (52,57,55)-(54,60,57) y 40-52 | (47,53,50) y 66 | soft bulge: lightest at about 0.6 H |
| energy lower zone | (45,49,47) y 32 | (49,54,51) y 45-50 | (44,50,47) y 66 | |
| gauge panel | (37,40,39) row 4, (44,49,46) y 5-10 | (50,57,54) y 17-60 | (41,47,45) y 67-79 | lighter middle, darker top and bottom. ~6 px inner darkening at the left edge (44,50,47) |
| wind panel | (45,49,47) row 4, (55,61,57) y 5-13 | (53,58,54) y 22 | (42,48,45) y 43 | top-to-bottom gradient, light to dark |
| "20" panel | (52,59,55) y 7 | (49,54,51) y 22 | (44,49,46) y 37 | slightly darker than wind |

* **Top edge:** there is **no light highlight line**. Row 4 is about 4-10 L *darker* than row 5 on
  every panel: a 1 px top inner shadow, alpha ≈ 0.1-0.2 black, or anti-aliasing against the black band.
* **Outline:** a **1 px opaque neutral grey line** on the bottom and slanted edges. Its colour is
  exactly R = G = B whatever lies below it.

  | panel | outline colour |
  |---|---|
  | metal / energy | `#3E3E3E` (62) |
  | wind | `#3C3C3C` (60) |
  | gauge left | `#3E3E3E` (62) |
  | gauge right | `#363636` (54) |
  | gauge bottom | `#3A3A3A` (57-58) |

  There is no outline on the top edge.
* **Outer shadow band.** It is hard-edged with no visible blur and a uniform darkening of the water:

  | where | width | colour (sample) | water × | ≈ black alpha |
  |---|---|---|---|---|
  | below metal/energy (rows 68-73) | **6 px (0.094 H)** | (82,94,87) / (75,87,81) | 0.77 | **0.23** |
  | below wind panel (rows 45-50) | 6 px | (70,83,77) | 0.75 | 0.25 |
  | below gauge (rows 81-87) | **7 px (0.11 H)** | (75,88,82) | 0.72 | 0.28 |
  | outside slanted edges (metal left, energy right, wind right) | 9 px horizontal ≈ 6.5 px perpendicular | (85-96) L | ≈ 0.78 | 0.22 |
  | gauge right chamfer | 8 px horizontal | | | |
  | gauge left side / left chamfer | **none** (water directly at the outline) | | | |

  The first row under an outline is slightly darker (≈ water × 0.70) because of anti-aliasing.
  The gauge shadow is effectively the gauge shape **offset by ≈ (+2.5, +7) px** (light from the
  upper left). For the strip, treat it as a 6-7 px hard drop shadow that also shows on the slanted
  outer edges.
* **Bar shadow:** rows 28-31 directly under each bar and its knobs are a 4 px dark band
  (35,37,36), 0.87 × the bar zone ≈ black alpha 0.13. It is hard-edged and follows the chamfered
  outer end diagonally.
* **Ring shadow (gauge):** about 4-5 px of darker panel (≈ (38,43,41)) beyond both arc end caps,
  offset down-right.
* **Water background:** mean (100.6, 116.9, 108.4) = `#65756C`, σ ≈ 9.4 per channel (texture).
  The left part is lighter: (110,126,117).

---

## 4. Bars and knobs

| item | x1 to x2 (edge) | y1 to y2 (edge) | size | colour |
|---|---|---|---|---|
| metal track | **228.0 – 405.5** | **17.5 – 27.0** | 177.5 × 9.5 px (2.77 H × 0.148 H) | vertical gradient, neutral: 58, 60, 63, 68, 75, 82, 88, 90, 91 from top to bottom (`#3A3A3A` → `#5B5B5B`; darker on top = inset look) |
| metal fill | **301.5 – 405.5** | 17.6 – 27.2 | 104 × 9.6 px; anchored at the **inner (gauge) end** and grows outward | flat `#D9D9D9` (217,217,217); corners ≈ 1 px |
| energy track | **546.5 – 723.5** | 17.5 – 27.0 | 177 × 9.5 px | same gradient. **No red zone on the track**: it is the same grey under and beside the red knob |
| energy fill | none (energy = 0) | | | |

* Bar centre y = 22.25 (n = 0.285). The bars sit symmetric about x ≈ 476: each inner end is 70.5 px from the gauge centre.
* The metal fill is 58.6 % of the track, while 812 / 1000 = 81 %. The mockup values are not consistent.
* Track corners: inner ends square; outer ends have a chamfer of about 3.5 px at the bottom only (section 2).
* Neither bar has a glow. The track's vertical gradient gives an inset look, and there is a 4 px shadow underneath (section 3).

**Knobs.** Both knobs are taller than the bar and square-cornered, with a 1 px dark outline.

| knob | x (pixel cols incl. outline) | y (rows) | size | position on energy track | fill |
|---|---|---|---|---|---|
| white share knob | **636 – 650** | **12 – 31** | 15 × 20 px (0.23 H × 0.31 H); interior 637-649 × 13-30 | centre x 643.5, fraction **0.548** | vertical gradient `#B5B5B5` (top) → `#EAEAEA` (bottom), with a glossy diagonal highlight stripe up to `#FAFAFA` from (647,14) to (644,30) (≈ 11° from vertical). Right of the stripe it is darker, `#BEBEBE` → `#A5A5A5` |
| red knob (overflow / threshold marker; this is the "red zone") | **705 – 719** | **12 – 31** | 15 × 20 px | centre x 712, fraction **0.935** | gradient `#F01919` → `#FA8484`, highlight stripe up to `#FEAFAF`, right part `#E05757`, right column `#C00D0C` → `#D84444`, top inner row `#950B0B` |

* Knob outline: `#222423` on the top row 12 and the right column. The red knob's left column is dark red (#46111x-#55313x).
* The bottom row 31 is a half-coverage anti-aliased row.
* Knob vs bar: the knob extends 5.5 px above and 4.5 px below the track, so knob height = 2.1 × bar height. The knob's vertical centre is 22.0, the same as the track's.

---

## 5. Texts

Notes for the table:

* Digit height comes from sub-pixel coverage, top edge to bottom edge. Round digits include about 0.3 px overshoot.
* Font px = digit height / 0.70. Size / H = font px / 64.

| text | pixel bbox (x / y) | sub-px box (edge) | digit h | font px | size / H | colour | alignment |
|---|---|---|---|---|---|---|---|
| **+15** | 170-202 / 16-29 | 170.6–202.8, 16.5–29.7 | 13.2 | 18.9 | 0.295 | green `#A0EC7D` (160,236,125) | the sign is a separate column centred at x ≈ 175 (plus 170-179, y 18-27). Digits left at x = 186 and right at ≈ 202.5. Vertical centre 23.1 ≈ bar centre (+0.9) |
| **-13** | 171-201 / 40-53 | 171.8–201.5, 40.3–53.9 | 13.5 | 19.3 | 0.30 | red `#FF7C7C` (255,124,124) | minus 172-179 at y 46-48, digits left at x 186. Vertical centre 47.1 |
| **1000** | 252-284 / 41-52 | 252.6–285.0, 41.1–52.6 | 11.5 | 16.4 | 0.26 | grey `#BCBCBC` (core 178-188) | follows the storage glyph after an 11.8 px gap. Centre y 46.9 |
| **812** | 344-376 / 39-55 | 344.4–376.5, 39.0–55.2 | 16.2 | 23.1 | 0.36 | light grey `#C1C1C1` (193) | right-aligned: the text plus the plate icon end at x 402.5, 3 px inside the bar's inner end (405.5). Centre y 47.1 |
| **50%** | 489-521 / 63-75 | 489.3–521.7, 63.1–75.6 | 12.5 | 17.9 | 0.28 | teal `#09FFE1` | **italic ≈ 10° (stem slope dx/dy 0.18, ±3°)**. The right edge is 10.3 px inside the gauge right outline. The bottom is 5.4 px above the gauge bottom edge. It sits at the lower right inside the ring opening |
| **+158** | 732-775 / 16-29 | 732.4–776.0, 16.3–30.0 | 13.7 | 19.6 | 0.31 | green `#A0EC7D` | plus 732-741 (centre 736.5). Digits 748-776, **right-aligned at x ≈ 776.2** (same as -214). Starts 8.9 px right of the bar end |
| **0** (energy current) | 576-587 / 39-54 | 576.0–587.7, 39.0–54.9 | 15.9 | 22.7 | 0.355 | cream `#E7DCB5` (231,220,181) | follows the bolt after a 10.2 px gap. The bolt's left edge (549.6) is 3 px inside the bar's inner end (546.5), mirroring "812" |
| **2500** | 687-722 / 41-52 | 687.1–722.6, 41.4–52.6 | 11.2 | 16.0 | 0.25 | cream-grey `#D9D0B1` (217,208,177) | right edge 722.6 ≈ the outer end of the energy track (723.5). The storage glyph precedes it with an 8.9 px gap |
| **-214** | 734-776 / 40-53 | 734.7–776.3, 40.4–53.7 | 13.3 | 19.0 | 0.30 | red `#FF7C7C` | minus 734-742 (y 46-48), digits 749-776, right-aligned at 776.3 |
| **15.2** | 886-924 / 16-31 | 886.0–924.2, 16.0–32.0 | 16.0 | 22.9 | 0.36 | cream `#E7DCB5` | 6.2 px after the propeller. Vertical centre 24.0 ≈ wind panel centre (24.5) |
| **1-25** | 933-963 / 18-28 | 933.5–963.2, 18.8–28.5 | 9.7 | 13.9 | 0.22 | white `#FFFFFF` | 9.3 px after "15.2". **Vertically centred (centre 23.65)**, not baseline-aligned: its bottom is 3.5 px above the bottom of "15.2" |
| **20** | 1015-1039 / 16-31 | 1015.7–1039.9, 16.0–32.0 | 16.0 | 22.9 | 0.36 | cream `#E7DCB5` | 7.7 px after the mountain icon |

Line groups:

* **Top line** (+15, +158): centre y ≈ 23.1, n = 0.30.
* **Bottom line** (-13, 1000, 812, 0, 2500, -214, and the glyphs): centre y ≈ 47.0 (±0.2), n = 0.67.
* **Wind line:** centre y ≈ 24, n = 0.31.

Size classes:

| class | digit height | font size |
|---|---|---|
| income / pull | 13.4 px | ≈ 19 px = **0.30 H** |
| storage | 11.3 px | ≈ 16 px = **0.25 H** |
| current value, wind, "20" | 16.0 px | ≈ 23 px = **0.36 H** |
| 50 % | 12.5 px | ≈ 18 px = **0.28 H** |
| wind range | 9.7 px | ≈ 14 px = **0.22 H** |

**Shadow on all texts:** a soft dark drop shadow, no symmetric outline.

* Pixels just below the glyphs and inside the counters fall to L ≈ 20-30, against a panel of 50-60.
  For example, "812" row 55 is at 21-29, row 56 at 30-45, row 57 back to normal.
* The right side is 1-2 px darker. The left side is only slightly darker (about -5 L).
* Estimate: offset ≈ (+1, +1.5) px, blur ≈ 1.5-2 px, peak black alpha ≈ 0.6.
* In BAR this is closer to the shadow option ("s") than to the outline option ("o"). Outline plus a slight offset also works.

The text is crisp, anti-aliased by about 1 px, with flat fill colours and no gradient.

---

## 6. Glyphs and icons

| glyph | pixel bbox | size | colour | relation |
|---|---|---|---|---|
| metal storage cylinder (3 stacked discs, line art) | x 226-240, y 40-54 | 14.6 × 14.5 px (0.23 H) | `#CCCCCC` | centre y 47.25 (on the bottom line). Its left edge 226.1 is ≈ 2 px left of the outer end of the metal track (228). 11.8 px gap to "1000" |
| energy storage cylinder | x 663-678, y 40-54 | 14.6 × 14.5 px | cream `#E8DAAC` | 8.9 px gap to "2500" |
| lightning bolt | x 549-565, y 38-57 | 16.2 × 18.8 px (0.29 H tall) | `#FFE455` core, darker orange rim, thin dark edge | centre y 48. 10.2 px gap to "0" |
| "white square" after 812 = **metal-plate icon, not a slider knob** | x 386-403, y 38-56 (incl. 1 px dark outline); interior 387-402 × 39-55 | 16 × 17 px interior (0.26 H) | metallic gradient `#BFBFBF` (top left) → `#FEFEFE`, with a diagonal glare and a darker right column `#AEAEAE`. Top row `#868686`, bottom row `#474848` | **4 dark rivet dots** at (389,40), (400,40), (388,54), (401,54). 9.6 px gap after "812" |
| propeller (wind) | x 858-879, y 13-34 | 21.8 × 20.6 px (0.33 H) | `#FFFFFF` | no hard outline, only a soft shadow (min L 29). Centre ≈ (869, 24) |
| mountain (last panel) | x 990-1007, y 17-33 | 18.0 × 16.1 px (0.25 H) | `#FFFFFF` | **1 px black outline** (`#000000`). Centre ≈ (999, 25.5) |
| recycle icon + dropdown arrow (ignored) | arrow x 57-66 y 23-28 `#D4D4D4`; icon x 73-96 y 14-37 green `#E2FECB`/`#9FE27D` | | | |

---

## 7. Buildpower gauge

### Ring geometry

The geometry comes from circle fits to the sub-pixel inner and outer edges of the teal part.
Residual σ = 0.06 px, max 0.15 px, so the ring is a perfect circle.

| quantity | px (edge coords) | / H |
|---|---|---|
| centre | **(477.17, 50.12)** ±0.1 | x is +0.7 px right of the panel centre (476.5). y is 46.1 px below the top, **0.72 H** |
| inner radius | **27.98** | 0.437 |
| outer radius | **37.30** | 0.583 |
| ring thickness | **9.32** | 0.146 |
| mid radius | 32.64 | 0.510 |
| end caps | **round**, cap radius = half thickness = 4.66 | 0.073 |

The grey segment is slightly thinner near the teal: its outer radius is 37.3 at the right end
and 36.0 next to the teal, and its inner radius is 28.1-28.6. This is a shading effect (see below).

### Sweep

The arc runs clockwise from the lower left over the top to 3 o'clock. Each segment is a round-capped
arc drawn over the previous one (grey track first, then dark teal, then bright teal), so every
boundary is a rounded tip, not a radial cut.

| point | visible tip angle | cap centre angle | clock (tip) |
|---|---|---|---|
| start (bright teal, lower left) | **216.0°** | 207.8° | **7:48** |
| bright teal → dark teal | **105.3°** | 113.5° (bright cap) | **11:29** |
| dark teal → grey | **50.5°** | 58.7° (dark cap) | **1:19** |
| end (grey, right) | **0.0°** | 8.2° | **3:00** |

* Visible sweep, tip to tip: **216°**. Between cap centres: **199.6°**.
* The start and end are not symmetric. The start sits 36° below the horizontal on the left; the end sits on the horizontal on the right.
* **Bright teal = 51.2 % of the visible sweep**, which matches "50 %". By cap centres it is 47.2 %.
* Dark teal = 25.3 %, grey = 23.4 %.

### Colours

| part | colour |
|---|---|
| bright teal | `#09FFE1` (9,255,225), flat |
| dark teal | `#009684` (0,150,132), flat. It is a second "brighter/darker" segment: probably the extra or reserved part of the build power |
| grey track | `#5A5A5A` (90,90,90) in the core. It is shaded: the inner part is lighter (84-91), and the outer rim near the top is darker (63-72). A slight 3D or vignette effect |
| ring shadow | darker panel (≈ (38,43,41)) for about 4-5 px beyond each end cap, i.e. a drop shadow down-right |

### Yellow tick

The yellow element is a thin outer arc plus an orange triangle marker.

* **Thin arc:** concentric, r = 44.9 ±0.6 (0.70 H), width ≈ 2 px (r 43.9-45.9).
  * Spans **75.4° → 135.0°**, i.e. 12:30 → 10:30, 60° of arc centred at 105°.
  * Colour `#A68C00` (166,140,0), a dull gold.
  * Gap to the ring's outer edge: 6.6 px.
* **Orange triangle marker:**
  * bbox x 457-468, y 5-13 (12 × 9 px). Centroid (463.3, 9.4) = **r 43.0, angle 108.8° (≈ 11:22)**.
  * It spans r 38.7-46.0, from 1.4 px outside the ring's outer edge to just past the thin arc.
  * Colour `#FFC047` with a highlight `#FFE976` / `#FFED8E` and a darker edge `#A68033`.
  * Shape: a triangle with its flat side outward and its apex pointing **inward** (toward the ring), at about (463, 13).
  * It sits at the bright/dark-teal junction: bright tip at 105.3°, bright cap centre at 113.5°.

### White pointer

* bbox x 481-491, y 26-34. Centroid r 22.4 (inside the ring hole), angle 64.4° (≈ 12:51).
* A small triangle with its top edge horizontal and the tip down-right at about (490, 34).
* Gradient `#838383` → `#FBFBFB`.

### Hexagon icon

* bbox x 466-487, y 35-60, including the side bars. Colour teal `#09FFE1`.
* Centre ≈ (476.5, 47.5), i.e. 0.7 px left of and 2.6 px above the ring centre.
* The hexagon outline sits at x 470-487 and y 35-56. There is a vertical bar on the left at x 466-468, y 43-51, and a diagonal bar at the bottom right at x 480-487, y 54-60.

### "50%" text

* x 489.3–521.7, y 63.1–75.6. Font ≈ 18 px (0.28 H), italic ≈ 10°. See section 5.

### Gauge panel

* Rectangle x **420.0 – 533.0** (113 px = **1.766 H**), y **4.0 – 81.0** (77 px = 1.203 H).
* **Top edge flush with the strip top (y = 4).** Bottom hangs **13 px = 0.203 H** below the strip bottom (68).
* Bottom corners have straight chamfers of about 10 × 13 px (section 2). Top corners are square.
* Fill: top (44,49,46), middle (50,57,54), bottom (41,47,45). It is slightly **lighter than the strip's
  bar zone** (39,42,41) and about equal to the strip's lower zone (47-53).
* Outline 1 px neutral grey (54-62). Shadow 7 px below and on the right side (alpha ≈ 0.28), none on the left.

---

## 8. Colour table

| role | RGB | hex | notes |
|---|---|---|---|
| background water (mean) | 101,117,108 | `#65756C` | textured, σ ≈ 9. The left part is lighter: (110,126,117) |
| band above panels (rows 0-3) | 30,30,30 | `#1E1E1E` | |
| metal/energy **bar zone** top / bottom | 38,40,39 → 41,44,42 | `#262827` → `#292C2A` | row 4: (35,36,35) |
| metal/energy **lower zone** top / middle / bottom | 46,51,48 / 53,58,56 / 47,53,50 | `#2E3330` / `#353A38` / `#2F3532` | |
| metal income zone | 61,67,64 | `#3D4340` | lighter area left of the bar zone |
| energy income zone | 55,61,58 | `#373D3A` | |
| gauge panel top / middle / bottom | 44,49,46 / 50,57,54 / 41,47,45 | `#2C312E` / `#323936` / `#292F2D` | |
| wind panel top / bottom | 55,61,57 / 42,48,45 | `#373D39` / `#2A302D` | |
| panel outline (bottom and slanted edges) | 62,62,62 | `#3E3E3E` | wind 60, gauge right 54, gauge bottom 57 |
| separator metal / gauge | 62,62,62 (+ AA 55) | `#3E3E3E` | plus a faint 2 px lighter strip on the metal side (+7 L) |
| separator gauge / energy | 54,54,54, then shadow 32,35,33 | `#363636` | 2-3 px shadow on the energy side |
| wind / "20" divider | 43,47,45 | `#2B2F2D` | 2 px, fading downward |
| outer shadow | black, α ≈ 0.23 (strip), 0.25 (wind), 0.28 (gauge) | | hard-edged, 6-7 px |
| metal fill | 217,217,217 | `#D9D9D9` | flat |
| bar track (metal and energy) | 58 → 91 grey (top → bottom) | `#3A3A3A` → `#5B5B5B` | neutral vertical gradient |
| bar shadow | black, α ≈ 0.13 | | 4 px |
| energy "red zone" = red knob | 240,25,25 → 250,132,132 | `#F01919` → `#FA8484` | highlight `#FEAFAF`, dark side `#C00D0C` |
| white knob | 181 → 234 grey, highlight 250 | `#B5B5B5` → `#EAEAEA` | outline `#222423` |
| teal, bright | 9,255,225 | `#09FFE1` | ring, hexagon, "50%" |
| teal, dark | 0,150,132 | `#009684` | |
| gauge grey track | 90,90,90 | `#5A5A5A` | inner part lighter, outer rim darker (63-72) |
| yellow thin arc | 166,140,0 | `#A68C00` | |
| yellow / orange marker | 255,192,71 (highlight 255,233,118) | `#FFC047` (`#FFE976`) | |
| green text (income) | 160,236,125 | `#A0EC7D` | |
| red text (pull) | 255,124,124 | `#FF7C7C` | |
| grey text (metal storage) | 188,188,188 | `#BCBCBC` | metal storage glyph `#CCCCCC` |
| energy storage text | 217,208,177 | `#D9D0B1` | energy storage glyph `#E8DAAC` |
| metal current "812" | 193,193,193 | `#C1C1C1` | |
| cream text (energy current, wind, "20") | 231,220,181 | `#E7DCB5` | |
| white text ("1-25") / icons | 255,255,255 | `#FFFFFF` | |
| lightning glyph | 255,228,85 | `#FFE455` | |
| text shadow | black, α ≈ 0.6, offset (+1, +1.5), blur 1.5-2 px | | |

---

## 9. Implementation hints (FlowUI terms)

All sizes are given as multiples of **H** (the panel height). In GL space y points up, so "top" is `py + H`.

### Panels

* **Skew.** Stock BAR uses `skewTan = tan(20°) = 0.364`. The mockup needs **tan ≈ 0.92** (42.5°), so
  set `cfg.skewAngleDeg ≈ 42.5`. With the stock RectRoundQuad skew convention:
  * metal: `skew = { blx = H * 0.95 }`, i.e. the bottom-left corner is shifted right by 0.95 H (43.5°).
  * energy: `skew = { brx = -H * 0.8875 }` (41.6°).

  One shared value of about 0.92 H is fine, since the 2° difference is mockup noise.
  The wind and "20" panel uses the same slope on both sides: `tlx = +0.876 * h`, `brx = -0.871 * h`
  with h = 0.64 H. In GL terms the top-left corner is shifted right.
* **Corner size.** `cs ≈ 1` (sharp) on all strip panels. FlowUI draws corners as chamfers, which is
  exactly what the gauge shows. Use `cs ≈ 0.18 H` on the gauge's bottom-left and bottom-right corners
  (tl = tr = 0, br = bl = 1).
* **Panel heights and widths.**
  * metal / energy: H.
  * gauge: 1.203 H tall, flush at the top, 1.766 H wide, centred on the ring.
  * wind + "20": 0.64 H tall.
  * metal/energy gap: 0 (the gauge sits between them).
  * energy → wind gap: 14.3 px = 0.22 H horizontal.
* **Gradients** (c1 = bottom, c2 = top in FlowUI):
  * bar zone: c1 `{0.16,0.17,0.165}`, c2 `{0.15,0.157,0.153}`.
  * lower zone: c1 `{0.185,0.21,0.195}`, c2 `{0.20,0.225,0.215}`. Optionally a 3-stop with a lighter middle `{0.21,0.23,0.22}`.
  * gauge: c1 `{0.16,0.185,0.175}`, c2 `{0.175,0.19,0.18}`, with a lighter middle `{0.196,0.224,0.21}`.
  * wind: c1 `{0.165,0.19,0.175}`, c2 `{0.215,0.24,0.225}`.

  All at alpha 1. The mockup panels are opaque.
* **Two-zone resource panel.**
  1. Draw the full panel in the lower-zone colour.
  2. Overlay the darker "bar zone": a skewed quad from y_top down 0.44 H, with its outer side slanted
     at about 0.69 dx/dy (35°) and inset so that it starts 1.71 H (metal) or 1.53 H (energy) from the
     panel's outer top corner.
  3. The area outside that boundary is the lighter "income zone": (61,67,64) for metal, (55,61,58) for energy.
     It can be drawn as the base colour in the upper 0.44 H.
* **Outline.** 1 px opaque `{0.243,0.243,0.243,1}` along the bottom and the slanted sides. None on top.
  Optionally a 1 px top inner darkening (black α 0.15).
* **Drop shadow.** Before the panel, draw the same skewed shape offset by **(+0.04 H, -0.10 H)** in GL
  (down-right) in black at α 0.23-0.28, hard-edged with no blur. For the slanted outer edges a pure
  y-offset looks too thin. Either grow the shape by about 0.1 H on the down and outer sides, or simply
  draw it offset by 0.1 H down and 0.1 H outward.

### Bars and knobs

* **Bars:** track 2.77 H long and **0.148 H tall**, centred at **0.285 H below the top**.
  * Inner end 1.10 H from the gauge centre.
  * Track gradient c1 = 0.357 grey (bottom), c2 = 0.227 grey (top). Darker on top.
  * Metal fill flat 0.85 grey, anchored at the inner end. `cs ≈ 0.015 H`.
  * 4 px (0.06 H) shadow below the track, black α 0.13.
  * Bottom-outer chamfer of about 0.055 H.
* **Knobs:** 0.23 H × 0.31 H, centred on the bar, 1 px dark outline (0.13 grey). Gradient from 0.71
  (top) to 0.92 (bottom), plus a narrow diagonal highlight quad.
  * red knob: gradient `{0.94,0.10,0.10}` → `{0.98,0.52,0.52}`.

### Gauge

Take `cx = gauge centre x`, `cy = top - 0.72 H`. Then:

| quantity | value |
|---|---|
| r_in | **0.437 H** |
| r_out | **0.583 H** |
| thickness | 0.146 H |
| round caps | radius 0.073 H |
| sweep, cap centres | from 207.8° to 8.2° clockwise (≈ 200°), i.e. tips at 216° → 0° |

* Draw order: grey track (full sweep), then the dark-teal arc up to "secondary" (cap centre at 58.7°),
  then the bright-teal arc up to "value" (cap centre at 113.5° for 50 %).
* Value mapping on cap centres: `angle = 207.8 - frac * 199.6`. If the visible tip should equal the
  value, map on the visible tips instead: `216 - frac * 216`.
* Thin gold arc: r = 0.70 H, width 0.03 H, from 75° to 135°.
* Orange marker triangle: about 0.19 H × 0.14 H, centred at r 0.67 H, angle ≈ 109°.

### Text sizes (font px = fraction × H)

| text | size | colour |
|---|---|---|
| income / pull | **0.30 H** | `#A0EC7D` / `#FF7C7C` |
| storage | **0.25 H** | |
| current, wind value, "20" | **0.36 H** | |
| "50%" | **0.28 H**, italic about 10° | |
| wind range "1-25" | **0.22 H** | |

* Line centres: top line at 0.30 H, bottom line at **0.67 H** below the panel top. Wind line at 0.31 H.
* All texts use a soft drop shadow (+1, -1.5 px in GL), black α ≈ 0.6.
* Gauge text "50%": right edge 0.16 H inside the gauge's right edge, bottom 0.08 H above the gauge bottom.
