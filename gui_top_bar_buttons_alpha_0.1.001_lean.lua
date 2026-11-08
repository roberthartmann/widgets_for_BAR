local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Top Bar Buttons 0.1.001 lean",
		desc = "The menu buttons top right and the quit/resign and save dialogs; no Update callin, one GL call per frame (replaces 'Top Bar Buttons'; enable only one)",
		author = "Floris, Robert82",
		date = "Nov, 2025",
		license = "GNU GPL, v2 or later",
		layer = -95000,
		enabled = true,
		handler = true, --can use widgetHandler:x()
		modalExempt = true, -- these buttons are how the player switches and closes windows
	}
end

--[[
0.1.001 lean: changes vs the official Top Bar Buttons
Base: luaui/Widgets/gui_top_bar_buttons.lua (BAR master, 2026-11-08). Same buttons, badge, auto hide, dialogs,
keys, save dialog text input, WG.topbar API and fallbacks, guishader blur; less work per frame.
Measured in a mock harness (Lua 5.1, 1920x1080, 60 fps draw, 30 Hz sim, the real FlowUI Draw functions and Editbox),
official -> lean, per frame. GL calls = Lua->GL calls issued by the frame (+ calls recorded into display lists that
frame); allocation = bytes per frame over all call-ins (Update / IsAbove / GameFrame / DrawScreen):
   state                        GL calls                 allocation        display lists created
   idle                         3       -> 1             192 B   -> 0      0/s  -> 0/s
   hovering a button            164     -> 2             2052 B  -> 0      0/s  -> 0/s (1 per button, first hover)
   changelog highlight          33      -> 3             368 B   -> 0      0/s  -> 0/s
   changelog + hovering         194     -> 4             2224 B  -> 0      0/s  -> 0/s
   auto-hidden, idle            1       -> 0             192 B   -> 0      0/s  -> 0/s
   quit dialog open (blur on)   5 + 1050 -> 1            13.4 kB -> 0      60/s -> 0/s
   quit dialog open (no blur)   6 + 1050 -> 2            13.4 kB -> 0      60/s -> 0/s
   save dialog open (blur on)   5 + 913 -> 1.7 + 4.7     11.1 kB -> 0      60/s -> 20/s (edit box caret)
   setScreenBlur(true) calls while a dialog is up: 60/s -> 0/s; quit dialog fade-in lists: 12 -> 12 at 60 fps,
   43 -> 13 at 144 fps; Update call-in: every frame -> none. (192 B/frame is 11.5 kB/s at 60 fps; the
   allocation scales with the frame rate.) Draw output traced call by call: strip, hover highlight, changelog shape
   and quit dialog (at rest and hovered) identical to the official; save dialog identical except the caret alpha.
   SetMouseCursor per frame unchanged (while hovering / while a dialog is up).
 - No Update call-in (the base ran one every frame). What it did moved to:
   * WG.topbar fallbacks (GetPosition, GetFreeArea, GetSkewConfig, the resource bar no-ops): the fallback functions
     are defined once (no closures per call; the base built three closures every frame and GetSkewConfig computed
     math.tan per call, now a constant). Provided in Initialize; re-checked when WG.topbar's identity changes or its
     GetPosition entry goes missing (the Top Bar shut down; two table reads per DrawScreen / GameFrame) and with
     every button-set check
   * button-set check (was every 0.5 s in Update with a 12-entry table + table.concat string per check): compares
     the 12 fields against stored values in place (no allocation); from widget:GameFrame every 15 sim frames and,
     while no game frame comes (pre-game, paused), from DrawScreen with the draw clock (0.5 s). The same check also
     reads WG.changelog.haschanges(), the paused state and re-applies the guishader registration (it was per frame)
   * hover (was a 30 Hz Spring.GetMouseState poll): widget:IsAbove(x, y) sets hoveringButtons and the hovered
     button (returns false, so widgetHandler:WidgetAt / IsAbove for the engine and other widgets are unchanged);
     widget:MouseMove while this widget owns the mouse; MousePress uses its own x, y. When IsAbove was not called
     for 0.25 s (another widget claimed the mouse first) DrawScreen polls Spring.GetMouseState: 4 Hz while the
     strip is hovered (to drop a stale hover quickly), 1 Hz otherwise. Spring.SetMouseCursor per frame only while
     hovering (unchanged)
   * changelog blink (was integrated in Update with the frame dt at a 30 Hz tick, so it ran at a frame-rate
     dependent speed): computed from a clock that advances with the draw time while the game is not paused (the
     base froze it while paused too). Curve = the base's as it runs at 60 fps: linear rise p = t / 0.217 s, then
     fall p = sqrt(1 - t / 1.567 s) (the solution of the base's dp = -dt / (1.5 p) at its 30 Hz tick), period
     1.783 s; alpha = 0.1 * p. (Base, measured in the harness: period 1.80 s at 60 fps, 4.41 s at 144 fps)
 - Strip: background chrome + labels + badges are rendered once per refresh (layout, button set, language, resize,
   auto hide option, first draw) into one RGBA8 FBO texture with gl.R2tHelper.RenderToTexture (premultiplied, as
   the Top Bar does) and drawn with one baked display list (blending, texture, TexRect). The texture is only
   recreated when its size changes. The panel list (dlist.background) is still built and handed to the guishader
   blur as before (InsertDlist; the blur only redraws it when its stencil is refreshed). Without R2tHelper /
   CreateTexture: one list calling the background and labels lists (still one call per frame)
 - Hover highlight (was four immediate-mode RectRounds per frame with new colour tables, after a pairs() scan of
   all buttons): one display list per button (the four RectRounds + blending changes), baked on the first hover of
   that button, cached until the next refresh; per frame one glCallList. The hovered button is found in IsAbove
   (and only re-scanned when the cursor leaves the current button)
 - Changelog highlight (was one immediate-mode RectRound per frame with a new colour table): baked once per
   refresh without colour; per frame glColor (pulse alpha) + glCallList
 - Dialogs (the base deleted and re-created the dialog list every frame, with font prints and FlowUI, removed and
   re-inserted it into the guishader every frame and called setScreenBlur(true) every frame, which made the
   guishader rebuild its screen stencil every frame): the quit/resign list is rebuilt only when something it shows
   changed: fade step (time quantised to 1/60 s, so 12 steps over the 0.2 s fade at any frame rate, then none),
   hovered button, texts / team resign (re-checked at 2 Hz and on PlayerChanged / GameOver / LanguageChanged),
   screen size, guishader presence. The guishader render list is swapped only when the list was rebuilt;
   setScreenBlur(true) only when getScreenBlur() reports it off (every frame where getScreenBlur is missing).
   Save dialog: a static list (dim, window, buttons, field, title, hint) rebuilt on the same kind of changes plus
   "name exists", and a small top list (calls the static list + the edit box) rebuilt at 20 Hz for the caret
   fade, on key / text / mouse input and every frame while a selection is dragged. Mouse position is polled per
   frame while a dialog is up (no allocation)
 - Strip blur registration remembers the guishader table it was inserted into, so a guishader that was restarted
   between two checks gets the region again (the base compared a boolean and kept the old registration)
 - No allocation on the steady path: colour tables hoisted to constants, no closures per frame, no tables in
   DrawScreen / IsAbove / GameFrame / the button-set check
 - DrawScreen returns before any GL call when the strip is auto-hidden (and no dialog is up): 0 GL calls; the
   trailing per-frame glColor(1, 1, 1, 1) is baked into the end of every list instead
]]

local Editbox = require("luaui/Include/keybind_editbox")
local KEYSYMS = require("luaui/Include/keybind_keysyms")

-- Localized functions for performance
local mathFloor = math.floor
local mathCeil = math.ceil
local mathMax = math.max
local mathSqrt = math.sqrt
local mathIsInRect = math.isInRect
local spGetMouseState = Spring.GetMouseState
local spSetMouseCursor = Spring.SetMouseCursor

-- System
local spec = Spring.GetSpectatingState()
local myTeamID = Spring.GetLocalTeamID()
local myAllyTeamID = Spring.GetLocalAllyTeamID()
local myAllyTeamList = Spring.GetTeamList(myAllyTeamID)

-- Game mode / state
local numPlayers = BAR.Utilities.GetPlayerCount()
local isSinglePlayer = BAR.Utilities.Gametype.IsSinglePlayer()
local _modOpts = Spring.GetModOptions()
local isScenario = _modOpts ~= nil and _modOpts.scenariooptions ~= nil
local chobbyLoaded = false
local gameStarted = (Spring.GetGameFrame() > 0)
local gameIsOver = false

-- Configuration. The geometry values mirror the Top Bar's, so the strip lines up with
-- the bar whether or not that widget is running.
local cfg = {
	relXpos = 0.3,
	borderPadding = 5,
	escapeKeyPressesQuit = false,
	allowSavegame = true,
	useSkew = true,
	smallElementHeightFraction = 0.85, -- buttons height as fraction of the top bar
}

local SAVE_PAUSE = "topbarSaveDialog" -- what the handler holds the game paused under, while the save dialog is up
-- the save dialog's buttons, as the quit dialog's: at rest bottom and top, hovered bottom and top
local SAVE_BUTTONS = {
	cancel = { { 0.25, 0, 0 }, { 0.5, 0, 0 }, { 0.4, 0, 0 }, { 0.6, 0.05, 0.05 } },
	save = { { 0, 0.25, 0 }, { 0, 0.5, 0 }, { 0, 0.4, 0 }, { 0.05, 0.6, 0.05 } },
	replace = { { 0.3, 0.2, 0 }, { 0.6, 0.4, 0 }, { 0.45, 0.3, 0 }, { 0.75, 0.5, 0.05 } },
}

-- Constants (colour tables hoisted: the base built them per draw)
local K = {
	skewTan = math.tan(math.rad(20)),
	hoverDark = { 0, 0, 0, 0.06 },
	hoverC1 = { 1, 1, 1, 0.03 },
	hoverC2 = { 0.44, 0.44, 0.44, 0.2 },
	hoverTop1 = { 1, 1, 1, 0 },
	hoverTop2 = { 1, 1, 1, 0.18 },
	hoverBot1 = { 1, 1, 1, 0.045 },
	hoverBot2 = { 1, 1, 1, 0 },
	badgeOutline = { 0.18, 0.18, 0.18, 1 },
	badgeFill = { 0.66, 0.66, 0.66, 1 },
	saveField = { 0, 0, 0, 0.65 },
	-- changelog blink, the base's curve as it runs at 60 fps (measured: rise 13 frames, fall 94 frames)
	blinkRise = 13 / 60,
	blinkFall = 94 / 60,
	fadeSteps = 12, -- the dialogs fade in over 0.2 s, in steps of 1/60 s
	textCheck = 0.5, -- quit dialog texts / team resign re-check while it is up
	saveCaretHz = 20, -- save dialog edit box (caret fade) rebuild rate
}
K.blinkPeriod = K.blinkRise + K.blinkFall

-- OpenGL
local glCreateList = gl.CreateList
local glCallList = gl.CallList
local glDeleteList = gl.DeleteList
local glBlending = gl.Blending
local glColor = gl.Color
local r2tHelper = gl.R2tHelper
local canR2T = type(r2tHelper) == "table" and type(r2tHelper.RenderToTexture) == "function"
	and type(gl.CreateTexture) == "function" and type(gl.DeleteTexture) == "function"

-- UI elements
local topbarArea = {}
local buttonsArea = {}

-- UI state
local orgHeight = 46
local ui_scale = tonumber(Spring.GetConfigFloat("ui_scale", 1)) or 1
local height = orgHeight * (1 + (ui_scale - 1) / 1.7)
local vsx, vsy = Spring.GetViewGeometry()
local widgetScale = (0.80 + (vsx * vsy / 6000000))
local xPos = mathFloor(vsx * cfg.relXpos)
local mx, my = -1, -1
local showButtons = true
local autoHideButtons = false
local hoveringButtons = false
local hoveredButton = nil -- name of the button under the cursor (set in IsAbove / MouseMove / the poll)
local configLoaded = false
local refreshButtons = true
local stripDirty = true -- strip texture / lists to be rebuilt in the next DrawScreen
---@type number
local bgpadding
---@type fun(...)
local RectRound
---@type fun(...)
local UiElement
---@type fun(...)
local UiButton
---@type fun(...)
local RectRoundCircle
---@type any
local font
---@type any
local font2

-- Display lists
-- background: the strip's panel chrome, handed to the blur (and drawn by the fallback strip list)
-- buttons:    the button labels and badges (only without render-to-texture)
-- strip:      what DrawScreen calls: the texture blit, or background + buttons
-- changelog:  the changelog highlight shape, without colour
-- quit:       the quit/resign dialog, or the save dialog's top list
-- saveStatic: the save dialog without its edit box
---@type table<string, integer>
local dlist = {}
local hoverLists = {} -- button name -> baked hover highlight
local strip = { tex = nil, w = 0, h = 0, x1 = 0, y1 = 0, x2 = 0, y2 = 0 }
-- the guishader table the strip's shape is currently registered with (nil: not registered)
local guishaderIn = nil

-- Interactions
---@type any
local quitscreenArea
---@type any
local quitscreenStayArea
---@type any
local quitscreenQuitArea
---@type any
local quitscreenResignArea
---@type any
local quitscreenTeamResignArea
---@type any
local showQuitscreen
---@type any
local hideQuitWindow
---@type boolean
local teamResign = false
-- While the save dialog is up: when it opened, its field (box), what an empty field saves as (fallback),
-- whether the name is taken (exists), the keys down when it opened (held), its rects once drawn
---@type table?
local saveDialog
-- What the open dialog's lists were built from (rebuilt when any of it changes)
local dlg = {
	kind = nil, -- 1 quit, 2 save
	opened = nil,
	step = -1,
	hover = -1,
	gs = nil,
	hide = false,
	textKey = nil,
	teamResign = false,
	nextTextCheck = 0,
	dirty = true, -- static part
	topDirty = true, -- save dialog edit box part
	topStep = -1,
	inserted = nil, -- guishader table the current list was inserted into
	fade = 0, -- fade progress used by the list being built
}

-- Audio
local playSounds = true
local leftclick = "LuaUI/Sounds/tock.wav"

-- Timers
local osClock = os.clock
local now = osClock()
local nextButtonCheck = 0
local lastIsAbove = -1
local nextHoverPoll = 0
local changelogActive = false
local gamePaused = false
local pulseT = 0
local seenTopbar = false -- WG.topbar as of the last fallback check (false: never checked)

--------------------------------------------------------------------------------
local function getPlayerLiveAllyCount()
	local nAllies = 0
	for _, teamID in ipairs(myAllyTeamList) do
		if teamID ~= myTeamID then
			local _, _, isDead, hasAI = Spring.GetTeamInfo(teamID, false)
			if not isDead and not hasAI then
				nAllies = nAllies + 1
			end
		end
	end
	return nAllies
end

-- Which menu button, if any, sits under these screen coords.
-- Exposed as WG.topbar.buttonAt so the window widgets (which sit on a lower layer and
-- therefore see the click first) can tell a click on the top bar apart from a click that
-- dismisses them: closing themselves there would eat the click meant to open another window.
local function buttonAt(x, y)
	if not buttonsArea.buttons then
		return nil
	end
	for name, pos in pairs(buttonsArea.buttons) do
		if mathIsInRect(x, y, pos[1], pos[2], pos[3], pos[4]) then
			return name
		end
	end
	return nil
end

-- hover state for the cursor at x, y (was polled in Update at 30 Hz)
-- deliberately not gated on showButtons: with auto-hide on, hovering the empty strip is what brings the buttons back
local function setHover(x, y)
	mx, my = x, y
	local ba = buttonsArea
	if ba[1] and mathIsInRect(x, y, ba[1], ba[2], ba[3], ba[4]) then
		hoveringButtons = true
		local buttons = ba.buttons
		local cur = hoveredButton and buttons and buttons[hoveredButton]
		if cur and mathIsInRect(x, y, cur[1], cur[2], cur[3], cur[4]) then
			return
		end
		hoveredButton = buttonAt(x, y)
	else
		hoveringButtons = false
		hoveredButton = nil
	end
end

local function updateButtons()
	local fontsize = (height * widgetScale) / 3

	-- if not buttonsArea['buttons'] then -- With this condition it doesn't actually update buttons if they were already added
	buttonsArea.buttons = {}
	buttonsArea.fontsize = fontsize

	local margin = bgpadding
	local textPadding = mathFloor(fontsize * 0.8)
	local sidePadding = textPadding
	local offset = sidePadding
	local lastbutton
	local badgeMinRadius = fontsize * 0.47
	local badgeFontsize = fontsize * 0.69

	-- badge: optional number shown in a circle at the bottom right of the button text
	local function addButton(name, text, badge)
		local textWidth = font2:GetTextWidth(text) * fontsize
		-- the circle grows along with the amount of characters the number has
		local badgeRadius = 0
		if badge then
			local badgeTextWidth = font2:GetTextWidth(badge) * badgeFontsize
			badgeRadius = mathMax(badgeMinRadius, (badgeTextWidth / 2) + (fontsize * 0.25))
		end
		local badgeWidth = badgeRadius * 2
		local width = mathFloor(textWidth + badgeWidth + textPadding)
		local textCenter = buttonsArea[3] - offset - (width / 2) - (badgeWidth / 2)
		buttonsArea.buttons[name] = {
			buttonsArea[3] - offset - width,
			buttonsArea[2] + margin,
			buttonsArea[3] - offset,
			buttonsArea[4],
			text,
			textCenter,
		}
		if badge then
			local button = buttonsArea.buttons[name]
			button[7] = {
				text = badge,
				x = textCenter + (textWidth / 2) + badgeRadius + (1.5 * widgetScale),
				-- slightly below the center of the button text, so it sits at its bottom right
				y = button[2] + ((button[4] - button[2]) * 0.5) - (fontsize / 5) + (fontsize * 0.15),
				radius = badgeRadius,
				fontsize = badgeFontsize,
			}
		end
		if not lastbutton then
			buttonsArea.buttons[name][3] = buttonsArea[3]
		end
		offset = mathFloor(offset + width + 0.5)
		lastbutton = name
	end

	if not gameIsOver and chobbyLoaded then
		addButton("quit", BAR.I18N("ui.topbar.button.lobby"))
	else
		addButton("quit", BAR.I18N("ui.topbar.button.quit"))
	end
	if not gameIsOver and not spec and gameStarted and not isSinglePlayer then
		addButton("resign", BAR.I18N("ui.topbar.button.resign"))
	end

	if WG.options then
		addButton("options", BAR.I18N("ui.topbar.button.settings"))
	end
	if WG.keybinds then
		addButton("keybinds", BAR.I18N("ui.topbar.button.keys"))
	end
	if WG.changelog and not isScenario then
		addButton("changelog", BAR.I18N("ui.topbar.button.changes"))
	end
	if WG.teamstats and not isScenario then
		addButton("stats", BAR.I18N("ui.topbar.button.stats"))
	end
	-- only shown when settings differ from their default, the amount of them is put in the badge
	if WG.gameinfo and (not isSinglePlayer or BAR.Utilities.ShowDevUI()) then
		local changedCount = WG.gameinfo.getChangedModoptionsCount and WG.gameinfo.getChangedModoptionsCount() or 0
		if changedCount > 0 then
			addButton("info", BAR.I18N("ui.topbar.button.info"), tostring(changedCount))
		end
	end
	if WG.scavengerinfo then
		addButton("scavengers", BAR.I18N("ui.topbar.button.scavengers"))
	end
	if isScenario and WG.missioninfo then
		addButton("mission", BAR.I18N("ui.topbar.button.mission"))
	end
	if isSinglePlayer and cfg.allowSavegame and WG.savegame then
		addButton("save", BAR.I18N("ui.topbar.button.save"))
	end

	buttonsArea.buttons[lastbutton][1] = buttonsArea.buttons[lastbutton][1] - sidePadding
	offset = offset + sidePadding
	buttonsArea[1] = buttonsArea[3] - offset - margin

	-- the graphics follow in the next DrawScreen; the hovered button is looked up again in the new layout
	stripDirty = true
	hoveredButton = nil
	setHover(mx, my)
end

-- the button labels and badges (was the body of the buttons list)
local function drawButtonsContents()
	local fontsize = buttonsArea.fontsize
	for _, params in pairs(buttonsArea.buttons) do
		local badge = params[7]
		if badge then
			-- corner size 0.586 x radius makes it a regular octagon, which reads as a circle at this size
			-- the dark circle below the smaller colored one acts as its outline
			local innerRadius = badge.radius - mathMax(1, badge.radius * 0.15)
			RectRoundCircle(badge.x, badge.y, badge.radius, badge.radius * 0.586, 0, K.badgeOutline, K.badgeOutline)
			RectRoundCircle(badge.x, badge.y, innerRadius, innerRadius * 0.586, 0, K.badgeFill, K.badgeFill)
		end
	end
	font2:Begin(true)
	font2:SetTextColor(0.92, 0.92, 0.92, 1)
	font2:SetOutlineColor(0, 0, 0, 1)
	for _, params in pairs(buttonsArea.buttons) do
		font2:Print(params[5], params[6], params[2] + ((params[4] - params[2]) * 0.5) - (fontsize / 5), fontsize, "co")
		local badge = params[7]
		if badge then
			font2:SetTextColor(0.08, 0.08, 0.08, 1)
			font2:Print(badge.text, badge.x, badge.y - (badge.fontsize * 0.32), badge.fontsize, "c")
			font2:SetTextColor(0.92, 0.92, 0.92, 1)
		end
	end
	font2:End()
end

-- The strip's panel chrome: only the bottom left corner is rounded, the other three sit against the screen edge
local function drawBackgroundContents()
	UiElement(buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4], 0, 0, 0, 1)
