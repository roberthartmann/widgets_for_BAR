local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Top Bar with Buildpower 0.5.005 gl4 tuned",
		desc = "Official top bar plus a buildpower bar; one draw call, glyph texts, cheap builder scan, low update rates (replaces 'Top Bar'; enable only one)",
		author = "Floris, Robert82",
		date = "Nov, 2025",
		license = "GNU GPL, v2 or later",
		layer = -95000,
		enabled = true,
		handler = true, --can use widgetHandler:x()
	}
end

--[[
0.5.005 tuned: changes vs 0.5.004 glyphs
Same bar, same single draw call (13 Lua -> GL calls per steady frame), lower update rates:
 - builder scan: the cheaper scan of 0.5.002 lean+scan (BPS.TrackUnit .. BPS.GameFrame replaced: dense arrays
   instead of a coroutine, GetUnitWorkerTask instead of ValidUnitID + GetUnitIsBuilding + GetUnitDefID,
   idle builders cost one engine call); the unused BPS.builderCoroutine field is gone
 - engine cadence (RecoilEngine master): Spring.GetTeamResources returns res (current) and resStorage as
   they are now, but pull / income / expense / sent / received are the resPrev* values (LuaSyncedRead.cpp
   GetTeamResources), copied and reset in CTeam::ResetResourceState (Team.cpp), which CTeamHandler::GameFrame
   (TeamHandler.cpp) calls only when frameNum % TEAM_SLOWUPDATE_RATE == 0, TEAM_SLOWUPDATE_RATE = 30
   (GlobalConstants.h): the rate values change once per 30 sim frames (1 s at normal speed), after
   eventHandler.GameFrame of that frame (Game.cpp), i.e. widgets see them from GameFrame(n + 1) / the next draw
 - two ticks instead of one 30 Hz tick:
   * gl4.tick, slow, 10 Hz (gl4.SLOW_TICK): Top Bar Buttons fallbacks, spectator team switch, hover re-poll,
     guishader check, slider sync, resource read every 0.25 s as before (gl4.READ_INTERVAL; overflow /
     stall state, banners, pull / income / storage texts, wind, commander count), smoothing (every slow tick;
     factor 1 - 0.5^1.5 per 0.1 s = the old 0.5 per 1/15 s), current value texts, flash states, options
     check (1 Hz, re-registers only when WG.options is a new table), BP tooltip on hover start
   * gl4.fastTick, 20 Hz (the bars timer of drawResBars, unchanged): fill widths of metal / energy / BP,
     slider knobs while dragging (MouseMove records the position, the fast tick applies it: SetShareLevel /
     the conversion message at most 20 per second instead of one per mouse event), hover reaction (bigger
     knobs). It does nothing while the sim does not advance (no game frame for 0.1 s: paused, pre-game) and
     no drag is active, except the first tick after that started and ticks whose inputs changed (smoothing,
     resource read, layout, options, team change: gl4.ts.fastDirty)
 - flash pulse in the shader: the two flash instances of a bar carry a blink mode (fillp.y: gl4.BLINK_NONE,
   _OVERFLOW, _ALLY, _LOW, _STALL) and the alpha at full pulse; Lua writes them only when the state or the
   intensity changes (gl4.updateFlashes / gl4.setFlash). The vertex shader multiplies the alpha by
     stall, ally overflow: p(t); own overflow: 0.6 + 0.4 p(t); low resource: 1 (steady, as before)
   with t = timeInfo.y (draw seconds) and p the 0.5.004 Lua curve (blinkProgress: +0.3 per 1/30 s step up to
   1, then -(1/30) / (1.5 p) per step down to 0; one cycle = 28 steps = 0.9333 s) in closed form:
     u = mod(t, 28/30);  p = min(1, 9u) for u < 4/30, else sqrt(max(0, 1 - (u - 4/30) / 0.78))
   (dp/dt = -k/p => p^2 falls linearly; 0.78 s fitted to the stepped decay: max error 0.017, mean 0.007).
   Draw time keeps pulsing while the game is paused (0.5.004 froze the pulse). blinkProgress / blinkDirection
   and gl4.BLINK_DT are gone
 - commander icon blink (allyComs == 1, game frame % 12 < 6) in the shader as well: icon instance blink mode
   gl4.BLINK_COM, tint (1, 0.6, 0, 0.45) from timeInfo.x (game frame); written only when allyComs changes
 - texts (still only through the glyph slot writer, uploading only the touched instance range):
   * pull / income: formatted when their number changed, i.e. after the engine's team slow update (1 per
     30 sim frames); pull and income are separate slots now (updateRes[res][2] / [4]), no concatenated string
   * current value: from the 10 Hz slow tick; the shown number is computed first and the string formatted
     only when it changed (gl4.valueText). gl4.VALUE_STEP = 5: while a bar is not hovered, values from
     gl4.VALUE_STEP_MIN = 100 up to gl4.VALUE_STEP_MAX = 1000 (exclusive) are shown in steps of 5; exact below
     100 and while hovering. 1000..9999 stay exact integers (short() only switches to "12k" above 9999);
     set VALUE_STEP_MAX = 10000 to step those too, VALUE_STEP = 1 to switch the rounding off
   * BP percentage: integer percent, recomputed at most every 0.5 s (gl4.PCT_INTERVAL)
   * wind: formatted and written only when the wind value changed (at the read); commander counts on change;
     storage hidden with the overflow banner in the same tick. T.frame no longer checks anything per frame
 - BP tooltip (BPS.updateTooltip): numbers re-checked and re-sent at the read cadence while the mouse is over
   the BP panel (and at once when it arrives), otherwise at most once per second (gl4.TOOLTIP_IDLE_INTERVAL)
 - bar instance uploads: gl4.flush uploads only the range of changed bar instances (was the whole VBO)
 - measured in the mock harness (60 fps, sim running, metal and energy changing every sim frame, rates once
   per 30 sim frames), 0.5.004 -> 0.5.005: slow ticks 30 -> 10 /s; fast ticks 15 -> 15 /s running (the 0.05 s
   bars timer fires every 4th frame at 60 fps, unchanged), 15 -> 0 /s paused; glyph slot writes 33.9 -> 23.7 /s;
   bar instance pushes 163 -> 116 /s (own overflow: 222 -> 117, flash pushes 62 -> 3); upload calls 16 -> 22 /s
   but floats uploaded 96.7k -> 23.8k /s; Lua per frame (all call-ins, mock) 22.6 -> 17.4 us running,
   9.8 -> 6.9 us paused; allocation 8.8 -> 1.3 KB/s (builder scan 6.1 -> 0)

0.5.004 glyphs: changes vs 0.5.003 onedraw
All dynamic texts are glyph instances in the same instance VBO, drawn by the same shader in the same single
draw call; no render-to-texture happens after init except the refreshUi rebuilds (uiBgTex, uiTex, glyph atlas).
 - texts: current / storage / pull / income of metal and energy, BP percentage, current / min / max wind,
   tidal value, commander counts and the commander icon (with its blink tint). All code is in gl4.text
 - glyph atlas (gl4.text.tex, texture unit 5 = gl4.TEXUNIT_GLYPH): built with font2:Print on refreshUi only
   (init: ViewResize, LanguageChanged, GameStart, team change, ...): one row per text style (font size +
   vertical option), each glyph of "0123456789.-+%km" twice: complete (white fill + baked black outline,
   exactly what font:Print 'o' draws) and fill only; one more cell for the commander icon. Premultiplied;
   instances tint it with color1 (black outline x tint = the colored text of 0.5.003)
 - text slot = fixed run of 2 * N instances (N complete glyphs, then N fill glyphs: Recoil draws all outlines
   of a string before its fills); 175 instances in group "text" (gl4.GROUPS: bg, wind, tidal, ui, text, metal,
   energy, BP): the texts keep their place in the layering (they were in the uiTex blit, below bar glow / knobs)
 - layout like font:Print: start = x - align * W(text) * size (rounded), then the kerning aware advance
   W(ab) - W(b) per glyph (measured with font2:GetTextWidth once per rebuild), pens rounded to pixels;
   positions / sizes / options are the 0.5.003 ones (resbarDrawinfo text tables, wind / tidal / coms formulas)
 - strings are written only when they change, at the 0.5.003 cadence (updateRes flags at the bars update,
   wind text on change, storage hidden at once with the overflow banner, com counts on change, icon blink per
   frame); writes go into the instance table's Lua mirror, only the touched instance range is uploaded,
   no allocation per write
 - shader: texMode 10 (gl4.TEX_GLYPH) samples glyphTex on unit 5 (color2 = atlas uv rect)
 - per frame: one more texture bind + unbind (unit 5): 13 Lua -> GL calls (0.5.003: 11)
 - uiTex keeps only static things: bar icons / backgrounds and the translated "no wind" lines (any language,
   static per language, so they stay text rendered on refreshUi). Removed: drawResbarValue /
   drawResbarPullIncome / drawResbarStorage / BPS.drawValue / renderResbarText / renderWindText /
   renderComCounter, the uiTex storage pre-clear, the text scissor rects and dlist.coms

0.5.003 onedraw: changes vs 0.5.002 lean
The whole bar is ONE instanced draw call per frame (plus one per overflow banner / BP alert list while
one is up). The per-frame display lists are gone; four instances were added in front of the bars:
 - draw order (= instance order, gl4.GROUPS): bg (uiBgTex blit), wind (rotating blades), tidal (bobbing
   waves), ui (uiTex blit: icons, bar backgrounds, texts, com counter), metal, energy, BP (bars, knobs,
   markers). This is the layering 0.5.002 drew with its lists (blendBg, wind, tidal, blendUi, bars);
   the com counter was never a per-frame list: it is rendered into uiTex (on change) and so is part of ui
 - texture units, fixed: 0 = texture atlas (gl4.atlas), 1 = uiBgTex, 2 = uiTex (rebound by id every frame,
   they are recreated on refreshUi), 5 = left free (reserved for a glyph atlas); 3, 4 unused
 - wind blades: one instance (bounding box of the rotated square); the fragment shader rotates the texture
   lookup by angle = phase + speed * (T - T0), T = (timeInfo.x + timeInfo.w) / 30 (game time incl. the
   frame offset), phase / speed (= wind * 6 deg/s, as before) / T0 in the instance, rewritten only when
   the wind value changes (gl4.setWindSpeed keeps the angle continuous). Game time because Lua knows it
   exactly; consequence: the blades stand still while the game is paused or not started (0.5.002 turned them
   by draw time, also while paused)
 - tidal waves: one instance, the vertex shader adds sin(timeInfo.y / pi) * tidalWaveAnimationHeight to y
   (draw time: keeps bobbing while paused, as before)
 - blades / waves textures (256 px, ':n:' nearest) are two more cells in the atlas, sampled at texel centers
   (= nearest filtering); the 0.2 alpha tint is the instance color; output premultiplied like the rest
 - uiBgTex / uiTex blits: premultiplied texture as is (was TexRect with ONE, ONE_MINUS_SRC_ALPHA)
 - all render-to-texture updates of uiTex (storage clear, wind text, resource texts, com counter) now happen
   before the draw, so a changed text shows in the same frame (0.5.002: one frame later)
 - guishader: uiBgList (uiBgTex blit list) is still built on refreshUi and inserted as before
 - per frame: 3 texture binds, blending, shader activate, 1 DrawArrays, deactivate, blending reset,
   3 unbinds = 11 Lua -> GL calls (0.5.002 lean: 15, 0.5.001: 29); + SetMouseCursor while hovering
 - sampler units are set once with the viewSize uniform in the first draw (besides uniformInt at link)
 - instance groups are data driven: gl4.GROUPS (order), gl4.ELEMENTS[group], gl4.range[group] =
   { first (0 based), count } filled by gl4.init. To append a group (e.g. glyph texts) add its name to
   gl4.GROUPS and its element list to gl4.ELEMENTS before gl4.init runs; gl4.groupDrawn returns true for
   groups it does not know, and consecutive drawn groups are merged into one draw call
 - gl4.BLINK_DT is at the top of the gl4 table

0.5.002 lean: changes vs 0.5.001 gl4
Same bar, same visuals, same buildpower tracking (BPS.GameFrame / TrackUnit / UntrackUnit untouched);
less work per frame:
 - No per-frame Update call-in. widget:Update runs once (first frame after Initialize) and removes itself
   (widget.Update = nil + the handler's queued RemoveCallIn / RemoveWidgetCallIn). What it did moved to:
   * gl4.tick() (30 Hz): from widget:GameFrame (at most every 0.02 s) and, while no game frame came for
     0.1 s (paused, pre-game), from DrawScreen with an os.clock accumulator. Top Bar Buttons fallbacks,
     spectator team switch, blink (fixed step of 1/30 s per tick), flash colours, guishader check, slider /
     hover checks (every tick, was 20 Hz), smoothing (~15 Hz, was 0.07 s), 4 Hz resource read, overflow,
     resource texts, wind text, coms, BP slow update and the options check (gl4.slowTick)
   * widget:IsAbove (always returns false, so nothing changes for other widgets / the engine) and
     widget:MouseMove set hoveringTopbar; the tick polls the mouse only when IsAbove was not called for 0.25 s.
     Spring.SetMouseCursor stays in DrawScreen while hovering
   * gl4.frameStart() at the top of DrawScreen (in place of now = os.clock()): draw time, the deferred bars
     update flag, wind blade rotation advanced by the draw time delta, the paused / pre-game tick
 - Shader: no uniforms per frame. viewSize is given at creation and set once in the first draw after
   ViewResize (uniform values persist in the program object, LuaShader's SetUniform cache relies on that too);
   the energy flow animation reads timeInfo.y (drawSeconds) of the engine uniform buffer
   (//__ENGINEUNIFORMBUFFERDEFS__ in the fragment shader), same speeds as before (-t/80, t/70, -t/55)
 - One texture atlas (1024 x 512 FBO texture, created in Initialize, filled with r2tHelper.RenderToTexture
   in the first draw, deleted in Shutdown) holds the flow, noise, glow centre and glow edge textures, each as
   a 2x2 tiled copy at source resolution; the shader samples fract(uv) inside the copy, which repeats them
   like GL_REPEAT including bilinear filtering at the wrap. The noise copy is stored at the mip level the
   original (mipmapped, minified) noise sampling used; re-rendered only if that level changes (resize).
   Bound as 1 texture on unit 0 (gl4.bindTextures: 1 bind + 1 unbind, was 4 + 4)
 - Quad winding made counter-clockwise in the vertex shader (x/y of the unit quad swapped), so the per-frame
   gl.Culling(false) is gone
 - DrawScreen: the matrix push/pop around the wind blades (the wind lists push/pop themselves) and the
   push / color / pop at the end are gone; the color is reset after a render-to-texture that may change it
 - Allocations on the steady path removed: drawResBars uses 7 preallocated scissor rects; short() lost its
   string-keyed memo (every call built a new key string); the value / pull / income / wind texts are only
   formatted when their number changed; resources are read in place at 4 Hz (smoothedResources gets a copy
   instead of becoming an alias of r); the ally team overflow check uses the cached ally team list instead of
   Spring.GetTeamList (a new table each call)
 - Lua -> GL calls per steady frame (mock harness, not hovering): 29 -> 15 (overflow banner frame 43 -> 23);
   allocation per steady frame (60 fps, sim running, outside the unchanged builder scan): ~236 bytes -> 0
If GL4 is not available the widget says so and removes itself: use "Top Bar with Buildpower 0.5.001 light".

GL4 variant (0.5.001 gl4) of "Top Bar with Buildpower 0.5.001 light"
Identical to the light file except for how the per-frame parts of the three resource bars are drawn:
 - flash/tint rects, value bars (fill, inner border, glow, metal noise, energy flow, BP reserved overlay),
   slider knobs and the BP eco/wind markers are instances in ONE instance VBO (gl.InstanceVBOTable),
   drawn by ONE GLSL shader (gl.LuaShader) with premultiplied alpha, normally in a single instanced
   draw call per frame (one per bar while an overflow banner / BP alert list has to go in between)
 - all instances are created once in Initialize; value / layout changes only rewrite instance fields
   (fill width, positions, colors) and the changed instances are uploaded once before drawing;
   no display lists are created or deleted for the bars at runtime
 - the static layer (panels, icons, bar backgrounds, texts rendered into textures), banners, wind,
   tidal, coms, tooltips, options and the buildpower tracking are unchanged
 - if GL4 is not available (or the shader fails) the widget says so and removes itself;
   use "Top Bar with Buildpower 0.5.001 light" then
All GL4 code is in the gl4 table (see the comment above it).

Buildpower additions to the official top bar (0.5.001 light)
Base: the official luaui/Widgets/gui_top_bar.lua (BAR master, 2026-11-07). Metal, energy, wind,
tidal and the commander counter are unchanged. Ported from gui_top_bar_alpha_0.4.010.lua:
 - buildpower tracking: TrackUnit/UntrackUnit on UnitFinished/Given/Taken/Destroyed, builder scan
   spread over game frames (coroutine), weighted averages, metal/energy supported buildpower,
   wind range. State in the BP / BPS / BPC tables, all skipped when the bar is off.
 - buildpower bar between the metal and energy bars ("BP" as third resource: resbarArea.BP, resbarDrawinfo.BP,
   dlist.resbar.BP[n], dlist.resValuesBar.BP, cache.lastValueWidth.BP; updateResbar("BP"),
   updateResbarValues("BP", update), updateResbarText("BP") dispatch to BPS.*; drawn in
   drawResBars(); panel/icon/bar background go through refreshUi into uiBgTex/uiTex, the
   percentage text is a glyph slot, rewritten only when it changed)
 - eco support and wind range indicators, stall flash, alerts below the bar, tooltips
 - options via WG.options.addOptions/removeOptions: buildpower bar (reload), eco support indicators,
   wind range indicators, debug data; saved with Get/SetConfigData
Not ported (no longer part of the official bar): buttons row and quit screen (now the separate
"Top Bar Buttons" widget), the energy flow scroll effect on the buildpower bar, the old guishader
handling, the bar scale/width and auto hide buttons options.
]]

-- Localized functions for performance
local mathCeil = math.ceil
local mathFloor = math.floor
local mathMax = math.max
local mathMin = math.min
local mathIsInRect = math.isInRect
local mathSin = math.sin
local PI = math.pi

-- Localized string functions
local stringFormat = string.format

-- Localized Spring API as table (avoids global lookups, saves local slots)
local sp = {
	GetGameFrame = Spring.GetGameFrame,
	GetTeamRulesParam = Spring.GetTeamRulesParam,
	GetTeamList = Spring.GetTeamList,
	SetMouseCursor = Spring.SetMouseCursor,
	GetMyAllyTeamID = Spring.GetLocalAllyTeamID,
	GetTeamUnitDefCount = Spring.GetTeamUnitDefCount,
	GetSpectatingState = Spring.GetSpectatingState,
	GetTeamResources = Spring.GetTeamResources,
	GetMyTeamID = Spring.GetLocalTeamID,
	GetMouseState = Spring.GetMouseState,
	GetWind = Spring.GetWind,
	GetGameSpeed = Spring.GetGameSpeed,
	GetFrameTimeOffset = Spring.GetFrameTimeOffset, -- (wind blade phase, 0.5.003)
	-- buildpower tracking
	GetUnitHealth = Spring.GetUnitHealth,
	GetUnitDefID = Spring.GetUnitDefID,
	GetUnitIsBuilding = Spring.GetUnitIsBuilding,
	GetUnitResources = Spring.GetUnitResources,
	GetUnitCurrentCommand = Spring.GetUnitCurrentCommand,
	GetTeamUnits = Spring.GetTeamUnits,
	ValidUnitID = Spring.ValidUnitID,
	-- GetUnitCommands(unitID, 0) / GetFactoryCommands(unitID, 0) are deprecated in Recoil
	GetUnitCommandCount = Spring.GetUnitCommandCount or function(unitID)
		return Spring.GetUnitCommands(unitID, 0)
	end,
	GetFactoryCommandCount = Spring.GetFactoryCommandCount or function(unitID)
		return Spring.GetFactoryCommands(unitID, 0)
	end,
}

-- Configuration (consolidated into table to save local slots)
local cfg = {
	relXpos = 0.3,
	borderPadding = 5,
	bladeSpeedMultiplier = 0.2,
	escapeKeyPressesQuit = false,
	allowSavegame = true, -- Spring.Utilities.ShowDevUI()
	spawnWarpInFrame = Game.spawnWarpInFrame,
	useSkew = true, -- toggle trapezoidal/parallelogram skew on all UI elements
	skewAngleDeg = 20, -- angle of skew slope in degrees
	smallElementHeightFraction = 0.85, -- wind/tidal/coms/buttons height as fraction of topbar
}

-- Precomputed skew tangent (updated whenever cfg is read at init)
local skewTan = math.tan(math.rad(cfg.skewAngleDeg))

-- System
local guishaderEnabled = false
local gaiaTeamID = Spring.GetGaiaTeamID()
local spec = sp.GetSpectatingState()
local myAllyTeamID = sp.GetMyAllyTeamID()
local myTeamID = sp.GetMyTeamID()
local mmLevel = sp.GetTeamRulesParam(myTeamID, "mmLevel")
local myAllyTeamList = sp.GetTeamList(myAllyTeamID)
local numTeamsInAllyTeam = #myAllyTeamList

-- Game mode / state
local isSingle = false
local gameFrame = sp.GetGameFrame()

-- Resources
local r = { metal = { sp.GetTeamResources(myTeamID, "metal") }, energy = { sp.GetTeamResources(myTeamID, "energy") } }
local energyOverflowLevel, metalOverflowLevel
local allyteamOverflowingMetal = false
local allyteamOverflowingEnergy = false
local overflowingMetal = false
local overflowingEnergy = false
local showOverflowTooltip = {}
local showingWarning = { metal = false, energy = false }
local supressOverflowNotifs = false
local isMetalmap = false

-- Wind + tide
local avgWindValue, riskWindValue
local currentWind = 0
local currentWindText = "\255\255\255\2550"
local displayTidalSpeed = not BAR.Lava.isLavaMap
local tidalSpeed = Spring.GetTidal() -- for now assumed that it is not dynamically changed
local tidalSpeedText = "\255\255\255\255" .. tostring(tidalSpeed)
local tidalWaveAnimationHeight = 10
local windRotation = 0
local minWind = Game.windMin
local maxWind = Game.windMax
local minWindText = "\255\166\166\166" .. tostring(minWind)
local maxWindText = "\255\166\166\166" .. tostring(maxWind)
local noWindText1 = "\255\200\200\200" .. BAR.I18N("ui.topbar.wind.nowind1")
local noWindText2 = "\255\200\200\200" .. BAR.I18N("ui.topbar.wind.nowind2")
local windFunctions = require("common/wind_functions")
local noWind = windFunctions.isNoWind() -- constant per game: Game.windMin/windMax never change

local function refreshWindTidalTextCache()
	tidalSpeedText = "\255\255\255\255" .. tostring(tidalSpeed)
	minWindText = "\255\166\166\166" .. tostring(minWind)
	maxWindText = "\255\166\166\166" .. tostring(maxWind)
	noWindText1 = "\255\200\200\200" .. BAR.I18N("ui.topbar.wind.nowind1")
	noWindText2 = "\255\200\200\200" .. BAR.I18N("ui.topbar.wind.nowind2")
end

-- Commanders
local allyComs = 0
local enemyComs = 0 -- if we are counting ourselves because we are a spec
local enemyComCount = 0 -- if we are receiving a count from the gadget part (needs modoption on)
local prevEnemyComCount = 0
local isCommander = {}
local commanderUnitDefIDs = {} -- Array of commander unitDefIDs for faster iteration
local displayComCounter = false

-- OpenGL (only localize functions used in hot paths)
local glTexture = gl.Texture
local glTexRect = gl.TexRect
local glCreateList = gl.CreateList
local glCallList = gl.CallList
local glDeleteList = gl.DeleteList
local glBlending = gl.Blending
local glColor = gl.Color
local glPushMatrix = gl.PushMatrix
local glPopMatrix = gl.PopMatrix
local glRotate = gl.Rotate
local glTranslate = gl.Translate
local glScale = gl.Scale
local glMatrixMode = gl.MatrixMode
local glLoadIdentity = gl.LoadIdentity
local r2tHelper = gl.R2tHelper

-- Graphics
local textures = {
	noiseBackground = ":g:LuaUI/Images/rgbnoise.png",
	barGlowCenter = ":l:LuaUI/Images/barglow-center.png",
	barGlowEdge = ":l:LuaUI/Images/barglow-edge.png",
	energyGlow = "LuaUI/Images/paralyzed.png",
	blades = ":n:LuaUI/Images/wind-blades.png",
	waves = ":n:LuaUI/Images/tidal-waves.png",
	com = ":n:Icons/corcom.png",
}
local textWarnColor = "\255\255\215\215"

-- UI Elements
local topbarArea = {}
local resbarArea = { metal = {}, energy = {}, BP = {} }
local resbarDrawinfo = { metal = {}, energy = {}, BP = {} }
local shareIndicatorArea = { metal = {}, energy = {} }
local windArea = {}
local tidalarea = {}
local comsArea = {}

-- UI State
local orgHeight = 46
local ui_scale = tonumber(Spring.GetConfigFloat("ui_scale", 1) or 1)
local ui_opacity = Spring.GetConfigFloat("ui_opacity", 0.7)
local height = orgHeight * (1 + (ui_scale - 1) / 1.7)
local vsx, vsy = Spring.GetViewGeometry()
local mx = -1
local my = -1
local widgetScale = (0.80 + (vsx * vsy / 6000000))
local xPos = mathFloor(vsx * cfg.relXpos)
local showResourceBars = true
local widgetSpaceMargin, bgpadding, RectRound, RectRoundOutline, TexturedRectRound, UiElement, UiSliderKnob
local updateRes =
	{ metal = { false, false, false, false }, energy = { false, false, false, false }, BP = { false, false, false, false } }

-- Display Lists (consolidated into table to save local slots)
local dlist = {
	windText = {},
	resValuesBar = {},
	resValues = {},
	resbar = { metal = {}, energy = {}, BP = {} },
	energyGlow = nil,
	quit = nil,
	buttons = nil,
	coms = nil,
	wind1 = nil,
	wind2 = nil,
	tidal2 = nil,
}

-- Caching (consolidated into table to save local slots)
local cache = {
	lastPullText = { metal = "", energy = "" }, -- 0.5.005: pull / income are formatted and written separately
	lastIncomeText = { metal = "", energy = "" },
	lastStorageValue = { metal = -1, energy = -1 },
	lastStorageText = { metal = "", energy = "" },
	lastWarning = { metal = nil, energy = nil },
	lastValueWidth = { metal = -1, energy = -1, BP = -1 },
	lastResbarValueWidth = { metal = 1, energy = 1 },
	lastDrawnValue = { metal = "", energy = "", BP = -2 }, -- BP: shown percentage (number)
	-- 0.5.002: numbers the texts were last formatted from (texts are only formatted when these change)
	lastPullNum = { metal = false, energy = false },
	lastIncomeNum = { metal = false, energy = false },
	warningCleared = { metal = false, energy = false },
	showIndicators = true,
}

-- Buildpower (BP): all added state lives in BPC, BPS and BP (Lua 5.1 limits: 200 locals in the
-- main chunk, 60 upvalues per function; DrawScreen is already at the upvalue cap and untouched)
local BPC = { -- config: saved with Get/SetConfigData, edited in the options widget
	drawBPBar = true, -- requires reload
	drawBPIndicators = true, -- metal/energy supported buildpower markers
	drawBPWindRangeIndicators = true, -- range of energy supported buildpower over the wind range
	debugTooltip = false, -- debug data in the buildpower tooltip
}

local BPS = { -- runtime state; the BP functions are added to this table further down
	on = false, -- BPC.drawBPBar as read in Initialize
	nextPct = 0, -- next BP percentage update (os.clock), gl4.PCT_INTERVAL
	cacheDataBase = { -- sums of the current builder scan pass
		usedBP_instant = 0,
		reservedBP_instant = 0,
		usedBPMetalExpense = 0,
		usedBPEnergyExpense = 0,
		usedBPExceptStalled = 0,
		usedBPIfNoStall = 0,
	},
	unitTracking = {
		frameCheckInterval = 3,
		maxUnitsPerFrame = 20,
		nextCheckFrame = 0,
		totalUnits = 0,
		unitsPerFrame = 20, -- limit processed units per frame to improve performance
		trackedNum = 0,
	},
	trackedBuilders = {}, -- [unitID] = { buildSpeed, isBuilt, unitDefID, unitTeamID, unitType }
	trackedWinds = {},
	numWindGenerators = 0,
	windDefNames = { armwin = true, corwin = true, legwin = true },
	unitCostData = {}, -- [unitDefID] = { buildTime, energy, metal, EperBP, MperBP }
	stalling = { lowPrioEnergy = 0, lowPrioMetal = 0 },
	playerStallingMetal = false,
	playerStallingEnergy = false,
	pct = -1, -- shown percentage (-1 = no builders, no text)
	lastAdditionalWidth = -1,
	textMaxWidth = 0,
	textClipL = 0,
	textClipR = 0,
	ind = { dirty = true }, -- indicator marker cache (pixel positions)
	tt = { dirty = true }, -- tooltip cache (areas, last numbers, last text)
	bannerKey = 0,
	optionsApi = nil,
	alerts = { -- bit, text, warning (else info)
		{ 1, "   Need metal   ", true },
		{ 2, "   Need energy   ", true },
		{ 4, "   Idle buildpower   ", false },
	},
	optionSpecs = {
		{ key = "drawBPBar", name = "buildpower bar", description = "Draw the buildpower bar (requires reload)" },
		{
			key = "drawBPIndicators",
			name = "eco support indicators",
			description = "Estimate how much buildpower is supported by your metal and energy income",
		},
		{
			key = "drawBPWindRangeIndicators",
			name = "wind range indicators",
			description = "Show how energy-supported buildpower might vary with wind speed",
		},
		{
			key = "debugTooltip",
			name = "debug data",
			description = "Show debug data in tooltip when hovering over the buildpower bar",
		},
	},
	colors = {
		bar1 = { 0.2, 0.65, 0, 1 },
		bar2 = { 0.5, 0.75, 0, 1 },
		reserved1 = { 0.1, 0.55, 0, 0.5 },
		reserved2 = { 0.3, 0.65, 0, 0.5 },
		border1 = { 0, 0, 0, 0.1 },
		border2 = { 0, 0, 0, 0.17 },
		mLow = { 0.6, 0.6, 0.6, 1 },
		mHigh = { 1, 1, 1, 1 },
		eLow = { 0.8, 0.8, 0.0, 1 },
		eHigh = { 1, 1, 0.2, 1 },
		windLow = { 0.8, 0.8, 0.0, 1 },
		windHigh = { 0.4, 0.4, 0.0, 1 },
		warnLow = { 0.35, 0.1, 0.1, 1 },
		warnHigh = { 0.25, 0.05, 0.05, 1 },
		infoLow = { 0.20, 0.20, 0.20, 1 },
		infoHigh = { 0.12, 0.12, 0.12, 1 },
		red = { 0.82, 0.39, 0.39 },
		orange = { 1.0, 0.39, 0.39 },
		yellow = { 1.0, 1.0, 0.39 },
		green = { 0.47, 0.92, 0.47 },
	},
}

-- circular queues so the tables' contents don't have to be shifted
function BPS.initWeightedAverage(maxN)
	return {
		maxn = maxN, -- max number of elements
		i = 1, -- next index to write to
		curn = 0, -- current number of elements
		sum_vw = 0, -- sum(sample*weight)
		sum_w = 0, -- sum(weight)
		v = {}, -- samples
		w = {}, -- weights
	}
end

function BPS.addValueAndGetWeightedAverage(t, newValue, newWeight)
	if newValue ~= nil then
		if t.i <= t.curn then
			-- remove the old sample and weight
			t.sum_vw = t.sum_vw - (t.v[t.i] * t.w[t.i])
			t.sum_w = t.sum_w - t.w[t.i]
		end
		-- add the new sample and weight
		t.v[t.i] = newValue
		t.w[t.i] = newWeight
		t.sum_vw = t.sum_vw + newValue * newWeight
		t.sum_w = t.sum_w + newWeight
		if t.curn < t.maxn then
			t.curn = t.curn + 1
		end
		t.i = t.i + 1
		if t.i > t.maxn then
			t.i = 1
		end
	end
	if math.abs(t.sum_w) < 0.01 then
		return nil
	end
	return t.sum_vw / t.sum_w
end

-- BP[1] unused, BP[2] = 1 (bar scale), BP[3] = avg reserved BP, BP[4] = total BP, BP[5] = avg used BP
local BP = { 0, 1, 0, 0, 0 }
BP.history_usedBP = BPS.initWeightedAverage(30)
BP.history_reservedBP = BPS.initWeightedAverage(30)
BP.history_nonBuilderMetalExpense = BPS.initWeightedAverage(30)
BP.history_nonBuilderEnergyExpense = BPS.initWeightedAverage(30)
BP.history_mSliderPosition = BPS.initWeightedAverage(30) -- metal supported share of BP
BP.history_eSliderPosition = BPS.initWeightedAverage(30) -- energy supported share of BP
BP.reservedBP_instant = 0
BP.usedBP_instant = 0
BP.usedBPMetalExpense = 0
BP.usedBPEnergyExpense = 0
BP.usedBPExceptStalled = 0
BP.usedBPIfNoStall = 0
BP.realWindStrength_instant = 0
BP.eSliderPosition_minWind = 0
BP.eSliderPosition_maxWind = 0

-- Reused scratch tables for DrawScreen to avoid per-frame allocations.
local resourceNames = { "metal", "energy" }

-- Smoothing
local smoothedResources = {
	metal = { 0, 0, 0, 0, 0, 0 }, -- Init
	energy = { 0, 0, 0, 0, 0, 0 }, -- Init
}
-- 0.5.005: one smoothing step per 10 Hz slow tick (was 0.5 per ~15 Hz step): 1 - 0.5^1.5 per 0.1 s keeps the
-- convergence speed. Returns true when a value changed; values within 0.001 of the target snap to it (the
-- float recurrence could otherwise keep changing the last bit, which would keep the fast tick busy while paused)
local smoothingFactor = 1 - 0.5 ^ 1.5
local oneMinusSmoothingFactor = 1 - smoothingFactor
local function smoothResources()
	local changed = false
	local sm = smoothedResources.metal
	local rm = r.metal
	local se = smoothedResources.energy
	local re = r.energy
	for i = 1, 6 do
		local target, old = rm[i], sm[i]
		local v = old == 0 and target or (smoothingFactor * target + oneMinusSmoothingFactor * old)
		if v - target < 0.001 and target - v < 0.001 then
			v = target
		end
		if v ~= old then
			sm[i] = v
			changed = true
		end
		target, old = re[i], se[i]
		v = old == 0 and target or (smoothingFactor * target + oneMinusSmoothingFactor * old)
		if v - target < 0.001 and target - v < 0.001 then
			v = target
		end
		if v ~= old then
			se[i] = v
			changed = true
		end
	end
	return changed
end

-- Interactions
local draggingShareIndicatorValue = {}
local draggingConversionIndicatorValue, draggingShareIndicator, draggingConversionIndicator
local conversionIndicatorArea, hoveringTopbar
local font2, fontSize, comcountChanged, resbarHover

-- Audio
local playSounds = true
local resourceclick = "LuaUI/Sounds/buildbar_click.wav"

-- Timers + intervals (consolidated into table to save local slots)
local osClock = os.clock
local now = osClock()
local timers = {
	nextStateCheck = 0,
	nextGuishaderCheck = 0,
	nextResBarUpdate = 0,
	nextBarsUpdate = 0,
	lastUpdateTime = 0,
	gameFrameHappened = false,
	deferResourceUpdate = false,
	guishaderCheckUpdateRate = 0.5,
	nextForcedBarsUpdate = 0,
}

--------------------------------------------------------------------------------
-- GL4 resource bar renderer
--------------------------------------------------------------------------------
-- The dynamic parts of every resource bar (flash tint, value bar with inner border,
-- glow, metal noise / energy flow, slider knobs) are instances in ONE instance VBO
-- (unit quad x instances) drawn by ONE shader. The instance list and its order are
-- created once in gl4.init() and never change: layout and value changes only rewrite
-- fields of existing instances (Lua mirror + pushElementInstance(..., true, true)),
-- dirty instances are uploaded once before drawing. No display lists are created or
-- deleted for the bars at runtime and nothing is allocated per frame.
--
-- Output is premultiplied alpha and drawn with gl.Blending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA),
-- so normal (SRC_ALPHA, ONE_MINUS_SRC_ALPHA) and additive (SRC_ALPHA, ONE) layers of the
-- original lists share a draw call; GL keeps the primitive (= instance) order.
--
-- instance layout: 7 x vec4 = 28 floats, attribute 0 = unit quad (makeRectVBO)
-- [1..4]   rect    x, y, w, h (screen px; for FILL_WIDTH w is added to the fill width)
-- [5..8]   color1  bottom color (outer color for outlines)
-- [9..12]  color2  top color (inner color for outlines)
-- [13..16] shape   chamfer size, corner mask (1=tl 2=tr 4=br 8=bl), outline width (0 = filled), visible
-- [17..20] fillp   fill width px, 0, 0, fill mode (0 none / 1 width += fill / 2 x += fill)
-- [21..24] texp    texture mode (0 plain/1 flow/2 noise/3 glow center/4 glow edge/5 glow edge flipped), tile px, additive,
--                  noise: cell size of the noise copy in the texture atlas (px)
-- [25..28] skew    per-corner x offsets of RectRoundQuad: blx, brx, tlx, trx
--
-- 0.5.002 lean: the four textures (energy flow, metal noise, glow center, glow edge) are copied once
-- into ONE atlas texture (gl4.buildAtlas, on texture unit 0); the shader takes no per-frame uniforms
-- (viewSize is set at creation and after ViewResize, the flow animation reads timeInfo.y of the engine
-- uniform buffer). The ticks (0.5.005: slow gl4.tick 10 Hz, fast gl4.fastTick 20 Hz), the hover tracking and the
-- per-frame bookkeeping that were in widget:Update are gl4.tick / gl4.fastTick / widget:IsAbove / gl4.frameStart.
--------------------------------------------------------------------------------
local gl4 = {
	WIDGET_NAME = "Top Bar with Buildpower 0.5.005 gl4 tuned",
	FALLBACK_NAME = "Top Bar with Buildpower 0.5.001 light",
	vbo = nil,
	quad = nil,
	shader = nil,
	verified = false,
	initFailed = false,
	STEP = 28,
	-- texture atlas: 2x2 tiled copy of every source texture (cell = source px), layout shared with the shader
	ATLAS_W = 1024, ATLAS_H = 512,
	ATLAS = {
		{ tex = "energyGlow", x = 0, y = 0, cell = 128 }, -- flow (128 px source)
		{ tex = "noiseBackground", x = 256, y = 0, cell = false }, -- noise (256 px source, cell = gl4.noiseCell)
		{ tex = "barGlowCenter", x = 768, y = 0, cell = 32 }, -- glow center (32 px source)
		{ tex = "barGlowEdge", x = 832, y = 0, cell = 32 }, -- glow edge (32 px source)
		{ tex = "waves", x = 0, y = 256, cell = 256, copies = 1 }, -- tidal waves (256 px, nearest)
		{ tex = "blades", x = 768, y = 256, cell = 256, copies = 1 }, -- wind blades (256 px, nearest)
	},
	-- texture units (fixed): 0 atlas, 1 uiBgTex, 2 uiTex, 5 glyph atlas (gl4.text.tex); 3, 4 unused
	TEXUNIT_UIBG = 1, TEXUNIT_UI = 2, TEXUNIT_GLYPH = 5,
	atlas = nil, -- the atlas texture (gl.CreateTexture, fbo)
	atlasDirty = true, -- (re)render the atlas in the next draw
	noiseCell = 256, -- noise copy size: the mip level the original noise sampling used
	viewDirty = true, -- set the viewSize uniform in the next draw (after creation / ViewResize)
	-- 0.5.005 rates (seconds): slow tick (gl4.tick), fast tick (gl4.fastTick = the bars timer of drawResBars),
	-- resource read inside the slow tick, BP percentage text, options check, BP tooltip re-send while not hovered
	SLOW_TICK = 0.1, FAST_TICK = 0.05, READ_INTERVAL = 0.25, PCT_INTERVAL = 0.5, OPTIONS_INTERVAL = 1,
	TOOLTIP_IDLE_INTERVAL = 1,
	-- current value text (gl4.valueText): while the bar is not hovered, integers in [VALUE_STEP_MIN, VALUE_STEP_MAX)
	-- are shown in steps of VALUE_STEP (exact below VALUE_STEP_MIN and while hovering); VALUE_STEP = 1: always exact
	VALUE_STEP = 5, VALUE_STEP_MIN = 100, VALUE_STEP_MAX = 1000,
	VT_FMT = { "%d", "%dk", "%dm" }, -- same output as short(n) (0 decimals)
	vt = { metal = { kind = -1, key = 0 }, energy = { kind = -1, key = 0 } }, -- shown value text (kind, number)
	-- blink modes (instance field 18 = fillp.y of the flash instances / the commander icon; the vertex shader
	-- turns them into the pulsing alpha, see blinkFactor)
	BLINK_NONE = 0, BLINK_OVERFLOW = 1, BLINK_ALLY = 2, BLINK_LOW = 3, BLINK_STALL = 4, BLINK_COM = 5,
	ts = { lastTick = -1, nextTick = 0, lastGameFrame = -1, lastHover = -1, nextRead = 0, nextOptions = 0,
		wasRunning = true, fastDirty = true, hoverApplied = false, dragX = false, dragY = 0 },
	lastWindNum = false,
	TEX_NONE = 0, TEX_FLOW = 1, TEX_NOISE = 2, TEX_GLOWCENTER = 3, TEX_GLOWEDGE = 4, TEX_GLOWEDGE_FLIP = 5,
	TEX_UIBG = 6, TEX_UI = 7, TEX_BLADES = 8, TEX_WAVES = 9, TEX_GLYPH = 10,
	FILL_NONE = 0, FILL_WIDTH = 1, FILL_OFFSET = 2,
	-- bars in draw order; instances of a bar are contiguous, in the draw order of the original lists
	-- (draw order of the light file: metal, energy, BP; the layout order is metal, BP, energy)
	RES = { "metal", "energy", "BP" },
	-- instance groups in draw order (0.5.003): the non-bar groups first, then the bars. gl4.init creates the
	-- instances of every group listed here (gl4.range[group] = { first, count }); append a group by adding
	-- it here and to ELEMENTS before gl4.init runs
	GROUPS = { "bg", "wind", "tidal", "ui", "metal", "energy", "BP" },
	ELEMENTS = {
		bg = { "blit" }, -- uiBgTex
		wind = { "blades" },
		tidal = { "waves" },
		ui = { "blit" }, -- uiTex
		metal = { "flashIn", "flashOut", "fill", "border", "glowMid", "glowLeft", "glowRight", "noise",
			"share1", "share2", "share3", "share4" },
		energy = { "flashIn", "flashOut", "fill", "border", "glowMid", "glowLeft", "glowRight", "flow", "flowGlow",
			"conv1", "conv2", "conv3", "conv4", "share1", "share2", "share3", "share4" },
		-- BP: stall flash, used fill + border + glow, additive reserved overlay, then the markers
		-- (metal supported BP, wind range strip, energy supported BP) in the order of the old list [2]
		BP = { "flashIn", "flashOut", "fill", "border", "glowMid", "glowLeft", "glowRight", "reserved",
			"indM", "indW", "indE" },
	},
	-- value group: instances whose geometry follows the fill width (written by gl4.setFill)
	FILL_ELEMENTS = {
		metal = { "fill", "border", "glowMid", "glowLeft", "glowRight", "noise" },
		energy = { "fill", "border", "glowMid", "glowLeft", "glowRight", "flow", "flowGlow" },
		BP = { "fill", "border", "glowMid", "glowLeft", "glowRight" }, -- "reserved" has its own width
	},
	BAR_COLORS = {
		metal = { { 0.51, 0.51, 0.5, 1 }, { 0.95, 0.95, 0.95, 1 } },
		energy = { { 0.5, 0.45, 0, 1 }, { 0.8, 0.75, 0, 1 } },
		BP = { BPS.colors.bar1, BPS.colors.bar2 },
	},
	KNOB_COLORS = { conv = { 0.95, 0.95, 0.7, 1 }, share = { 0.85, 0, 0, 1 } },
	K = {},          -- K[res][element] = instance key
	templates = {},  -- key -> 28 float Lua mirror
	order = {},      -- keys in draw order
	dirty = {},      -- keys changed since the last flush
	range = {},      -- range[res] = { first (0 based), count }
	flashReady = {}, -- replaces the existence check of dlist.resbar[res][4]
	total = 0,
}

do
	local IVT = (type(gl.InstanceVBOTable) == "table") and gl.InstanceVBOTable or nil
	local pushElementInstance = IVT and IVT.pushElementInstance
	local uploadAllElements = IVT and IVT.uploadAllElements

	local instanceLayout = {
		{ id = 1, name = "rect", size = 4 },
		{ id = 2, name = "color1", size = 4 },
		{ id = 3, name = "color2", size = 4 },
		{ id = 4, name = "shape", size = 4 },
		{ id = 5, name = "fillp", size = 4 },
		{ id = 6, name = "texp", size = 4 },
		{ id = 7, name = "skew", size = 4 },
	}

	local shaderSourceCache = {
		vsSrc = [=[
#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require

//__ENGINEUNIFORMBUFFERDEFS__

layout (location = 0) in vec4 position_xy_uv; // unit quad 0..1
layout (location = 1) in vec4 rect;
layout (location = 2) in vec4 color1;
layout (location = 3) in vec4 color2;
layout (location = 4) in vec4 shape;
layout (location = 5) in vec4 fillp;
layout (location = 6) in vec4 texp;
layout (location = 7) in vec4 skew;

uniform vec2 viewSize;

// 0.5.005 blink (Lua writes a mode into fillp.y of the flash instances / the commander icon, only on change):
// the 0.5.004 Lua curve blinkProgress (+0.3 per 1/30 s step up to 1, then -(1/30) / (1.5 p) per step down to 0,
// 28 steps = 0.9333 s per cycle) in closed form, t = timeInfo.y (draw seconds):
//   u = mod(t, 28/30); p = min(1, 9u) for u < 4/30, else sqrt(max(0, 1 - (u - 4/30) / 0.78))
const float BLINK_PERIOD = 28.0 / 30.0;
const float BLINK_RISE = 4.0 / 30.0;
const float BLINK_DECAY = 0.78;
const vec4 COM_ALERT_TINT = vec4(1.0, 0.6, 0.0, 0.45); // commander icon tint while blinking (game frame % 12 < 6)

float blinkCurve(float t) {
	float u = mod(t, BLINK_PERIOD);
	if (u < BLINK_RISE) {
		return min(1.0, 9.0 * u);
	}
	return sqrt(max(0.0, 1.0 - (u - BLINK_RISE) / BLINK_DECAY));
}

// 1 overflow: 0.6 + 0.4 p; 2 ally team overflow, 4 BP stall: p; 3 low resource: steady
float blinkFactor(int mode, float t) {
	if (mode == 3) {
		return 1.0;
	}
	float p = blinkCurve(t);
	return (mode == 1) ? (0.6 + 0.4 * p) : p;
}

out vec2 v_local;
flat out vec2 v_size;
flat out vec4 v_cornersX; // bl, br, tr, tl x positions (local px)
flat out vec4 v_color1;
flat out vec4 v_color2;
flat out vec4 v_shape;
flat out vec4 v_tex;
flat out vec4 v_fill;

void main() {
	float x = rect.x;
	float w = rect.z;
	if (fillp.w > 0.5) {
		if (fillp.w < 1.5) {
			w = rect.z + fillp.x;  // width follows the fill
		} else {
			x = rect.x + fillp.x;  // position follows the fill end
		}
	}
	float h = rect.w;
	vec4 cx = vec4(skew.x, w + skew.y, w + skew.w, skew.z);
	float minX = min(cx.x, cx.w);
	float maxX = max(cx.y, cx.z);
	// x and y of the unit quad swapped: makeRectVBO's triangles are clockwise, swapped they are
	// counter-clockwise (front facing), so the draw does not depend on the face culling state
	vec2 q = position_xy_uv.yx;
	v_local = vec2(mix(minX, maxX, q.x), q.y * h);
	v_size = vec2(w, h);
	v_cornersX = cx;
	v_color1 = color1;
	v_color2 = color2;
	int texModeV = int(texp.x + 0.5);
	if (fillp.y > 0.5 && (texModeV == 0 || texModeV == 10)) {
		// blink mode (plain flash instances / commander icon glyph; other plain instances keep fillp.y = 0)
		int mode = int(fillp.y + 0.5);
		if (texModeV == 10) {
			if (mod(floor(timeInfo.x + 0.5), 12.0) < 6.0) {
				v_color1 = COM_ALERT_TINT; // timeInfo.x = game frame
			}
		} else {
			float b = blinkFactor(mode, timeInfo.y);
			v_color1.a *= b;
			v_color2.a *= b;
		}
	}
	v_shape = shape;
	v_tex = texp;
	v_fill = fillp;
	vec2 screenPos = vec2(x, rect.y) + v_local;
	if (int(texp.x + 0.5) == 9) {
		// tidal waves: vertical bob (was glTranslate(.., sin(now / pi) * tidalWaveAnimationHeight + ..)), draw time
		screenPos.y += sin(timeInfo.y / 3.14159265) * fillp.y;
	}
	gl_Position = vec4((screenPos / viewSize) * 2.0 - 1.0, 0.0, 1.0);
	if (shape.w < 0.5 || w <= 0.0 || h <= 0.0) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0); // hidden: outside the clip volume
	}
}
]=],
		fsSrc = [=[
#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require

//__ENGINEUNIFORMBUFFERDEFS__

uniform sampler2D atlasTex; // texture unit 0
uniform sampler2D uiBgTex; // texture unit 1
uniform sampler2D uiTex; // texture unit 2
uniform sampler2D glyphTex; // texture unit 5 (glyph atlas, gl4.text)

// texture atlas (gl4.buildAtlas): every source texture is stored as a 2x2 tiled copy of cell x cell px
// at its origin. Sampling the middle window of the copy at fract(uv) repeats the texture like GL_REPEAT,
// bilinear filtering included (all neighbours of a sample are inside the copy, no mipmaps).
const vec2 ATLAS_SIZE = vec2(1024.0, 512.0);
const vec2 FLOW_ORIGIN = vec2(0.0, 0.0);
const float FLOW_CELL = 128.0;
const vec2 NOISE_ORIGIN = vec2(256.0, 0.0);
const vec2 GLOWC_ORIGIN = vec2(768.0, 0.0);
const vec2 GLOWE_ORIGIN = vec2(832.0, 0.0);
const float GLOW_CELL = 32.0;
const vec2 WAVES_ORIGIN = vec2(0.0, 256.0); // single copies, nearest sampling
const vec2 BLADES_ORIGIN = vec2(768.0, 256.0);
const float ICON_CELL = 256.0;

vec4 atlasTexture(vec2 uv, vec2 origin, float cell) {
	return texture(atlasTex, (origin + cell * (0.5 + fract(uv - 0.5))) / ATLAS_SIZE);
}

// nearest filtering (':n:' textures): the texel center of the texel GL_NEAREST would pick
vec4 atlasNearest(vec2 uv, vec2 origin, float cell) {
	vec2 texel = min(floor(uv * cell), vec2(cell - 1.0));
	return texture(atlasTex, (origin + texel + 0.5) / ATLAS_SIZE);
}

in vec2 v_local;
flat in vec2 v_size;
flat in vec4 v_cornersX;
flat in vec4 v_color1;
flat in vec4 v_color2;
flat in vec4 v_shape;
flat in vec4 v_tex;
flat in vec4 v_fill;

out vec4 fragColor;

vec2 safeNormalize(vec2 v) {
	float l = length(v);
	return (l > 0.0001) ? v / l : vec2(0.0, 1.0);
}

// signed inside distance to edge a->b of a CCW polygon
float edgeDist(vec2 p, vec2 a, vec2 b) {
	vec2 d = safeNormalize(b - a);
	return dot(p - a, vec2(-d.y, d.x));
}

// FlowUI RectRoundQuad chamfer: cut points at cs along both edges of corner c
float chamferDist(vec2 p, vec2 c, vec2 nextC, vec2 prevC, float cs) {
	vec2 e1 = safeNormalize(nextC - c);
	vec2 e2 = safeNormalize(prevC - c);
	vec2 n = safeNormalize(e1 + e2);
	return dot(p - c, n) - cs * dot(e1, n);
}

void main() {
	vec2 p = v_local;
	vec2 s = v_size;
	vec2 bl = vec2(v_cornersX.x, 0.0);
	vec2 br = vec2(v_cornersX.y, 0.0);
	vec2 tr = vec2(v_cornersX.z, s.y);
	vec2 tl = vec2(v_cornersX.w, s.y);

	float d = min(min(edgeDist(p, bl, br), edgeDist(p, br, tr)), min(edgeDist(p, tr, tl), edgeDist(p, tl, bl)));
	float cs = v_shape.x;
	if (cs > 0.0) {
		int mask = int(v_shape.y + 0.5);
		if ((mask & 1) != 0) { d = min(d, chamferDist(p, tl, bl, tr, cs)); }
		if ((mask & 2) != 0) { d = min(d, chamferDist(p, tr, tl, br, cs)); }
		if ((mask & 4) != 0) { d = min(d, chamferDist(p, br, tr, bl, cs)); }
		if ((mask & 8) != 0) { d = min(d, chamferDist(p, bl, br, tl, cs)); }
	}
	int texMode = int(v_tex.x + 0.5);
	// blits, blades and waves replace plain textured quads: hard edges, no anti-aliasing
	float coverage = (texMode >= 6) ? step(0.0, d) : clamp(d + 0.5, 0.0, 1.0);
	if (coverage <= 0.0) {
		discard;
	}

	vec4 col;
	float outlineW = v_shape.z;
	if (outlineW > 0.0) {
		// RectRoundOutline: color1 at the outer edge -> color2 at outlineW inside
		if (d > outlineW) {
			discard;
		}
		col = mix(v_color1, v_color2, clamp(d / outlineW, 0.0, 1.0));
	} else {
		// RectRound / RectRoundQuad: color1 bottom -> color2 top
		col = mix(v_color1, v_color2, clamp(p.y / max(s.y, 0.0001), 0.0, 1.0));
	}

	vec3 pm; // premultiplied rgb
	float alpha;
	if (texMode == 10) {
		// text glyph (gl4.text): color2 = atlas uv rect, color1 = tint; the atlas is premultiplied
		vec2 gn = clamp(p / max(s, vec2(0.0001)), 0.0, 1.0);
		vec4 t = texture(glyphTex, mix(v_color2.xy, v_color2.zw, gn));
		pm = t.rgb * v_color1.rgb * v_color1.a;
		alpha = t.a * v_color1.a;
		coverage = 1.0;
	} else if (texMode == 0) {
		pm = col.rgb * col.a;
		alpha = col.a;
	} else if (texMode == 1) {
		// energy flow: the three scrolling TexturedRectRound layers (texture matrix offsets -t/80, t/70, -t/55)
		// time = timeInfo.y (drawSeconds) of the engine uniform buffer; offsets wrapped (same result, keeps precision)
		vec2 base = vec2(p.x, s.y - p.y);
		float tile = max(v_tex.y, 1.0);
		float time = timeInfo.y;
		vec4 t1 = atlasTexture(base / (tile / 0.5) + vec2(fract(-time / 80.0)), FLOW_ORIGIN, FLOW_CELL);
		vec4 t2 = atlasTexture(base / (tile / 0.33) + vec2(fract(time / 70.0)), FLOW_ORIGIN, FLOW_CELL);
		vec4 t3 = atlasTexture(base / (tile / 0.45) + vec2(fract(-time / 55.0)), FLOW_ORIGIN, FLOW_CELL);
		pm = col.rgb * col.a * (t1.rgb * t1.a + t2.rgb * t2.a + t3.rgb * t3.a);
		alpha = col.a * clamp(t1.a + t2.a + t3.a, 0.0, 1.0);
	} else if (texMode == 2) {
		// noise: TexturedRectRound(size = tile, offset = 0)
		vec4 t = atlasTexture(vec2(p.x, s.y - p.y) / max(v_tex.y, 1.0), NOISE_ORIGIN, (v_tex.w > 0.5) ? v_tex.w : 256.0);
		pm = col.rgb * t.rgb * col.a * t.a;
		alpha = col.a * t.a;
	} else if (texMode == 6 || texMode == 7) {
		// uiBgTex / uiTex blit: premultiplied texture as is (was gl.TexRect(topbarArea, false, true),
		// blending ONE, ONE_MINUS_SRC_ALPHA, color 1): bottom left of the rect = texcoord (0, 0)
		vec2 uv = p / max(s, vec2(0.0001));
		vec4 t = (texMode == 6) ? texture(uiBgTex, uv) : texture(uiTex, uv);
		pm = t.rgb * col.a;
		alpha = t.a * col.a;
	} else if (texMode == 8 || texMode == 9) {
		// wind blades (rotated about the center of the rect) / tidal waves (the vertex shader moved them)
		vec2 uv;
		if (texMode == 8) {
			float hs = s.x * 0.35355339; // half side of the square: the rect is its bounding box (side * sqrt 2)
			float T = (timeInfo.x + timeInfo.w) / 30.0; // game seconds
			float ang = radians(v_fill.y + v_fill.z * (T - v_tex.w));
			float ca = cos(ang);
			float sa = sin(ang);
			vec2 q = p - s * 0.5;
			// inverse of glRotate(angle, 0, 0, 1)
			uv = vec2(ca * q.x + sa * q.y, -sa * q.x + ca * q.y) / (hs + hs) + 0.5;
		} else {
			uv = p / max(s, vec2(0.0001));
		}
		if (uv.x < 0.0 || uv.y < 0.0 || uv.x >= 1.0 || uv.y >= 1.0) {
			discard;
		}
		// gl.TexRect(-size, -size, size, size) default texcoords: t = 1 at the bottom
		vec2 tc = vec2(uv.x, 1.0 - uv.y);
		vec4 t = (texMode == 8) ? atlasNearest(tc, BLADES_ORIGIN, ICON_CELL) : atlasNearest(tc, WAVES_ORIGIN, ICON_CELL);
		pm = col.rgb * t.rgb * col.a * t.a;
		alpha = col.a * t.a;
	} else {
		// glow quads (DrawRect with the 0.008 texcoord inset)
		vec2 n = p / max(s, vec2(0.0001));
		float v = 0.992 - 0.984 * n.y;
		vec4 t;
		if (texMode == 3) {
			t = atlasTexture(vec2(0.008 + 0.984 * n.x, v), GLOWC_ORIGIN, GLOW_CELL);
		} else if (texMode == 4) {
			t = atlasTexture(vec2(0.008 + 0.984 * n.x, v), GLOWE_ORIGIN, GLOW_CELL);
		} else {
			t = atlasTexture(vec2(0.992 - 0.984 * n.x, v), GLOWE_ORIGIN, GLOW_CELL);
		}
		pm = col.rgb * t.rgb * col.a * t.a;
		alpha = col.a * t.a;
	}

	pm *= coverage;
	alpha *= coverage;
	if (alpha <= 0.0 && (pm.r + pm.g + pm.b) <= 0.0) {
		discard;
	}
	// additive layers (SRC_ALPHA, ONE) keep the destination: alpha 0 with blend ONE, ONE_MINUS_SRC_ALPHA
	fragColor = vec4(pm, (v_tex.z > 0.5) ? 0.0 : alpha);
}
]=],
		forceupdate = true, -- inline sources: without this CheckShaderUpdates sees "no change" and returns nil
		shaderName = "Top Bar Resbars GL4",
		uniformInt = {
			atlasTex = 0,
			uiBgTex = 1, -- gl4.TEXUNIT_UIBG
			uiTex = 2, -- gl4.TEXUNIT_UI
			glyphTex = 5, -- gl4.TEXUNIT_GLYPH
		},
		uniformFloat = {
			viewSize = { 1920, 1080 }, -- replaced by the view size before the shader is created
		},
		shaderConfig = {},
	}

	-- instance keys, built once
	for i = 1, #gl4.GROUPS do
		local res = gl4.GROUPS[i]
		local k = {}
		local elements = gl4.ELEMENTS[res]
		for j = 1, #elements do
			k[elements[j]] = res .. "_" .. elements[j]
		end
		gl4.K[res] = k
	end

	local function newTemplate()
		local t = {}
		for i = 1, gl4.STEP do
			t[i] = 0
		end
		return t
	end

	-- write one float of an instance; marks it dirty only when the value changed
	local function setInst(key, i, v)
		local t = gl4.templates[key]
		if t and t[i] ~= v then
			t[i] = v
			gl4.dirty[key] = true
		end
	end
	gl4.setInst = setInst

	function gl4.setRect(key, x, y, w, h)
		setInst(key, 1, x)
		setInst(key, 2, y)
		setInst(key, 3, w)
		setInst(key, 4, h)
	end

	function gl4.setColors(key, c1, c2)
		c2 = c2 or c1
		setInst(key, 5, c1[1])
		setInst(key, 6, c1[2])
		setInst(key, 7, c1[3])
		setInst(key, 8, c1[4])
		setInst(key, 9, c2[1])
		setInst(key, 10, c2[2])
		setInst(key, 11, c2[3])
		setInst(key, 12, c2[4])
	end

	function gl4.setColor(key, cr, cg, cb, ca)
		setInst(key, 5, cr)
		setInst(key, 6, cg)
		setInst(key, 7, cb)
		setInst(key, 8, ca)
		setInst(key, 9, cr)
		setInst(key, 10, cg)
		setInst(key, 11, cb)
		setInst(key, 12, ca)
	end

	-- chamfer, corner mask, outline width
	function gl4.setShape(key, cs, mask, outline)
		setInst(key, 13, cs)
		setInst(key, 14, mask)
		setInst(key, 15, outline or 0)
	end

	function gl4.setVisible(key, visible)
		setInst(key, 16, visible and 1 or 0)
	end

	function gl4.setFillMode(key, mode)
		setInst(key, 20, mode)
	end

	function gl4.setTex(key, mode, tile, additive)
		setInst(key, 21, mode)
		setInst(key, 22, tile or 0)
		setInst(key, 23, additive and 1 or 0)
	end

	function gl4.setSkew(key, blx, brx, tlx, trx)
		setInst(key, 25, blx or 0)
		setInst(key, 26, brx or 0)
		setInst(key, 27, tlx or 0)
		setInst(key, 28, trx or 0)
	end

	-- push changed instances into the VBO table (in place) and upload them once before drawing. 0.5.005: only
	-- the instance range from the first to the last changed bar instance is uploaded (was the whole VBO);
	-- returns true if a full upload was done (only when the instance table asks for one, e.g. after a resize)
	function gl4.flush()
		local vbo = gl4.vbo
		local templates = gl4.templates
		local full = vbo.dirty
		local index = vbo.instanceIDtoIndex
		local lo, hi = 1e9, -1
		for key in pairs(gl4.dirty) do
			pushElementInstance(vbo, templates[key], key, true, true)
			local i = index[key] - 1
			if i < lo then
				lo = i
			end
			if i > hi then
				hi = i
			end
			gl4.dirty[key] = nil
		end
		if full then
			uploadAllElements(vbo)
			return true
		end
		if hi >= 0 then
			vbo.instanceVBO:Upload(vbo.instanceData, nil, lo, lo * gl4.STEP + 1, (hi + 1) * gl4.STEP)
		end
		vbo.dirty = false
		return false
	end

	-- returns true or false, reason
	function gl4.init()
		local LuaShader = (type(gl.LuaShader) == "table") and gl.LuaShader or nil
		if not (IVT and LuaShader and gl.GetVBO and gl.GetVAO and gl.CreateShader) then
			return false, "gl.InstanceVBOTable, gl.LuaShader or GL4 VBO/VAO/shader support is not available"
		end
		if not (IVT.makeInstanceVBOTable and IVT.makeVAOandAttach and IVT.makeRectVBO and pushElementInstance and uploadAllElements and LuaShader.CheckShaderUpdates) then
			return false, "gl.InstanceVBOTable or gl.LuaShader is missing functions this widget needs"
		end

		if not (gl.CreateTexture and gl.DeleteTexture and r2tHelper and r2tHelper.RenderToTexture) then
			return false, "gl.CreateTexture or gl.R2tHelper is not available"
		end

		-- initial uniform values are set when the program is linked; viewSize is re-set only after ViewResize
		shaderSourceCache.uniformFloat.viewSize = { vsx, vsy }
		gl4.shader = LuaShader.CheckShaderUpdates(shaderSourceCache)
		if not gl4.shader then
			return false, "the resource bar shader failed to compile (see the shader log above)"
		end

		local quadVBO, numVertices = IVT.makeRectVBO(0, 0, 1, 1, 0, 0, 1, 1, "topbarGL4QuadVBO")
		if not quadVBO then
			return false, "could not create the quad VBO"
		end
		gl4.quad = quadVBO
		gl4.numVertices = numVertices or 6

		local vbo = IVT.makeInstanceVBOTable(instanceLayout, 64 + gl4.text.total, "topbarGL4ResbarVBO")
		if not vbo then
			return false, "could not create the instance VBO"
		end
		gl4.vbo = vbo
		vbo.numVertices = gl4.numVertices
		vbo.primitiveType = GL.TRIANGLES

		local vao = IVT.makeVAOandAttach(quadVBO, vbo.instanceVBO)
		if not vao then
			return false, "could not create the VAO"
		end
		if IVT.fillVAOSlots then
			vao = IVT.fillVAOSlots(vao, false, true) or vao
		end
		vbo.VAO = vao
		vbo.vertexVBO = quadVBO -- so a resize of the instance table can rebuild the VAO

		-- create every instance once, hidden, in draw order; afterwards only fields change
		for i = 1, #gl4.GROUPS do
			local res = gl4.GROUPS[i]
			if not gl4.K[res] then -- a group appended after the keys were built
				local k = {}
				for j = 1, #gl4.ELEMENTS[res] do
					k[gl4.ELEMENTS[res][j]] = res .. "_" .. gl4.ELEMENTS[res][j]
				end
				gl4.K[res] = k
			end
			local elements = gl4.ELEMENTS[res]
			gl4.range[res] = { #gl4.order, #elements }
			for j = 1, #elements do
				local key = gl4.K[res][elements[j]]
				gl4.templates[key] = newTemplate()
				gl4.order[#gl4.order + 1] = key
				pushElementInstance(vbo, gl4.templates[key], key, true, true)
			end
		end
		gl4.total = #gl4.order
		gl4.text.attach(vbo) -- glyph slots -> instance offsets of the text group, glyph texMode
		uploadAllElements(vbo)

		-- texture atlas: filled by gl4.buildAtlas in the first draw (render to texture needs a draw call-in)
		gl4.atlas = gl.CreateTexture(gl4.ATLAS_W, gl4.ATLAS_H, {
			target = GL.TEXTURE_2D,
			format = GL.RGBA8,
			fbo = true,
			min_filter = GL.LINEAR,
			mag_filter = GL.LINEAR,
			wrap_s = GL.CLAMP_TO_EDGE,
			wrap_t = GL.CLAMP_TO_EDGE,
		})
		if not gl4.atlas then
			return false, "could not create the texture atlas"
		end
		gl4.atlasDirty = true
		gl4.viewDirty = true
		return true
	end

	-- copies the four source textures into the atlas, each as 2x2 tiles of cell x cell px with the source's
	-- (0,0) at the tile's bottom left (texcoords 0..1 as the shader samples them); blending off = exact RGBA
	local function renderAtlas()
		glTranslate(-1, -1, 0)
		glScale(2 / gl4.ATLAS_W, 2 / gl4.ATLAS_H, 0)
		glBlending(false)
		glColor(1, 1, 1, 1)
		local cells = gl4.ATLAS
		for i = 1, #cells do
			local c = cells[i]
			local n = c.cell or gl4.noiseCell
			local last = (c.copies or 2) - 1
			glTexture(textures[c.tex])
			for a = 0, last do
				for b = 0, last do
					local x, y = c.x + a * n, c.y + b * n
					glTexRect(x, y, x + n, y + n, 0, 0, 1, 1)
				end
			end
		end
		glTexture(false)
		glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	end

	-- (re)fills the atlas: at the first draw and when the noise mip level changed (gl4.layoutBar)
	function gl4.buildAtlas()
		gl4.atlasDirty = false
		r2tHelper.RenderToTexture(gl4.atlas, renderAtlas, true)
	end

	function gl4.shutdown()
		if gl4.text then
			gl4.text.shutdown()
		end
		if gl4.atlas then
			gl.DeleteTexture(gl4.atlas)
			gl4.atlas = nil
		end
		if gl4.shader then
			gl4.shader:Finalize()
			gl4.shader = nil
		end
		local vbo = gl4.vbo
		if vbo then
			if WG and WG.VBOTableRegistry and vbo.myName then
				WG.VBOTableRegistry[vbo.myName] = nil
			end
			if vbo.Delete then
				vbo:Delete()
			else
				if vbo.instanceVBO then
					vbo.instanceVBO:Delete()
				end
				if vbo.VAO then
					vbo.VAO:Delete()
				end
			end
			gl4.vbo = nil
		end
		if gl4.quad then
			gl4.quad:Delete()
			gl4.quad = nil
		end
	end
end

-- Flash / tint rects (were dlist.resbar[res][4]: two RectRoundQuad, corners br+bl, skewed like the panel).
-- Called where the list used to be built; color and blink mode are written by gl4.setFlash (slow tick, on change).
function gl4.layoutFlash(res)
	local k = gl4.K[res]
	local area = resbarArea[res]
	local H = area[4] - area[2]
	local blx, brx = 0, 0
	if cfg.useSkew then
		if res == "metal" then
			blx = H * skewTan
		elseif res == "energy" then
			brx = -(H * skewTan)
		end -- BP: plain rectangle (the metal/energy edges next to it are vertical)
	end
	local key = k.flashIn
	gl4.setRect(key, area[1] + bgpadding, area[2] + bgpadding, (area[3] - bgpadding) - (area[1] + bgpadding), area[4] - (area[2] + bgpadding))
	gl4.setShape(key, mathMax(bgpadding * 1.25, 1), 12, 0)
	gl4.setSkew(key, blx, brx, 0, 0)
	gl4.setTex(key, gl4.TEX_NONE, 0, true)
	key = k.flashOut
	gl4.setRect(key, area[1], area[2], area[3] - area[1], H)
	gl4.setShape(key, mathMax(5.5 * widgetScale, 1), 12, 0)
	gl4.setSkew(key, blx, brx, 0, 0)
	gl4.setTex(key, gl4.TEX_NONE, 0, true)
	gl4.flashReady[res] = true
end

-- flash color (additive) and blink mode (0.5.005: fa = alpha at full pulse, the shader pulses it); fa == nil hides it
function gl4.setFlash(res, fr, fg, fb, fa, mode)
	local k = gl4.K[res]
	local visible = fa ~= nil and fa > 0
	if visible then
		gl4.setColor(k.flashIn, fr, fg, fb, fa)
		gl4.setColor(k.flashOut, fr, fg, fb, fa)
		gl4.setInst(k.flashIn, 18, mode or gl4.BLINK_NONE)
		gl4.setInst(k.flashOut, 18, mode or gl4.BLINK_NONE)
	end
	gl4.setVisible(k.flashIn, visible)
	gl4.setVisible(k.flashOut, visible)
end

-- Static part of the value group (was the geometry of dlist.resValuesBar[res] / dlist.energyGlow).
-- Called from updateResbar every time the bar layout is (re)computed; unchanged fields are not re-uploaded.
function gl4.layoutBar(res)
	local info = resbarDrawinfo[res]
	local ba = info.barArea
	local k = gl4.K[res]
	local barHeight = ba[4] - ba[2]
	local barWidth = ba[3] - ba[1]
	local barSize = barHeight * 0.2
	local glowSize = barHeight * 7
	local x = ba[1]
	local key

	-- value bar: RectRound(x, y, x + valueWidth, y2, barSize, 1,1,1,1, color1, color2)
	key = k.fill
	gl4.setRect(key, x, ba[2], 0, barHeight)
	gl4.setShape(key, mathMax(barSize, 1), 15, 0)
	gl4.setColors(key, gl4.BAR_COLORS[res][1], gl4.BAR_COLORS[res][2])
	gl4.setFillMode(key, gl4.FILL_WIDTH)
	gl4.setTex(key, gl4.TEX_NONE, 0, false)
	-- inner dark border: 1px inset on every side
	key = k.border
	gl4.setRect(key, x + 1, ba[2] + 1, -2, barHeight - 2)
	gl4.setShape(key, mathMax(barSize, 1), 15, 0)
	gl4.setColor(key, 0, 0, 0, 0.1)
	gl4.setInst(key, 12, 0.17) -- top alpha
	gl4.setFillMode(key, gl4.FILL_WIDTH)
	gl4.setTex(key, gl4.TEX_NONE, 0, false)
	-- glow (additive): center follows the fill, left edge static, right edge starts at the fill end
	key = k.glowMid
	gl4.setRect(key, x, ba[2] - glowSize, 0, barHeight + glowSize + glowSize)
	gl4.setShape(key, 0, 0, 0)
	gl4.setFillMode(key, gl4.FILL_WIDTH)
	gl4.setTex(key, gl4.TEX_GLOWCENTER, 0, true)
	key = k.glowLeft
	gl4.setRect(key, x - (glowSize * 2.5), ba[2] - glowSize, glowSize * 2.5, barHeight + glowSize + glowSize)
	gl4.setShape(key, 0, 0, 0)
	gl4.setFillMode(key, gl4.FILL_NONE)
	gl4.setTex(key, gl4.TEX_GLOWEDGE, 0, true)
	key = k.glowRight
	gl4.setRect(key, x, ba[2] - glowSize, glowSize * 3, barHeight + glowSize + glowSize)
	gl4.setShape(key, 0, 0, 0)
	gl4.setFillMode(key, gl4.FILL_OFFSET)
	gl4.setTex(key, gl4.TEX_GLOWEDGE_FLIP, 0, true)
	if k.noise then
		-- metal noise: TexturedRectRound(..., barSize, 1,1,1,1, barWidth * 0.33, 0), color 1,1,1,0.37 additive
		key = k.noise
		gl4.setRect(key, x, ba[2], 0, barHeight)
		gl4.setShape(key, barSize, 15, 0)
		gl4.setColor(key, 1, 1, 1, 0.37)
		gl4.setFillMode(key, gl4.FILL_WIDTH)
		gl4.setTex(key, gl4.TEX_NOISE, barWidth * 0.33, true)
		-- the original samples the (mipmapped) noise texture minified: store it in the atlas at the mip
		-- level GL would pick (nearest level for a tile of barWidth * 0.33 px) and tell the shader its size
		local cell = 256
		while cell > 8 and barWidth * 0.33 * 1.41421356 < cell do
			cell = cell * 0.5
		end
		if cell ~= gl4.noiseCell then
			gl4.noiseCell = cell
			gl4.atlasDirty = true
		end
		gl4.setInst(key, 24, cell)
	end
	if k.flow then
		-- energy flow: 3x TexturedRectRound(..., barSize, 0,0,1,1, barWidth / 0.5|0.33|0.45, 0), color 1,1,1,0.33 additive
		key = k.flow
		gl4.setRect(key, x, ba[2], 0, barHeight)
		gl4.setShape(key, barSize, 12, 0)
		gl4.setColor(key, 1, 1, 1, 0.33)
		gl4.setFillMode(key, gl4.FILL_WIDTH)
		gl4.setTex(key, gl4.TEX_FLOW, barWidth, true)
		-- colorize: RectRound(x - added, y - added, x + valueWidth + added, y2 + added, barHeight * 0.33), color 1,1,0,0.14 additive
		local addedSize = mathFloor((barHeight * 0.15) + 0.5)
		key = k.flowGlow
		gl4.setRect(key, x - addedSize, ba[2] - addedSize, addedSize + addedSize, barHeight + addedSize + addedSize)
		gl4.setShape(key, mathMax(barHeight * 0.33, 1), 15, 0)
		gl4.setColor(key, 1, 1, 0, 0.14)
		gl4.setFillMode(key, gl4.FILL_WIDTH)
		gl4.setTex(key, gl4.TEX_NONE, 0, true)
	end
	if k.reserved then
		-- BP reserved overlay: RectRound(x, y, x + used + reserved, y2, barSize, 1,1,1,1, reserved1, reserved2),
		-- drawn while additive blending was still active (as in the light file / 0.4.010)
		key = k.reserved
		gl4.setRect(key, x, ba[2], 0, barHeight)
		gl4.setShape(key, mathMax(barSize, 1), 15, 0)
		gl4.setColors(key, BPS.colors.reserved1, BPS.colors.reserved2)
		gl4.setFillMode(key, gl4.FILL_WIDTH)
		gl4.setTex(key, gl4.TEX_NONE, 0, true)
	end
end

-- BP marker (was one RectRound of dlist.resbar.BP[2]): px, py, sx, sy, cs, corner mask, colors; hidden when px is false
function gl4.setMarker(key, px, py, sx, sy, cs, mask, c1, c2)
	if not px or sx <= px or sy <= py then
		gl4.setVisible(key, false)
		return
	end
	gl4.setRect(key, px, py, sx - px, sy - py)
	gl4.setShape(key, mathMax(cs, 1), mask, 0)
	gl4.setColors(key, c1, c2)
	gl4.setTex(key, gl4.TEX_NONE, 0, false)
	gl4.setVisible(key, true)
end

-- Dynamic part of the value group (was the rebuild of dlist.resValuesBar[res] / dlist.energyGlow):
-- only the fill width and the glow alpha change.
function gl4.setFill(res, valueWidth, glowAlpha)
	local k = gl4.K[res]
	local elements = gl4.FILL_ELEMENTS[res]
	for i = 1, #elements do
		local key = k[elements[i]]
		gl4.setInst(key, 17, valueWidth)
		gl4.setVisible(key, true)
	end
	local bc = resbarDrawinfo[res].barColor
	gl4.setColor(k.glowMid, bc[1], bc[2], bc[3], glowAlpha)
	gl4.setColor(k.glowLeft, bc[1], bc[2], bc[3], glowAlpha)
	gl4.setColor(k.glowRight, bc[1], bc[2], bc[3], glowAlpha)
end

-- FlowUI SliderKnob(x, y, radius, color) = 4 instances: faint edge, dark outline, knob gradient, additive inner light edge
function gl4.setKnob(res, prefix, x, y, radius, visible)
	local k = gl4.K[res]
	local k1, k2, k3, k4 = k[prefix .. "1"], k[prefix .. "2"], k[prefix .. "3"], k[prefix .. "4"]
	if not k1 then
		return
	end
	if not visible then
		gl4.setVisible(k1, false)
		gl4.setVisible(k2, false)
		gl4.setVisible(k3, false)
		gl4.setVisible(k4, false)
		return
	end
	local color = gl4.KNOB_COLORS[prefix]
	local cs = mathMax(1.1, radius * 0.15)
	local edge1 = mathMax(1, mathFloor(radius * 0.05))
	gl4.setRect(k1, x - radius - edge1, y - radius - edge1, (radius + edge1) * 2, (radius + edge1) * 2)
	gl4.setShape(k1, mathMax(cs, 1), 15, 0)
	gl4.setColor(k1, 0, 0, 0, 0.12)
	gl4.setTex(k1, gl4.TEX_NONE, 0, false)
	local edge2 = mathMax(2, mathFloor(radius * 0.3))
	gl4.setRect(k2, x - radius - edge2, y - radius - edge2, (radius + edge2) * 2, (radius + edge2) * 2)
	gl4.setShape(k2, cs, 15, edge2)
	gl4.setColor(k2, 0, 0, 0, 0)
	gl4.setInst(k2, 12, 0.17) -- inner color alpha
	gl4.setTex(k2, gl4.TEX_NONE, 0, false)
	gl4.setRect(k3, x - radius, y - radius, radius * 2, radius * 2)
	gl4.setShape(k3, mathMax(cs, 1), 15, 0)
	gl4.setInst(k3, 5, color[1] * 0.55)
	gl4.setInst(k3, 6, color[2] * 0.55)
	gl4.setInst(k3, 7, color[3] * 0.55)
	gl4.setInst(k3, 8, color[4])
	gl4.setInst(k3, 9, color[1])
	gl4.setInst(k3, 10, color[2])
	gl4.setInst(k3, 11, color[3])
	gl4.setInst(k3, 12, color[4])
	gl4.setTex(k3, gl4.TEX_NONE, 0, false)
	gl4.setRect(k4, x - radius, y - radius, radius * 2, radius * 2)
	gl4.setShape(k4, cs, 15, mathMax(0.01, radius * 0.17))
	gl4.setColor(k4, 1, 1, 1, 0.22)
	gl4.setInst(k4, 12, 0) -- inner color alpha
	gl4.setTex(k4, gl4.TEX_NONE, 0, true)
	gl4.setVisible(k1, true)
	gl4.setVisible(k2, true)
	gl4.setVisible(k3, true)
	gl4.setVisible(k4, true)
end

-- one instanced draw of a contiguous instance range (shader must be active)
function gl4.drawRange(first, count)
	if count > 0 then
		gl4.vbo.VAO:DrawArrays(GL.TRIANGLES, gl4.numVertices, 0, count, first)
	end
end

-- unit 0 atlas, unit 1 uiBgTex, unit 2 uiTex (by id: they are recreated on refreshUi), unit 5 glyph atlas. gl.Texture(unit, false)
-- also disables GL_TEXTURE_2D on that unit for the fixed-function drawing after it (banner lists, other widgets)
function gl4.bindTextures(on)
	if on then
		glTexture(gl4.atlas)
		if uiBgTex then
			glTexture(gl4.TEXUNIT_UIBG, uiBgTex)
		end
		if uiTex then
			glTexture(gl4.TEXUNIT_UI, uiTex)
		end
		glTexture(gl4.TEXUNIT_GLYPH, gl4.text.tex or false)
	else
		glTexture(false)
		glTexture(gl4.TEXUNIT_UIBG, false)
		glTexture(gl4.TEXUNIT_UI, false)
		glTexture(gl4.TEXUNIT_GLYPH, false)
	end
end

-- is this group drawn this frame: bars with the conditions of the light file's drawResBars;
-- other groups always (their instances hide themselves via the visible flag)
function gl4.groupDrawn(res)
	if res == "BP" then
		return showResourceBars and BPS.on and dlist.resbar.BP[1] ~= nil
	elseif res == "metal" or res == "energy" then
		return showResourceBars and dlist.resbar[res][1] ~= nil
	end
	return true
end

-- Draws all groups (gl4.GROUPS): consecutive drawn groups are merged into one instanced draw call (normally
-- 1 call), a banner list (dlist.resbar[res][7], drawn after that bar's knobs/markers in the original) splits it.
function gl4.draw()
	if gl4.atlasDirty then
		gl4.buildAtlas()
	end
	local fullUpload = false
	if next(gl4.dirty) ~= nil or gl4.vbo.dirty then
		fullUpload = gl4.flush() -- changed bar instances only (everything only if the instance table asks)
	end
	gl4.text.upload(fullUpload) -- changed glyph instances only (nothing when flush uploaded everything)
	local RES = gl4.GROUPS

	-- per frame: bind, blending, activate, draw, deactivate, blending, unbind (no uniforms, no culling call:
	-- the quads are front facing, the time comes from the engine uniform buffer)
	gl4.bindTextures(true)
	glBlending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA)
	local shader = gl4.shader
	shader:Activate()
	if gl4.viewDirty then
		-- uniform values persist in the program object: only after creation / ViewResize
		gl4.viewDirty = false
		shader:SetUniform("viewSize", vsx, vsy)
		-- sampler units (also given as uniformInt at link time)
		shader:SetUniformInt("atlasTex", 0)
		shader:SetUniformInt("uiBgTex", gl4.TEXUNIT_UIBG)
		shader:SetUniformInt("uiTex", gl4.TEXUNIT_UI)
		shader:SetUniformInt("glyphTex", gl4.TEXUNIT_GLYPH)
	end
	local runFirst, runCount = 0, 0
	for i = 1, #RES do
		local res = RES[i]
		local range = gl4.range[res]
		if gl4.groupDrawn(res) then
			if runCount > 0 and runFirst + runCount == range[1] then
				runCount = runCount + range[2] -- contiguous: merge into the pending call
			else
				gl4.drawRange(runFirst, runCount)
				runFirst, runCount = range[1], range[2]
			end
			if showOverflowTooltip[res] and dlist.resbar[res] and dlist.resbar[res][7] then
				gl4.drawRange(runFirst, runCount)
				runCount = 0
				shader:Deactivate()
				-- gl.Texture(tex) also enables GL_TEXTURE_2D for fixed function:
				-- disable it around the fixed-function banner list
				gl4.bindTextures(false)
				glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
				glCallList(dlist.resbar[res][7]) -- overflow warning / BP alerts
				gl4.bindTextures(true)
				glBlending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA)
				shader:Activate()
			end
		end
	end
	gl4.drawRange(runFirst, runCount)
	shader:Deactivate()
	glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	gl4.bindTextures(false)
end

-- first frame runs under pcall: if the GL4 path fails on this engine / driver, say so and leave
function gl4.drawChecked()
	if gl4.verified then
		gl4.draw()
		return true
	end
	local ok, err = pcall(gl4.draw)
	if ok then
		gl4.verified = true
		return true
	end
	if gl4.shader then
		pcall(gl4.shader.Deactivate, gl4.shader)
	end
	pcall(gl4.bindTextures, false)
	glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	Spring.Echo(gl4.WIDGET_NAME .. ": GL4 drawing failed (" .. tostring(err) .. "). Removing this widget - please enable '" .. gl4.FALLBACK_NAME .. "' instead.")
	widgetHandler:RemoveWidget(widget)
	return false
end
--------------------------------------------------------------------------------


local function RectQuad(px, py, sx, sy, offset)
	gl.TexCoord(offset, 1 - offset)
	gl.Vertex(px, py, 0)
	gl.TexCoord(1 - offset, 1 - offset)
	gl.Vertex(sx, py, 0)
	gl.TexCoord(1 - offset, offset)
	gl.Vertex(sx, sy, 0)
	gl.TexCoord(offset, offset)
	gl.Vertex(px, sy, 0)
end

local function DrawRect(px, py, sx, sy, zoom)
	gl.BeginEnd(GL.QUADS, RectQuad, px, py, sx, sy, zoom)
end

function widget:ViewResize()
	vsx, vsy = gl.GetViewSizes()
	gl4.viewDirty = true -- the viewSize uniform is set in the next draw
	widgetScale = (vsy / height) * 0.0425 * ui_scale
	xPos = mathFloor(vsx * cfg.relXpos)

	widgetSpaceMargin = WG.FlowUI.elementMargin
	bgpadding = WG.FlowUI.elementPadding
	RectRound = WG.FlowUI.Draw.RectRound
	RectRoundOutline = WG.FlowUI.Draw.RectRoundOutline
	TexturedRectRound = WG.FlowUI.Draw.TexturedRectRound
	UiElement = WG.FlowUI.Draw.Element
	UiSliderKnob = WG.FlowUI.Draw.SliderKnob

	font2 = WG.fonts.getFont(2)

	for n, _ in pairs(dlist.windText) do
		dlist.windText[n] = glDeleteList(dlist.windText[n])
	end
	for res, _ in pairs(dlist.resValues) do
		dlist.resValues[res] = glDeleteList(dlist.resValues[res])
	end
	for res, _ in pairs(dlist.resValuesBar) do
		dlist.resValuesBar[res] = glDeleteList(dlist.resValuesBar[res])
	end

	-- Reset cache.lastValueWidth so display lists are recreated with new dimensions
	cache.lastValueWidth = { metal = -1, energy = -1, BP = -1 }

	init()
end

-- 0.5.002: no memo. The memo's key (n .. ":" .. f) was a new string on every call (the values are
-- floats that change all the time), which allocated more than it saved; string.format of an already
-- existing text returns the interned string without allocating.
local shortCache = {} -- [f] = format strings for that precision (built once)
local function short(n, f)
	f = f or 0
	local fmts = shortCache[f]
	if not fmts then
		fmts = { "%." .. f .. "fm", "%." .. f .. "fk", "%." .. f .. "f" }
		shortCache[f] = fmts
	end
	if n > 9999999 then
		return stringFormat(fmts[1], n / 1000000)
	elseif n > 9999 then
		return stringFormat(fmts[2], n / 1000)
	end
	return stringFormat(fmts[3], n)
