# Headless checks for the top bar widgets

No game needed. Requires Python 3 and `pip install lupa` (bundles a real Lua 5.1).

    python3 -I tools/luacheck51.py gui_top_bar_buildpower.lua      # compile with Lua 5.1 (catches syntax errors and the 200-local / 60-upvalue limits)
    python3 -I tools/run_widget.py gui_top_bar_buildpower.lua      # run the widget lifecycle against mocked Spring/gl/WG APIs

`mock_env.lua` is the mocked engine: a few fake UnitDefs (commander, builder, nano, factory, wind,
tank, solar), resources, rules params, and no-op gl. `run_widget.py` drives Initialize, ViewResize,
400 game frames with units finishing, dying and being given away, hover, a spectator switch and
Shutdown, and prints PASS/FAIL per step. The stock widget in `stock_reference/` passes it.

## Rendering a widget to a PNG

    python3 -I tools/render_widget.py gui_top_bar_new_design.lua --out nd.png --scale 2
    python3 -I tools/render_widget.py gui_top_bar_new_design.lua --compare tools/assets/mockup_new_design.png --out cmp.png
    python3 -I tools/render_widget.py gui_top_bar_buildpower.lua --legacy --vsx 2560 --vsy 1440 --ui-scale 1.3

Options: `--out file.png`, `--vsx/--vsy` (1920x1080), `--ui-scale` (1), `--legacy` (spring-2026 build:
no BAR table, FlowUI without the skewed drawers), `--frames` (200 game frames before the shot),
`--crop auto|full|x1,y1,x2,y2` (auto: everything drawn, 10 px around, at least 40 px below the bar),
`--scale N` (upsample for viewing), `--compare mockup.png` (rows: mockup scaled to the same bar height and
aligned on the metal element's left edge, the render, a 50% blend; `--mockup-bar-height` 67 and
`--mockup-metal-x` 100 fit the bundled mockup), `--ss` (supersampling, 2), `--bg R,G,B|transparent`
(flat 60,80,70 water), `--font-scale` (0.95), `--wind` (15.2), `--no-coms`, `--no-tidal`. About 3 s per shot.

How it works: `mock_env.lua` as for run_widget.py, then `mock_gl_record.lua` replaces the no-op gl with a
recording layer (matrix stacks, colour, texture, blending, scissor, gl.BeginEnd/Shape/Rect/TexRect, display
lists that record their gl calls and replay them with the state current at CallList, gl.CreateTexture and
gl.R2tHelper.RenderToTexture/BlendTexRect render targets, fonts that record Print). The real
`stock_reference/gui_flowui.lua` is loaded (in its own `widget` environment) so the elements are drawn by the
stock FlowUI code. The widget runs Initialize, ViewResize, 20 pregame updates and the game frames (os.clock is
simulated at 30 fps; resources 812/1000 +15 -13 and 0/2500 +158 -214, wind 15.2, a water map with tidal 20,
four teams so the commander counter shows, mouse away from the bar); only the last DrawScreen goes to the
screen, render-to-texture contents are whatever the textures hold at that moment. `render_widget.py`
rasterises the recorded triangles (2x2 supersampled) and text, and composites.

Exact (follows GL): geometry, skew, chamfers, matrices (rotation about z only), Gouraud colour per triangle
(FlowUI gradients), blend factors (on premultiplied targets; render targets accumulate alpha like
`BlendFuncSeparate(..., ONE, ONE_MINUS_SRC_ALPHA)`, additive draws keep the target alpha), scissor, the
texture matrix (scrolling energy glow), Spring texture flags `n` `l` `g` `i` `c` `rW,H`, render-to-texture
clears (scissor lists clear only those rectangles and limit only the clear, not the drawing (the documented R2tHelper behaviour); `--r2t-clip` restores clipping).

Approximations: antialiased edges (the game draws the UI without multisampling); bilinear sampling with one
mip level per triangle (no trilinear); text is Pillow/FreeType with Poppins-Regular (font 1) and
Exo2-SemiBold (font 2), size = 0.95 em per Spring size unit (calibrated on readme_pics/sliders_01.png, a real
screenshot), the outline is a blurred glyph mask times the outline strength (Spring bakes a similar blurred
outline texture), the shadow is an offset copy, colour codes `\255RGB`, `\254RGBA` and `\b` are honoured;
vertical alignment follows Spring (`d` descender line, `v` centre, `t` top, `a` ascender, `b` bottom, default
baseline). The guishader (background blur) is ignored: with a flat background the blur changes nothing.
Textures missing from `tools/assets` draw as grey at 0.3 alpha and are listed on stdout; `VFS.FileExists`
answers from `tools/assets` for `Icons/` and `LuaUI/Images/`, so fallbacks happen as in the game when the
file is not in the BAR repo either.

### Comparing the new design against the mockup

    python3 -I tools/render_widget.py gui_top_bar_new_design.lua --compare tools/assets/mockup_new_design.png \
        --calm --bp-used 0.5125 --bp-reserved 0.766 --bp-msupport 0.702 --bp-esupport 0.4963 --no-coms \
        --out /tmp/compare.png --scale 2

`--calm` clears the stall/idle flags and alerts for the shot, `--bp-*` set the gauge to the mockup's state,
`--mm-level`, `--share-metal`, `--share-energy` move the knobs. The compare image shows the mockup, the render and
a 50% blend; the mockup is scaled so its strip height (64 px) matches the render and aligned on the metal element.
The measurement script used for the pixel comparison lives in design/mockup_measurements.md's method section;
the target was every geometric value within 2% of H and angles within 1.5 degrees.