end

-- The blur follows the strip rather than its geometry: with auto hide on, a region
-- left registered would keep blurring a rectangle of map where the buttons no longer
-- are. Re-checked when the strip shows / hides, after a rebuild and with the button-set check,
-- which also picks the blur back up if the guishader widget is enabled mid-game.
-- (identity tracked, so a guishader that was restarted between two checks gets the region again)
local function applyGuishader()
	local gs = WG.guishader
	if not gs then
		guishaderIn = nil
		return
	end
	local wanted = showButtons and dlist.background ~= nil
	if wanted == (guishaderIn == gs) then
		return
	end
	if wanted then
		gs.InsertDlist(dlist.background, "topbar_buttons", nil, widget)
		guishaderIn = gs
	else
		gs.RemoveDlist("topbar_buttons")
		guishaderIn = nil
	end
end

-- render-to-texture body: screen coords mapped onto the strip texture
local function renderStrip()
	local s = strip
	gl.Translate(-1, -1, 0)
	gl.Scale(2 / (s.x2 - s.x1), 2 / (s.y2 - s.y1), 0)
	gl.Translate(-s.x1, -s.y1, 0)
	drawBackgroundContents()
	drawButtonsContents()
end

-- the per-frame strip: the texture (premultiplied) as one quad
local function drawStripBlit()
	local s = strip
	gl.Blending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA)
	gl.Color(1, 1, 1, 1)
	gl.Texture(s.tex)
	gl.TexRect(s.x1, s.y1, s.x2, s.y2, false, true)
	gl.Texture(false)
	gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