end


--------------------------------------------------------------------------------
-- GL4 texts: glyph instances (no render-to-texture for texts after the atlas is built)
--------------------------------------------------------------------------------
-- Every dynamic text (current / storage / pull / income per bar, BP percentage, wind value,
-- min / max wind, tidal value, commander counter + its icon) is a fixed run of instances in the
-- same instance VBO, drawn by the same shader and draw call as the bars (texMode gl4.TEX_GLYPH):
-- instance group gl4.text.GROUP, registered in gl4.GROUPS right after "ui" (the texts were part of the
-- uiTex blit, so bar glow and slider knobs stay above them) and merged into the single draw.
--  * glyph atlas gl4.text.tex (unit gl4.TEXUNIT_GLYPH): rebuilt with font2:Print on refreshUi only
--    (init: ViewResize, LanguageChanged, GameStart, team change, ...). One row per text style
--    (font size + vertical option), every glyph of CHARS twice: "complete" (white fill + baked
--    outline, exactly what font:Print 'o' draws) and "fill" (no outline). The commander icon is
--    one more cell. The atlas is premultiplied (r2tHelper blending), instances tint it with color1;
--    the outline is black, so tint * atlas reproduces the base's colored text.
--  * text slot = 2 * N instances: N complete glyphs, then N fill glyphs (Recoil draws all outlines
--    of a string before its fills; the fill layer restores fills covered by the next glyph's outline)
--  * x layout like font:Print: start = x - align * W(text) * size, rounded (FONT_NEAREST), then per
--    glyph the measured advance step[a][b] = W(ab) - W(b) (kerning aware), each pen rounded to a pixel
--  * strings are written only when they change (0.5.005: current values from the 10 Hz slow tick, pull / income /
--    storage / wind at the resource read when their number changed, BP percentage at most 2 per second, coms on
--    count change; the commander icon blink is in the shader); writes go into the IVT Lua mirror and
--    only the touched instance range is uploaded before the next draw; nothing is allocated per write
-- glyph instance fields: rect = atlas cell on screen (px), color1 = tint, color2 = atlas uv (u0, v0, u1, v1),
-- shape.w = visible, texp.x = gl4.TEX_GLYPH (everything else 0)
--------------------------------------------------------------------------------
gl4.text = {
	GROUP = "text", -- instance group (gl4.GROUPS / gl4.ELEMENTS / gl4.range)
	AFTER_GROUP = "ui", -- inserted right after this group
	CHARS = "0123456789.-+%km", -- everything short(), string.format("%.1f"), tostring() and "%" produce
	ready = false,
	tex = nil,
	aw = 1,
	ah = 1,
	first = 0, -- first instance (0 based) of the text range in the VBO
	total = 0, -- instances of the text range
	lo = 1e9, -- dirty instance range (0 based, inclusive), uploaded by gl4.text.upload
	hi = -1,
	BAR_RES = { "metal", "energy" },
	-- slots in instance (= draw) order; n = max glyphs; pre / suf = extra leading / trailing byte
	SLOTS = {
		{ name = "comIcon", kind = "comIcon", icon = true, tint = { 1, 1, 1, 0.22 } },
		{ name = "metal_current", kind = "bar", res = "metal", field = "textCurrent", n = 6, tint = { 0.95, 0.95, 0.95, 1 } },
		{ name = "metal_storage", kind = "bar", res = "metal", field = "textStorage", n = 6, tint = { 0.55, 0.55, 0.55, 1 } },
		{ name = "metal_pull", kind = "bar", res = "metal", field = "textPull", n = 7, pre = 45, tint = { 240 / 255, 125 / 255, 125 / 255, 1 } },
		{ name = "metal_income", kind = "bar", res = "metal", field = "textIncome", n = 7, pre = 43, tint = { 120 / 255, 235 / 255, 120 / 255, 1 } },
		{ name = "energy_current", kind = "bar", res = "energy", field = "textCurrent", n = 6, tint = { 1, 1, 0.74, 1 } },
		{ name = "energy_storage", kind = "bar", res = "energy", field = "textStorage", n = 6, tint = { 0.57, 0.57, 0.45, 1 } },
		{ name = "energy_pull", kind = "bar", res = "energy", field = "textPull", n = 7, pre = 45, tint = { 240 / 255, 125 / 255, 125 / 255, 1 } },
		{ name = "energy_income", kind = "bar", res = "energy", field = "textIncome", n = 7, pre = 43, tint = { 120 / 255, 235 / 255, 120 / 255, 1 } },
		{ name = "BP_current", kind = "bar", res = "BP", field = "textCurrent", n = 4, suf = 37, tint = { 1, 1, 1, 1 } },
		{ name = "wind_current", kind = "windCur", n = 5, tint = { 1, 1, 1, 1 } },
		{ name = "wind_min", kind = "windMin", n = 6, tint = { 1, 1, 1, 1 } },
		{ name = "wind_max", kind = "windMax", n = 6, tint = { 1, 1, 1, 1 } },
		{ name = "tidal", kind = "tidal", n = 6, tint = { 1, 1, 1, 1 } },
		{ name = "com_enemy", kind = "comEnemy", n = 4, tint = { 1, 0, 0, 1 } },
		{ name = "com_ally", kind = "comAlly", n = 4, tint = { 0, 1, 0, 1 } },
	},
	byName = {},
	bar = {}, -- bar[res][field] = slot (metal / energy)
	gidx = {}, -- byte -> glyph index
	chars = {}, -- glyph index -> one character string
	NG = 0,
	step = {}, -- [(a - 1) * NG + b] = W(ab) - W(b) (font units)
	wl = {}, -- [a] = W(a) (width of a glyph that ends the text)
	styles = {},
	PCT = {}, -- 0..100 as strings (BP percentage without allocation)
	icon = { ok = false },
}

do
	local T = gl4.text
	local byte = string.byte
	local STEP = gl4.STEP

	for i = 1, #T.CHARS do
		local c = T.CHARS:sub(i, i)
		T.gidx[byte(c)] = i
		T.chars[i] = c
	end
	T.NG = #T.CHARS
	for i = 0, 100 do
		T.PCT[i] = tostring(i)
	end
	local total = 0
	for i = 1, #T.SLOTS do
		local sl = T.SLOTS[i]
		T.byName[sl.name] = sl
		if sl.kind == "bar" and sl.res ~= "BP" then
			T.bar[sl.res] = T.bar[sl.res] or {}
			T.bar[sl.res][sl.field] = sl
		end
		sl.rel = total
		sl.count = sl.icon and 1 or (2 * sl.n)
		total = total + sl.count
		sl.g, sl.gr, sl.gg, sl.gb = {}, {}, {}, {}
		for j = 1, (sl.n or 0) do -- preallocated: writes never grow a table
			sl.g[j], sl.gr[j], sl.gg[j], sl.gb[j] = 0, 0, 0, 0
		end
		sl.ok, sl.show, sl.warn = false, false, false
		if sl.tint then
			sl.base = { sl.tint[1], sl.tint[2], sl.tint[3], sl.tint[4] }
		end
	end
	T.total = total

	local function markDirty(first, count)
		if first < T.lo then
			T.lo = first
		end
		if first + count - 1 > T.hi then
			T.hi = first + count - 1
		end
	end

	-- the text group: one element per glyph instance, created (hidden) by gl4.init with the other groups
	do
		local groups = gl4.GROUPS
		local pos = #groups + 1
		for i = 1, #groups do
			if groups[i] == T.AFTER_GROUP then
				pos = i + 1
			end
		end
		table.insert(groups, pos, T.GROUP)
		local elements = {}
		for i = 1, T.total do
			elements[i] = "g" .. i
		end
		gl4.ELEMENTS[T.GROUP] = elements
	end

	-- called by gl4.init after it created the instances (before the upload): slot offsets, glyph texMode
	function T.attach(vbo)
		T.first = gl4.range[T.GROUP][1]
		for i = 1, #T.SLOTS do
			local sl = T.SLOTS[i]
			sl.first = T.first + sl.rel
		end
		local K = gl4.K[T.GROUP]
		local d = vbo.instanceData
		local elements = gl4.ELEMENTS[T.GROUP]
		for i = 1, T.total do
			local t = gl4.templates[K[elements[i]]]
			if t then
				t[21] = gl4.TEX_GLYPH
			end
			d[(T.first + i - 1) * STEP + 21] = gl4.TEX_GLYPH
		end
	end

	-- upload the touched text range (skipped when the bars just uploaded everything)
	function T.upload(fullUploadDone)
		if T.hi < 0 then
			return
		end
		if not fullUploadDone then
			local vbo = gl4.vbo
			vbo.instanceVBO:Upload(vbo.instanceData, nil, T.lo, T.lo * STEP + 1, (T.hi + 1) * STEP)
		end
		T.lo, T.hi = 1e9, -1
	end

	local function parseOpts(sl, opts)
		opts = opts or ""
		sl.align = opts:find("c", 1, true) and 0.5 or (opts:find("r", 1, true) and 1 or 0)
		sl.v = opts:gsub("[^atvxbd]", "")
		sl.outline = opts:find("o", 1, true) ~= nil
	end

	-- slot position / size / options, computed exactly like the base's font:Print calls
	function T.place(sl)
		local k = sl.kind
		sl.ok = false
		if k == "bar" then
			local info = resbarDrawinfo[sl.res] and resbarDrawinfo[sl.res][sl.field]
			if info and info[2] then
				sl.x, sl.y, sl.size = info[2], info[3], info[4]
				parseOpts(sl, info[5])
				sl.ok = true
			end
			return
		end
		local useSkew = cfg.useSkew
		if k == "windCur" or k == "windMin" or k == "windMax" then
			local area = windArea
			if not area[4] then
				return
			end
			local windH = area[4] - area[2]
			if k == "windCur" then
				local fs = windH / 2.3
				sl.x = area[1] + ((area[3] - area[1]) / 2.1) - (useSkew and windH * skewTan * 0.5 or 0)
				sl.y = area[2] + (windH / 1.85) - (fs / 5)
				sl.size = fs
				parseOpts(sl, "oc")
			elseif k == "windMin" then
				local smallFS = windH / 3.4
				local minBaseline = area[4] - smallFS + (1 * widgetScale)
				sl.x = area[3] - (useSkew and skewTan * (area[4] - minBaseline) or 0) - (4.5 * widgetScale)
				sl.y = minBaseline
				sl.size = smallFS
				parseOpts(sl, "or")
			else
				sl.x = area[3] - (useSkew and windH * skewTan or 0) - (1.2 * widgetScale)
				sl.y = area[2] + (4.5 * widgetScale)
				sl.size = windH / 3.4
				parseOpts(sl, "or")
			end
			sl.ok = true
		elseif k == "tidal" then
			local area = tidalarea
			if not area[4] then
				return
			end
			local h = area[4] - area[2]
			local fs = h / 2.3
			sl.x = area[1] + ((area[3] - area[1]) / 2) - (useSkew and h * skewTan * 0.5 or 0)
			sl.y = area[2] + (h / 2.05) - (fs / 5)
			sl.size = fs
			parseOpts(sl, "oc")
			sl.ok = true
		else -- commander counter
			local area = comsArea
			if not area[4] then
				return
			end
			local areaH = area[4] - area[2]
			local cx = area[1] + ((area[3] - area[1]) / 2) - (useSkew and areaH * skewTan * 0.5 or 0)
			if k == "comEnemy" then
				sl.x = area[3] - (useSkew and areaH * skewTan or 0) - (1.2 * widgetScale)
				sl.y = area[2] + (4.5 * widgetScale)
				sl.size = areaH / 2.5
				parseOpts(sl, "or")
			elseif k == "comAlly" then
				local fs = areaH / 1.9
				sl.x = cx
				sl.y = area[2] + (areaH / 1.77) - (fs / 5)
				sl.size = fs
				parseOpts(sl, "oc")
			else -- icon: glTexRect(cx - sizeHalf, y1, cx + sizeHalf, y1 + 2 * sizeHalf)
				local sizeHalf = areaH / 2.44
				local x1 = cx - sizeHalf
				local y1 = area[2] + (areaH / 2) - sizeHalf + ((area[3] - area[1]) * 0.025)
				sl.ix, sl.iy = mathFloor(x1), mathFloor(y1)
				sl.fx, sl.fy = x1 - sl.ix, y1 - sl.iy -- sub-pixel offset, baked into the atlas cell
				sl.isize = sizeHalf * 2
				sl.iw = mathCeil(sl.fx + sl.isize)
				sl.ih = mathCeil(sl.fy + sl.isize)
			end
			sl.ok = true
		end
	end

	-- conditions under which the base drew the text
	function T.visible(sl)
		local k = sl.kind
		if k == "bar" then
			if not showResourceBars then
				return false
			end
			if sl.res == "BP" then
				return BPS.on and BPS.pct >= 0
			end
			if sl.field == "textStorage" then
				return not showingWarning[sl.res]
			end
			return true
		end
		if not cache.showIndicators then
			return false
		end
		if k == "windCur" then
			return not noWind and gameFrame > 0
		elseif k == "windMin" or k == "windMax" then
			return not noWind
		elseif k == "tidal" then
			return displayTidalSpeed
		elseif k == "comIcon" then
			return displayComCounter and T.icon.ok
		end
		return displayComCounter and gameFrame > 0
	end

	-- write the instances of one slot from sl.str (no allocation)
	function T.write(sl)
		local vbo = gl4.vbo
		if not vbo or not sl.first then
			return
		end
		local d = vbo.instanceData
		if sl.icon then
			local o = sl.first * STEP
			if T.ready and sl.ok and sl.show then
				local ic = T.icon
				d[o + 1], d[o + 2], d[o + 3], d[o + 4] = sl.ix, sl.iy, sl.iw, sl.ih
				local t = sl.tint
				d[o + 5], d[o + 6], d[o + 7], d[o + 8] = t[1], t[2], t[3], t[4]
				d[o + 9], d[o + 10] = ic.x / T.aw, ic.y / T.ah
				d[o + 11], d[o + 12] = (ic.x + sl.iw) / T.aw, (ic.y + sl.ih) / T.ah
				d[o + 16] = 1
				-- 0.5.005: the alert blink (one ally commander left) is done by the shader from the game frame
				d[o + 18] = (allyComs == 1) and gl4.BLINK_COM or gl4.BLINK_NONE
			else
				d[o + 16] = 0
			end
			markDirty(sl.first, 1)
			return
		end
		local n = sl.n
		local g, gr, gg, gb = sl.g, sl.gr, sl.gg, sl.gb
		local cnt = 0
		local s = sl.str
		local tint = sl.tint
		local gi
		if T.ready and sl.ok and sl.show and s then
			local gidx = T.gidx
			local cr, cg, cb = tint[1], tint[2], tint[3]
			gi = sl.pre and gidx[sl.pre]
			if gi then
				cnt = 1
				g[1], gr[1], gg[1], gb[1] = gi, cr, cg, cb
			end
			local len = #s
			local i = 1
			while i <= len do
				local b = byte(s, i)
				if b == 255 and i + 3 <= len then -- inline color code \255rgb
					local r1, g1, b1 = byte(s, i + 1, i + 3)
					cr, cg, cb = r1 / 255, g1 / 255, b1 / 255
					i = i + 4
				else
					gi = gidx[b]
					if gi and cnt < n then
						cnt = cnt + 1
						g[cnt], gr[cnt], gg[cnt], gb[cnt] = gi, cr, cg, cb
					end
					i = i + 1
				end
			end
			gi = sl.suf and gidx[sl.suf]
			if gi and cnt < n then
				cnt = cnt + 1
				g[cnt], gr[cnt], gg[cnt], gb[cnt] = gi, cr, cg, cb
			end
		end
		local first = sl.first
		if cnt > 0 then
			local NG, step, wl = T.NG, T.step, T.wl
			local width = wl[g[cnt]]
			for i = 1, cnt - 1 do
				width = width + step[(g[i] - 1) * NG + g[i + 1]]
			end
			local st = sl.style
			local size = sl.size
			local aw, ah = T.aw, T.ah
			local start = mathFloor(sl.x - (width * size * sl.align) + 0.5)
			local y = mathFloor(sl.y + 0.5) - st.base
			local h = st.rowH
			local v0, v1 = st.rowY / ah, (st.rowY + h) / ah
			local a = tint[4]
			local pad = st.pad
			local cellX, cellW, fillOff = st.cellX, st.cellW, st.fillOff
			local full = sl.outline and 1 or 0
			local off = 0
			for i = 1, n do
				local o1 = (first + i - 1) * STEP
				local o2 = (first + n + i - 1) * STEP
				if i <= cnt then
					gi = g[i]
					local x = mathFloor(start + (off * size) + 0.5) - pad
					local w = cellW[gi]
					local u0 = cellX[gi]
					local r1, g1, b1 = gr[i], gg[i], gb[i]
					d[o1 + 1], d[o1 + 2], d[o1 + 3], d[o1 + 4] = x, y, w, h
					d[o1 + 5], d[o1 + 6], d[o1 + 7], d[o1 + 8] = r1, g1, b1, a
					d[o1 + 9], d[o1 + 10], d[o1 + 11], d[o1 + 12] = u0 / aw, v0, (u0 + w) / aw, v1
					d[o1 + 16] = full
					u0 = u0 + fillOff
					d[o2 + 1], d[o2 + 2], d[o2 + 3], d[o2 + 4] = x, y, w, h
					d[o2 + 5], d[o2 + 6], d[o2 + 7], d[o2 + 8] = r1, g1, b1, a
					d[o2 + 9], d[o2 + 10], d[o2 + 11], d[o2 + 12] = u0 / aw, v0, (u0 + w) / aw, v1
					d[o2 + 16] = 1
					if i < cnt then
						off = off + step[(gi - 1) * NG + g[i + 1]]
					end
				else
					d[o1 + 16] = 0
					d[o2 + 16] = 0
				end
			end
		else
			for i = 0, 2 * n - 1 do
				d[(first + i) * STEP + 16] = 0
			end
		end
		markDirty(first, 2 * n)
	end

	function T.refresh(sl)
		sl.show = T.visible(sl)
		T.write(sl)
	end

	function T.setStr(sl, s)
		sl.str = s
		T.refresh(sl)
	end

	-- was the text part of dlist.coms (updateComs)
	function T.comsChanged()
		T.setStr(T.byName.com_enemy, tostring(enemyComCount))
		T.setStr(T.byName.com_ally, tostring(allyComs))
		T.refresh(T.byName.comIcon)
	end

	-- r2t callback: draws every style row and the commander icon into the atlas
	function T.renderAtlas()
		glTranslate(-1, -1, 0)
		glScale(2 / T.aw, 2 / T.ah, 0)
		local styles = T.styles
		local chars = T.chars
		font2:Begin(true)
		font2:SetTextColor(1, 1, 1, 1)
		font2:SetOutlineColor(0, 0, 0, 1)
		for s = 1, #styles do
			local st = styles[s]
			local y = st.rowY + st.base
			for gi = 1, T.NG do
				local x = st.cellX[gi] + st.pad
				font2:Print(chars[gi], x, y, st.size, st.optFull)
				font2:Print(chars[gi], x + st.fillOff, y, st.size, st.optFill)
			end
		end
		font2:End()
		local ic = T.icon
		if ic.ok then
			local sl = T.byName.comIcon
			glColor(1, 1, 1, 1)
			glTexture(textures.com)
			glTexRect(ic.x + sl.fx, ic.y + sl.fy, ic.x + sl.fx + sl.isize, ic.y + sl.fy + sl.isize)
			glTexture(false)
		end
	end

	-- on refreshUi: layout, styles, font metrics, atlas packing and rendering, then every slot rewritten
	function T.rebuild()
		T.ready = false
		if not font2 or not gl4.vbo then
			return
		end
		local slots = T.SLOTS
		local styles, byKey = {}, {}
		for i = 1, #slots do
			local sl = slots[i]
			T.place(sl)
			if sl.ok and not sl.icon then
				local key = string.format("%.4f|%s", sl.size, sl.v)
				local st = byKey[key]
				if not st then
					st = { size = sl.size, v = sl.v, optFull = "o" .. sl.v, optFill = sl.v, cellX = {}, cellW = {} }
					byKey[key] = st
					styles[#styles + 1] = st
				end
				sl.style = st
			end
		end
		T.styles = styles

		-- font metrics (font units): W(a) and the kerning aware advance W(ab) - W(b)
		local NG, chars = T.NG, T.chars
		for a = 1, NG do
			T.wl[a] = font2:GetTextWidth(chars[a])
		end
		for a = 1, NG do
			for b = 1, NG do
				T.step[(a - 1) * NG + b] = font2:GetTextWidth(chars[a] .. chars[b]) - T.wl[b]
			end
		end

		-- packing: one row per style (complete glyphs, then fill glyphs), 1 px gaps
		local aw, y = 1, 0
		local ic = T.icon
		local iconSlot = T.byName.comIcon
		local texPath = string.lower(string.gsub(textures.com, ":.:", ""))
		ic.ok = displayComCounter and iconSlot.ok and VFS.FileExists(texPath) and true or false
		if ic.ok then
			ic.x, ic.y = 0, 0
			aw = iconSlot.iw + 1
			y = iconSlot.ih + 1
		end
		for s = 1, #styles do
			local st = styles[s]
			local size = st.size
			st.pad = mathCeil(size * 0.3) + 2
			st.base = st.pad + mathCeil(size * 0.5)
			st.rowH = mathCeil(size * 2) + st.pad * 2
			st.rowY = y
			local x = 0
			for gi = 1, NG do
				st.cellX[gi] = x
				st.cellW[gi] = mathCeil(T.wl[gi] * size) + st.pad * 2
				x = x + st.cellW[gi] + 1
			end
			st.fillOff = x
			aw = mathMax(aw, x * 2)
			y = y + st.rowH + 1
		end
		local ah = mathMax(1, y)
		if T.tex and (T.aw ~= aw or T.ah ~= ah) then
			gl.DeleteTexture(T.tex)
			T.tex = nil
		end
		T.aw, T.ah = aw, ah
		if not T.tex then
			T.tex = gl.CreateTexture(aw, ah, {
				target = GL.TEXTURE_2D,
				format = GL.RGBA8,
				fbo = true,
				min_filter = GL.LINEAR,
				mag_filter = GL.LINEAR,
				wrap_s = GL.CLAMP_TO_EDGE,
				wrap_t = GL.CLAMP_TO_EDGE,
			})
		end
		if not T.tex then
			return
		end
		r2tHelper.RenderToTexture(T.tex, T.renderAtlas, true)
		T.ready = true

		-- strings that do not come through updateRes (bar texts keep theirs; renderUi re-flags them)
		local by = T.byName
		by.wind_current.str = currentWindText
		by.wind_min.str = minWindText
		by.wind_max.str = maxWindText
		by.tidal.str = tidalSpeedText
		by.com_enemy.str = tostring(enemyComCount)
		by.com_ally.str = tostring(allyComs)
		for i = 1, #slots do
			local sl = slots[i]
			sl.warn = showingWarning[sl.res] == true
			T.refresh(sl)
		end
	end

	-- changed bar texts (0.5.005: called at the end of every slow tick and after a working fast tick; the
	-- strings were formatted where their numbers are checked: gl4.valueText, updateResbarText, BP percentage)
	function T.barTexts()
		for i = 1, 2 do
			local res = T.BAR_RES[i]
			local u = updateRes[res]
			local slots = T.bar[res]
			if u[1] then
				u[1] = false
				T.setStr(slots.textCurrent, cache.lastDrawnValue[res])
			end
			if u[2] then
				u[2] = false
				T.setStr(slots.textPull, cache.lastPullText[res])
			end
			if u[4] then
				u[4] = false
				T.setStr(slots.textIncome, cache.lastIncomeText[res])
			end
			if u[3] then
				u[3] = false
				T.setStr(slots.textStorage, cache.lastStorageText[res])
			end
		end
		if BPS.on and updateRes.BP[1] then
			updateRes.BP[1] = false
			local pct = BPS.pct
			cache.lastDrawnValue.BP = pct
			local sl = T.byName.BP_current
			if pct >= 0 then
				local colors = BPS.colors
				local col = (pct < 40 and colors.red) or (pct < 60 and colors.orange) or (pct < 80 and colors.yellow) or colors.green
				local t = sl.tint
				t[1], t[2], t[3], t[4] = col[1], col[2], col[3], 1
			end
			T.setStr(sl, T.PCT[pct])
		end
	end

	-- per frame (from drawResBars): atlas on refreshUi, bar texts after a working fast tick. 0.5.005: no
	-- per-frame checks any more (storage is re-flagged with the banner, the wind text is written by the
	-- resource read when it changed, the commander icon blinks in the shader)
	function T.frame(update)
		if refreshUi then
			T.rebuild()
		end
		if update and T.ready then
			T.barTexts()
		end
	end

	function T.shutdown()
		if T.tex then
			gl.DeleteTexture(T.tex)
			T.tex = nil
		end
		T.ready = false
	end
end
--------------------------------------------------------------------------------

local function updateComs(forceText)
	local area = comsArea

	-- icon (atlas cell) and counts are glyph instances; the icon blink is done by the shader (blink mode)
	gl4.text.comsChanged()

	comcountChanged = nil

	if WG.tooltip and refreshUi then
		WG.tooltip.AddTooltip(
			"coms",
			area,
			BAR.I18N("ui.topbar.commanderCountTooltip"),
			nil,
			BAR.I18N("ui.topbar.commanderCount")
		)
	end
end

local function updateWindRisk()
	riskWindValue = windFunctions.getWindRisk()
end

local function updateAvgWind()
	-- precomputed average wind values, from wind random monte carlo simulation, given minWind and maxWind
	local avgWind = windFunctions.averageWindLookup

	-- pull average wind from precomputed table, if it exists
	if avgWind[minWind] then
		avgWindValue = avgWind[minWind][maxWind]
	end

	-- fallback approximation
	if not avgWindValue then
		avgWindValue = "~" .. tostring(mathMax(minWind, maxWind * 0.75))
	end
end

local function updateWind()
	local area = windArea

	-- (0.5.003: the blades are an instance, see gl4.layoutUi)

	if WG.tooltip and refreshUi then
		local avgWindValueForTooltip = noWind and BAR.I18N("ui.topbar.wind.nowind1") or avgWindValue
		WG.tooltip.AddTooltip(
			"wind",
			area,
			BAR.I18N(
				"ui.topbar.windspeedTooltip",
				{ avgWindValue = avgWindValueForTooltip, riskWindValue = riskWindValue, warnColor = textWarnColor }
			),
			nil,
			BAR.I18N("ui.topbar.windspeed")
		)
	end
end

-- return true if tidal speed is *relevant*, enough water in the world (>= 10%)
local function checkTidalRelevant()
	local mapMinHeight = 0

	-- account for invertmap to the best of our ability
	if string.find(Spring.GetModOptions().debugcommands, "invertmap") then
		if string.find(Spring.GetModOptions().debugcommands, "wet") then
			-- assume that they want water if keyword "wet" is involved, too violitile between initialization and subsequent post terraform checks
			return true
			--else
			--	mapMinHeight = 0
		end
	else
		mapMinHeight = select(3, Spring.GetGroundExtremes())
	end

	mapMinHeight = mapMinHeight - (Spring.GetModOptions().map_waterlevel or 0)
	return mapMinHeight <= -20 -- armtide/cortide can be built from 20 waterdepth (hardcoded here cause am too lazy to auto cycle through unitdefs and read it from there)
end

local function updateTidal()
	local area = tidalarea

	-- (0.5.003: the waves are an instance, see gl4.layoutUi; the bob amplitude is read there)
	tidalWaveAnimationHeight = (area[4] - area[2]) * 0.1

	if WG.tooltip and refreshUi then
		WG.tooltip.AddTooltip(
			"tidal",
			area,
			BAR.I18N("ui.topbar.tidalspeedTooltip"),
			nil,
			BAR.I18N("ui.topbar.tidalspeed")
		)
	end
end

-- The quit dialog lives in the Top Bar Buttons widget; the resource bars stop
-- reacting to hover while it is up.
local function showingQuitscreen()
	return WG.topbar ~= nil and WG.topbar.showingQuit ~= nil and WG.topbar.showingQuit() ~= nil
end

local function updateResbarText(res, force)
	if not showResourceBars then
		return
	end
	if res == "BP" then
		BPS.updateResbarText(force)
		return
	end

	-- used to flashing resbar area (tinting): GL4 instances, color / blink mode set by gl4.updateFlashes
	if not gl4.flashReady[res] or force then
		gl4.layoutFlash(res)
	end

	-- storage changed!
	if cache.lastStorageValue[res] ~= r[res][2] or force then
		cache.lastStorageValue[res] = r[res][2]

		-- storage
		local storageText = short(r[res][2])
		if cache.lastStorageText[res] ~= storageText or force then
			cache.lastStorageText[res] = storageText
			updateRes[res][3] = true
		end
	end

	-- pull / income: these numbers only change at the engine's team slow update (once per 30 sim frames, see
	-- the header), so comparing them is the slow update detector; formatted only then, each text on its own
	local pull, income = r[res][3], r[res][4]
	if pull ~= cache.lastPullNum[res] then
		cache.lastPullNum[res] = pull
		local text = short(pull)
		if cache.lastPullText[res] ~= text then
			cache.lastPullText[res] = text
			updateRes[res][2] = true
		end
	end
	if income ~= cache.lastIncomeNum[res] then
		cache.lastIncomeNum[res] = income
		local text = short(income)
		if cache.lastIncomeText[res] ~= text then
			cache.lastIncomeText[res] = text
			updateRes[res][4] = true
		end
	end

	if not spec and gameFrame > cfg.spawnWarpInFrame then
		-- display overflow notification
		if
			(res == "metal" and (allyteamOverflowingMetal or overflowingMetal))
			or (res == "energy" and (allyteamOverflowingEnergy or overflowingEnergy))
		then
			if not showOverflowTooltip[res] then
				showOverflowTooltip[res] = now + 1.1
			end

			if showOverflowTooltip[res] < now then
				local bgpadding2 = 2.2 * widgetScale
				local text = ""

				if res == "metal" then
					text = (
						allyteamOverflowingMetal and "   " .. BAR.I18N("ui.topbar.resources.wastingMetal") .. "   "
						or "   " .. BAR.I18N("ui.topbar.resources.overflowing") .. "   "
					)
					if
						not supressOverflowNotifs
						and WG.notifications
						and not isMetalmap
						and (not WG.sharedMetalFrame or WG.sharedMetalFrame + 60 < gameFrame)
					then
						if allyteamOverflowingMetal then
							if numTeamsInAllyTeam > 1 then
								WG.notifications.queueNotification("WholeTeamWastingMetal")
							else
								WG.notifications.queueNotification("YouAreWastingMetal")
							end
						elseif r[res][6] > 0.75 then -- suppress if you are deliberately overflowing by adjustingthe share slider down
							WG.notifications.queueNotification("YouAreOverflowingMetal")
						end
					end
				else
					text = (
						allyteamOverflowingEnergy
							and "   " .. BAR.I18N("ui.topbar.resources.wastingEnergy") .. "   "
						or "   " .. BAR.I18N("ui.topbar.resources.overflowing") .. "   "
					)
					if
						not supressOverflowNotifs
						and WG.notifications
						and (not WG.sharedEnergyFrame or WG.sharedEnergyFrame + 60 < gameFrame)
					then
						if allyteamOverflowingEnergy then
							if numTeamsInAllyTeam > 1 then
								WG.notifications.queueNotification("WholeTeamWastingEnergy")
							else
								WG.notifications.queueNotification("YouAreWastingEnergy")
							end
						end
					end
				end

				if not showingWarning[res] then
					showingWarning[res] = true
					updateRes[res][3] = true
				end
				if cache.lastWarning[res] ~= text or force then
					cache.lastWarning[res] = text

					if dlist.resbar[res][7] then
						glDeleteList(dlist.resbar[res][7])
					end

					dlist.resbar[res][7] = glCreateList(function()
						local fontSize = (orgHeight * (1 + (ui_scale - 1) / 1.33) / 4) * widgetScale
						local textWidth = font2:GetTextWidth(text) * fontSize

						-- background
						local color1, color2, color3, color4
						if res == "metal" then
							if allyteamOverflowingMetal then
								color1 = { 0.35, 0.1, 0.1, 1 }
								color2 = { 0.25, 0.05, 0.05, 1 }
								color3 = { 1, 0.3, 0.3, 0.25 }
								color4 = { 1, 0.3, 0.3, 0.44 }
							else
								color1 = { 0.35, 0.35, 0.35, 1 }
								color2 = { 0.25, 0.25, 0.25, 1 }
								color3 = { 1, 1, 1, 0.25 }
								color4 = { 1, 1, 1, 0.44 }
							end
						else
							if allyteamOverflowingEnergy then
								color1 = { 0.35, 0.1, 0.1, 1 }
								color2 = { 0.25, 0.05, 0.05, 1 }
								color3 = { 1, 0.3, 0.3, 0.25 }
								color4 = { 1, 0.3, 0.3, 0.44 }
							else
								color1 = { 0.35, 0.25, 0, 1 }
								color2 = { 0.25, 0.16, 0, 1 }
								color3 = { 1, 0.88, 0, 0.25 }
								color4 = { 1, 0.88, 0, 0.44 }
							end
						end

						local bannerH = 15.5 * widgetScale
						local bannerRightX = resbarArea[res][3]
							- bgpadding
							- (res == "energy" and cfg.useSkew and bannerH * skewTan * 0.5 or 0)

						RectRound(
							bannerRightX - textWidth,
							resbarArea[res][4] - bannerH,
							bannerRightX,
							resbarArea[res][4],
							3.7 * widgetScale,
							0,
							0,
							1,
							1,
							color1,
							color2
						)
						RectRound(
							bannerRightX - textWidth + bgpadding2,
							resbarArea[res][4] - bannerH + bgpadding2,
							bannerRightX - bgpadding2,
							resbarArea[res][4],
							2.8 * widgetScale,
							0,
							0,
							1,
							1,
							color3,
							color4
						)
						RectRoundOutline(
							bannerRightX - textWidth + bgpadding2,
							resbarArea[res][4] - bannerH + bgpadding2,
							bannerRightX - bgpadding2,
							resbarArea[res][4] + 10,
							2.8 * widgetScale,
							bgpadding2 * 1.33,
							0,
							0,
							1,
							1,
							{ 1, 1, 1, 0.15 },
							{ 1, 1, 1, 0 }
						)

						font2:Begin(true)
						font2:SetTextColor(1, 0.88, 0.88, 1)
						font2:SetOutlineColor(0.2, 0, 0, 0.6)
						font2:Print(text, bannerRightX, resbarArea[res][4] - 9.3 * widgetScale, fontSize, "or")
						font2:End()
					end)
				end
			end
		else
			-- Always clean up the banner dlist and lastWarning so the next overflow
			-- always recreates the banner in sync with showingWarning being set.
			-- Without this, the old banner dlist persists, drawResBars shows it
			-- immediately when overflow restarts while showingWarning stays false
			-- for another 1.1s, leaving storage text visible under the banner.
			if dlist.resbar[res][7] then
				glDeleteList(dlist.resbar[res][7])
			end
			dlist.resbar[res][7] = nil
			cache.lastWarning[res] = nil
			if showingWarning[res] then
				showingWarning[res] = false
				updateRes[res][3] = true
			end
			cache.warningCleared[res] = false

			showOverflowTooltip[res] = nil
		end
	end
end

-- storage is 0 when the team has no units (dead/resigned team, or before the commander spawned),
-- dividing by it would put NaN into the bar geometry, which gl.Vertex errors on
local function fillRatio(current, storage)
	if not storage or storage <= 0 then
		return 0
	end
	return current / storage
end

-- Flash / tint state of each bar (was computed per frame in drawResBars and applied with glColor before
-- calling dlist.resbar[res][4]; 0.5.004 wrote the blinking alpha at the 30 Hz tick). 0.5.005: Lua writes a
-- blink mode and the intensity (alpha at full pulse) into the two flash instances, only when they change;
-- the vertex shader multiplies the alpha by the pulse of the mode (blinkFactor, from timeInfo.y):
--   BLINK_STALL / BLINK_ALLY: p(t); BLINK_OVERFLOW: 0.6 + 0.4 p(t); BLINK_LOW: 1 (steady, as before)
function gl4.updateFlashes()
	for i = 1, #gl4.RES do
		local res = gl4.RES[i]
		local fr, fg, fb, fa, mode
		if res == "BP" then
			-- stall flash (light file: red, 0.1 * blinkProgress while stalling metal or energy)
			if
				BPS.on
				and not spec
				and gameFrame > cfg.spawnWarpInFrame
				and gl4.flashReady.BP
				and (BPS.playerStallingMetal or BPS.playerStallingEnergy)
			then
				fr, fg, fb, fa, mode = 1, 0, 0, 0.1, gl4.BLINK_STALL
			end
		elseif not spec and gameFrame > cfg.spawnWarpInFrame and gl4.flashReady[res] then
			local allyOverflowing, overflowing, lowLimit, ovG, ovB, lowG
			if res == "metal" then
				allyOverflowing, overflowing, lowLimit, ovG, ovB, lowG = allyteamOverflowingMetal, overflowingMetal, 1000, 1, 1, 0.4
			else
				allyOverflowing, overflowing, lowLimit, ovG, ovB, lowG = allyteamOverflowingEnergy, overflowingEnergy, 2000, 1, 0, 0.55
			end
			if allyOverflowing then
				fr, fg, fb, fa, mode = 1, 0, 0, 0.1 * allyOverflowing, gl4.BLINK_ALLY
			elseif overflowing then
				fr, fg, fb, fa, mode = 1, ovG, ovB, 0.04 * overflowing, gl4.BLINK_OVERFLOW
			elseif r[res][1] < lowLimit then
				local process = fillRatio(r[res][1], r[res][2]) * 13
				if process < 1 then
					fr, fg, fb, fa, mode = 0.9, lowG, 1, 0.045 * (1 - process), gl4.BLINK_LOW
				end
			end
		end
		gl4.setFlash(res, fr, fg, fb, fa, mode)
	end
end

local function updateResbar(res)
	if not showResourceBars then
		return
	end
	gl4.ts.fastDirty = true -- (0.5.005) layout / knobs changed: let the next fast tick run
	if res == "BP" then
		BPS.updateResbar()
		return
	end

	local area = resbarArea[res]

	if dlist.resbar[res][1] then
		glDeleteList(dlist.resbar[res][1])
	end

	local barHeight = mathFloor((height * widgetScale / 7) + 0.5)
	local barHeightPadding = mathFloor(((height / 4.4) * widgetScale) + 0.5)
	-- Extra inset on the slanted side so content stays within the trapezoidal shape.
	-- At mid-bar-height the slanted edge has shifted inward by ~H/2 * tan(22.5 deg).
	local skewSideInset = cfg.useSkew and mathFloor((area[4] - area[2]) * skewTan * 0.5) or 0
	local barLeftPadding = mathFloor(53 * widgetScale) + (res == "metal" and skewSideInset or 0)
	local barRightPadding = mathFloor(14.5 * widgetScale) + (res == "energy" and skewSideInset or 0)
	local barArea = {
		area[1] + mathFloor((height * widgetScale) + barLeftPadding),
		area[2] + barHeightPadding,
		area[3] - barRightPadding,
		area[2] + barHeight + barHeightPadding,
	}
	local sliderHeightAdd = mathFloor(barHeight / 1.55)
	local shareSliderWidth = barHeight + sliderHeightAdd + sliderHeightAdd
	local barWidth = barArea[3] - barArea[1]
	local glowSize = barHeight * 7
	local edgeWidth = mathMax(1, mathFloor(vsy / 1100))

	if not showingQuitscreen() and resbarHover and resbarHover == res then
		sliderHeightAdd = barHeight / 0.75
		shareSliderWidth = barHeight + sliderHeightAdd + sliderHeightAdd
	end
	shareSliderWidth = mathCeil(shareSliderWidth)

	-- Always update barArea so glow calculations work correctly even when refreshUi is false
	if not resbarDrawinfo[res] then
		resbarDrawinfo[res] = {}
	end
	resbarDrawinfo[res].barArea = barArea
	-- Always update barTexRect so it has current coordinates
	resbarDrawinfo[res].barTexRect =
		{ barArea[1], barArea[2], barArea[1] + (fillRatio(r[res][1], r[res][2]) * barWidth), barArea[4] }

	-- Ensure barColor is initialized
	if not resbarDrawinfo[res].barColor then
		if res == "metal" then
			resbarDrawinfo[res].barColor = { 1, 1, 1, 1 }
		else
			resbarDrawinfo[res].barColor = { 1, 1, 0, 1 }
		end
	end

	if refreshUi then
		if res == "metal" then
			resbarDrawinfo[res].barColor = { 1, 1, 1, 1 }
		else
			resbarDrawinfo[res].barColor = { 1, 1, 0, 1 }
		end
		resbarDrawinfo[res].barArea = barArea

		resbarDrawinfo[res].barTexRect =
			{ barArea[1], barArea[2], barArea[1] + (fillRatio(r[res][1], r[res][2]) * barWidth), barArea[4] }
		-- Glow rectangles should be relative to barArea, not barTexRect, so they don't shift when resource values change
		resbarDrawinfo[res].barGlowMiddleTexRect =
			{ barArea[1], barArea[2] - glowSize, barArea[3], barArea[4] + glowSize }
		resbarDrawinfo[res].barGlowLeftTexRect =
			{ barArea[1] - (glowSize * 2.5), barArea[2] - glowSize, barArea[1], barArea[4] + glowSize }
		resbarDrawinfo[res].barGlowRightTexRect =
			{ barArea[3], barArea[2] - glowSize, barArea[3] + (glowSize * 2.5), barArea[4] + glowSize }

		resbarDrawinfo[res].textCurrent = {
			short(r[res][1]),
			barArea[1] + barWidth / 2,
			barArea[2] + barHeight * 1.8,
			(height / 2.5) * widgetScale,
			"ocd",
		}
		resbarDrawinfo[res].textStorage = {
			"\255\150\150\150" .. short(r[res][2]),
			barArea[3],
			barArea[2] + barHeight * 2.1,
			(height / 3.2) * widgetScale,
			"ord",
		}
		resbarDrawinfo[res].textPull = {
			"\255\210\100\100" .. short(r[res][3]),
			barArea[1] - (10 * widgetScale),
			barArea[2] + barHeight * 2.15,
			(height / 3) * widgetScale,
			"ord",
		}
		resbarDrawinfo[res].textExpense = {
			"\255\210\100\100" .. short(r[res][5]),
			barArea[1] + (10 * widgetScale),
			barArea[2] + barHeight * 2.15,
			(height / 3) * widgetScale,
			"old",
		}
		resbarDrawinfo[res].textIncome = {
			"\255\100\210\100" .. short(r[res][4]),
			barArea[1] - (10 * widgetScale),
			barArea[2] - (barHeight * 0.55),
			(height / 3) * widgetScale,
			"ord",
		}
	else -- just update values
		resbarDrawinfo[res].textCurrent[1] = short(r[res][1])
		resbarDrawinfo[res].textStorage[1] = "\255\150\150\150" .. short(r[res][2])
		resbarDrawinfo[res].textPull[1] = "\255\210\100\100" .. short(r[res][3])
		resbarDrawinfo[res].textExpense[1] = "\255\210\100\100" .. short(r[res][5])
		resbarDrawinfo[res].textIncome[1] = "\255\100\210\100" .. short(r[res][4])
	end

	-- GL4: static geometry of the value bar / glow / noise / flow instances
	gl4.layoutBar(res)

	dlist.resbar[res][1] = glCreateList(function()
		glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

		-- Icon
		glColor(1, 1, 1, 1)
		local iconPadding = mathFloor((area[4] - area[2]) / 7)
		local iconSize = mathFloor(area[4] - area[2] - iconPadding - iconPadding)
		local bgpaddingHalf = mathFloor((bgpadding * 0.5) + 0.5)
		local texSize = mathFloor(iconSize * 2)

		if res == "metal" then
			glTexture(":lr" .. texSize .. "," .. texSize .. ":LuaUI/Images/metal.png")
		else
			glTexture(":lr" .. texSize .. "," .. texSize .. ":LuaUI/Images/energy.png")
		end

		local iconSkewShift = res == "metal" and skewSideInset or 0
		glTexRect(
			area[1] + bgpaddingHalf + iconPadding + iconSkewShift,
			area[2] + bgpaddingHalf + iconPadding,
			area[1] + bgpaddingHalf + iconPadding + iconSkewShift + iconSize,
			area[4] + bgpaddingHalf - iconPadding
		)
		glTexture(false)

		-- Bar background
		local addedSize = mathFloor(((barArea[4] - barArea[2]) * 0.15) + 0.5)
		local borderSize = 1
		RectRound(
			barArea[1] - edgeWidth + borderSize,
			barArea[2] - edgeWidth + borderSize,
			barArea[3] + edgeWidth - borderSize,
			barArea[4] + edgeWidth - borderSize,
			barHeight * 0.2,
			1,
			1,
			1,
			1,
			{ 0, 0, 0, 0.15 },
			{ 0, 0, 0, 0.2 }
		)

		-- bar dark outline
		local featherHeight = addedSize * 4
		WG.FlowUI.Draw.RectRoundOutline(
			barArea[1] - addedSize - featherHeight - edgeWidth,
			barArea[2] - addedSize - featherHeight - edgeWidth,
			barArea[3] + addedSize + featherHeight + edgeWidth,
			barArea[4] + addedSize + featherHeight + edgeWidth,
			barHeight * 0.8,
			featherHeight,
			1,
			1,
			1,
			1,
			{ 0, 0, 0, 0 },
			{ 0, 0, 0, 0.22 }
		)
		featherHeight = addedSize
		WG.FlowUI.Draw.RectRoundOutline(
			barArea[1] - addedSize - featherHeight - edgeWidth,
			barArea[2] - addedSize - featherHeight - edgeWidth,
			barArea[3] + addedSize + featherHeight + edgeWidth,
			barArea[4] + addedSize + featherHeight + edgeWidth,
			featherHeight * 1.5,
			featherHeight,
			1,
			1,
			1,
			1,
			{ 0, 0, 0, 0 },
			{ 0, 0, 0, 0.66 }
		)

		-- bar inner light outline
		WG.FlowUI.Draw.RectRoundOutline(
			barArea[1] - addedSize - edgeWidth,
			barArea[2] - addedSize - edgeWidth,
			barArea[3] + addedSize + edgeWidth,
			barArea[4] + addedSize + edgeWidth,
			barHeight * 0.33,
			barHeight * 0.1,
			1,
			1,
			1,
			1,
			{ 1, 1, 1, 0.3 },
			{ 1, 1, 1, 0 }
		)

		glBlending(GL.SRC_ALPHA, GL.ONE)
		glTexture(textures.noiseBackground)
		glColor(1, 1, 1, 0.88)
		TexturedRectRound(
			barArea[1] - edgeWidth,
			barArea[2] - edgeWidth,
			barArea[3] + edgeWidth,
			barArea[4] + edgeWidth,
			barHeight * 0.33,
			1,
			1,
			1,
			1,
			barWidth * 0.33,
			0
		)
		glTexture(false)
		RectRound(
			barArea[1] - addedSize - edgeWidth,
			barArea[2] - addedSize - edgeWidth,
			barArea[3] + addedSize + edgeWidth,
			barArea[4] + addedSize + edgeWidth,
			barHeight * 0.33,
			1,
			1,
			1,
			1,
			{ 0, 0, 0, 0.1 },
			{ 0, 0, 0, 0.1 }
		)
		RectRound(
			barArea[1] - addedSize,
			barArea[2] - addedSize,
			barArea[3] + addedSize,
			barArea[4] + addedSize,
			barHeight * 0.33,
			1,
			1,
			1,
			1,
			{ 0.15, 0.15, 0.15, 0.17 },
			{ 0.8, 0.8, 0.8, 0.13 }
		)
		-- -- gloss
		RectRound(
			barArea[1] - addedSize,
			barArea[2] + addedSize,
			barArea[3] + addedSize,
			barArea[4] + addedSize,
			barHeight * 0.33,
			1,
			1,
			0,
			0,
			{ 1, 1, 1, 0 },
			{ 1, 1, 1, 0.05 }
		)
		RectRound(
			barArea[1] - addedSize,
			barArea[2] - addedSize,
			barArea[3] + addedSize,
			barArea[2] + addedSize + (addedSize * 1.5),
			barHeight * 0.2,
			0,
			0,
			1,
			1,
			{ 1, 1, 1, 0.08 },
			{ 1, 1, 1, 0.0 }
		)
		glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	end)

	-- sliders (were dlist.resbar[res][2]): GL4 knob instances
	-- Metalmaker Conversion slider
	if res == "energy" then
		mmLevel = Spring.GetTeamRulesParam(myTeamID, "mmLevel")
		local convValue = mmLevel
		if draggingConversionIndicatorValue then
			convValue = draggingConversionIndicatorValue / 100
		end
		if convValue == nil then
			convValue = 1
		end

		conversionIndicatorArea = {
			mathFloor(barArea[1] + (convValue * barWidth) - (shareSliderWidth / 2)),
			mathFloor(barArea[2] - sliderHeightAdd),
			mathFloor(barArea[1] + (convValue * barWidth) + (shareSliderWidth / 2)),
			mathFloor(barArea[4] + sliderHeightAdd),
		}

		gl4.setKnob(
			res,
			"conv",
			mathFloor(conversionIndicatorArea[1] + ((conversionIndicatorArea[3] - conversionIndicatorArea[1]) / 2)),
			mathFloor(conversionIndicatorArea[2] + ((conversionIndicatorArea[4] - conversionIndicatorArea[2]) / 2)),
			mathFloor((conversionIndicatorArea[3] - conversionIndicatorArea[1]) / 2),
			true
		)
	end

	-- Share slider
	if not isSingle then
		if res == "energy" then
			energyOverflowLevel = r[res][6]
		else
			metalOverflowLevel = r[res][6]
		end

		local value = r[res][6]

		if draggingShareIndicator and draggingShareIndicatorValue[res] then
			value = draggingShareIndicatorValue[res]
		else
			draggingShareIndicatorValue[res] = value
		end

		shareIndicatorArea[res] = {
			mathFloor(barArea[1] + (value * barWidth) - (shareSliderWidth / 2)),
			mathFloor(barArea[2] - sliderHeightAdd),
			mathFloor(barArea[1] + (value * barWidth) + (shareSliderWidth / 2)),
			mathFloor(barArea[4] + sliderHeightAdd),
		}

		gl4.setKnob(
			res,
			"share",
			mathFloor(shareIndicatorArea[res][1] + ((shareIndicatorArea[res][3] - shareIndicatorArea[res][1]) / 2)),
			mathFloor(shareIndicatorArea[res][2] + ((shareIndicatorArea[res][4] - shareIndicatorArea[res][2]) / 2)),
			mathFloor((shareIndicatorArea[res][3] - shareIndicatorArea[res][1]) / 2),
			true
		)
	else
		gl4.setKnob(res, "share", 0, 0, 0, false)
	end

	local resourceTranslations = {
		metal = BAR.I18N("ui.topbar.resources.metal"),
		energy = BAR.I18N("ui.topbar.resources.energy"),
	}

	local resourceName = resourceTranslations[res]

	-- add/update tooltips
	if WG.tooltip and conversionIndicatorArea then
		-- always update for now
		if res == "energy" then
			WG.tooltip.AddTooltip(
				res .. "_share_slider",
				{
					resbarDrawinfo[res].barArea[1],
					shareIndicatorArea[res][2],
					conversionIndicatorArea[1],
					shareIndicatorArea[res][4],
				},
				BAR.I18N("ui.topbar.resources.shareEnergyTooltip"),
				nil,
				BAR.I18N("ui.topbar.resources.shareEnergyTooltipTitle")
			)
			WG.tooltip.AddTooltip(
				res .. "_share_slider2",
				{
					conversionIndicatorArea[3],
					shareIndicatorArea[res][2],
					resbarDrawinfo[res].barArea[3],
					shareIndicatorArea[res][4],
				},
				BAR.I18N("ui.topbar.resources.shareEnergyTooltip"),
				nil,
				BAR.I18N("ui.topbar.resources.shareEnergyTooltipTitle")
			)
			WG.tooltip.AddTooltip(
				res .. "_metalmaker_slider",
				conversionIndicatorArea,
				BAR.I18N("ui.topbar.resources.conversionTooltip"),
				nil,
				BAR.I18N("ui.topbar.resources.conversionTooltipTitle")
			)
		else
			WG.tooltip.AddTooltip(
				res .. "_share_slider",
				{
					resbarDrawinfo[res].barArea[1],
					shareIndicatorArea[res][2],
					resbarDrawinfo[res].barArea[3],
					shareIndicatorArea[res][4],
				},
				BAR.I18N("ui.topbar.resources.shareMetalTooltip"),
				nil,
				BAR.I18N("ui.topbar.resources.shareMetalTooltipTitle")
			)
		end

		if refreshUi then
			WG.tooltip.AddTooltip(res .. "_pull", {
				resbarDrawinfo[res].textPull[2] - (resbarDrawinfo[res].textPull[4] * 2.5),
				resbarDrawinfo[res].textPull[3],
				resbarDrawinfo[res].textPull[2] + (resbarDrawinfo[res].textPull[4] * 0.5),
				resbarDrawinfo[res].textPull[3] + resbarDrawinfo[res].textPull[4],
			}, BAR.I18N("ui.topbar.resources.pullTooltip", { resource = resourceName }))
			WG.tooltip.AddTooltip(res .. "_income", {
				resbarDrawinfo[res].textIncome[2] - (resbarDrawinfo[res].textIncome[4] * 2.5),
				resbarDrawinfo[res].textIncome[3],
				resbarDrawinfo[res].textIncome[2] + (resbarDrawinfo[res].textIncome[4] * 0.5),
				resbarDrawinfo[res].textIncome[3] + resbarDrawinfo[res].textIncome[4],
			}, BAR.I18N("ui.topbar.resources.incomeTooltip", { resource = resourceName }))
			--WG['tooltip'].AddTooltip(res .. '_expense', { resbarDrawinfo[res].textExpense[2] - (4 * widgetScale), resbarDrawinfo[res].textExpense[3], resbarDrawinfo[res].textExpense[2] + (30 * widgetScale), resbarDrawinfo[res].textExpense[3] + resbarDrawinfo[res].textExpense[4] }, Spring.I18N('ui.topbar.resources.expenseTooltip', { resource = resourceName }))
			WG.tooltip.AddTooltip(res .. "_storage", {
				resbarDrawinfo[res].textStorage[2] - (resbarDrawinfo[res].textStorage[4] * 2.75),
				resbarDrawinfo[res].textStorage[3],
				resbarDrawinfo[res].textStorage[2],
				resbarDrawinfo[res].textStorage[3] + resbarDrawinfo[res].textStorage[4],
			}, BAR.I18N("ui.topbar.resources.storageTooltip", { resource = resourceName }))
		end
	end
end

local function updateResbarValues(res, update)
	if not showResourceBars then
		return
	end
	if res == "BP" then
		if update then
			BPS.updateResbarValues()
		end
		return
	end

	if update then
		local barHeight = resbarDrawinfo[res].barArea[4] - resbarDrawinfo[res].barArea[2] -- only read values if update is needed
		local barWidth = resbarDrawinfo[res].barArea[3] - resbarDrawinfo[res].barArea[1] -- only read values if update is needed
		-- (0.5.005: the current value text is gl4.valueText, from the slow tick)
		local maxStorageRes = smoothedResources[res][2]
		local cappedCurRes = smoothedResources[res][1] -- limit so when production dies the value won't be much larger than what you can store
		if cappedCurRes > maxStorageRes * 1.07 then
			cappedCurRes = maxStorageRes * 1.07
		end
		local barSize = barHeight * 0.2
		local valueWidth = mathFloor(fillRatio(cappedCurRes, maxStorageRes) * barWidth)
		if valueWidth < mathCeil(barSize) then
			valueWidth = mathCeil(barSize)
		end
		if valueWidth ~= cache.lastValueWidth[res] then -- only recalc if the width changed
			cache.lastValueWidth[res] = valueWidth

			-- GL4: the value bar, its glow, the metal noise and the energy flow are instances;
			-- a width change only rewrites their fill width (and the glow alpha)
			local glowAlpha
			if res == "metal" then
				glowAlpha = 0.025 + (0.05 * mathMin(1, fillRatio(cappedCurRes, r[res][2]) * 40))
			else
				glowAlpha = 0.035 + (0.07 * mathMin(1, fillRatio(cappedCurRes, r[res][2]) * 40))
			end
			gl4.setFill(res, valueWidth, glowAlpha)
		end
	end
end

-- Current value text of metal / energy (0.5.005, from the 10 Hz slow tick after the smoothing): the shown
-- number is computed first and the string is only formatted (and its glyphs written) when that number
-- changed. Same output as short(): "%d" up to 9999, "%dk" up to 9999999, then "%dm" (rounded to nearest).
-- While the bar is not hovered, values in [gl4.VALUE_STEP_MIN, gl4.VALUE_STEP_MAX) are rounded to steps of
-- gl4.VALUE_STEP (5: 100..995); below VALUE_STEP_MIN and while hovering the exact integer is shown.
function gl4.valueText(res)
	local n = smoothedResources[res][1]
	if n ~= n then
		n = 0 -- (string.format errors on NaN)
	end
	local kind, key
	if n > 9999999 then
		kind, key = 3, mathFloor(n / 1000000 + 0.5)
	elseif n > 9999 then
		kind, key = 2, mathFloor(n / 1000 + 0.5)
	else
		kind, key = 1, mathFloor(n + 0.5)
		local step = gl4.VALUE_STEP
		if step > 1 and key >= gl4.VALUE_STEP_MIN and key < gl4.VALUE_STEP_MAX and hoveringTopbar ~= res then
			key = mathFloor(n / step + 0.5) * step
		end
	end
	local vt = gl4.vt[res]
	if key == vt.key and kind == vt.kind then
		return
	end
	vt.key, vt.kind = key, kind
	cache.lastDrawnValue[res] = stringFormat(gl4.VT_FMT[kind], key)
	updateRes[res][1] = true
end

--------------------------------------------------------------------------------
-- Buildpower ("BP") bar
-- Handled like a third resource bar: resbarArea.BP, resbarDrawinfo.BP,
-- dlist.resbar.BP[n], dlist.resValuesBar.BP, cache.lastValueWidth.BP, and the
-- base entry points updateResbar("BP"), updateResbarValues("BP", update) and
-- updateResbarText("BP") dispatch to the BPS.* functions below.
--  dlist.resbar.BP[1] icon + bar background (static, rendered into uiTex on refreshUi)
--  (gl4) BP markers: eco support / wind range indicators (moved in place when a marker moves a pixel)
--  (gl4) BP flash pair: panel shape for the stall flash
--  dlist.resbar.BP[7] alerts below the panel (need metal / need energy / idle buildpower)
--  (gl4) BP fill / border / glow / reserved: used + reserved buildpower (widths written when they change)
-- The percentage text is a glyph slot (gl4.text, written when updateRes.BP[1] is set).
--------------------------------------------------------------------------------

-- The BP panel sits between metal and energy (0.4.010 layout). With cfg.useSkew the metal bar only
-- slants its left edge and the energy bar only its right edge, so the edges meeting the BP panel are
-- vertical: the BP panel is a plain rectangle (no skew, no horizontal shift of its content).

function BPS.validRatio(v)
	if v == nil or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	return v
end

function BPS.fmt(n)
	if n == nil then
		return "nil"
	end
	if n ~= n or n == math.huge or n == -math.huge then
		return "n/a" -- string.format errors on NaN/inf
	end
	return stringFormat("%.3f", n)
end

-- widths of the metal/energy bars and of the BP bar. The official layout is kept when everything
-- (metal, energy, BP, wind/tidal/coms) fits left of the area the Top Bar Buttons widget reserves;
-- otherwise the three bars share the available width (0.4.010 behaviour).
function BPS.layoutWidths(totalWidth, width)
	local smallWidth = mathFloor((height * 1.18) * widgetScale) + widgetSpaceMargin
	local smallSections = 1 -- wind
	if displayTidalSpeed and checkTidalRelevant() then
		smallSections = smallSections + 1
	end
	if displayComCounter then
		smallSections = smallSections + 1
	end
	local buttonsWidth = mathFloor(totalWidth / 4) + widgetSpaceMargin
	local available = totalWidth - buttonsWidth - (smallWidth * smallSections) - (3 * widgetSpaceMargin)
	local bpWidth = mathFloor(width * 2 / 6)
	if (width * 2) + bpWidth > available then
		local combined = mathMax(0, available)
		bpWidth = mathFloor(combined / 7)
		width = mathFloor((combined - bpWidth) / 2)
	end
	return width, bpWidth
end

-- same bar background as the official metal/energy bars (see updateResbar)
function BPS.drawBarBackground(barArea, barHeight, barWidth, edgeWidth)
	local addedSize = mathFloor(((barArea[4] - barArea[2]) * 0.15) + 0.5)
	local borderSize = 1
	RectRound(
		barArea[1] - edgeWidth + borderSize,
		barArea[2] - edgeWidth + borderSize,
		barArea[3] + edgeWidth - borderSize,
		barArea[4] + edgeWidth - borderSize,
		barHeight * 0.2,
		1,
		1,
		1,
		1,
		{ 0, 0, 0, 0.15 },
		{ 0, 0, 0, 0.2 }
	)

	-- bar dark outline
	local featherHeight = addedSize * 4
	WG.FlowUI.Draw.RectRoundOutline(
		barArea[1] - addedSize - featherHeight - edgeWidth,
		barArea[2] - addedSize - featherHeight - edgeWidth,
		barArea[3] + addedSize + featherHeight + edgeWidth,
		barArea[4] + addedSize + featherHeight + edgeWidth,
		barHeight * 0.8,
		featherHeight,
		1,
		1,
		1,
		1,
		{ 0, 0, 0, 0 },
		{ 0, 0, 0, 0.22 }
	)
	featherHeight = addedSize
	WG.FlowUI.Draw.RectRoundOutline(
		barArea[1] - addedSize - featherHeight - edgeWidth,
		barArea[2] - addedSize - featherHeight - edgeWidth,
		barArea[3] + addedSize + featherHeight + edgeWidth,
		barArea[4] + addedSize + featherHeight + edgeWidth,
		featherHeight * 1.5,
		featherHeight,
		1,
		1,
		1,
		1,
		{ 0, 0, 0, 0 },
		{ 0, 0, 0, 0.66 }
	)

	-- bar inner light outline
	WG.FlowUI.Draw.RectRoundOutline(
		barArea[1] - addedSize - edgeWidth,
		barArea[2] - addedSize - edgeWidth,
		barArea[3] + addedSize + edgeWidth,
		barArea[4] + addedSize + edgeWidth,
		barHeight * 0.33,
		barHeight * 0.1,
		1,
		1,
		1,
		1,
		{ 1, 1, 1, 0.3 },
		{ 1, 1, 1, 0 }
	)

	glBlending(GL.SRC_ALPHA, GL.ONE)
	glTexture(textures.noiseBackground)
	glColor(1, 1, 1, 0.88)
	TexturedRectRound(
		barArea[1] - edgeWidth,
		barArea[2] - edgeWidth,
		barArea[3] + edgeWidth,
		barArea[4] + edgeWidth,
		barHeight * 0.33,
		1,
		1,
		1,
		1,
		barWidth * 0.33,
		0
	)
	glTexture(false)
	RectRound(
		barArea[1] - addedSize - edgeWidth,
		barArea[2] - addedSize - edgeWidth,
		barArea[3] + addedSize + edgeWidth,
		barArea[4] + addedSize + edgeWidth,
		barHeight * 0.33,
		1,
		1,
		1,
		1,
		{ 0, 0, 0, 0.1 },
		{ 0, 0, 0, 0.1 }
	)
	RectRound(
		barArea[1] - addedSize,
		barArea[2] - addedSize,
		barArea[3] + addedSize,
		barArea[4] + addedSize,
		barHeight * 0.33,
		1,
		1,
		1,
		1,
		{ 0.15, 0.15, 0.15, 0.17 },
		{ 0.8, 0.8, 0.8, 0.13 }
	)
	-- gloss
	RectRound(
		barArea[1] - addedSize,
		barArea[2] + addedSize,
		barArea[3] + addedSize,
		barArea[4] + addedSize,
		barHeight * 0.33,
		1,
		1,
		0,
		0,
		{ 1, 1, 1, 0 },
		{ 1, 1, 1, 0.05 }
	)
	RectRound(
		barArea[1] - addedSize,
		barArea[2] - addedSize,
		barArea[3] + addedSize,
		barArea[2] + addedSize + (addedSize * 1.5),
		barHeight * 0.2,
		0,
		0,
		1,
		1,
		{ 1, 1, 1, 0.08 },
		{ 1, 1, 1, 0.0 }
	)
	glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
end

-- geometry + static display list; called from init() (refreshUi) via updateResbar("BP")
function BPS.updateResbar()
	local area = resbarArea.BP
	if not area[1] then
		return
	end
	local bar = dlist.resbar.BP
	if bar[1] then
		bar[1] = glDeleteList(bar[1])
	end
	if bar[2] then
		bar[2] = glDeleteList(bar[2])
	end
	if bar[7] then
		bar[7] = glDeleteList(bar[7])
	end
	BPS.bannerKey = -1
	BPS.nextPct = 0
	BPS.ind.dirty = true
	BPS.tt.dirty = true
	cache.lastValueWidth.BP = -1
	cache.lastDrawnValue.BP = -2

	local areaH = area[4] - area[2]
	local barHeight = mathFloor((height * widgetScale / 7) + 0.5)
	local barHeightPadding = mathFloor(((height / 4.4) * widgetScale) + 0.5)
	local sidePadding = mathFloor(14.5 * widgetScale)
	local edgeWidth = mathMax(1, mathFloor(vsy / 1100))
	local barShift = 0 -- rectangular panel (see above)
	local barArea = {
		area[1] + sidePadding - barShift,
		area[2] + barHeightPadding,
		area[3] - sidePadding - barShift,
		area[2] + barHeight + barHeightPadding,
	}
	if barArea[3] - barArea[1] < barHeight then
		barArea[3] = barArea[1] + barHeight
	end
	local barWidth = barArea[3] - barArea[1]

	-- icon: small striped square in the top left corner (as in 0.4.010)
	local iconPadding = mathFloor(areaH / 9)
	local iconSize = mathFloor((height / 3) * widgetScale)
	local bgpaddingHalf = mathFloor((bgpadding * 0.5) + 0.5)
	local iconTop = area[4] - bgpaddingHalf - iconPadding
	local iconBottom = iconTop - iconSize
	local iconLeft = area[1] + sidePadding
	local iconRight = iconLeft + iconSize

	-- percentage text: centered between the icon and the right edge. Its uiTex clear region
	-- (textClipL..textClipR, above 48% of the bar height) must not touch the icon or the bar.
	local fontSize = (height / 2.5) * widgetScale
	local textY = barArea[2] + barHeight * 1.8
	local textShift = 0
	local textLeft = iconRight + mathCeil(2 * widgetScale)
	local textRight = area[3] - textShift - bgpadding
	local textX = mathFloor(((textLeft + textRight) * 0.5) + 0.5)
	BPS.textMaxWidth = font2:GetTextWidth("100%") * fontSize
	local half = (BPS.textMaxWidth * 0.5) + (2 * widgetScale)
	BPS.textClipL = mathFloor(mathMax(textLeft, textX - half))
	BPS.textClipR = mathCeil(mathMin(area[3] - textShift, textX + half))

	local info = resbarDrawinfo.BP
	info.barArea = barArea
	info.barTexRect = { barArea[1], barArea[2], barArea[3], barArea[4] }
	info.barColor = { 0, 1, 0, 1 }
	info.textCurrent = { "", textX, textY, fontSize, "ocd" }

	-- GL4: static geometry of the used / reserved fill and glow instances
	gl4.layoutBar("BP")

	local texSize = mathFloor(iconSize * 2)
	bar[1] = glCreateList(function()
		glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
		glColor(1, 0.9, 0.2, 1)
		glTexture(":lr" .. texSize .. "," .. texSize .. ":LuaUI/Images/stripes.png")
		TexturedRectRound(iconLeft, iconBottom, iconRight, iconTop, iconSize * 0.2, 1, 1, 1, 1, iconSize, 0)
		glTexture(false)
		glColor(1, 1, 1, 1)
		BPS.drawBarBackground(barArea, barHeight, barWidth, edgeWidth)
	end)

	-- tooltip areas: the explanation below the text line, "You are using X%" on the text
	BPS.tt.areaAll = { barArea[1], area[2], barArea[3], textY }
	BPS.tt.areaCurrent = { BPS.textClipL, textY, BPS.textClipR, area[4] }
	BPS.updateTooltip(true)
end

-- panel shape used to flash the BP panel while stalling (like dlist.resbar[res][4] of metal/energy)
function BPS.updateResbarText(force)
	local area = resbarArea.BP
	if not area[1] then
		return
	end
	-- GL4 flash instances (rectangular panel between metal and energy), color set by gl4.updateFlashes
	if gl4.flashReady.BP and not force then
		return
	end
	gl4.layoutFlash("BP")
end

-- fast tick (20 Hz, gl4.fastTick): fill widths, indicator markers, percentage text flag (at most 2 Hz)
function BPS.updateResbarValues()
	local info = resbarDrawinfo.BP
	if not info.barArea then
		return
	end
	local barArea = info.barArea
	local barHeight = barArea[4] - barArea[2]
	local barWidth = barArea[3] - barArea[1]
	local barSize = barHeight * 0.2
	local minWidth = mathCeil(barSize)

	-- totalBP is at least 1: no division by zero before the first builder exists
	local totalBP = mathMax(1, BP[4])
	local reservedBP = mathMin(totalBP, BP[3])
	local usedBP = mathMin(totalBP, BP[5])
	local valueWidth = mathFloor((usedBP / totalBP) * barWidth)
	if valueWidth > barWidth then
		valueWidth = barWidth
	end
	-- reserved (assigned) buildpower as a proportion of total buildpower
	local additionalWidth = mathFloor((reservedBP / totalBP) * barWidth) - valueWidth
	if additionalWidth < minWidth or minWidth > barWidth then
		additionalWidth = 0
	end
	if valueWidth < minWidth then
		valueWidth = minWidth
	end

	-- percentage text (integer percent, recomputed at most every gl4.PCT_INTERVAL; glyphs rewritten only
	-- when it changed). The source values are averages over 30 scan passes anyway
	if now >= BPS.nextPct then
		BPS.nextPct = now + gl4.PCT_INTERVAL - gl4.FAST_TICK * 0.5
		local pct = -1
		if BP[4] > 0 then
			pct = mathMax(0, mathMin(100, mathFloor((BP[5] * 100 / BP[4]) + 0.5)))
		end
		BPS.pct = pct
		if pct ~= cache.lastDrawnValue.BP then
			updateRes.BP[1] = true
		end
	end

	if valueWidth ~= cache.lastValueWidth.BP or additionalWidth ~= BPS.lastAdditionalWidth then -- only when a width changed
		cache.lastValueWidth.BP = valueWidth
		BPS.lastAdditionalWidth = additionalWidth

		-- GL4: used fill + border + glow (alpha 0.035, barColor) and the reserved overlay
		-- (from the bar start to used + reserved) are instances; only their widths change
		gl4.setFill("BP", valueWidth, 0.035)
		gl4.setInst(gl4.K.BP.reserved, 17, valueWidth + additionalWidth)
		gl4.setVisible(gl4.K.BP.reserved, true)
	end

	BPS.updateIndicators()
end

-- metal/energy supported buildpower markers and the wind range strip; the list is only
-- rebuilt when a marker moved by a pixel, grew/shrank (stalling) or an option changed
function BPS.updateIndicators()
	local info = resbarDrawinfo.BP
	local barArea = info.barArea
	local barWidth = barArea[3] - barArea[1]
	local ind = BPS.ind

	local mx, ex, wx1, wx2 = false, false, false, false
	if BPC.drawBPIndicators then
		local mPos = BPS.validRatio(BP.mSliderPosition)
		local ePos = BPS.validRatio(BP.eSliderPosition)
		if mPos then
			mx = mathFloor(barArea[1] + (mPos * barWidth) + 0.5)
		end
		if ePos then
			ex = mathFloor(barArea[1] + (ePos * barWidth) + 0.5)
			local wMin = BPS.validRatio(BP.eSliderPosition_minWind)
			local wMax = BPS.validRatio(BP.eSliderPosition_maxWind)
			if BPC.drawBPWindRangeIndicators and BPS.numWindGenerators > 0 and wMin and wMax then
				wx1 = mathFloor(barArea[1] + (mathMin(wMin, wMax) * barWidth) + 0.5)
				wx2 = mathFloor(barArea[1] + (mathMax(wMin, wMax) * barWidth) + 0.5)
			end
		end
	end
	local sm = BPS.playerStallingMetal and true or false
	local se = BPS.playerStallingEnergy and true or false

	if
		not ind.dirty
		and mx == ind.mx
		and ex == ind.ex
		and wx1 == ind.wx1
		and wx2 == ind.wx2
		and sm == ind.sm
		and se == ind.se
	then
		return
	end
	ind.dirty = false
	ind.mx, ind.ex, ind.wx1, ind.wx2, ind.sm, ind.se = mx, ex, wx1, wx2, sm, se

	-- GL4: the markers are instances (was dlist.resbar.BP[2]); hidden when not shown
	local k = gl4.K.BP
	local colors = BPS.colors
	local barHeight = barArea[4] - barArea[2]
	local indicatorH = barHeight -- height of the metal/energy supported BP indicators
	local barIntrusion = barHeight * 0.4 -- how much of the bar an indicator may cover (vertically)
	local indicatorW = indicatorH * 1.2
	local cornerSize = indicatorH / 2
	local multM = sm and 1.4 or 1
	local multE = se and 1.4 or 1
	local halfM = indicatorW * multM / 2
	local halfE = indicatorW * multE / 2

	-- buildpower that the current METAL income can support: along the bottom edge, pointing up (corners tl, tr)
	gl4.setMarker(
		k.indM,
		mx and (mx - halfM),
		barArea[2] + (barIntrusion - indicatorH * multM),
		(mx or 0) + halfM,
		barArea[2] + barIntrusion,
		cornerSize * multM,
		3,
		colors.mLow,
		colors.mHigh
	)
	-- range of buildpower that energy could support if the wind changes (no corners)
	gl4.setMarker(
		k.indW,
		ex and wx1 and (wx1 - halfE),
		barArea[4] + barIntrusion,
		(wx2 or 0) + halfE,
		barArea[4] - barIntrusion + indicatorH,
		(indicatorH - 2 * barIntrusion) / 2,
		0,
		colors.windLow,
		colors.windHigh
	)
	-- buildpower that the current ENERGY income can support: along the top edge, pointing down (corners br, bl)
	gl4.setMarker(
		k.indE,
		ex and (ex - halfE),
		barArea[4] - barIntrusion,
		(ex or 0) + halfE,
		barArea[4] - barIntrusion + indicatorH * multE,
		cornerSize * multE,
		12,
		colors.eLow,
		colors.eHigh
	)
end

function BPS.debugText(avgTotalUsedBP)
	local fmt = BPS.fmt
	local nBuilders = 0
	local nBuiltBuilders = 0
	for _, builder in pairs(BPS.trackedBuilders) do
		nBuilders = nBuilders + 1
		if builder.isBuilt then
			nBuiltBuilders = nBuiltBuilders + 1
		end
	end
	return "\n\nDEBUG:"
		.. fmt(avgTotalUsedBP)
		.. " BP used (smoothed), "
		.. fmt(BP.usedBP_instant)
		.. " BP non-stalled "
		.. fmt(BP.usedBPIfNoStall)
		.. " if no stall \n"
		.. tostring(nBuilders)
		.. " tracked builders\n"
		.. tostring(nBuiltBuilders)
		.. " built builders\n"
		.. tostring(BP[4])
		.. " total BP \n"
		.. fmt(r.metal[5])
		.. " M, "
		.. fmt(r.energy[5])
		.. " E spent by all units\n"
		.. fmt(BP.usedBPMetalExpense)
		.. " M spent by builders, \n"
		.. fmt(BP.usedBPEnergyExpense)
		.. " E spent by builders, \n"
		.. fmt(r.metal[5])
		.. " / "
		.. fmt(r.energy[5])
		.. " metal/energy expense, \n"
		.. fmt(BP.metalExpensePerBP)
		.. " / "
		.. fmt(BP.energyExpensePerBP)
		.. " M/E expense per BP, \n"
		.. fmt(r.energy[4])
		.. " E income\n"
		.. fmt(BPS.numWindGenerators)
		.. " wind generators\n"
		.. "\nprojections:\n"
		.. fmt(BP.metalExpenseIfAllBPUsed)
		.. " M spent if all BP is used, \n"
		.. fmt(BP.energyExpenseIfAllBPUsed)
		.. " E spent if all BP is used, \n"
		.. fmt(BP.metalSupportedBP)
		.. " BP supported by M income, \n"
		.. fmt(BP.energySupportedBP)
		.. " BP supported by E income,\n\n"
end

-- tooltips via WG.tooltip like the base; the texts are only rebuilt (and re-sent, which makes the
-- tooltip widget drop its cached list) when a number in them changed. Called at the read cadence (4 Hz), on
-- hover start and on init. 0.5.005: while the mouse is not over the BP panel at most once per
-- gl4.TOOLTIP_IDLE_INTERVAL (the tooltip only shows on hover; hover start re-checks at once, see gl4.tick)
function BPS.updateTooltip(force)
	local tooltip = WG.tooltip
	local tt = BPS.tt
	if not tooltip or not tt.areaAll then
		return
	end
	force = force or tt.dirty
	tt.dirty = false
	if not force and hoveringTopbar ~= "BP" then
		if now < (tt.nextIdle or 0) then
			return
		end
		tt.nextIdle = now + gl4.TOOLTIP_IDLE_INTERVAL
	end

	local textColor = "\255\215\215\215"
	local highlightColor = "\255\255\255\255"
	local reserved = mathFloor(BP[3] + 0.5)
	local total = BP[4]
	local used = mathFloor(BP[5] + 0.5)
	local mPos = BPS.validRatio(BP.mSliderPosition)
	local ePos = BPS.validRatio(BP.eSliderPosition)
	local showIndicators = BPC.drawBPIndicators and mPos ~= nil and ePos ~= nil
	local mPct = showIndicators and mathCeil(mPos * 100) or -1
	local ePct = showIndicators and mathCeil(ePos * 100) or -1

	if
		force
		or BPC.debugTooltip
		or reserved ~= tt.reserved
		or total ~= tt.total
		or used ~= tt.used
		or mPct ~= tt.mPct
		or ePct ~= tt.ePct
	then
		tt.reserved, tt.total, tt.used, tt.mPct, tt.ePct = reserved, total, used, mPct, ePct

		local text
		if total > 0 then
			local percentAssigned = mathMax(0, mathFloor((reserved / total * 100) + 0.5))
			local percentActive = mathMax(0, mathFloor((used / total * 100) + 0.5))
			local percentIdle = mathMax(0, mathFloor(((total - reserved) / total * 100) + 0.5))
			text = textColor
				.. "Your total buildpower (BP) is "
				.. highlightColor
				.. total
				.. textColor
				.. ", of which:\n"
				.. highlightColor
				.. stringFormat("%3d", percentAssigned)
				.. "%"
				.. textColor
				.. " is assigned to tasks or moving to jobs (dark green bar).\n"
				.. highlightColor
				.. stringFormat("%3d", percentActive)
				.. "%"
				.. textColor
				.. " is currently active and being used (green bar). This is the number shown.\n"
				.. highlightColor
				.. stringFormat("%3d", percentIdle)
				.. "%"
				.. textColor
				.. " is idle with no BP tasks (empty part of the bar)."
		else
			text = textColor .. "Your total buildpower (BP) is " .. highlightColor .. "0" .. textColor .. " (no builders)."
		end

		if showIndicators then
			text = text
				.. "\n\n"
				.. textColor
				.. "The grey and yellow indicators show you that, if all BP were fully engaged:\n"
				.. "Metal income would support "
				.. highlightColor
				.. mPct
				.. textColor
				.. "% of BP.\n"
				.. "Energy income would support "
				.. highlightColor
				.. ePct
				.. textColor
				.. "% of BP."
		end

		if BPC.debugTooltip then
			text = text .. BPS.debugText(used)
		end

		if force or text ~= tt.text then
			tt.text = text
			tooltip.AddTooltip("BP_all", tt.areaAll, text, nil, "Buildpower")
		end
	end

	local pct = -1
	if total > 0 then
		pct = mathMax(0, mathMin(100, mathFloor((BP[5] * 100 / total) + 0.5)))
	end
	if force or pct ~= tt.pct then
		tt.pct = pct
		if pct >= 0 then
			tooltip.AddTooltip(
				"BP_Current",
				tt.areaCurrent,
				textColor .. "You are using " .. highlightColor .. pct .. textColor .. "% of your buildpower."
			)
		else
			tooltip.RemoveTooltip("BP_Current")
		end
	end
end

-- alerts below the BP panel (0.4.010 showBuildpowerAlert); rebuilt only when the set changes
function BPS.updateBanner()
	local area = resbarArea.BP
	local bar = dlist.resbar.BP
	local total, reserved = BP[4], BP[3]
	local idle = total > 0 and reserved / total <= 0.5 and (total - reserved) > 300
	local key = (BPS.playerStallingMetal and 1 or 0) + (BPS.playerStallingEnergy and 2 or 0) + (idle and 4 or 0)

	if spec or gameFrame <= cfg.spawnWarpInFrame or key == 0 or not area[1] then
		if bar[7] then
			bar[7] = glDeleteList(bar[7])
		end
		showOverflowTooltip.BP = nil
		BPS.bannerKey = 0
		return
	end
	if not showOverflowTooltip.BP then
		showOverflowTooltip.BP = now + 1.1
	end
	if showOverflowTooltip.BP >= now or key == BPS.bannerKey then
		return
	end
	BPS.bannerKey = key

	if bar[7] then
		glDeleteList(bar[7])
	end
	bar[7] = glCreateList(function()
		local colors = BPS.colors
		local fontSize = (orgHeight * (1 + (ui_scale - 1) / 1.33) / 4) * widgetScale
		local padding = 2.2 * widgetScale
		-- right aligned to the panel's bottom right corner
		local rightX = area[3]
		local alerts = BPS.alerts
		local offset = 0
		for i = 1, #alerts do
			local alert = alerts[i]
			if key % (alert[1] * 2) >= alert[1] then
				local textWidth = font2:GetTextWidth(alert[2]) * fontSize
				RectRound(
					rightX - (offset + textWidth) + padding,
					area[2] - 15.5 * widgetScale + padding,
					rightX - offset - padding,
					area[2],
					2.8 * widgetScale,
					0,
					0,
					1,
					1,
					alert[3] and colors.warnLow or colors.infoLow,
					alert[3] and colors.warnHigh or colors.infoHigh
				)
				offset = offset + textWidth
			end
		end
		font2:Begin(true)
		font2:SetTextColor(1, 0.88, 0.88, 1)
		font2:SetOutlineColor(0.2, 0, 0, 0.6)
		offset = 0
		for i = 1, #alerts do
			local alert = alerts[i]
			if key % (alert[1] * 2) >= alert[1] then
				font2:Print(alert[2], rightX - offset, area[2] - 9.3 * widgetScale, fontSize, "or")
				offset = offset + font2:GetTextWidth(alert[2]) * fontSize
			end
		end
		font2:End()
	end)
end

-- 4 Hz, from the resource read (gl4.slowTick)
function BPS.slowUpdate()
	-- stalling (0.4.010 updateAllyTeamOverflowing, own team only)
	local mPos = BPS.validRatio(BP.mSliderPosition)
	local ePos = BPS.validRatio(BP.eSliderPosition)
	BPS.playerStallingMetal = (mPos ~= nil and mPos < 0.8 and r.metal[1] < 2 * r.metal[3])
	BPS.playerStallingEnergy = (ePos ~= nil and ePos < 0.8 and r.energy[1] < 2 * r.energy[3])

	-- low priority builders: add what they are being denied to the shown pull (0.4.010).
	-- Only when the game publishes these team rules params (current BAR does not), so the
	-- official metal/energy pull stays untouched otherwise.
	local lowPrioNeededEnergy = sp.GetTeamRulesParam(myTeamID, "lowPrioNeededEnergy")
	local lowPrioExpenseEnergy = sp.GetTeamRulesParam(myTeamID, "lowPrioExpenseEnergy")
	local lowPrioNeededMetal = sp.GetTeamRulesParam(myTeamID, "lowPrioNeededMetal")
	local lowPrioExpenseMetal = sp.GetTeamRulesParam(myTeamID, "lowPrioExpenseMetal")
	if lowPrioNeededEnergy and lowPrioExpenseEnergy and lowPrioNeededMetal and lowPrioExpenseMetal then
		local stalling = BPS.stalling
		stalling.lowPrioEnergy = lowPrioNeededEnergy + lowPrioExpenseEnergy
		stalling.lowPrioMetal = lowPrioNeededMetal + lowPrioExpenseMetal
		r.metal[3] = r.metal[3] + stalling.lowPrioMetal
		r.energy[3] = r.energy[3] + stalling.lowPrioEnergy
	end

	BPS.updateBanner()
	BPS.updateTooltip(false)
end

--------------------------------------------------------------------------------
-- Buildpower tracking and calculation (0.4.010, functionally unchanged)
--------------------------------------------------------------------------------

function BPS.initUnitCostData()
	local unitCostData = BPS.unitCostData
	for unitDefID, unitDef in pairs(UnitDefs) do
		local buildTime = unitDef.buildTime
		if not buildTime or buildTime <= 0 then
			buildTime = 1
		end
		unitCostData[unitDefID] = {
			buildTime = buildTime,
			energy = unitDef.energyCost,
			metal = unitDef.metalCost,
			EperBP = unitDef.energyCost / buildTime,
			MperBP = unitDef.metalCost / buildTime,
		}
	end
end

-- builder scan state (0.5.002 scan): the tracked builders are also kept in dense arrays so the scan
-- walks them by index (no coroutine, no per-pass tables) and reads the per-builder constants from arrays
BPS.scanIDs = {} -- [pos] = unitID
BPS.scanBP = {} -- [pos] = buildSpeed
BPS.scanKind = {} -- [pos] = 1 builder, 2 nano, 3 factory
BPS.scanPos = {} -- [unitID] = pos
BPS.scanN = 0 -- number of tracked builders
BPS.scanCursor = 1 -- next position of the current pass; [1, scanCursor - 1] already scanned
BPS.builderDefs = {} -- [unitDefID] = { buildSpeed, kind, unitType } or false, cached on first use
-- engine functions picked once: GetUnitWorkerTask gives the buildee (as -unitDefID) and its id in one call
BPS.getWorkerTask = Spring.GetUnitWorkerTask
BPS.CMD_REPAIR = CMD.REPAIR or 40
BPS.CMD_FIGHT = CMD.FIGHT or 16

function BPS.builderDefInfo(unitDefID, unitDef)
	local info = BPS.builderDefs[unitDefID]
	if info == nil then
		info = false
		local buildSpeed = unitDef.buildSpeed or 0
		if buildSpeed > 0 and unitDef.canAssist or unitDef.isFactory then
			local kind, unitType = 1, "builder"
			if unitDef.isFactory then
				kind, unitType = 3, "factory"
			elseif unitDef.name:find("nano") then
				kind, unitType = 2, "nano"
			end
			info = { buildSpeed = buildSpeed, kind = kind, unitType = unitType }
		end
		BPS.builderDefs[unitDefID] = info
	end
	return info
end

function BPS.TrackUnit(unitID, unitDefID, unitTeam) -- needed for exact calculations
	if myTeamID ~= unitTeam then
		return
	end
	local unitDef = unitDefID and UnitDefs[unitDefID]
	if not unitDef then
		return
	end
	local _, _, _, _, build = sp.GetUnitHealth(unitID) -- is it finished?
	if not build or build < 1 then
		return
	end
	local info = BPS.builderDefInfo(unitDefID, unitDef)
	if info then
		local buildSpeed = info.buildSpeed
		local pos = BPS.scanPos[unitID]
		if not pos then -- may already be tracked; don't add its BP twice
			BP[4] = BP[4] + buildSpeed -- BP[4] = total available BP
			pos = BPS.scanN + 1
			BPS.scanN = pos
			BPS.scanIDs[pos] = unitID
			BPS.scanPos[unitID] = pos
			BPS.unitTracking.trackedNum = pos
		end
		BPS.scanBP[pos] = buildSpeed
		BPS.scanKind[pos] = info.kind
		BPS.trackedBuilders[unitID] = {
			buildSpeed = buildSpeed,
			isBuilt = true,
			unitDefID = unitDefID,
			unitTeamID = unitTeam,
			unitType = info.unitType,
		}
	elseif BPS.windDefNames[unitDef.name] then -- wind generator
		if not BPS.trackedWinds[unitID] then
			BPS.trackedWinds[unitID] = 1
			BPS.numWindGenerators = BPS.numWindGenerators + 1
		end
	end
end

-- move the entry at position `from` to position `to` (arrays and index)
function BPS.scanMove(from, to)
	local ids = BPS.scanIDs
	local unitID = ids[from]
	ids[to] = unitID
	BPS.scanBP[to] = BPS.scanBP[from]
	BPS.scanKind[to] = BPS.scanKind[from]
	BPS.scanPos[unitID] = to
end

-- remove a builder from the scan arrays; every remaining builder is still scanned exactly once
-- in the current pass (positions below scanCursor stay the already scanned ones)
function BPS.scanRemove(unitID)
	local pos = BPS.scanPos[unitID]
	if not pos then
		return
	end
	local n = BPS.scanN
	local cursor = BPS.scanCursor
	if pos < cursor then -- already scanned: fill the hole with the last scanned one
		cursor = cursor - 1
		if pos ~= cursor then
			BPS.scanMove(cursor, pos)
		end
		pos = cursor
		BPS.scanCursor = cursor
	end
	if pos ~= n then -- fill the hole with the last one
		BPS.scanMove(n, pos)
	end
	BPS.scanIDs[n] = nil
	BPS.scanBP[n] = nil
	BPS.scanKind[n] = nil
	BPS.scanPos[unitID] = nil
	BPS.scanN = n - 1
	BPS.unitTracking.trackedNum = n - 1
end

function BPS.UntrackUnit(unitID, unitDefID, unitTeam) -- needed for exact calculations
	if myTeamID ~= unitTeam then
		return
	end
	local builder = BPS.trackedBuilders[unitID]
	if builder then
		BP[4] = BP[4] - builder.buildSpeed -- BP[4] = total available BP
		BPS.trackedBuilders[unitID] = nil
		BPS.scanRemove(unitID)
	end
	if BPS.trackedWinds[unitID] then
		BPS.trackedWinds[unitID] = nil
		BPS.numWindGenerators = BPS.numWindGenerators - 1
	end
end

function BPS.InitAdditionalValues()
	BP[4] = 0
	BPS.unitTracking.trackedNum = 0
	BPS.trackedBuilders = {}
	BPS.trackedWinds = {}
	BPS.numWindGenerators = 0
	BPS.scanIDs = {}
	BPS.scanBP = {}
	BPS.scanKind = {}
	BPS.scanPos = {}
	BPS.scanN = 0
	-- restart the builder scan on the new lists
	BPS.scanCursor = 1
	local cacheDataBase = BPS.cacheDataBase
	for k in pairs(cacheDataBase) do
		cacheDataBase[k] = 0
	end
	local units = sp.GetTeamUnits(myTeamID)
	if units then
		for i = 1, #units do
			local unitID = units[i]
			BPS.TrackUnit(unitID, sp.GetUnitDefID(unitID), myTeamID)
		end
	end
end

function BPS.updateBPValues()
	local cacheDataBase = BPS.cacheDataBase
	BP.reservedBP_instant = cacheDataBase.reservedBP_instant
	BP.usedBP_instant = cacheDataBase.usedBP_instant
	BP.usedBPMetalExpense = cacheDataBase.usedBPMetalExpense
	BP.usedBPEnergyExpense = cacheDataBase.usedBPEnergyExpense
	BP.usedBPExceptStalled = cacheDataBase.usedBPExceptStalled
	BP.usedBPIfNoStall = cacheDataBase.usedBPIfNoStall

	cacheDataBase.reservedBP_instant = 0
	cacheDataBase.usedBP_instant = 0
	cacheDataBase.usedBPMetalExpense = 0
	cacheDataBase.usedBPEnergyExpense = 0
	cacheDataBase.usedBPExceptStalled = 0
	cacheDataBase.usedBPIfNoStall = 0
end

function BPS.calculateAverages()
	local average = BPS.addValueAndGetWeightedAverage
	BP[3] = mathFloor(average(BP.history_reservedBP, BP.reservedBP_instant, 1) + 0.5)
	BP[5] = mathFloor(average(BP.history_usedBP, BP.usedBP_instant, 1) + 0.5)

	if BPC.drawBPWindRangeIndicators then
		BP.energyIncomeNoWind = r.energy[4] - BPS.numWindGenerators * BP.realWindStrength_instant
	end

	local bpRatioSupportedByMIncome = 1
	local bpRatioSupportedByEIncome = 1
	if BP.usedBP_instant >= 1 then
		local totalBP = BP[4]
		local m_per_bp = BP.metalExpensePerBP or 0
		local e_per_bp = BP.energyExpensePerBP or 0
		-- how much metal and energy are we spending _not_ due to builders?
		local metalExpenseMinusBuilders_instant = r.metal[5] - BP.usedBP_instant * m_per_bp
		local energyExpenseMinusBuilders_instant = r.energy[5] - BP.usedBP_instant * e_per_bp
		local metalExpenseMinusBuilders =
			average(BP.history_nonBuilderMetalExpense, metalExpenseMinusBuilders_instant, 1)
		local energyExpenseMinusBuilders =
			average(BP.history_nonBuilderEnergyExpense, energyExpenseMinusBuilders_instant, 1)

		BP.metalExpensePerBP = BP.usedBPMetalExpense / BP.usedBP_instant
		BP.energyExpensePerBP = BP.usedBPEnergyExpense / BP.usedBP_instant

		BP.metalExpenseIfAllBPUsed = metalExpenseMinusBuilders + BP.metalExpensePerBP * totalBP
		BP.energyExpenseIfAllBPUsed = energyExpenseMinusBuilders + BP.energyExpensePerBP * totalBP

		BP.metalSupportedBP = nil
		BP.energySupportedBP = nil
		-- (guards: no division by a zero or negative projected expense / total BP)
		if BP.metalExpensePerBP > 0 and BP.metalExpenseIfAllBPUsed > 0 and totalBP > 0 then
			BP.metalSupportedBP = r.metal[4] / BP.metalExpenseIfAllBPUsed * totalBP
			bpRatioSupportedByMIncome = mathMax(0, mathMin(BP.metalSupportedBP / totalBP, 1))
		end
		if BP.energyExpensePerBP > 0 and BP.energyExpenseIfAllBPUsed > 0 and totalBP > 0 then
			BP.energySupportedBP = r.energy[4] / BP.energyExpenseIfAllBPUsed * totalBP
			bpRatioSupportedByEIncome = mathMax(0, mathMin(BP.energySupportedBP / totalBP, 1))
		end

		if BPC.drawBPWindRangeIndicators then
			local energyIncome = r.energy[4] or select(4, sp.GetTeamResources(myTeamID, "energy"))
			local perAllBP = BP.energyExpensePerBP * BP[4]
			if perAllBP > 0 then
				local smoothing = 0.1 -- 0 = no movement, 1 = jump
				local windMin = (energyIncome - BPS.numWindGenerators * BP.realWindStrength_instant) / perAllBP
				local smoothedWindMin = BP.eSliderPosition_minWind + (windMin - BP.eSliderPosition_minWind) * smoothing
				BP.eSliderPosition_minWind = mathMin(1, mathMax(0, smoothedWindMin))
				local windMax = (energyIncome + BPS.numWindGenerators * (maxWind - BP.realWindStrength_instant))
					/ perAllBP
				local smoothedWindMax = BP.eSliderPosition_maxWind + (windMax - BP.eSliderPosition_maxWind) * smoothing
				BP.eSliderPosition_maxWind = mathMin(1, mathMax(0, smoothedWindMax))
			end
		end
	end

	BP.mSliderPosition = average(BP.history_mSliderPosition, bpRatioSupportedByMIncome, BP.usedBP_instant)
	BP.eSliderPosition = average(BP.history_eSliderPosition, bpRatioSupportedByEIncome, BP.usedBP_instant)
end

-- builder scan: walks the scan arrays by index, unitsPerFrame builders per game frame, one full pass
-- every frameCheckInterval frames (0.4.010 timing). Per builder: one command count call (idle
-- builders stop there), then GetUnitWorkerTask for the buildee and GetUnitResources only while
-- building. Same sums as the 0.4.010 scan (GetUnitIsBuilding + GetUnitDefID of the buildee).
function BPS.GameFrame(n)
	local unitTracking = BPS.unitTracking
	if n < unitTracking.nextCheckFrame then
		return
	end

	local unitCostData = BPS.unitCostData
	local cacheTotalReservedBP = 0
	local cacheTotallyUsedBP = 0
	local usedBPMetalExpense = 0
	local usedBPEnergyExpense = 0
	local buildingBP = 0 -- how much BP is actively building, regardless of how stalled it is?
	local nonStalledBuildingBP = 0 -- how much BP is actively building and not stalled?

	local ids, bps, kinds = BPS.scanIDs, BPS.scanBP, BPS.scanKind
	local getUnitCommandCount, getFactoryCommandCount = sp.GetUnitCommandCount, sp.GetFactoryCommandCount
	local getUnitResources, getUnitDefID = sp.GetUnitResources, sp.GetUnitDefID
	local getWorkerTask, CMD_REPAIR, CMD_FIGHT = BPS.getWorkerTask, BPS.CMD_REPAIR, BPS.CMD_FIGHT
	local cursor = BPS.scanCursor
	local finished = false

	for _ = 1, unitTracking.unitsPerFrame do
		local pos = cursor
		if pos > BPS.scanN then
			finished = true -- pass finished
			break
		end
		local unitID = ids[pos]
		cursor = pos + 1
		local kind = kinds[pos]
		local numCommands
		if kind ~= 3 then
			numCommands = getUnitCommandCount(unitID)
		else
			numCommands = getFactoryCommandCount(unitID)
		end
		if numCommands == nil then -- no answer: gone (or not readable, then idle as before)
			if not sp.ValidUnitID(unitID) then
				local builder = BPS.trackedBuilders[unitID]
				BPS.scanCursor = cursor
				BPS.UntrackUnit(unitID, builder.unitDefID, builder.unitTeamID)
				cursor = BPS.scanCursor
			end
		elseif
			numCommands > 0
			-- a nano turret whose only order is its default fight/patrol order is idle
			and not (kind == 2 and numCommands == 1 and sp.GetUnitCurrentCommand(unitID) == CMD_FIGHT)
		then
			local currentUnitBP = bps[pos]
			cacheTotalReservedBP = cacheTotalReservedBP + currentUnitBP
			local builtUnitDefID
			if getWorkerTask then
				-- build or assist: -unitDefID of the buildee; repair of a finished unit: CMD.REPAIR
				-- (both are GetUnitIsBuilding's curBuild); reclaim/capture/resurrect/restore: not building
				local cmdID, targetID = getWorkerTask(unitID)
				if cmdID then
					if cmdID < 0 then
						builtUnitDefID = -cmdID
					elseif cmdID == CMD_REPAIR then
						builtUnitDefID = getUnitDefID(targetID)
					end
				end
			else
				local builtUnitID = sp.GetUnitIsBuilding(unitID)
				builtUnitDefID = builtUnitID and getUnitDefID(builtUnitID)
			end
			local cost = builtUnitDefID and unitCostData[builtUnitDefID]
			if cost then
				local _, currentlyUsedM, _, currentlyUsedE = getUnitResources(unitID)
				currentlyUsedM = currentlyUsedM or 0
				currentlyUsedE = currentlyUsedE or 0
				usedBPMetalExpense = usedBPMetalExpense + currentlyUsedM
				usedBPEnergyExpense = usedBPEnergyExpense + currentlyUsedE

				local MperBP = cost.MperBP
				local currentlyUsedBP = MperBP > 0 and currentlyUsedM / MperBP or nil
				buildingBP = buildingBP + currentUnitBP

				local currentlyWantedM = MperBP * currentUnitBP
				local currentlyWantedE = cost.EperBP * currentUnitBP
				-- low-priority units don't have their pulled M/E reported correctly
				local nonStalledRateM = 1
				local nonStalledRateE = 1
				if currentlyWantedM > 0 then
					nonStalledRateM = currentlyUsedM / currentlyWantedM
				end
				if currentlyWantedE > 0 then
					nonStalledRateE = currentlyUsedE / currentlyWantedE
				end
				nonStalledBuildingBP = nonStalledBuildingBP + currentUnitBP * mathMin(nonStalledRateM, nonStalledRateE)

				if currentlyUsedBP and currentlyUsedBP >= 0 then
					cacheTotallyUsedBP = cacheTotallyUsedBP + currentlyUsedBP
				end
			end
		end
	end
	BPS.scanCursor = cursor

	local cacheDataBase = BPS.cacheDataBase
	cacheDataBase.reservedBP_instant = cacheDataBase.reservedBP_instant + cacheTotalReservedBP
	cacheDataBase.usedBP_instant = cacheDataBase.usedBP_instant + cacheTotallyUsedBP
	-- how much metal and energy are builders pulling? (drops when they are resource-stalled)
	cacheDataBase.usedBPMetalExpense = cacheDataBase.usedBPMetalExpense + usedBPMetalExpense
	cacheDataBase.usedBPEnergyExpense = cacheDataBase.usedBPEnergyExpense + usedBPEnergyExpense
	cacheDataBase.usedBPExceptStalled = cacheDataBase.usedBPExceptStalled + nonStalledBuildingBP
	cacheDataBase.usedBPIfNoStall = cacheDataBase.usedBPIfNoStall + buildingBP

	if finished then
		local totalUnits = BPS.scanN
		unitTracking.totalUnits = totalUnits
		-- at least 1, otherwise a pass over an empty list never starts (and never finishes) again
		unitTracking.unitsPerFrame = mathMax(
			1,
			mathMin(unitTracking.maxUnitsPerFrame, mathCeil(totalUnits / unitTracking.frameCheckInterval))
		)
		unitTracking.nextCheckFrame = n + unitTracking.frameCheckInterval
		BPS.scanCursor = 1 -- the next pass starts from the first builder
		BPS.updateBPValues()
	end

	if BPC.drawBPWindRangeIndicators then
		local realWindStrength = 0
		for unitID in pairs(BPS.trackedWinds) do
			local _, _, energyMake = sp.GetUnitResources(unitID)
			if energyMake ~= nil then
				realWindStrength = energyMake
				break
			end
		end
		BP.realWindStrength_instant = realWindStrength
	end
	BPS.calculateAverages()
end

--------------------------------------------------------------------------------
-- Buildpower options (WG.options.addOptions / removeOptions, listed under this widget)
--------------------------------------------------------------------------------

function BPS.setOption(key, value)
	BPC[key] = value and true or false
	-- drawBPBar only takes effect after a reload (BPS.on is read in Initialize)
	BPS.ind.dirty = true
	BPS.tt.dirty = true
	gl4.ts.fastDirty = true
end

-- (re)registers whenever WG.options appears or is replaced (options widget reloaded)
function BPS.registerOptions()
	local api = WG.options
	if api == BPS.optionsApi then
		return
	end
	BPS.optionsApi = api
	if not api or not api.addOptions then
		return
	end
	local widgetName = widget:GetInfo().name
	local list = {}
	local specs = BPS.optionSpecs
	for i = 1, #specs do
		local optionSpec = specs[i]
		local key = optionSpec.key
		list[i] = {
			id = "top_bar_bp_" .. key,
			name = optionSpec.name,
			description = optionSpec.description,
			type = "bool",
			value = BPC[key],
			widgetname = widgetName,
			onchange = function(_, value)
				BPS.setOption(key, value)
			end,
		}
	end
	api.addOptions(list)
end

function BPS.unregisterOptions()
	local api = WG.options
	if api and api.removeOptions and api == BPS.optionsApi then
		local ids = {}
		local specs = BPS.optionSpecs
		for i = 1, #specs do
			ids[i] = "top_bar_bp_" .. specs[i].key
		end
		api.removeOptions(ids)
	end
	BPS.optionsApi = nil
end

function init()
	refreshUi = true

	r = { metal = { sp.GetTeamResources(myTeamID, "metal") }, energy = { sp.GetTeamResources(myTeamID, "energy") } }
	topbarArea =
		{ mathFloor(xPos + (cfg.borderPadding * widgetScale)), mathFloor(vsy - (height * widgetScale)), vsx, vsy }

	local filledWidth = 0
	local totalWidth = topbarArea[3] - topbarArea[1]

	-- metal
	local width = mathFloor(totalWidth / 4.4)
	local bpWidth = 0
	if BPS.on then
		width, bpWidth = BPS.layoutWidths(totalWidth, width)
	end
	resbarArea.metal =
		{ topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
	filledWidth = filledWidth + width + widgetSpaceMargin
	updateResbar("metal")

	-- buildpower (between metal and energy, as in 0.4.010)
	if BPS.on then
		resbarArea.BP =
			{ topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + bpWidth, topbarArea[4] }
		filledWidth = filledWidth + bpWidth + widgetSpaceMargin
		updateResbar("BP")
	end

	--energy
	resbarArea.energy =
		{ topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
	filledWidth = filledWidth + width + widgetSpaceMargin
	updateResbar("energy")

	-- wind
	width = mathFloor((height * 1.18) * widgetScale)
	-- Small elements (wind, tidal, coms, buttons) — height fraction from cfg, top-aligned, when skew is on.
	skewTan = math.tan(math.rad(cfg.skewAngleDeg)) -- refresh in case cfg changed
	local smallVPad = cfg.useSkew and mathFloor((topbarArea[4] - topbarArea[2]) * (1 - cfg.smallElementHeightFraction))
		or 0
	windArea =
		{ topbarArea[1] + filledWidth, topbarArea[2] + smallVPad, topbarArea[1] + filledWidth + width, topbarArea[4] }
	filledWidth = filledWidth + width + widgetSpaceMargin
	updateWind()

	-- tidal
	if displayTidalSpeed then
		if not checkTidalRelevant() then
			displayTidalSpeed = false
		else
			width = mathFloor((height * 1.18) * widgetScale)
			tidalarea = {
				topbarArea[1] + filledWidth,
				topbarArea[2] + smallVPad,
				topbarArea[1] + filledWidth + width,
				topbarArea[4],
			}
			filledWidth = filledWidth + width + widgetSpaceMargin
			updateTidal()
		end
	end

	-- coms
	if displayComCounter then
		comsArea = {
			topbarArea[1] + filledWidth,
			topbarArea[2] + smallVPad,
			topbarArea[1] + filledWidth + width,
			topbarArea[4],
		}
		filledWidth = filledWidth + width + widgetSpaceMargin
		updateComs()
	end

	-- the button strip is drawn by the Top Bar Buttons widget; this is the width it
	-- reserves on the right, which GetFreeArea and GetPosition below report
	width = mathFloor(totalWidth / 4)
	local buttonsBottom = topbarArea[2] + smallVPad

	if WG.topbar then
		WG.topbar.GetPosition = function()
			local leftSkewOffset = cfg.useSkew and mathFloor((topbarArea[4] - topbarArea[2]) * skewTan) or 0
			return {
				topbarArea[1] + leftSkewOffset + widgetSpaceMargin,
				topbarArea[2],
				topbarArea[3],
				topbarArea[4],
				widgetScale,
				buttonsBottom,
			}
		end

		WG.topbar.GetFreeArea = function()
			return {
				topbarArea[1] + filledWidth,
				topbarArea[2],
				topbarArea[3] - width - widgetSpaceMargin,
				topbarArea[4],
				widgetScale,
			}
		end
		WG.topbar.GetSkewConfig = function()
			return {
				useSkew = cfg.useSkew,
				skewTan = skewTan,
				smallElementHeightFraction = cfg.smallElementHeightFraction,
			}
		end
	end

	updateResbarText("metal", true)
	updateResbarText("energy", true)
	if BPS.on then
		updateResbarText("BP", true)
	end

	updateRes =
		{ metal = { true, true, true, true }, energy = { true, true, true, true }, BP = { true, true, true, true } }
	gl4.ts.fastDirty = true
end

local function checkSelfStatus()
	myAllyTeamID = sp.GetMyAllyTeamID()
	myAllyTeamList = sp.GetTeamList(myAllyTeamID)
	myTeamID = sp.GetMyTeamID()

	local startUnit = sp.GetTeamRulesParam(myTeamID, "startUnit")
	if myTeamID ~= gaiaTeamID and UnitDefs[startUnit] then
		textures.com = ":n:Icons/" .. UnitDefs[startUnit].name .. ".png"
	end
end

local function countComs(forceUpdate)
	-- recount my own ally team coms
	local prevAllyComs = allyComs
	local prevEnemyComs = enemyComs
	allyComs = 0

	local myAllyTeamListLen = #myAllyTeamList
	local commanderUnitDefIDsLen = #commanderUnitDefIDs
	for i = 1, myAllyTeamListLen do
		local teamID = myAllyTeamList[i]
		for j = 1, commanderUnitDefIDsLen do
			local unitDefID = commanderUnitDefIDs[j]
			allyComs = allyComs + sp.GetTeamUnitDefCount(teamID, unitDefID)
		end
	end

	local newEnemyComCount = sp.GetTeamRulesParam(myTeamID, "enemyComCount")
	if type(newEnemyComCount) == "number" then
		enemyComCount = newEnemyComCount
		if enemyComCount ~= prevEnemyComCount then
			comcountChanged = true
			prevEnemyComCount = enemyComCount
		end
	end

	if forceUpdate or allyComs ~= prevAllyComs or enemyComs ~= prevEnemyComs then
		comcountChanged = true
	end

	if comcountChanged then
		updateComs()
	end
end

function widget:GameStart()
	checkSelfStatus()
	if BPS.on then
		BPS.InitAdditionalValues()
	end
	if displayComCounter then
		countComs(true)
	end
	init()
end

function widget:GameFrame(n)
	spec = sp.GetSpectatingState()
	gameFrame = n
	timers.gameFrameHappened = true
	if n == 2 then
		init()
	end
	if BPS.on then
		BPS.GameFrame(n)
	end
	gl4.onGameFrame()
end

local function updateAllyTeamOverflowing()
	allyteamOverflowingMetal = false
	allyteamOverflowingEnergy = false
	overflowingMetal = false
	overflowingEnergy = false
	local totalEnergy = 0
	local totalEnergyStorage = 0
	local totalMetal = 0
	local totalMetalStorage = 0
	local energyPercentile, metalPercentile
	local teams = myAllyTeamList -- (kept current by checkSelfStatus; GetTeamList allocates a new table)
	local teamsLen = #teams

	for i = 1, teamsLen do
		local teamID = teams[i]
		local energy, energyStorage, _, _, _, energyShare, energySent = sp.GetTeamResources(teamID, "energy")
		totalEnergy = totalEnergy + energy
		totalEnergyStorage = totalEnergyStorage + energyStorage
		local metal, metalStorage, _, _, _, metalShare, metalSent = sp.GetTeamResources(teamID, "metal")
		totalMetal = totalMetal + metal
		totalMetalStorage = totalMetalStorage + metalStorage
		if teamID == myTeamID then
			energyPercentile = energySent / totalEnergyStorage
			metalPercentile = metalSent / totalMetalStorage

			if energyPercentile > 0.0001 then
				overflowingEnergy = energyPercentile * 40 -- (1 / 0.025) = 40
				if overflowingEnergy > 1 then
					overflowingEnergy = 1
				end
			end

			if metalPercentile > 0.0001 then
				overflowingMetal = metalPercentile * 40 -- (1 / 0.025) = 40
				if overflowingMetal > 1 then
					overflowingMetal = 1
				end
			end
		end
	end

	energyPercentile = totalEnergy / totalEnergyStorage
	metalPercentile = totalMetal / totalMetalStorage

	if energyPercentile > 0.975 then
		allyteamOverflowingEnergy = (energyPercentile - 0.975) * 40 -- (1 / 0.025) = 40
		if allyteamOverflowingEnergy > 1 then
			allyteamOverflowingEnergy = 1
		end
	end

	if metalPercentile > 0.975 then
		allyteamOverflowingMetal = (metalPercentile - 0.975) * 40 -- (1 / 0.025) = 40
		if allyteamOverflowingMetal > 1 then
			allyteamOverflowingMetal = 1
		end
	end
end

local function hoveringElement(x, y)
	if
		resbarArea.metal[1]
		and mathIsInRect(x, y, resbarArea.metal[1], resbarArea.metal[2], resbarArea.metal[3], resbarArea.metal[4])
	then
		return "metal"
	end
	if
		resbarArea.energy[1]
		and mathIsInRect(x, y, resbarArea.energy[1], resbarArea.energy[2], resbarArea.energy[3], resbarArea.energy[4])
	then
		return "energy"
	end
	if
		BPS.on
		and resbarArea.BP[1]
		and mathIsInRect(x, y, resbarArea.BP[1], resbarArea.BP[2], resbarArea.BP[3], resbarArea.BP[4])
	then
		return "BP"
	end
	if windArea[1] and mathIsInRect(x, y, windArea[1], windArea[2], windArea[3], windArea[4]) then
		return "wind"
	end
	if
		displayTidalSpeed
		and tidalarea[1]
		and mathIsInRect(x, y, tidalarea[1], tidalarea[2], tidalarea[3], tidalarea[4])
	then
		return "tidal"
	end
	if displayComCounter and comsArea[1] and mathIsInRect(x, y, comsArea[1], comsArea[2], comsArea[3], comsArea[4]) then
		return "com"
	end
	return false
end

-- WG.topbar is shared with the Top Bar Buttons widget. Consumers guard on the table,
-- not on the individual functions, so when that widget is not running its half of the
-- API has to answer "there are no buttons" rather than be missing. Checked from the one-shot
-- Update (after every widget's Initialize) and from every gl4.tick (if it is disabled mid-game).
local fallback = {}

local function provide(name, fn)
	local current = WG.topbar[name]
	if current == nil then
		fallback[name] = fn
		WG.topbar[name] = fn
	elseif fallback[name] ~= nil and current ~= fallback[name] then
		fallback[name] = nil -- the buttons widget took over
	end
end

local function returnNil() end
local function returnFalse()
	return false
end

local function provideButtonFallbacks()
	if not WG.topbar then
		return
	end
	provide("showingQuit", returnNil)
	provide("hideWindows", returnNil)
	provide("buttonAt", returnNil)
	provide("GetButtonsPosition", returnNil)
	provide("setAutoHideButtons", returnNil)
	provide("getAutoHideButtons", returnFalse)
	provide("getShowButtons", returnFalse)
end

local function removeButtonFallbacks()
	if not WG.topbar then
		return
	end
	for name, fn in pairs(fallback) do
		if WG.topbar[name] == fn then
			WG.topbar[name] = nil
		end
	end
end

-- copies the 8 resource values of src into dst (metal and energy), keeps the tables
function gl4.copyRes(dst, src)
	local dm, de, sm, se = dst.metal, dst.energy, src.metal, src.energy
	for i = 1, 8 do
		dm[i] = sm[i]
		de[i] = se[i]
	end
end

-- hovered element at x, y (was computed from Spring.GetMouseState in widget:Update)
function gl4.setHover(x, y)
	mx, my = x, y
	hoveringTopbar = false
	if topbarArea[1] and x > topbarArea[1] and y > topbarArea[2] then -- checking if the cursor is high enough, too
		hoveringTopbar = hoveringElement(x, y)
	end
end

-- resource read (was the 4 Hz nextSlowUpdate block of widget:Update): runs inside the 10 Hz slow tick every
-- gl4.READ_INTERVAL (0.25 s, as before). Reads in place; pull / income / expense / sent only change at the
-- engine's team slow update (every TEAM_SLOWUPDATE_RATE = 30 sim frames), so their texts are re-formatted
-- only when one of those numbers changed (updateResbarText compares them)
function gl4.slowTick()
	local rm, re = r.metal, r.energy
	local prevM7, prevM8, prevE7, prevE8 = rm[7], rm[8], re[7], re[8]
	rm[1], rm[2], rm[3], rm[4], rm[5], rm[6], rm[7], rm[8] = sp.GetTeamResources(myTeamID, "metal")
	re[1], re[2], re[3], re[4], re[5], re[6], re[7], re[8] = sp.GetTeamResources(myTeamID, "energy")
	-- check if we need to smooth the resources
	local metalDiff7 = rm[7] - prevM7
	local metalDiff8 = rm[8] - prevM8
	local energyDiff7 = re[7] - prevE7
	local energyDiff8 = re[8] - prevE8
	local metalStorage = rm[2]
	local energyStorage = re[2]

	if
		(rm[7] > 1 and metalDiff7 ~= 0 and rm[7] / metalStorage > 0.05)
		or (rm[8] > 1 and metalDiff8 ~= 0 and rm[8] / metalStorage > 0.05)
		or (re[7] > 1 and energyDiff7 ~= 0 and re[7] / energyStorage > 0.05)
		or (re[8] > 1 and energyDiff8 ~= 0 and re[8] / energyStorage > 0.05)
	then
		gl4.copyRes(smoothedResources, r) -- (0.5.001: smoothedResources = r, an alias until the next read)
	end

	-- buildpower: stalling, alerts, tooltip (at the read cadence; the stall flags move the BP markers)
	if BPS.on then
		local sm, se = BPS.playerStallingMetal, BPS.playerStallingEnergy
		BPS.slowUpdate()
		if sm ~= BPS.playerStallingMetal or se ~= BPS.playerStallingEnergy then
			gl4.ts.fastDirty = true
		end
	end

	-- resbar values and overflow
	updateAllyTeamOverflowing()
	updateResbarText("metal")
	updateResbarText("energy")

	-- wind (text only formatted, and its glyphs only written, when the wind changed)
	local wind = select(4, sp.GetWind())
	if wind ~= gl4.lastWindNum then
		gl4.lastWindNum = wind
		currentWind = stringFormat("%.1f", wind)
		local text = "\255\255\255\255" .. currentWind
		if text ~= currentWindText then
			currentWindText = text
			gl4.text.setStr(gl4.text.byName.wind_current, text)
		end
		-- blades: degrees per second, as 0.5.002 turned them (wind * bladeSpeedMultiplier * 30 per second)
		gl4.setWindSpeed((tonumber(currentWind) or 0) * cfg.bladeSpeedMultiplier * 30)
	end

	-- coms (counts are only rewritten when they changed, see countComs / updateComs)
	if displayComCounter then
		countComs()
	end
end

-- hovered bar -> bigger slider knobs (was part of the 30 Hz tick; acts only on changes). Called by the fast tick
-- when hoveringTopbar changed and by every slow tick (catches a quit screen that closed in between)
function gl4.applyHover()
	gl4.ts.hoverApplied = hoveringTopbar
	if spec or showingQuitscreen() then
		return
	end
	if hoveringTopbar == "energy" then
		if not resbarHover then
			resbarHover = "energy"
			updateResbar("energy")
		end
	elseif resbarHover and resbarHover == "energy" then
		resbarHover = nil
		updateResbar("energy")
	end
	if hoveringTopbar == "metal" then
		if not resbarHover then
			resbarHover = "metal"
			updateResbar("metal")
		end
	elseif resbarHover and resbarHover == "metal" then
		resbarHover = nil
		updateResbar("metal")
	end
end

-- make sure conversion/overflow sliders are adjusted (spectating or quit screen up, as before)
function gl4.syncSliders()
	if mmLevel then
		local currentMmLevel = sp.GetTeamRulesParam(myTeamID, "mmLevel")
		if mmLevel ~= currentMmLevel or energyOverflowLevel ~= r.energy[6] then
			mmLevel = currentMmLevel
			updateResbar("energy")
		end
		if metalOverflowLevel ~= r.metal[6] then
			updateResbar("metal")
		end
	end
end

-- The slow tick (0.5.005: 10 Hz, gl4.SLOW_TICK; was the 30 Hz tick): Top Bar Buttons fallbacks, spectator
-- team switch, hover re-poll, guishader check, slider sync, resource read (every READ_INTERVAL), smoothing,
-- current value texts, flash states, options check (1 Hz), BP tooltip on hover start, changed bar texts.
-- Runs from widget:GameFrame and, while no game frame arrives (paused, pre-game), from DrawScreen.
-- The fill widths are the fast tick (gl4.fastTick, 20 Hz bars timer in drawResBars); the flash pulse and the
-- commander icon blink are computed by the shader (no per-tick blink integration any more).
function gl4.tick()
	now = osClock()
	local ts = gl4.ts
	ts.lastTick = now
	local nextTick = ts.nextTick + gl4.SLOW_TICK
	if nextTick < now then
		nextTick = now + gl4.SLOW_TICK -- no catching up
	end
	ts.nextTick = nextTick

	provideButtonFallbacks()

	-- (was the 30 Hz nextStateCheck block)
	local prevMyTeamID = myTeamID
	local newMyTeamID = sp.GetMyTeamID()
	if spec and newMyTeamID ~= prevMyTeamID then
		-- check if the team that we are spectating changed
		myTeamID = newMyTeamID
		checkSelfStatus()
		if BPS.on then
			BPS.InitAdditionalValues()
		end
		init()
	end

	-- hover comes from widget:IsAbove; poll the mouse only while the handler has not called it recently
	-- (e.g. a widget before this one in the IsAbove list claims the mouse)
	if now - ts.lastHover > 0.25 then
		local x, y = sp.GetMouseState()
		gl4.setHover(x, y)
	end

	if now > timers.nextGuishaderCheck then
		timers.nextGuishaderCheck = now + timers.guishaderCheckUpdateRate
		local guishaderActive = WG.guishader ~= nil
		if guishaderActive and not guishaderEnabled then
			guishaderEnabled = guishaderActive
			init()
		elseif not guishaderActive and guishaderEnabled then
			guishaderEnabled = guishaderActive
		end
	end

	-- (was the 20 Hz nextResBarUpdate block, every 30 Hz tick in 0.5.004; it only acts on changes)
	if not spec and not showingQuitscreen() then
		gl4.applyHover()
	elseif spec then
		newMyTeamID = sp.GetMyTeamID()
		if newMyTeamID ~= myTeamID then
			-- check if the team that we are spectating changed
			myTeamID = newMyTeamID
			draggingShareIndicatorValue = {}
			draggingConversionIndicatorValue = nil
			updateResbar("metal")
			updateResbar("energy")
		else
			gl4.syncSliders()
		end
	else
		gl4.syncSliders()
	end

	-- resource read every READ_INTERVAL (0.25 s: every 2nd / 3rd slow tick, 4 per second on average)
	if now >= ts.nextRead - 0.04 then
		local nextRead = ts.nextRead + gl4.READ_INTERVAL
		if nextRead < now then
			nextRead = now + gl4.READ_INTERVAL
		end
		ts.nextRead = nextRead
		gl4.slowTick()
	end

	-- smoothing (every slow tick; factor scaled so the bars converge as fast as with 0.5 at ~15 Hz)
	if smoothResources() then
		ts.fastDirty = true -- the fill widths follow the smoothed values
	end
	gl4.valueText("metal")
	gl4.valueText("energy")

	-- GL4: flash / tint states (mode + intensity; written only when they change, the shader pulses them)
	gl4.updateFlashes()

	-- options: re-registered only when WG.options was replaced (identity check, 1 Hz)
	if now >= ts.nextOptions then
		ts.nextOptions = now + gl4.OPTIONS_INTERVAL
		BPS.registerOptions()
	end

	-- BP tooltip: re-checked at once when the mouse arrives on the BP panel (otherwise at most 1 Hz)
	if BPS.on then
		local tt = BPS.tt
		local hoverBP = hoveringTopbar == "BP"
		if hoverBP ~= tt.hover then
			tt.hover = hoverBP
			if hoverBP then
				BPS.updateTooltip(false)
			end
		end
	end

	-- changed bar texts -> glyph instances (storage hidden with the banner in the same tick)
	gl4.text.barTexts()
end

-- from widget:GameFrame: the slow tick on its 10 Hz schedule (every 3rd game frame at normal speed)
function gl4.onGameFrame()
	local t = osClock()
	local ts = gl4.ts
	ts.lastGameFrame = t
	if t >= ts.nextTick - 0.005 then
		gl4.tick()
	end
end

-- top of DrawScreen: the per-frame bookkeeping of widget:Update, plus the slow tick while the game does not
-- advance (paused or not started): when no game frame came for 0.1 s, tick on the same 10 Hz schedule
function gl4.frameStart()
	local t = osClock()
	now = t
	timers.deferResourceUpdate = timers.gameFrameHappened and t - timers.lastUpdateTime < (1 / 30)
	timers.gameFrameHappened = false
	timers.lastUpdateTime = t

	-- (0.5.003: the wind blade angle is advanced in the shader, see gl4.setWindSpeed)

	local ts = gl4.ts
	if t - ts.lastGameFrame > 0.1 and t >= ts.nextTick - 0.005 then
		gl4.tick()
	end
end

-- Instances of the non-bar groups (0.5.003): uiBgTex / uiTex blits over the top bar area, the wind blades
-- (was dlist.wind1 / wind2 + glRotate) and the tidal waves (was dlist.tidal2 + glTranslate). Same geometry,
-- color (1, 1, 1, 0.2) and visibility conditions as the lists. Called in DrawScreen on refreshUi.
function gl4.layoutUi()
	local K = gl4.K
	local x, y = topbarArea[1], topbarArea[2]
	local w, h = topbarArea[3] - topbarArea[1], topbarArea[4] - topbarArea[2]
	local key = K.bg.blit
	gl4.setRect(key, x, y, w, h)
	gl4.setShape(key, 0, 0, 0)
	gl4.setColor(key, 1, 1, 1, 1)
	gl4.setTex(key, gl4.TEX_UIBG, 0, false)
	gl4.setVisible(key, uiBgTex ~= nil)
	key = K.ui.blit
	gl4.setRect(key, x, y, w, h)
	gl4.setShape(key, 0, 0, 0)
	gl4.setColor(key, 1, 1, 1, 1)
	gl4.setTex(key, gl4.TEX_UI, 0, false)
	gl4.setVisible(key, uiTex ~= nil)

	-- wind blades: square of 2 * bladesSize around the (skew corrected) center, rotated in the shader;
	-- the instance rect is the bounding box of the square in any rotation (side * sqrt 2)
	key = K.wind.blades
	local area = windArea
	local show = cache.showIndicators and area[1] ~= nil
	if show then
		local areaH = area[4] - area[2]
		local cx = area[1] + ((area[3] - area[1]) / 2) - (cfg.useSkew and areaH * skewTan * 0.5 or 0)
		local cy = area[2] + (bgpadding / 2) + (areaH / 2)
		local half = areaH * 0.57 * 1.41421356
		gl4.setRect(key, cx - half, cy - half, half + half, half + half)
		gl4.setShape(key, 0, 0, 0)
		gl4.setColor(key, 1, 1, 1, 0.2)
		gl4.setFillMode(key, gl4.FILL_NONE)
		gl4.setTex(key, gl4.TEX_BLADES, 0, false)
	end
	gl4.setVisible(key, show)

	-- tidal waves: square of 2 * wavesSize around the center; the shader adds the sine bob
	key = K.tidal.waves
	area = tidalarea
	show = cache.showIndicators and displayTidalSpeed and area[1] ~= nil
	if show then
		local areaH = area[4] - area[2]
		local cx = area[1] + ((area[3] - area[1]) / 2) - (cfg.useSkew and areaH * skewTan * 0.5 or 0)
		local cy = area[2] + (bgpadding / 2) + (areaH / 2)
		local ws = areaH * 0.59
		gl4.setRect(key, cx - ws, cy - ws, ws + ws, ws + ws)
		gl4.setShape(key, 0, 0, 0)
		gl4.setColor(key, 1, 1, 1, 0.2)
		gl4.setFillMode(key, gl4.FILL_NONE)
		gl4.setInst(key, 18, tidalWaveAnimationHeight) -- bob amplitude (px)
		gl4.setTex(key, gl4.TEX_WAVES, 0, false)
	end
	gl4.setVisible(key, show)
end

-- wind blade rotation speed (deg/s). The shader turns the blades by phase + speed * (T - T0) with T the
-- game time in seconds (timeInfo.x + timeInfo.w) / 30; on a speed change the current angle becomes the
-- new phase, so the blades do not jump. Instance fields: [18] phase (deg), [19] speed, [24] T0.
function gl4.setWindSpeed(speed)
	local key = gl4.K.wind.blades
	local t = gl4.templates[key]
	if not t or t[19] == speed then
		return
	end
	local T = (sp.GetGameFrame() + ((sp.GetFrameTimeOffset and sp.GetFrameTimeOffset()) or 0)) / 30
	gl4.setInst(key, 18, (t[18] + t[19] * (T - t[24])) % 360)
	gl4.setInst(key, 19, speed)
	gl4.setInst(key, 24, T)
end

-- Runs once, in the first frame after Initialize (after every widget's Initialize, like the old per-frame
-- Update did for the Top Bar Buttons fallbacks), then removes the Update call-in for good.
-- barwidgets.lua: the restricted handler of a user widget has RemoveCallIn(name) -> RemoveWidgetCallIn(name,
-- widget); the full handler (game widget with handler = true) has RemoveWidgetCallIn(name, w). Both are
-- queued and applied after the Update loop (the Raw versions would change the list while it is iterated).
-- (widgetHandler:UpdateCallIn("Update") of the full handler returns early for "Update": not usable here.)
-- widget.Update = nil keeps Raise/LowerWidget and UpdateWidgetCallIn from adding it back.
function widget:Update()
	gl4.tick()
	local wh = widgetHandler
	if wh.RemoveWidgetCallIn then
		widget.Update = nil
		wh:RemoveWidgetCallIn("Update", widget)
	elseif wh.RemoveCallIn then
		widget.Update = nil
		wh:RemoveCallIn("Update")
	elseif wh.UpdateCallIn then
		widget.Update = nil
		wh:UpdateCallIn("Update") -- restricted handler: UpdateWidgetCallIn, removes it as Update is nil
	end
	-- (no handler API: Update stays registered and ticks every frame, as before)
end

local function drawResBars()
	-- (no matrix push/pop needed: nothing in here touches the modelview matrix)
	local update = false

	if
		showResourceBars
		and now > timers.nextBarsUpdate
		and (not timers.deferResourceUpdate or now > timers.nextForcedBarsUpdate)
	then
		timers.nextBarsUpdate = now + 0.05
		timers.nextForcedBarsUpdate = now + 0.03
		update = true
	end

	-- 0.5.005: the fast tick (fill widths, drag, hover; idle while the sim does not advance)
	if update then
		update = gl4.fastTick()
	end

	-- texts: atlas on refreshUi, changed strings -> glyph instances (no render-to-texture);
	-- drawn with everything else by gl4.drawChecked at the end of DrawScreen
	gl4.text.frame(update)
end


local function drawUiBackground()
	if showResourceBars then
		if resbarArea.energy[1] then
			local energySkew = cfg.useSkew and { brx = -((resbarArea.energy[4] - resbarArea.energy[2]) * skewTan) }
				or nil
			UiElement(
				resbarArea.energy[1],
				resbarArea.energy[2],
				resbarArea.energy[3],
				resbarArea.energy[4],
				0,
				0,
				1,
				1,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				energySkew
			)
		end
		if resbarArea.metal[1] then
			local metalSkew = cfg.useSkew and { blx = (resbarArea.metal[4] - resbarArea.metal[2]) * skewTan } or nil
			UiElement(
				resbarArea.metal[1],
				resbarArea.metal[2],
				resbarArea.metal[3],
				resbarArea.metal[4],
				0,
				0,
				1,
				1,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				metalSkew
			)
		end
		if BPS.on and resbarArea.BP[1] then
			-- plain rectangle: metal's right edge and energy's left edge are vertical
			UiElement(
				resbarArea.BP[1],
				resbarArea.BP[2],
				resbarArea.BP[3],
				resbarArea.BP[4],
				0,
				0,
				1,
				1,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil,
				nil
			)
		end
	end
	if cache.showIndicators and comsArea[1] then
		local H = comsArea[4] - comsArea[2]
		local smallSkew = cfg.useSkew and { blx = -(H * skewTan), brx = -(H * skewTan) } or nil
		UiElement(
			comsArea[1],
			comsArea[2],
			comsArea[3],
			comsArea[4],
			0,
			0,
			1,
			1,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			smallSkew
		)
	end
	if cache.showIndicators and windArea[1] then
		local H = windArea[4] - windArea[2]
		local smallSkew = cfg.useSkew and { blx = -(H * skewTan), brx = -(H * skewTan) } or nil
		UiElement(
			windArea[1],
			windArea[2],
			windArea[3],
			windArea[4],
			0,
			0,
			1,
			1,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			smallSkew
		)
	end
	if cache.showIndicators and displayTidalSpeed and tidalarea[1] then
		local H = tidalarea[4] - tidalarea[2]
		local smallSkew = cfg.useSkew and { blx = -(H * skewTan), brx = -(H * skewTan) } or nil
		UiElement(
			tidalarea[1],
			tidalarea[2],
			tidalarea[3],
			tidalarea[4],
			0,
			0,
			1,
			1,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			nil,
			smallSkew
		)
	end
end

local function drawUi()
	if showResourceBars and dlist.resbar.energy and dlist.resbar.energy[1] then
		glCallList(dlist.resbar.energy[1])
		glCallList(dlist.resbar.metal[1])
		if dlist.resbar.BP[1] then
			glCallList(dlist.resbar.BP[1])
		end
	end

	-- min / max / current wind are glyph instances (gl4.text); the translated nowind text stays here
	local windH = windArea[4] - windArea[2]
	local fontsize = windH / 3.2
	local windSkewCX = windArea[1] + ((windArea[3] - windArea[1]) / 2) - (cfg.useSkew and windH * skewTan * 0.5 or 0)
	if cache.showIndicators and noWind then
		font2:Begin(true)
		--font2:Print("\255\200\200\200no wind", windSkewCX, windArea[2] + ((windArea[4] - windArea[2]) / 2.05) - (fontsize / 5), fontsize, 'oc') -- Wind speed text
		font2:Print(
			noWindText1,
			windSkewCX,
			windArea[2] + ((windArea[4] - windArea[2]) / 1.5) - (fontsize / 5),
			fontsize * 1.06,
			"oc"
		) -- Wind speed text
		font2:Print(
			noWindText2,
			windSkewCX,
			windArea[2] + ((windArea[4] - windArea[2]) / 2.8) - (fontsize / 5),
			fontsize * 1.06,
			"oc"
		) -- Wind speed text
		font2:End()
	end

	-- tidal speed: glyph instances (gl4.text)
end

-- --- OPTIMIZATION: Pre-defined functions for RenderToTexture to avoid creating closures.
local function renderUiBackground()
	glTranslate(-1, -1, 0)
	glScale(2 / (topbarArea[3] - topbarArea[1]), 2 / (topbarArea[4] - topbarArea[2]), 0)
	glTranslate(-topbarArea[1], -topbarArea[2], 0)
	drawUiBackground()
end

local function renderUi()
	glTranslate(-1, -1, 0)
	glScale(2 / (topbarArea[3] - topbarArea[1]), 2 / (topbarArea[4] - topbarArea[2]), 0)
	glTranslate(-topbarArea[1], -topbarArea[2], 0)
	drawUi()
	-- uiTex was just recreated blank: force all resbar texts to re-render on the next
	-- bars update (their dirty flags may be clear when the values didn't change)
	local um, ue = updateRes.metal, updateRes.energy
	um[1], um[2], um[3], um[4] = true, true, true, true
	ue[1], ue[2], ue[3], ue[4] = true, true, true, true
	if BPS.on then
		updateRes.BP[1] = true
	end
end

function widget:DrawScreen()
	gl4.frameStart() -- now = os.clock(), deferred bar update flag, tick while paused / pre-game

	if hoveringTopbar then
		sp.SetMouseCursor("cursornormal")
	end

	if refreshUi then
		if uiBgTex then
			gl.DeleteTexture(uiBgTex)
		end
		uiBgTex = gl.CreateTexture(mathFloor(topbarArea[3] - topbarArea[1]), mathFloor(topbarArea[4] - topbarArea[2]), {
			target = GL.TEXTURE_2D,
			format = GL.RGBA8,
			fbo = true,
		})
		if uiTex then
			gl.DeleteTexture(uiTex)
		end
		uiTex = gl.CreateTexture(
			mathFloor(topbarArea[3] - topbarArea[1]),
			mathFloor(topbarArea[4] - topbarArea[2]),
			{ --*(vsy<1400 and 2 or 1)
				target = GL.TEXTURE_2D,
				format = GL.RGBA8,
				fbo = true,
			}
		)

		if uiBgTex then
			r2tHelper.RenderToTexture(uiBgTex, renderUiBackground, true)
		end
		if uiTex then
			r2tHelper.RenderToTexture(uiTex, renderUi, true)
		end

		if WG.guishader then
			if uiBgList then
				glDeleteList(uiBgList)
			end
			uiBgList = glCreateList(function()
				glColor(1, 1, 1, 1)
				gl.Texture(uiBgTex)
				gl.TexRect(topbarArea[1], topbarArea[2], topbarArea[3], topbarArea[4], false, true)
				gl.Texture(false)
			end)
			-- 'self' rather than 'widget': this function sits at the Lua 5.1 upvalue cap
			WG.guishader.InsertDlist(uiBgList, "topbar_background", nil, self)
		end

		-- blit instances (uiBgTex / uiTex are bound by id in every draw), wind blades, tidal waves
		gl4.layoutUi()
	end

	-- 20 Hz bar values; glyph atlas on refreshUi, changed texts -> glyph instances (before the draw)
	drawResBars()

	-- the whole bar in one instanced draw: uiBgTex, wind blades, tidal waves, uiTex, texts, bars (+ banner lists)
	gl4.drawChecked()

	refreshUi = false
end

local function adjustSliders(x, y)
	if draggingShareIndicator and not spec then
		local shareValue = (x - resbarDrawinfo[draggingShareIndicator].barArea[1])
			/ (resbarDrawinfo[draggingShareIndicator].barArea[3] - resbarDrawinfo[draggingShareIndicator].barArea[1])
		if shareValue < 0 then
			shareValue = 0
		end
		if shareValue > 1 then
			shareValue = 1
		end
		Spring.SetShareLevel(draggingShareIndicator, shareValue)
		draggingShareIndicatorValue[draggingShareIndicator] = shareValue
		updateResbar(draggingShareIndicator)
	end

	if draggingConversionIndicator and not spec then
		local convValue = mathFloor(
			(x - resbarDrawinfo.energy.barArea[1])
				/ (resbarDrawinfo.energy.barArea[3] - resbarDrawinfo.energy.barArea[1])
				* 100
		)
		if convValue < 12 then
			convValue = 12
		end
		if convValue > 88 then
			convValue = 88
		end
		Spring.SendLuaRulesMsg(stringFormat(string.char(137) .. "%i", convValue))
		draggingConversionIndicatorValue = convValue
		updateResbar("energy")
	end
end

function widget:MouseMove(x, y)
	-- 0.5.005: the knob follows at the fast tick (20 Hz), which calls adjustSliders with the last position
	if draggingShareIndicator or draggingConversionIndicator then
		gl4.ts.dragX, gl4.ts.dragY = x, y
	end
	gl4.ts.lastHover = osClock()
	gl4.setHover(x, y)
end

-- hover tracking (was polled in widget:Update). Returns false: the top bar does not claim the mouse,
-- so the result of widgetHandler:IsAbove / WidgetAt for other widgets and the engine is unchanged.
function widget:IsAbove(x, y)
	gl4.ts.lastHover = osClock()
	gl4.setHover(x, y)
	return false
end

-- The fast tick (0.5.005; the 20 Hz bars update of drawResBars): fill widths of the value bars and of the BP
-- used / reserved fill, slider knobs while dragging (MouseMove only records the position), hover reaction.
-- Does nothing while the sim does not advance (paused, pre-game: no game frame for 0.1 s) and no drag is
-- active, except the first tick after that started and ticks whose inputs changed (ts.fastDirty: smoothing,
-- resource read, layout, options, team change). Returns true when it updated the bars.
function gl4.fastTick()
	local ts = gl4.ts
	local drag = draggingShareIndicator or draggingConversionIndicator
	if drag and ts.dragX then
		local x = ts.dragX
		ts.dragX = false
		adjustSliders(x, ts.dragY)
	end
	if hoveringTopbar ~= ts.hoverApplied then
		gl4.applyHover()
	end
	local running = now - ts.lastGameFrame <= 0.1
	if not (running or drag or ts.fastDirty or ts.wasRunning) then
		return false
	end
	ts.wasRunning = running
	ts.fastDirty = false
	if dlist.resbar.metal[1] then
		updateResbarValues("metal", true)
	end
	if dlist.resbar.energy[1] then
		updateResbarValues("energy", true)
	end
	if BPS.on and dlist.resbar.BP[1] then
		updateResbarValues("BP", true)
	end
	return true
end




function widget:MousePress(x, y, button)
	if button == 1 then
		if not spec then
			if not isSingle then
				if
					mathIsInRect(
						x,
						y,
						shareIndicatorArea.metal[1],
						shareIndicatorArea.metal[2],
						shareIndicatorArea.metal[3],
						shareIndicatorArea.metal[4]
					)
				then
					draggingShareIndicator = "metal"
				end

				if
					mathIsInRect(
						x,
						y,
						shareIndicatorArea.energy[1],
						shareIndicatorArea.energy[2],
						shareIndicatorArea.energy[3],
						shareIndicatorArea.energy[4]
					)
				then
					draggingShareIndicator = "energy"
				end
			end

			if
				not draggingShareIndicator
				and mathIsInRect(
					x,
					y,
					conversionIndicatorArea[1],
					conversionIndicatorArea[2],
					conversionIndicatorArea[3],
					conversionIndicatorArea[4]
				)
			then
				draggingConversionIndicator = true
			end

			if draggingShareIndicator or draggingConversionIndicator then
				if playSounds then
					Spring.PlaySoundFile(resourceclick, 0.7, "ui")
				end
				return true
			end
		end
	end

	if hoveringTopbar then
		return true
	end
end

function widget:MouseRelease(x, y, button)
	gl4.ts.dragX = false -- (the release position is applied right here)
	if draggingShareIndicator then
		adjustSliders(x, y)
		draggingShareIndicator = nil
	end
	if draggingConversionIndicator then
		adjustSliders(x, y)
		draggingConversionIndicator = nil
	end
end

function widget:PlayerChanged()
	local prevMyTeamID = myTeamID
	local prevSpec = spec
	spec = sp.GetSpectatingState()
	checkSelfStatus()
	numTeamsInAllyTeam = #Spring.GetTeamList(myAllyTeamID)
	if BPS.on then
		BPS.InitAdditionalValues()
	end
	if displayComCounter then
		countComs(true)
	end
	if spec then
		resbarHover = nil
		if prevMyTeamID ~= myTeamID then
			r = {
				metal = { sp.GetTeamResources(myTeamID, "metal") },
				energy = { sp.GetTeamResources(myTeamID, "energy") },
			}
			gl4.copyRes(smoothedResources, r) -- (copy, not an alias: r is read in place at 4 Hz)
		end
	end

	if not prevSpec and prevSpec ~= spec then
		init()
	end
	gl4.ts.fastDirty = true
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
	if isCommander[unitDefID] then
		if select(6, Spring.GetTeamInfo(unitTeam, false)) == myAllyTeamID then
			allyComs = allyComs + 1
		elseif spec then
			enemyComs = enemyComs + 1
		end
		comcountChanged = true
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if BPS.on then
		BPS.TrackUnit(unitID, unitDefID, unitTeam)
	end
end

function widget:UnitGiven(unitID, unitDefID, unitTeam)
	if BPS.on then
		BPS.TrackUnit(unitID, unitDefID, unitTeam)
	end
end

function widget:UnitTaken(unitID, unitDefID, unitTeam)
	if BPS.on then
		BPS.UntrackUnit(unitID, unitDefID, unitTeam)
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam, weaponDefID)
	if BPS.on then
		BPS.UntrackUnit(unitID, unitDefID, unitTeam)
	end
	if isCommander[unitDefID] then
		if select(6, Spring.GetTeamInfo(unitTeam, false)) == myAllyTeamID then
			allyComs = allyComs - 1
		elseif spec then
			enemyComs = enemyComs - 1
		end
		comcountChanged = true
	end
end

function widget:LanguageChanged()
	refreshWindTidalTextCache()
	widget:ViewResize()
end

function widget:Initialize()
	-- GL4 renderer first: if it is not available, say so and leave without touching anything else
	local gl4ok, gl4err = gl4.init()
	if not gl4ok then
		Spring.Echo(gl4.WIDGET_NAME .. ": GL4 renderer unavailable (" .. tostring(gl4err) .. "). Removing this widget - please enable '" .. gl4.FALLBACK_NAME .. "' (F11 widget list) instead.")
		gl4.shutdown()
		gl4.initFailed = true -- Shutdown must not touch WG.topbar / tooltips we never set up
		widgetHandler:RemoveWidget(self)
		return
	end

	gameFrame = sp.GetGameFrame()
	Spring.SendCommands("resbar 0")

	-- determine if we want to show comcounter
	local allteams = Spring.GetTeamList()
	local teamN = table.maxn(allteams) - 1 --remove gaia
	if teamN > 2 then
		displayComCounter = true
	end

	if UnitDefs[Spring.GetTeamRulesParam(Spring.GetLocalTeamID(), "startUnit")] then
		textures.com = ":n:Icons/"
			.. UnitDefs[Spring.GetTeamRulesParam(Spring.GetLocalTeamID(), "startUnit")].name
			.. ".png"
	end

	for _, teamID in ipairs(myAllyTeamList) do
		if select(4, Spring.GetTeamInfo(teamID, false)) then -- is AI?
			local luaAI = Spring.GetTeamLuaAI(teamID)
			if luaAI and luaAI ~= "" and (string.find(luaAI, "Scavengers") or string.find(luaAI, "Raptors")) then
				supressOverflowNotifs = true
				break
			end
		end
	end

	if not spec then
		local teamList = Spring.GetTeamList(myAllyTeamID) or {}
		isSingle = #teamList == 1
	end

	for unitDefID, unitDef in pairs(UnitDefs) do
		if unitDef.customParams.iscommander or unitDef.customParams.isscavcommander then
			isCommander[unitDefID] = true
			commanderUnitDefIDs[#commanderUnitDefIDs + 1] = unitDefID
		end
	end

	-- Shared with the Top Bar Buttons widget, which fills in the button and quit
	-- dialog half of this API. Either widget can run without the other.
	WG.topbar = WG.topbar or {}

	WG.topbar.updateTopBarEnergy = function(value)
		draggingConversionIndicatorValue = value
		updateResbar("energy")
	end

	WG.topbar.setResourceBarsVisible = function(visible)
		if showResourceBars == visible then
			return
		end

		showResourceBars = visible
		refreshUi = true

		-- Quick-start/base-build-budget hides bars pregame and restores them at
		-- game start. Rebuild UI state when showing again so bar/slider geometry
		-- is recreated from current topbar dimensions.
		if visible then
			draggingShareIndicatorValue = {}
			draggingConversionIndicatorValue = nil
			init()
		else
			resbarHover = nil
			draggingShareIndicator = nil
			draggingConversionIndicator = nil
		end
	end

	WG.topbar.getResourceBarsVisible = function()
		return showResourceBars
	end

	WG.topbar.setIndicatorsVisible = function(visible)
		if cache.showIndicators == visible then
			return
		end

		cache.showIndicators = visible
		refreshUi = true
	end

	WG.topbar.getIndicatorsVisible = function()
		return cache.showIndicators
	end

	updateAvgWind()
	updateWindRisk()
	currentWindText = "\255\255\255\255" .. currentWind
	refreshWindTidalTextCache()

	-- buildpower bar (BPC.drawBPBar requires a reload, so it is only read here)
	BPS.on = BPC.drawBPBar == true
	if BPS.on then
		resourceNames[3] = "BP"
		BPS.initUnitCostData()
		BPS.InitAdditionalValues()
	end
	BPS.registerOptions()

	guishaderEnabled = WG.guishader ~= nil
	widget:ViewResize()

	if gameFrame > 0 then
		widget:GameStart()
	end

	if
		WG.resource_spot_finder
		and WG.resource_spot_finder.metalSpotsList
		and #WG.resource_spot_finder.metalSpotsList > 0
		and #WG.resource_spot_finder.metalSpotsList <= 2
	then -- probably speedmetal kind of map
		isMetalmap = true
	end
end

function widget:Shutdown()
	--Spring.SendCommands("resbar 1")

	gl4.shutdown()
	if gl4.initFailed then
		return
	end

	do -- (0.5.003: no blendBg / blendUi / wind / tidal lists any more)
		if dlist.coms then
			dlist.coms = glDeleteList(dlist.coms)
		end

		if dlist.energyGlow then
			for i = 1, 4 do
				glDeleteList(dlist.energyGlow[i])
			end
			dlist.energyGlow = nil
		end

		for n, _ in pairs(dlist.windText) do
			dlist.windText[n] = glDeleteList(dlist.windText[n])
		end
		for n, _ in pairs(dlist.resbar.metal) do
			dlist.resbar.metal[n] = glDeleteList(dlist.resbar.metal[n])
		end
		for n, _ in pairs(dlist.resbar.energy) do
			dlist.resbar.energy[n] = glDeleteList(dlist.resbar.energy[n])
		end
		for n, _ in pairs(dlist.resbar.BP) do
			dlist.resbar.BP[n] = glDeleteList(dlist.resbar.BP[n])
		end
		for res, _ in pairs(dlist.resValues) do
			dlist.resValues[res] = glDeleteList(dlist.resValues[res])
		end
		for res, _ in pairs(dlist.resValuesBar) do
			dlist.resValuesBar[res] = glDeleteList(dlist.resValuesBar[res])
		end
	end

	if uiBgTex then
		gl.DeleteTexture(uiBgTex)
		uiBgTex = nil
	end
	if uiTex then
		gl.DeleteTexture(uiTex)
		uiTex = nil
	end

	if WG.guishader then
		WG.guishader.DeleteDlist("topbar_background")
	end

	if WG.tooltip then
		WG.tooltip.RemoveTooltip("coms")
		WG.tooltip.RemoveTooltip("wind")
		local res = "energy"
		WG.tooltip.RemoveTooltip(res .. "_share_slider")
		WG.tooltip.RemoveTooltip(res .. "_share_slider2")
		WG.tooltip.RemoveTooltip(res .. "_metalmaker_slider")
		WG.tooltip.RemoveTooltip(res .. "_pull")
		WG.tooltip.RemoveTooltip(res .. "_income")
		WG.tooltip.RemoveTooltip(res .. "_storage")
		WG.tooltip.RemoveTooltip(res .. "_current")
		res = "metal"
		WG.tooltip.RemoveTooltip(res .. "_share_slider")
		WG.tooltip.RemoveTooltip(res .. "_share_slider2")
		WG.tooltip.RemoveTooltip(res .. "_pull")
		WG.tooltip.RemoveTooltip(res .. "_income")
		WG.tooltip.RemoveTooltip(res .. "_storage")
		WG.tooltip.RemoveTooltip(res .. "_current")
		WG.tooltip.RemoveTooltip("BP_all")
		WG.tooltip.RemoveTooltip("BP_Current")
	end
	BPS.unregisterOptions()

	removeButtonFallbacks()
	if WG.topbar then
		WG.topbar.GetPosition = nil
		WG.topbar.GetFreeArea = nil
		WG.topbar.GetSkewConfig = nil
		WG.topbar.updateTopBarEnergy = nil
		WG.topbar.setResourceBarsVisible = nil
		WG.topbar.getResourceBarsVisible = nil
		WG.topbar.setIndicatorsVisible = nil
		WG.topbar.getIndicatorsVisible = nil
		-- the Top Bar Buttons widget may still be using the table for its own half
		if next(WG.topbar) == nil then
			WG.topbar = nil
		end
	end
end

function widget:GetConfigData()
	return {
		drawBPBar = BPC.drawBPBar,
		drawBPIndicators = BPC.drawBPIndicators,
		drawBPWindRangeIndicators = BPC.drawBPWindRangeIndicators,
		debugTooltip = BPC.debugTooltip,
	}
end

function widget:SetConfigData(data)
	if type(data) ~= "table" then
		return
	end
	for k, v in pairs(data) do
		if BPC[k] ~= nil and type(v) == type(BPC[k]) then
			BPC[k] = v
		end
	end
end