end

-- the per-frame strip without render-to-texture: the two lists of the base in one call
local function drawStripLists()
	gl.CallList(dlist.background)
	gl.CallList(dlist.buttons)
	gl.Color(1, 1, 1, 1)
end

-- the changelog highlight, without colour: DrawScreen sets the pulse alpha before calling it
local function drawChangelogShape()
	local b = buttonsArea.buttons.changelog
	RectRound(b[1] + 1, b[2] + 1, b[3] - 1, b[4] - 1, 3.5 * widgetScale, 0, 0, 0, 0)
	gl.Color(1, 1, 1, 1)
end

-- the hover highlight of one button (the base drew this every frame while hovering)
local hoverBuild
local function drawHoverShape()
	local b = hoverBuild
	local paddingsize = 1
	RectRound(b[1] + paddingsize, b[2] + paddingsize, b[3] - paddingsize, b[4] - paddingsize, 3.5 * widgetScale, 0, 0, 0, 0, K.hoverDark)
	glBlending(GL.SRC_ALPHA, GL.ONE)
	RectRound(b[1], b[2], b[3], b[4], 3.5 * widgetScale, 0, 0, 0, 0, K.hoverC1, K.hoverC2)
	RectRound(b[1], b[4] - ((b[4] - b[2]) * 0.4), b[3], b[4], 3.3 * widgetScale, 0, 0, 0, 0, K.hoverTop1, K.hoverTop2)
	RectRound(b[1], b[2], b[3], b[2] + ((b[4] - b[2]) * 0.25), 3.3 * widgetScale, 0, 0, 0, 0, K.hoverBot1, K.hoverBot2)
	glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	glColor(1, 1, 1, 1)
end

local function deleteHoverLists()
	for name, list in pairs(hoverLists) do
		glDeleteList(list)
		hoverLists[name] = nil
	end
end

local function drawHover()
	local list = hoverLists[hoveredButton]
	if not list then
		local b = buttonsArea.buttons and buttonsArea.buttons[hoveredButton]
		if not b then
			return
		end
		hoverBuild = b
		list = glCreateList(drawHoverShape)
		hoverLists[hoveredButton] = list
	end
	glCallList(list)
end

-- Everything the strip draws, rebuilt once per refresh (in DrawScreen: render-to-texture needs a draw call-in)
local function rebuildStrip()
	stripDirty = false
	deleteHoverLists()
	if dlist.background then
		if WG.guishader then
			WG.guishader.RemoveDlist("topbar_buttons")
		end
		guishaderIn = nil
		dlist.background = glDeleteList(dlist.background)
	end
	if dlist.buttons then
		dlist.buttons = glDeleteList(dlist.buttons)
	end
	if dlist.strip then
		dlist.strip = glDeleteList(dlist.strip)
	end
	if dlist.changelog then
		dlist.changelog = glDeleteList(dlist.changelog)
	end
	if not buttonsArea[1] or not buttonsArea.buttons then
		return
	end
	dlist.background = glCreateList(drawBackgroundContents)

	-- whole pixels, so the texture maps 1:1 onto the screen
	local s = strip
	local x1, y1 = mathFloor(buttonsArea[1]), mathFloor(buttonsArea[2])
	local x2, y2 = mathCeil(buttonsArea[3]), mathCeil(buttonsArea[4])
	local w, h = x2 - x1, y2 - y1
	local useTex = canR2T and w > 0 and h > 0
	if useTex and (not s.tex or s.w ~= w or s.h ~= h) then
		if s.tex then
			gl.DeleteTexture(s.tex)
		end
		s.tex = gl.CreateTexture(w, h, { target = GL.TEXTURE_2D, format = GL.RGBA8, fbo = true })
		s.w, s.h = w, h
	end
	if useTex and s.tex then
		s.x1, s.y1, s.x2, s.y2 = x1, y1, x2, y2
		r2tHelper.RenderToTexture(s.tex, renderStrip, true)
		dlist.strip = glCreateList(drawStripBlit)
		glColor(1, 1, 1, 1) -- the render may leave a colour behind
	else
		if s.tex then
			gl.DeleteTexture(s.tex)
			s.tex, s.w, s.h = nil, 0, 0
		end
		dlist.buttons = glCreateList(drawButtonsContents)
		dlist.strip = glCreateList(drawStripLists)
	end
	if buttonsArea.buttons.changelog then
		dlist.changelog = glCreateList(drawChangelogShape)
	end
	applyGuishader()
end

-- Mirrors the Top Bar's own geometry so the strip lines up with the bar, without
-- depending on that widget being loaded.
local function updateLayout()
	widgetScale = (vsy / height) * 0.0425 * ui_scale
	xPos = mathFloor(vsx * cfg.relXpos)
	topbarArea =
		{ mathFloor(xPos + (cfg.borderPadding * widgetScale)), mathFloor(vsy - (height * widgetScale)), vsx, vsy }

	-- Small elements (wind, tidal, coms, buttons) are top-aligned to a fraction of the
	-- bar height when skew is on.
	local smallVPad = cfg.useSkew and mathFloor((topbarArea[4] - topbarArea[2]) * (1 - cfg.smallElementHeightFraction))
		or 0
	local width = mathFloor((topbarArea[3] - topbarArea[1]) / 4)
	buttonsArea = { topbarArea[3] - width, topbarArea[2] + smallVPad, topbarArea[3], topbarArea[4] }

	updateButtons()
	dlg.dirty = true
end

function widget:ViewResize()
	vsx, vsy = gl.GetViewSizes()

	bgpadding = WG.FlowUI.elementPadding
	RectRound = WG.FlowUI.Draw.RectRound
	UiElement = WG.FlowUI.Draw.Element
	UiButton = WG.FlowUI.Draw.Button
	RectRoundCircle = WG.FlowUI.Draw.RectRoundCircle

	font = WG.fonts.getFont()
	font2 = WG.fonts.getFont(2)

	updateLayout()
end

-- the quit dialog's main text and whether it offers a team resign (was worked out in every frame's list)
local function quitTextState()
	local key = "ui.topbar.quit.reallyQuit"
	local canTeamResign = false
	if not spec then
		key = "ui.topbar.quit.reallyQuitResign"
		if not gameIsOver and chobbyLoaded then
			if numPlayers < 3 then
				key = "ui.topbar.quit.reallyResign"
			else
				if getPlayerLiveAllyCount() >= 1 then
					canTeamResign = true
				end
				key = "ui.topbar.quit.reallyResignSpectate"
			end
		end
	end
	return key, canTeamResign
end

-- the quit/resign dialog's list body (the base built this list every frame)
local function drawQuitContents()
	local fadeProgress = dlg.fade
	if dlg.gs then
		glColor(0, 0, 0, (0.18 * fadeProgress))
	else
		glColor(0, 0, 0, (0.35 * fadeProgress))
	end

	gl.Rect(0, 0, vsx, vsy)

	if not hideQuitWindow then
		-- when terminating spring, keep the faded screen

		local w = mathFloor(320 * widgetScale)
		local h = mathFloor(w / 3.5)

		local fontSize = h / 6
		local textKey
		textKey, teamResign = quitTextState()
		dlg.textKey, dlg.teamResign = textKey, teamResign
		local text = BAR.I18N(textKey)

		local padding = mathFloor(w / 90)
		local textTopPadding = padding + padding + padding + padding + padding + fontSize
		local txtWidth = font:GetTextWidth(text) * fontSize
		w = mathMax(w, txtWidth + textTopPadding + textTopPadding)

		local x = mathFloor((vsx / 2) - (w / 2))
		local y = mathFloor((vsy / 1.8) - (h / 2))
		local maxButtons = teamResign and 5 or 4
		local buttonMargin = mathFloor(h / 9)
		local buttonWidth = mathFloor((w - buttonMargin * maxButtons) / (maxButtons - 1)) -- maxButtons+1 margins for maxButtons buttons
		local buttonHeight = mathFloor(h * 0.30)

		quitscreenArea = { x, y, x + w, y + h }

		if teamResign then
			quitscreenArea[2] = quitscreenArea[2] - mathFloor(fontSize * 1.7)
		end

		quitscreenStayArea = {
			x + buttonMargin + 0 * (buttonWidth + buttonMargin),
			y + buttonMargin,
			x + buttonMargin + 0 * (buttonWidth + buttonMargin) + buttonWidth,
			y + buttonMargin + buttonHeight,
		}
		quitscreenResignArea = {
			x + buttonMargin + 1 * (buttonWidth + buttonMargin),
			y + buttonMargin,
			x + buttonMargin + 1 * (buttonWidth + buttonMargin) + buttonWidth,
			y + buttonMargin + buttonHeight,
		}
		local nextButton = 2
		if teamResign then
			quitscreenTeamResignArea = {
				x + buttonMargin + nextButton * (buttonWidth + buttonMargin),
				y + buttonMargin,
				x + buttonMargin + nextButton * (buttonWidth + buttonMargin) + buttonWidth,
				y + buttonMargin + buttonHeight,
			}
			nextButton = nextButton + 1
		end
		quitscreenQuitArea = {
			x + buttonMargin + nextButton * (buttonWidth + buttonMargin),
			y + buttonMargin,
			x + buttonMargin + nextButton * (buttonWidth + buttonMargin) + buttonWidth,
			y + buttonMargin + buttonHeight,
		}

		-- window
		UiElement(
			quitscreenArea[1],
			quitscreenArea[2],
			quitscreenArea[3],
			quitscreenArea[4],
			1,
			1,
			1,
			1,
			1,
			1,
			1,
			1,
			nil,
			{ 1, 1, 1, 0.6 + (0.34 * fadeProgress) },
			{ 0.45, 0.45, 0.4, 0.025 + (0.025 * fadeProgress) },
			nil
		)
		local color1, color2

		font:Begin(true)
		font:SetTextColor(0, 0, 0, 1)
		font:Print(
			text,
			quitscreenArea[1] + ((quitscreenArea[3] - quitscreenArea[1]) / 2),
			quitscreenArea[4] - textTopPadding,
			fontSize,
			"cn"
		)
		font:End()

		font2:Begin(true)
		font2:SetTextColor(1, 1, 1, 1)
		font2:SetOutlineColor(0, 0, 0, 0.23)

		fontSize = fontSize * 0.92

		-- stay button
		if gameIsOver or not chobbyLoaded then
			if
				mathIsInRect(mx, my, quitscreenStayArea[1], quitscreenStayArea[2], quitscreenStayArea[3], quitscreenStayArea[4])
			then
				color1 = { 0, 0.4, 0, 0.4 + (0.5 * fadeProgress) }
				color2 = { 0.05, 0.6, 0.05, 0.4 + (0.5 * fadeProgress) }
			else
				color1 = { 0, 0.25, 0, 0.35 + (0.5 * fadeProgress) }
				color2 = { 0, 0.5, 0, 0.35 + (0.5 * fadeProgress) }
			end
			UiButton(
				quitscreenStayArea[1],
				quitscreenStayArea[2],
				quitscreenStayArea[3],
				quitscreenStayArea[4],
				1,
				1,
				1,
				1,
				1,
				1,
				1,
				1,
				nil,
				color1,
				color2,
				padding * 0.5
			)
			font2:Print(
				BAR.I18N("ui.topbar.quit.stay"),
				quitscreenStayArea[1] + ((quitscreenStayArea[3] - quitscreenStayArea[1]) / 2),
				quitscreenStayArea[2] + ((quitscreenStayArea[4] - quitscreenStayArea[2]) / 2) - (fontSize / 3),
				fontSize,
				"con"
			)
		end

		-- resign button
		if not spec and not gameIsOver then
			local mouseOver = false
			if
				mathIsInRect(
					mx,
					my,
					quitscreenResignArea[1],
					quitscreenResignArea[2],
					quitscreenResignArea[3],
					quitscreenResignArea[4]
				)
			then
				color1 = { 0.4, 0, 0, 0.4 + (0.5 * fadeProgress) }
				color2 = { 0.6, 0.05, 0.05, 0.4 + (0.5 * fadeProgress) }
				mouseOver = "resign"
			else
				color1 = { 0.25, 0, 0, 0.35 + (0.5 * fadeProgress) }
				color2 = { 0.5, 0, 0, 0.35 + (0.5 * fadeProgress) }
			end
			UiButton(
				quitscreenResignArea[1],
				quitscreenResignArea[2],
				quitscreenResignArea[3],
				quitscreenResignArea[4],
				1,
				1,
				1,
				1,
				1,
				1,
				1,
				1,
				nil,
				color1,
				color2,
				padding * 0.5
			)
			font2:Print(
				BAR.I18N("ui.topbar.quit.resign"),
				quitscreenResignArea[1] + ((quitscreenResignArea[3] - quitscreenResignArea[1]) / 2),
				quitscreenResignArea[2] + ((quitscreenResignArea[4] - quitscreenResignArea[2]) / 2) - (fontSize / 3),
				fontSize,
				"con"
			)

			if teamResign then
				if
					mathIsInRect(
						mx,
						my,
						quitscreenTeamResignArea[1],
						quitscreenTeamResignArea[2],
						quitscreenTeamResignArea[3],
						quitscreenTeamResignArea[4]
					)
				then
					color1 = { 0.28, 0.28, 0.28, 0.4 + (0.5 * fadeProgress) }
					color2 = { 0.45, 0.45, 0.45, 0.4 + (0.5 * fadeProgress) }
					mouseOver = "teamResign"
				else
					color1 = { 0.18, 0.18, 0.18, 0.4 + (0.5 * fadeProgress) }
					color2 = { 0.33, 0.33, 0.33, 0.4 + (0.5 * fadeProgress) }
				end
				UiButton(
					quitscreenTeamResignArea[1],
					quitscreenTeamResignArea[2],
					quitscreenTeamResignArea[3],
					quitscreenTeamResignArea[4],
					1,
					1,
					1,
					1,
					1,
					1,
					1,
					1,
					nil,
					color1,
					color2,
					padding * 0.5
				)
				font2:Print(
					BAR.I18N("ui.topbar.quit.teamResign"),
					quitscreenTeamResignArea[1] + ((quitscreenTeamResignArea[3] - quitscreenTeamResignArea[1]) / 2),
					quitscreenTeamResignArea[2]
						+ ((quitscreenTeamResignArea[4] - quitscreenTeamResignArea[2]) / 2)
						- (fontSize / 3),
					fontSize,
					"con"
				)
			end
			if mouseOver and teamResign then
				font:Print(
					BAR.I18N("ui.topbar.hint." .. mouseOver),
					quitscreenTeamResignArea[1] - buttonMargin,
					quitscreenArea[2] + (2.5 * fontSize / 3),
					fontSize * 0.9,
					"cn"
				)
			end
		end

		-- quit button
		if gameIsOver or not chobbyLoaded then
			if
				mathIsInRect(mx, my, quitscreenQuitArea[1], quitscreenQuitArea[2], quitscreenQuitArea[3], quitscreenQuitArea[4])
			then
				color1 = { 0.4, 0, 0, 0.4 + (0.5 * fadeProgress) }
				color2 = { 0.6, 0.05, 0.05, 0.4 + (0.5 * fadeProgress) }
			else
				color1 = { 0.25, 0, 0, 0.35 + (0.5 * fadeProgress) }
				color2 = { 0.5, 0, 0, 0.35 + (0.5 * fadeProgress) }
			end
			UiButton(
				quitscreenQuitArea[1],
				quitscreenQuitArea[2],
				quitscreenQuitArea[3],
				quitscreenQuitArea[4],
				1,
				1,
				1,
				1,
				1,
				1,
				1,
				1,
				nil,
				color1,
				color2,
				padding * 0.5
			)
			font2:Print(
				BAR.I18N("ui.topbar.quit.quit"),
				quitscreenQuitArea[1] + ((quitscreenQuitArea[3] - quitscreenQuitArea[1]) / 2),
				quitscreenQuitArea[2] + ((quitscreenQuitArea[4] - quitscreenQuitArea[2]) / 2) - (fontSize / 3),
				fontSize,
				"con"
			)
		end

		font2:End()
	end
	glColor(1, 1, 1, 1)
end

local function drawSaveButton(area, label, colors, fadeProgress, padding, fontSize)
	local over = mathIsInRect(mx, my, area[1], area[2], area[3], area[4])
	local alpha = (over and 0.4 or 0.35) + 0.5 * fadeProgress
	local c1, c2 = colors[over and 3 or 1], colors[over and 4 or 2]
	UiButton(
		area[1],
		area[2],
		area[3],
		area[4],
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		nil,
		{ c1[1], c1[2], c1[3], alpha },
		{ c2[1], c2[2], c2[3], alpha },
		padding * 0.5
	)
	font2:Print(label, (area[1] + area[3]) * 0.5, (area[2] + area[4]) * 0.5 - (fontSize / 3), fontSize, "con")
end

-- Sized as the quit dialog, with room for the name's field and what it says when the name is taken.
-- (the edit box itself is drawn by the top list, drawSaveTop)
local function drawSaveWindow(fadeProgress)
	local d = saveDialog --[[@as table]]
	local w = mathFloor(320 * widgetScale)
	local base = mathFloor(w / 3.5)
	local fontSize = base / 6
	local padding = mathFloor(w / 90)
	local margin = mathFloor(base / 9)
	local buttonHeight = mathFloor(base * 0.30)
	local hintHeight = mathFloor(fontSize * 1.6)
	local textTopPadding = mathFloor(padding * 5 + fontSize)
	local h = margin + buttonHeight + hintHeight + buttonHeight + padding * 2 + textTopPadding
	local x = mathFloor((vsx / 2) - (w / 2))
	local y = mathFloor((vsy / 1.8) - (h / 2))
	local buttonWidth = mathFloor((w - margin * 3) / 2)
	local buttonTop = y + margin + buttonHeight
	local fieldBottom = buttonTop + hintHeight
	local fieldTop = fieldBottom + buttonHeight
	d.area = { x, y, x + w, y + h }
	d.cancel = { x + margin, y + margin, x + margin + buttonWidth, buttonTop }
	d.confirm = { x + w - margin - buttonWidth, y + margin, x + w - margin, buttonTop }

	UiElement(
		x,
		y,
		x + w,
		y + h,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		1,
		nil,
		{ 1, 1, 1, 0.6 + (0.34 * fadeProgress) },
		{ 0.45, 0.45, 0.4, 0.025 + (0.025 * fadeProgress) },
		nil
	)
	RectRound(x + margin, fieldBottom, x + w - margin, fieldTop, padding, 1, 1, 1, 1, K.saveField)

	font:Begin(true)
	font:SetTextColor(0, 0, 0, 1)
	font:Print(BAR.I18N("ui.topbar.save.title"), x + (w / 2), y + h - textTopPadding, fontSize, "cn")
	if d.exists then
		local hintY = buttonTop + mathFloor(hintHeight * 0.5)
		font:Print(BAR.I18N("ui.topbar.save.exists"), x + (w / 2), hintY, fontSize * 0.9, "cvn")
	end
	font:End()

	font2:Begin(true)
	font2:SetTextColor(1, 1, 1, 1)
	font2:SetOutlineColor(0, 0, 0, 0.23)
	local buttonFontSize = fontSize * 0.92
	local cancelLabel = BAR.I18N("ui.topbar.save.cancel")
	drawSaveButton(d.cancel, cancelLabel, SAVE_BUTTONS.cancel, fadeProgress, padding, buttonFontSize)
	local label = BAR.I18N(d.exists and "ui.topbar.save.replace" or "ui.topbar.button.save")
	local colors = d.exists and SAVE_BUTTONS.replace or SAVE_BUTTONS.save
	drawSaveButton(d.confirm, label, colors, fadeProgress, padding, buttonFontSize)
	font2:End()

	d.box:setRect(x + margin, fieldBottom, x + w - margin, fieldTop, mathFloor(fontSize))
end

-- the save dialog without its edit box
local function drawSaveStatic()
	glColor(0, 0, 0, (dlg.gs and 0.18 or 0.35) * dlg.fade)
	gl.Rect(0, 0, vsx, vsy)
	drawSaveWindow(dlg.fade)
	glColor(1, 1, 1, 1)
end

-- the save dialog's top list: the static list plus the edit box (caret fade, typed text, selection)
local function drawSaveTop()
	glCallList(dlist.saveStatic)
	saveDialog.box:draw()
	glColor(1, 1, 1, 1)
end

-- What a save may be called. The name goes through commands that split on spaces, into a file name and into the
-- lobby's start script, so anything else becomes an underscore, a whole UTF-8 character at a time: the field's
-- caret stays where it is.
local function saveFileName(text)
	return (text:gsub("[\192-\255][\128-\191]*", "_"):gsub("[^%w%-_%(%)]", "_"))
end

local function saveNameChanged(text)
	local d = saveDialog --[[@as table]]
	local clean = saveFileName(text)
	d.box.text = clean
	local exists = clean ~= "" and VFS.FileExists("Saves/" .. clean .. ".ssf")
	if exists ~= d.exists then
		dlg.dirty = true
	end
	d.exists = exists
	dlg.topDirty = true
end

local function closeSaveDialog()
	saveDialog = nil
	if widgetHandler.textOwner == widget then
		widgetHandler.textOwner = nil
	end
	Spring.SDLStopTextInput()
	local guishader = WG.guishader ---@type table?
	if guishader then
		guishader.setScreenBlur(false)
	end
	widgetHandler:Unpause(SAVE_PAUSE)
end

local function saveAsTyped()
	local d = saveDialog --[[@as table]]
	local typed = d.box:getText()
	Spring.SendCommands("savegame " .. (typed ~= "" and typed or d.fallback))
	closeSaveDialog()
end

-- Pauses, and asks for the name: the time unless the player changes it. It opens selected, so typing replaces it.
local function openSaveDialog()
	local name = os.date("%Y%m%d_%H%M%S")
	local box = Editbox.new({
		text = name,
		placeholder = name,
		keepPlaceholder = true,
		plain = true,
		outline = { 0, 0, 0, 0.4 },
		maxChars = 64,
		onChange = saveNameChanged,
	})
	box:focus()
	box:setCaret(0)
	box:setCaret(#name, true)
	saveDialog = { opened = now, box = box, fallback = name, held = Spring.GetPressedKeys() }
	widgetHandler:Pause(SAVE_PAUSE)
	-- chat has to be asked to let go: toggling its flag is the public way, and it persists it, so straight back
	if WG.chat and WG.chat.isInputActive and WG.chat.isInputActive() then
		WG.chat.setHandleInput(false)
		WG.chat.setHandleInput(true)
	end
	widgetHandler.textOwner = widget
end

local function pressOnSaveDialog(x, y)
	local d = saveDialog --[[@as table]]
	if not d.area or d.box:mousePress(x, y) then
		return
	end
	local cancel = d.cancel --[[@as table]]
	local confirm = d.confirm --[[@as table]]
	local toCancel = mathIsInRect(x, y, cancel[1], cancel[2], cancel[3], cancel[4])
	if toCancel or mathIsInRect(x, y, confirm[1], confirm[2], confirm[3], confirm[4]) then
		if playSounds then
			Spring.PlaySoundFile(leftclick, 0.75, "ui")
		end
		if toCancel then
			closeSaveDialog()
		else
			saveAsTyped()
		end
	end
end

-- which quit dialog button the cursor is over (0: none), against the rects of the last build
local function quitHoverKey()
	if not quitscreenArea then
		return 0
	end
	local a = quitscreenStayArea
	if a and mathIsInRect(mx, my, a[1], a[2], a[3], a[4]) then
		return 1
	end
	a = quitscreenResignArea
	if a and mathIsInRect(mx, my, a[1], a[2], a[3], a[4]) then
		return 2
	end
	a = quitscreenTeamResignArea
	if teamResign and a and mathIsInRect(mx, my, a[1], a[2], a[3], a[4]) then
		return 3
	end
	a = quitscreenQuitArea
	if a and mathIsInRect(mx, my, a[1], a[2], a[3], a[4]) then
		return 4
	end
	return 0
end

local function saveHoverKey()
	local d = saveDialog --[[@as table]]
	local a = d.cancel
	if a and mathIsInRect(mx, my, a[1], a[2], a[3], a[4]) then
		return 1
	end
	a = d.confirm
	if a and mathIsInRect(mx, my, a[1], a[2], a[3], a[4]) then
		return 2
	end
	return 0
end

-- replaces the dialog list DrawScreen (or the guishader) draws
local function swapDialogList(list)
	local old = dlist.quit
	if old then
		local gs = WG.guishader
		if gs then
			gs.removeRenderDlist(old)
		end
		glDeleteList(old)
	end
	dlist.quit = list
	dlg.inserted = nil
end

local function closeDialogLists()
	swapDialogList(nil)
	if dlist.saveStatic then
		dlist.saveStatic = glDeleteList(dlist.saveStatic)
	end
	dlg.kind = nil
	dlg.dirty = true
	dlg.topDirty = true
end

-- The open dialog: lists rebuilt only when what they show changed, then drawn (or handed to the guishader)
local function drawDialog()
	spSetMouseCursor("cursornormal")
	mx, my = spGetMouseState()
	local d = dlg
	local gs = WG.guishader
	local kind = showQuitscreen and 1 or 2
	local opened = showQuitscreen or saveDialog.opened
	local step = mathFloor((now - opened) * 60 + 0.01) -- (+0.01: a frame exactly on a 1/60 s step counts)
	if step > K.fadeSteps then
		step = K.fadeSteps
	elseif step < 0 then
		step = 0
	end
	local rebuild = d.dirty or d.kind ~= kind or d.opened ~= opened or d.step ~= step or d.gs ~= gs
	local hover
	if kind == 1 then
		hover = quitHoverKey()
		if (hideQuitWindow ~= nil) ~= d.hide then
			rebuild = true
		end
		if now >= d.nextTextCheck then
			d.nextTextCheck = now + K.textCheck
			if not hideQuitWindow then
				local key, canTeamResign = quitTextState()
				if key ~= d.textKey or canTeamResign ~= d.teamResign then
					rebuild = true
				end
			end
		end
	else
		-- here, after this frame's Updates: a window that closed to make way stops text input in its own
		if not saveDialog.textStarted then
			saveDialog.textStarted = true
			Spring.SDLStartTextInput()
		end
		hover = saveHoverKey()
	end
	if hover ~= d.hover then
		rebuild = true
	end

	if rebuild then
		d.dirty = false
		d.kind, d.opened, d.step, d.gs, d.hover = kind, opened, step, gs, hover
		d.hide = hideQuitWindow ~= nil
		d.fade = step / K.fadeSteps
		if kind == 1 then
			if dlist.saveStatic then
				dlist.saveStatic = glDeleteList(dlist.saveStatic)
			end
			swapDialogList(glCreateList(drawQuitContents))
			-- the rects may have moved: the hovered button again, against the new ones
			d.hover = quitHoverKey()
		else
			if dlist.saveStatic then
				glDeleteList(dlist.saveStatic)
			end
			dlist.saveStatic = glCreateList(drawSaveStatic)
			d.hover = saveHoverKey()
			d.topDirty = true
		end
	end
	if kind == 2 then
		local topStep = mathFloor(now * K.saveCaretHz)
		if d.topDirty or topStep ~= d.topStep or saveDialog.box.dragging then
			d.topDirty = false
			d.topStep = topStep
			swapDialogList(glCreateList(drawSaveTop))
		end
	end

	-- background
	if gs then
		if d.inserted ~= gs then
			gs.insertRenderDlist(dlist.quit)
			d.inserted = gs
		end
		-- the base set it every frame, which made the guishader rebuild its screen stencil every frame
		if not (gs.getScreenBlur and gs.getScreenBlur()) then
			gs.setScreenBlur(true)
		end
	else
		glCallList(dlist.quit)
	end
end

-- Second return value: the window refused to close (the keybind editor raises a guard
-- when there are unsaved edits) and is still up.
local function closeWindow(name)
	if WG[name] ~= nil and WG[name].isvisible() then
		WG[name].toggle(false)
		return true, WG[name].isvisible() == true
	end
	return false, false
end

local function hideWindows()
	local closedWindow = false
	local stillOpen = false

	local function hide(name)
		local closed, blocked = closeWindow(name)
		closedWindow = closed or closedWindow
		stillOpen = blocked or stillOpen
	end

	hide("options")
	hide("scavengerinfo")
	hide("missioninfo")
	hide("keybinds")
	hide("changelog")
	hide("gameinfo")
	hide("teamstats")
	hide("widgetselector")
	if showQuitscreen then
		closedWindow = true
	end
	if saveDialog then
		closedWindow = true
		closeSaveDialog()
	end

	showQuitscreen = nil

	if WG.guishader then
		WG.guishader.setScreenBlur(false)
	end

	return closedWindow, stillOpen
end

local function toggleWindow(name)
	local isvisible = false
	if WG[name] ~= nil then
		isvisible = WG[name].isvisible()
	end
	local _, stillOpen = hideWindows()
	-- Opening another window on top of a window that refused to close would bury its guard.
	if stillOpen then
		return isvisible
	end
	if WG[name] ~= nil and isvisible ~= true then
		WG[name].toggle()
	end
	return isvisible
end

local function applyButtonAction(button)
	if playSounds then
		Spring.PlaySoundFile(leftclick, 0.8, "ui")
	end

	local isvisible = false
	if button == "quit" or button == "resign" then
		if not gameIsOver and chobbyLoaded and button == "quit" then
			Spring.SendLuaMenuMsg("showLobby")
		else
			local oldShowQuitscreen
			if showQuitscreen then
				oldShowQuitscreen = showQuitscreen
				isvisible = true
			end

			hideWindows()

			if oldShowQuitscreen then
				if isvisible ~= true then
					showQuitscreen = oldShowQuitscreen
					if WG.guishader then
						WG.guishader.setScreenBlur(true)
					end
				end
			else
				showQuitscreen = now
			end
		end
	elseif button == "options" then
		toggleWindow("options")
	elseif button == "save" then
		hideWindows()
		if isSinglePlayer and cfg.allowSavegame and WG.savegame then
			openSaveDialog()
		end
	elseif button == "scavengers" then
		toggleWindow("scavengerinfo")
	elseif button == "mission" then
		toggleWindow("missioninfo")
	elseif button == "keybinds" then
		toggleWindow("keybinds")
	elseif button == "changelog" then
		toggleWindow("changelog")
	elseif button == "stats" then
		toggleWindow("teamstats")
	elseif button == "info" then
		toggleWindow("gameinfo")
	end
	-- opening the changelog clears its highlight: re-read now rather than at the next check
	changelogActive = (WG.changelog and WG.changelog.haschanges()) and true or false
end

-- WG.topbar is shared with the Top Bar widget. Consumers guard on the table, not on the
-- individual functions, so when that widget is not running its half of the API has to be
-- filled in rather than left missing. Provided in Initialize and re-checked when the table
-- changes, when the Top Bar's GetPosition goes missing (it shut down) and with every button check.
local fallback = {}

local function provide(name, fn)
	local current = WG.topbar[name]
	if current == nil then
		fallback[name] = fn
		WG.topbar[name] = fn
	elseif fallback[name] ~= nil and current ~= fallback[name] then
		fallback[name] = nil -- the Top Bar widget took over
	end
end

local function noop() end
local function returnFalse()
	return false
end
-- defined once (the base made new closures for these on every check, every frame)
local function fallbackGetPosition()
	local buttonsBottom = showButtons and buttonsArea[2] or buttonsArea[4]
	return { topbarArea[1], topbarArea[2], topbarArea[3], topbarArea[4], widgetScale, buttonsBottom }
end
local function fallbackGetFreeArea()
	-- no resource bars to make room for, so everything left of the strip is free
	return { topbarArea[1], topbarArea[2], buttonsArea[1], topbarArea[4], widgetScale }
end
local function fallbackGetSkewConfig()
	return {
		useSkew = cfg.useSkew,
		skewTan = K.skewTan,
		smallElementHeightFraction = cfg.smallElementHeightFraction,
	}
end

local function provideTopBarFallbacks()
	seenTopbar = WG.topbar
	if not WG.topbar then
		return
	end
	provide("GetPosition", fallbackGetPosition)
	provide("GetFreeArea", fallbackGetFreeArea)
	provide("GetSkewConfig", fallbackGetSkewConfig)
	-- there are no resource bars or indicators to show, hide or update
	provide("updateTopBarEnergy", noop)
	provide("setResourceBarsVisible", noop)
	provide("setIndicatorsVisible", noop)
	provide("getResourceBarsVisible", returnFalse)
	provide("getIndicatorsVisible", returnFalse)
end

local function removeFallbacks()
	if not WG.topbar then
		return
	end
	for name, fn in pairs(fallback) do
		if WG.topbar[name] == fn then
			WG.topbar[name] = nil
		end
	end
end

-- Which buttons exist depends on widgets that may load after this one (game info, save
-- game, the scenario panels) and on game state, so the set is re-checked periodically
-- instead of only at startup. The 12 fields are compared in place (the base built a
-- table and a string per check).
local sig = {}
local function sigSet(i, v)
	if sig[i] ~= v then
		sig[i] = v
		return true
	end
	return false
end
local function buttonSetChanged()
	local changedModoptions = 0
	if WG.gameinfo and WG.gameinfo.getChangedModoptionsCount then
		changedModoptions = WG.gameinfo.getChangedModoptionsCount() or 0
	end
	local c = sigSet(1, WG.options ~= nil)
	c = sigSet(2, WG.keybinds ~= nil) or c
	c = sigSet(3, WG.changelog ~= nil) or c
	c = sigSet(4, WG.teamstats ~= nil) or c
	c = sigSet(5, WG.scavengerinfo ~= nil) or c
	c = sigSet(6, WG.missioninfo ~= nil) or c
	c = sigSet(7, WG.savegame ~= nil) or c
	c = sigSet(8, changedModoptions) or c
	c = sigSet(9, gameIsOver) or c
	c = sigSet(10, gameStarted) or c
	c = sigSet(11, spec) or c
	c = sigSet(12, chobbyLoaded) or c
	return c
end

-- 2 Hz: from GameFrame while the game runs, else from DrawScreen
local function checkButtonSet(t)
	nextButtonCheck = t + 0.5
	provideTopBarFallbacks()
	if buttonSetChanged() then
		refreshButtons = true
	end
	changelogActive = (WG.changelog and WG.changelog.haschanges()) and true or false
	local _, _, isPaused = Spring.GetGameSpeed()
	gamePaused = isPaused and true or false
	applyGuishader()
end

-- the base's blink curve at 60 fps, from the pulse clock: linear rise, then sqrt fall
local function blinkCurve(t)
	local ph = t % K.blinkPeriod
	if ph < K.blinkRise then
		return ph / K.blinkRise
	end
	return mathSqrt(1 - (ph - K.blinkRise) / K.blinkFall)
end

local function pollHover(t)
	nextHoverPoll = t + (hoveringButtons and 0.25 or 1)
	local x, y = spGetMouseState()
	setHover(x, y)
end

function widget:DrawScreen()
	local t = osClock()
	local dt = t - now
	now = t

	local tb = WG.topbar
	if tb ~= seenTopbar or (tb and tb.GetPosition == nil) then
		provideTopBarFallbacks()
	end
	if t >= nextButtonCheck then
		checkButtonSet(t)
	end
	if t - lastIsAbove > 0.25 and t >= nextHoverPoll then
		pollHover(t)
	end

	if hoveringButtons then
		spSetMouseCursor("cursornormal")
	end

	if refreshButtons then
		refreshButtons = false
		updateButtons()
	end
	if stripDirty then
		rebuildStrip()
	end

	if autoHideButtons then
		local wanted = buttonsArea[1] ~= nil and hoveringButtons
		if wanted ~= showButtons then
			showButtons = wanted
			applyGuishader()
		end
	end

	if showButtons and dlist.strip then
		glCallList(dlist.strip)

		-- changelog changes highlight
		if changelogActive and dlist.changelog then
			if not gamePaused and dt > 0 and dt < 0.5 then
				pulseT = (pulseT + dt) % K.blinkPeriod
			end
			glColor(1, 1, 1, 0.1 * blinkCurve(pulseT))
			glCallList(dlist.changelog)
		end

		-- hovered?
		if hoveredButton and not showQuitscreen and not saveDialog then
			drawHover()
		end
	end

	if showQuitscreen or saveDialog then
		drawDialog()
	elseif dlist.quit then
		closeDialogLists()
	end
end

function widget:IsAbove(x, y)
	lastIsAbove = now
	setHover(x, y)
	return false
end

function widget:MouseMove(x, y)
	setHover(x, y)
end

function widget:GameFrame(n)
	local tb = WG.topbar
	if tb ~= seenTopbar or (tb and tb.GetPosition == nil) then
		provideTopBarFallbacks()
	end
	if n % 15 == 0 then
		checkButtonSet(osClock())
	end
end

function widget:MousePress(x, y, button)
	setHover(x, y)
	if saveDialog then
		if button == 1 then
			pressOnSaveDialog(x, y)
		end
		dlg.topDirty = true
		return true
	end
	if button == 1 then
		if showQuitscreen and quitscreenArea then
			if mathIsInRect(x, y, quitscreenArea[1], quitscreenArea[2], quitscreenArea[3], quitscreenArea[4]) then
				if
					(gameIsOver or not chobbyLoaded or not spec)
					and mathIsInRect(
						x,
						y,
						quitscreenStayArea[1],
						quitscreenStayArea[2],
						quitscreenStayArea[3],
						quitscreenStayArea[4]
					)
				then
					if playSounds then
						Spring.PlaySoundFile(leftclick, 0.75, "ui")
					end

					showQuitscreen = nil
					if WG.guishader then
						WG.guishader.setScreenBlur(false)
					end
				end
				if
					(gameIsOver or not chobbyLoaded)
					and mathIsInRect(
						x,
						y,
						quitscreenQuitArea[1],
						quitscreenQuitArea[2],
						quitscreenQuitArea[3],
						quitscreenQuitArea[4]
					)
				then
					if playSounds then
						Spring.PlaySoundFile(leftclick, 0.75, "ui")
					end

					if not chobbyLoaded then
						Spring.SendCommands("QuitForce") -- Exit the game completely
					else
						Spring.SendCommands("ReloadForce") -- Exit to the lobby
					end

					showQuitscreen = nil
					hideQuitWindow = now
				end
				if
					not spec
					and not gameIsOver
					and mathIsInRect(
						x,
						y,
						quitscreenResignArea[1],
						quitscreenResignArea[2],
						quitscreenResignArea[3],
						quitscreenResignArea[4]
					)
				then
					if playSounds then
						Spring.PlaySoundFile(leftclick, 0.75, "ui")
					end
					Spring.SendCommands("spectator")
					showQuitscreen = nil
					if WG.guishader then
						WG.guishader.setScreenBlur(false)
					end
				end
				if
					not spec
					and not gameIsOver
					and teamResign
					and mathIsInRect(
						x,
						y,
						quitscreenTeamResignArea[1],
						quitscreenTeamResignArea[2],
						quitscreenTeamResignArea[3],
						quitscreenTeamResignArea[4]
					)
				then
					if playSounds then
						Spring.PlaySoundFile(leftclick, 0.75, "ui")
					end
					Spring.SendCommands("say !cv resign")
					showQuitscreen = nil
					if WG.guishader then
						WG.guishader.setScreenBlur(false)
					end
				end
			else
				showQuitscreen = nil
				if WG.guishader then
					WG.guishader.setScreenBlur(false)
				end
			end
			return true
		end

		local clickedButton = buttonAt(x, y)
		if clickedButton then
			applyButtonAction(clickedButton)
			return true
		end
	else
		if showQuitscreen and quitscreenArea then
			return true
		end
	end

	-- a click on the strip itself never falls through to the world
	if hoveringButtons then
		return true
	end
end

function widget:MouseWheel(up, value) -- up = true/false , value = -1/1
	if saveDialog or (showQuitscreen and quitscreenArea) then
		return true
	end
end

function widget:KeyPress(key)
	if saveDialog then
		dlg.topDirty = true
		if key == KEYSYMS.ESCAPE then
			closeSaveDialog()
		elseif key == KEYSYMS.RETURN or key == KEYSYMS.KP_ENTER then
			saveAsTyped()
		else
			saveDialog.box:keyPress(key)
		end
		return true
	end
	if key == 27 then -- ESC
		if not WG.options or (WG.options.disallowEsc and not WG.options.disallowEsc()) then
			local escDidSomething = hideWindows()
			if cfg.escapeKeyPressesQuit and not escDidSomething then
				applyButtonAction("quit")
			end
		end
	end
	if showQuitscreen and quitscreenArea then
		return true
	end
end

-- A key held when the dialog opened: its release is not the field's to swallow. Once per key.
function widget:KeyRelease(key)
	if not saveDialog then
		return false
	end
	if saveDialog.held[key] then
		saveDialog.held[key] = nil
		return false
	end
	return true
end

function widget:TextInput(char)
	if saveDialog then
		dlg.topDirty = true
		saveDialog.box:textInput(char)
		return true
	end
	return false
end

function widget:GameStart()
	gameStarted = true
	refreshButtons = true
end

function widget:GameOver()
	gameIsOver = true
	refreshButtons = true
	dlg.dirty = true
end

function widget:PlayerChanged()
	spec = Spring.GetSpectatingState()
	myAllyTeamID = Spring.GetLocalAllyTeamID()
	myTeamID = Spring.GetLocalTeamID()
	myAllyTeamList = Spring.GetTeamList(myAllyTeamID)
	refreshButtons = true
	dlg.dirty = true
end

function widget:LanguageChanged()
	refreshButtons = true
	dlg.dirty = true
end

function widget:MouseRelease(x, y, button)
	if saveDialog or (showQuitscreen and quitscreenArea) then
		return true
	end
end

function widget:Initialize()
	if Spring.GetMenuName and string.find(string.lower(Spring.GetMenuName()), "chobby") then
		chobbyLoaded = true
		Spring.SendLuaMenuMsg("disableLobbyButton")
	end

	-- The quit/resign and save dialogs count as windows: while one is up, the handler can hide
	-- the rest of the interface (springsetting WindowsHideInterface), and this widget stays.
	widgetHandler:RegisterModalWindow(widget, function()
		return showQuitscreen ~= nil or saveDialog ~= nil
	end)

	-- This widget was split out of "Top Bar", which used to persist the auto-hide setting.
	-- Adopt it once so the setting survives the split.
	if not configLoaded and widgetHandler.configData then
		local previous = widgetHandler.configData["Top Bar"]
		if previous and previous.autoHideButtons ~= nil then
			autoHideButtons = previous.autoHideButtons
			showButtons = not autoHideButtons
		end
	end

	-- Shared with the Top Bar widget: each fills in its own half, so either can run alone.
	WG.topbar = WG.topbar or {}

	-- (the save dialog too: what makes way for the quit dialog makes way for it)
	WG.topbar.showingQuit = function()
		return showQuitscreen or (saveDialog and saveDialog.opened)
	end

	WG.topbar.hideWindows = function()
		hideWindows()
	end

	WG.topbar.buttonAt = function(x, y)
		return buttonAt(x, y)
	end

	-- The strip's rect, for widgets that place themselves under it (ecostats, the
	-- spectator HUD). While auto-hidden it has no height, bottom at the screen top, so
	-- those widgets move up into the space it gave up.
	WG.topbar.GetButtonsPosition = function()
		if not buttonsArea[1] then
			return nil
		end
		local bottom = showButtons and buttonsArea[2] or buttonsArea[4]
		return { buttonsArea[1], bottom, buttonsArea[3], buttonsArea[4], widgetScale }
	end

	WG.topbar.setAutoHideButtons = function(value)
		autoHideButtons = value
		showButtons = not value
		refreshButtons = true
	end

	WG.topbar.getAutoHideButtons = function()
		return autoHideButtons
	end

	WG.topbar.getShowButtons = function()
		return showButtons
	end

	widget:ViewResize()
	buttonSetChanged() -- stores the current set
	local t = osClock()
	checkButtonSet(t) -- fallbacks, changelog / paused state
	refreshButtons = false -- the set was just laid out by ViewResize
end

function widget:Shutdown()
	if saveDialog then
		closeSaveDialog()
	end
	removeFallbacks()

	deleteHoverLists()
	for _, name in ipairs({ "buttons", "strip", "changelog", "saveStatic" }) do
		if dlist[name] then
			dlist[name] = glDeleteList(dlist[name])
		end
	end
	if dlist.background then
		if WG.guishader then
			WG.guishader.RemoveDlist("topbar_buttons")
		end
		dlist.background = glDeleteList(dlist.background)
	end
	if dlist.quit then
		if WG.guishader then
			WG.guishader.removeRenderDlist(dlist.quit)
			WG.guishader.setScreenBlur(false)
		end
		dlist.quit = glDeleteList(dlist.quit)
	end
	if strip.tex then
		gl.DeleteTexture(strip.tex)
		strip.tex = nil
	end

	if WG.topbar then
		WG.topbar.showingQuit = nil
		WG.topbar.hideWindows = nil
		WG.topbar.buttonAt = nil
		WG.topbar.GetButtonsPosition = nil
		WG.topbar.setAutoHideButtons = nil
		WG.topbar.getAutoHideButtons = nil
		WG.topbar.getShowButtons = nil
		-- the Top Bar widget may still be using the table for its own half
		if next(WG.topbar) == nil then
			WG.topbar = nil
		end
	end
end

function widget:GetConfigData()
	return { autoHideButtons = autoHideButtons }
end

function widget:SetConfigData(data)
	configLoaded = true
	if data.autoHideButtons ~= nil then
		autoHideButtons = data.autoHideButtons
		showButtons = not autoHideButtons
	end
end
