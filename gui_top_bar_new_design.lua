local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Top Bar New Design",
		desc = "Stock top bar with a round buildpower gauge between metal and energy, new layout. Disable the stock \"Top Bar\" and \"Top Bar with Buildpower\" when using this.",
		author = "Floris, Robert82",
		date = "Oct, 2026",
		license = "GNU GPL, v2 or later",
		layer = -95000,
		enabled = false,
		handler = true, --can use widgetHandler:x()
	}
end

--------------------------------------------------------------------------------
-- Top Bar New Design
-- A visual variant of "Top Bar with Buildpower" (gui_top_bar_buildpower.lua), which is
-- the stock gui_top_bar.lua (see stock_reference/COMMIT.txt for the exact BAR revision)
-- plus buildpower (BP) tracking. The BP numbers, alerts, tooltip and options are the same;
-- only the look differs:
-- * The look follows the design mockup (design/mockup_measurements.md, sizes in units of the
--   strip height in bpUi.D / bpUi.C): opaque panels with sharp corners and 42.5 degree outer
--   slants, hard drop shadows, metal | gauge | energy touching, wind / tidal / coms as one panel.
-- * BP is a round gauge between metal and energy: a 216 degree ring with round caps (used /
--   reserved / idle), the energy support marker and the wind range arc outside the ring, the
--   metal support pointer inside it, a hexagon icon and the percent text. Its panel hangs below
--   the top bar.
-- * Metal and energy mirror each other around the gauge: the income/pull column on the
--   outer side, the fill bar on the upper row (metal fills from the gauge outward), storage and
--   current value with the resource icon on the lower row. Both have a red share knob (also in
--   single-player teams), energy the white conversion knob.
--   The overflow/wasting banner hangs under its section, so it covers no numbers.
-- BP hooks in stock functions are marked "-- BP", layout changes in stock functions
-- "-- ND"; the BP state lives in the tables bp / bpTrack / bpUi (one block of functions
-- after updateResbarValues) and new call-ins are appended at the end of the file.
-- Disable the stock "Top Bar" and "Top Bar with Buildpower" widgets when enabling this one.
--------------------------------------------------------------------------------

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
}

-- Configuration (consolidated into table to save local slots)
local cfg = {
	relXpos = 0.3,
	borderPadding = 5,
	bladeSpeedMultiplier = 0.2,
	escapeKeyPressesQuit = false,
	allowSavegame = true, -- Spring.Utilities.ShowDevUI()
	spawnWarpInFrame = Game.spawnWarpInFrame or 90, -- compat: constant added Feb 2026
	useSkew = true, -- toggle trapezoidal/parallelogram skew on all UI elements
	skewAngleDeg = 42.5, -- angle of skew slope in degrees (ND: the mockup slant)
	smallElementHeightFraction = 0.64, -- wind/tidal/coms/buttons height as fraction of topbar (ND: mockup)
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
local prevWind = nil
-- Compatibility: user widgets on game builds before July 2026 have no BAR module table.
-- Take what exists and fall back to the older Spring equivalents (one extra local).
local BAR = {
	I18N = (BAR and BAR.I18N) or Spring.I18N or function(key)
		return key
	end,
	Lava = (BAR and BAR.Lava) or Spring.Lava or {
		isLavaMap = Spring.GetModOptions().map_waterislava == true or (Game.waterDamage or 0) > 0,
	},
}
local displayTidalSpeed = not BAR.Lava.isLavaMap
local tidalSpeed = Spring.GetTidal() -- for now assumed that it is not dynamically changed
local tidalSpeedText = "\255\231\220\181" .. tostring(tidalSpeed)
local tidalWaveAnimationHeight = 10
local windRotation = 0
local minWind = Game.windMin
local maxWind = Game.windMax
local minWindText = "\255\166\166\166" .. tostring(minWind)
local maxWindText = "\255\166\166\166" .. tostring(maxWind)
local noWindText1 = "\255\200\200\200" .. BAR.I18N("ui.topbar.wind.nowind1")
local noWindText2 = "\255\200\200\200" .. BAR.I18N("ui.topbar.wind.nowind2")
local windFunctions
do -- Compatibility: require() is refused or missing for user widgets on builds before Oct 2026
	local ok, mod = pcall(require, "common/wind_functions")
	if not (ok and type(mod) == "table") then
		ok, mod = pcall(VFS.Include, "common/wind_functions.lua", nil, VFS.ZIP)
	end
	if ok and type(mod) == "table" then
		windFunctions = mod
	else -- same approximations the module falls back to when the lookup tables have no entry
		windFunctions = {
			averageWindLookup = {},
			getWindRisk = function()
				return (Game.windMin + Game.windMax >= 0.5) and "0" or "100"
			end,
			isNoWind = function()
				return (Game.windMin + Game.windMax) < 0.5
			end,
		}
	end
end
local noWind = windFunctions.isNoWind() -- constant per game: Game.windMin/windMax never change

local function refreshWindTidalTextCache()
	tidalSpeedText = "\255\231\220\181" .. tostring(tidalSpeed)
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
local resbarArea = { metal = {}, energy = {} }
local resbarDrawinfo = { metal = {}, energy = {} }
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
local updateRes = { metal = { false, false, false, false }, energy = { false, false, false, false } }

-- Display Lists (consolidated into table to save local slots)
local dlist = {
	windText = {},
	resValuesBar = {},
	resValues = {},
	resbar = { metal = {}, energy = {} },
	energyGlow = nil,
	quit = nil,
	buttons = nil,
	coms = nil,
	wind1 = nil,
	wind2 = nil,
	tidal2 = nil,
}
resbarArea.BP, resbarDrawinfo.BP, dlist.resbar.BP = {}, {}, {} -- BP

-- Caching (consolidated into table to save local slots)
local cache = {
	lastPullIncomeText = { metal = -1, energy = -1 },
	lastStorageValue = { metal = -1, energy = -1 },
	lastStorageText = { metal = "", energy = "" },
	lastWarning = { metal = nil, energy = nil },
	lastValueWidth = { metal = -1, energy = -1 },
	lastResbarValueWidth = { metal = 1, energy = 1 },
	lastDrawnValue = { metal = "", energy = "" },
	warningCleared = { metal = false, energy = false },
	showIndicators = true,
}
cache.lastStorageWidth = { metal = 0, energy = 0 } -- ND: width of the drawn storage number (sizes its clear rect)

-- Reused scratch tables for DrawScreen to avoid per-frame allocations.
local resourceNames = { "metal", "energy" }
local windTextScissor = { 0, 0, 0, 0 }
local comCounterScissor = { 0, 0, 0, 0 }
local storageScissors = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
local activeStorageScissors = { nil, nil }

-- Buildpower (all BP state lives in these three tables; see design/integration_design.md)
local bp = { cfg = { enabled = true, indicators = true, windRange = true,
	alerts = true, icon = true, debugTooltip = false } } -- data fields: bpTrack.reset, spec section 11
local bpTrack = { perFrame = 20, frameStep = 3 } -- unit tracking state, filled by bpTrack.reset
local bpUi = { last = {}, s = {}, hang = 0 } -- render caches and draw functions; hang: how far the gauge reaches under the bar

-- Smoothing
local smoothedResources = {
	metal = { 0, 0, 0, 0, 0, 0 }, -- Init
	energy = { 0, 0, 0, 0, 0, 0 }, -- Init
}
local smoothingFactor = 0.5
local oneMinusSmoothingFactor = 1 - smoothingFactor
local function smoothResources()
	local sm = smoothedResources.metal
	local rm = r.metal
	local se = smoothedResources.energy
	local re = r.energy
	for i = 1, 6 do
		sm[i] = sm[i] == 0 and rm[i] or (smoothingFactor * rm[i] + oneMinusSmoothingFactor * sm[i])
		se[i] = se[i] == 0 and re[i] or (smoothingFactor * re[i] + oneMinusSmoothingFactor * se[i])
	end
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
	nextSlowUpdate = 0,
	nextBarsUpdate = 0,
	lastUpdateTime = 0,
	gameFrameHappened = false,
	deferResourceUpdate = false,
	guishaderCheckUpdateRate = 0.5,
	nextSmoothUpdate = 0,
	nextForcedBarsUpdate = 0,
}

local blinkDirection = true
local blinkProgress = 0
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
	widgetScale = (vsy / height) * 0.0425 * ui_scale
	xPos = mathFloor(vsx * cfg.relXpos)

	widgetSpaceMargin = WG.FlowUI.elementMargin
	bgpadding = WG.FlowUI.elementPadding
	RectRound = WG.FlowUI.Draw.RectRound
	-- Compatibility: older FlowUI without the skewed quad (May 2026) or the outline (Nov 2025) drawers.
	-- Only added when missing, so other widgets are unaffected.
	if not WG.FlowUI.Draw.RectRoundQuad then
		cfg.useSkew = false
		WG.FlowUI.Draw.RectRoundQuad = function(px, py, sx, sy, cs, tl, tr, br, bl, c1, c2)
			return RectRound(px, py, sx, sy, cs, tl, tr, br, bl, c1, c2)
		end
	end
	if not WG.FlowUI.Draw.RectRoundOutline then
		WG.FlowUI.Draw.RectRoundOutline = function() end
	end
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
	cache.lastValueWidth = { metal = -1, energy = -1 }

	init()
end

-- --- OPTIMIZATION: Memoized short() function to reduce string allocations.
local shortCache = {}
local shortCacheCount = 0
local function short(n, f)
	f = f or 0
	local key = n .. ":" .. f
	if shortCache[key] then
		return shortCache[key]
	end

	local result
	if n > 9999999 then
		result = stringFormat("%." .. f .. "fm", n / 1000000)
	elseif n > 9999 then
		result = stringFormat("%." .. f .. "fk", n / 1000)
	else
		result = stringFormat("%." .. f .. "f", n)
	end

	-- Safety net to prevent the cache from growing indefinitely over a very long game.
	if shortCacheCount > 500 then
		shortCache = {}
		shortCacheCount = 0
	end

	shortCache[key] = result
	shortCacheCount = shortCacheCount + 1
	return result
end

-- ND: income / pull column: at most 3 digits plus a unit (815, 1.9k, 12k, 815k, 1.2m, 12m), so the narrow column
-- seldom has to shrink a number (stock short() prints 1000 to 9999 with 4 digits)
function bpUi.piText(n)
	if n < 999.5 then
		return stringFormat("%.0f", n)
	elseif n < 9950 then
		return stringFormat("%.1fk", n / 1000)
	elseif n < 999500 then
		return stringFormat("%.0fk", n / 1000)
	elseif n < 9950000 then
		return stringFormat("%.1fm", n / 1000000)
	end
	return stringFormat("%.0fm", n / 1000000)
end


local function updateComs(forceText)
	local area = comsArea

	local texPath = string.lower(string.gsub(textures.com, ":.:", ""))

	if dlist.coms then
		glDeleteList(dlist.coms)
	end
	comsDlistUpdate = true
	dlist.coms = glCreateList(bpUi.drawComs, area, texPath, gameFrame > 0 or forceText) -- ND: icon, own and enemy count in a row

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

	bpUi.windLists(area) -- ND: blades icon with a shadow at the left of the wind segment

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

	if dlist.tidal2 then
		glDeleteList(dlist.tidal2)
	end
	tidalWaveAnimationHeight = 0 -- ND: a static icon
	dlist.tidal2 = glCreateList(bpUi.tidalList, area)

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

local function drawResbarPullIncome(res)
	bpUi.drawPullIncome(res) -- ND: sign and number, shadowed, mockup colours and sizes
end

-- ND: storage glyph (three stacked discs, line art) + storage number on the lower row. The overflow banner
-- hangs under the section, so the storage stays visible with it.
local function drawResbarStorage(res)
	bpUi.drawStorage(res)
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

	-- used to flashing resbar area (tinting)
	if not dlist.resbar[res][4] or force then
		if dlist.resbar[res][4] then
			glDeleteList(dlist.resbar[res][4])
		end
		dlist.resbar[res][4] = glCreateList(bpUi.fill, res == "metal" and bpUi.g.pm or bpUi.g.pe) -- ND: the panel shape
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

	local piText = bpUi.piText(r[res][3]) .. " " .. bpUi.piText(r[res][4]) -- ND: what bpUi.drawPullIncome prints
	if cache.lastPullIncomeText[res] ~= piText then
		cache.lastPullIncomeText[res] = piText
		updateRes[res][2] = true
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
					cache.warningCleared[res] = true -- ND: the banner hangs under the section, nothing to pre-clear in DrawScreen
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
						-- ND: under the section (top edge on its bottom edge), right aligned at its bottom right corner
						local bannerRightX = resbarArea[res][3]
							- bgpadding
							- (res == "energy" and (resbarArea[res][4] - resbarArea[res][2]) * bpUi.g.eTan or 0)
						local bannerTop = resbarArea[res][2]

						RectRound(
							bannerRightX - textWidth,
							bannerTop - bannerH,
							bannerRightX,
							bannerTop,
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
							bannerTop - bannerH + bgpadding2,
							bannerRightX - bgpadding2,
							bannerTop,
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
							bannerTop - bannerH + bgpadding2,
							bannerRightX - bgpadding2,
							bannerTop,
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
						font2:Print(text, bannerRightX, bannerTop - 9.3 * widgetScale, fontSize, "or")
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

local function drawResbarValue(res)
	local value = short(smoothedResources[res][1])
	cache.lastDrawnValue[res] = value
	cache.lastResbarValueWidth[res] = font2:GetTextWidth(value) * resbarDrawinfo[res].textCurrent[4]
	bpUi.drawValue(res, value) -- ND
end

-- storage is 0 when the team has no units (dead/resigned team, or before the commander spawned),
-- dividing by it would put NaN into the bar geometry, which gl.Vertex errors on
local function fillRatio(current, storage)
	if not storage or storage <= 0 then
		return 0
	end
	return current / storage
end

local function updateResbar(res)
	if not showResourceBars then
		return
	end
	if res == "BP" then -- BP
		return bpUi.updateBar()
	end

	if dlist.resbar[res][1] then
		glDeleteList(dlist.resbar[res][1])
		glDeleteList(dlist.resbar[res][2])
	end

	-- ND: new layout (bar on the upper row, texts around it); also sets the text positions, the static shapes,
	-- tooltip rects and render-to-texture clear rects in resbarDrawinfo[res]
	local barArea = bpUi.resLayout(res)

	-- Always update barArea so the fill calculations work correctly even when refreshUi is false
	if not resbarDrawinfo[res] then
		resbarDrawinfo[res] = {}
	end
	resbarDrawinfo[res].barArea = barArea
	if not refreshUi then -- just update values
		resbarDrawinfo[res].textCurrent[1] = short(r[res][1])
		resbarDrawinfo[res].textStorage[1] = "\255\150\150\150" .. short(r[res][2])
		resbarDrawinfo[res].textPull[1] = "\255\210\100\100" .. short(r[res][3])
		resbarDrawinfo[res].textExpense[1] = "\255\210\100\100" .. short(r[res][5])
		resbarDrawinfo[res].textIncome[1] = "\255\100\210\100" .. short(r[res][4])
	end

	-- ND: icon, track and its shadow (static, baked into uiTex by drawUi)
	dlist.resbar[res][1] = glCreateList(bpUi.drawResStatic, res)

	-- ND: slider knobs (per frame): metal share, energy conversion + share; also sets their mouse areas.
	-- Share knobs are drawn in single-player teams too. Hovered: 20 % larger.
	dlist.resbar[res][2] = glCreateList(bpUi.drawKnobs, res, barArea, not showingQuitscreen() and resbarHover == res)

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

		if refreshUi then -- ND: rects from bpUi.resLayout
			WG.tooltip.AddTooltip(res .. "_pull", resbarDrawinfo[res].tipPull, BAR.I18N("ui.topbar.resources.pullTooltip", { resource = resourceName }))
			WG.tooltip.AddTooltip(res .. "_income", resbarDrawinfo[res].tipIncome, BAR.I18N("ui.topbar.resources.incomeTooltip", { resource = resourceName }))
			--WG['tooltip'].AddTooltip(res .. '_expense', { resbarDrawinfo[res].textExpense[2] - (4 * widgetScale), resbarDrawinfo[res].textExpense[3], resbarDrawinfo[res].textExpense[2] + (30 * widgetScale), resbarDrawinfo[res].textExpense[3] + resbarDrawinfo[res].textExpense[4] }, Spring.I18N('ui.topbar.resources.expenseTooltip', { resource = resourceName }))
			WG.tooltip.AddTooltip(res .. "_storage", resbarDrawinfo[res].tipStorage, BAR.I18N("ui.topbar.resources.storageTooltip", { resource = resourceName }))
		end
	end
end

local function updateResbarValues(res, update)
	if not showResourceBars then
		return
	end

	if update then
		local barHeight = resbarDrawinfo[res].barArea[4] - resbarDrawinfo[res].barArea[2] -- only read values if update is needed
		local barWidth = resbarDrawinfo[res].barArea[3] - resbarDrawinfo[res].barArea[1] -- only read values if update is needed
		if short(smoothedResources[res][1]) ~= cache.lastDrawnValue[res] then
			updateRes[res][1] = true
		end
		local maxStorageRes = smoothedResources[res][2]
		local cappedCurRes = smoothedResources[res][1] -- limit so when production dies the value won't be much larger than what you can store
		if cappedCurRes > maxStorageRes * 1.07 then
			cappedCurRes = maxStorageRes * 1.07
		end
		local valueWidth = mathFloor(fillRatio(cappedCurRes, maxStorageRes) * barWidth) -- ND: no minimum width
		if valueWidth ~= cache.lastValueWidth[res] then -- only recalc if the width changed
			cache.lastValueWidth[res] = valueWidth

			-- resbar (ND: a flat fill growing from the gauge end, no glow)
			if dlist.resValuesBar[res] then
				glDeleteList(dlist.resValuesBar[res])
			end
			dlist.resValuesBar[res] = glCreateList(bpUi.drawFill, res, valueWidth)
		end
	end
end

--------------------------------------------------------------------------------
-- Buildpower (BP) block: everything from here to init() is new (not in stock).
-- Data: bp (published, spec section 11), unit tracking: bpTrack, drawing: bpUi.
-- No new top-level locals here: every function is a field of one of the three tables.
--------------------------------------------------------------------------------

-- Spring functions used by the BP code (kept out of the stock `sp` table so the stock lines stay untouched)
bpTrack.GetTeamUnits = Spring.GetTeamUnits
bpTrack.GetUnitDefID = Spring.GetUnitDefID
bpTrack.ValidUnitID = Spring.ValidUnitID
bpTrack.GetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
bpTrack.GetUnitCommandCount = Spring.GetUnitCommandCount
bpTrack.GetUnitCommands = Spring.GetUnitCommands
bpTrack.GetFactoryCommands = Spring.GetFactoryCommands
bpTrack.GetUnitCurrentCommand = Spring.GetUnitCurrentCommand
bpTrack.GetUnitIsBuilding = Spring.GetUnitIsBuilding
bpTrack.GetUnitResources = Spring.GetUnitResources
bpTrack.GetTeamResources = Spring.GetTeamResources
bpTrack.GetWind = Spring.GetWind
bpTrack.CMD_FIGHT = CMD.FIGHT
bpTrack.CMD_GUARD = CMD.GUARD

-- time based weighted averages: a ring of samples (one per pass), read back over the last avgWindow frames
bpTrack.avgWindow = 60 -- game frames (2 s)
bpTrack.avgCap = 40 -- > avgWindow / frameStep, so the window, not the ring size, limits the average
bpTrack.avgSeries = 8 -- 1 reserved, 2 used, 3 non-builder M, 4 non-builder E, 5 M support, 6 E support, 7 E support at min wind, 8 at max wind
bpTrack.pass = {} -- snapshot of bpTrack.ids taken at the start of every pass (reused, never replaced)
function bpTrack.createArrays() -- a function, so the loop does not use main chunk local slots
	local t = bpTrack
	t.avgT, t.avgV, t.avgW, t.avgSV, t.avgSW = {}, {}, {}, {}, {}
	for k = 1, t.avgSeries do
		t.avgV[k], t.avgW[k], t.avgSV[k], t.avgSW[k] = {}, {}, 0, 0
	end
end
bpTrack.createArrays()

-- per-UnitDef data, filled once
function bpTrack.buildDefs()
	local kind, speed, mPerBP, ePerBP, windCap = {}, {}, {}, {}, {}
	for unitDefID, ud in pairs(UnitDefs) do
		local buildTime = mathMax(1, ud.buildTime or 1)
		mPerBP[unitDefID] = mathMax(0, ud.metalCost or 0) / buildTime
		ePerBP[unitDefID] = mathMax(0, ud.energyCost or 0) / buildTime
		local bs = ud.buildSpeed or 0
		if bs > 0 then
			if ud.isFactory then
				kind[unitDefID] = 3 -- factory
			elseif ud.canAssist then
				kind[unitDefID] = (ud.isBuilder and not ud.canMove) and 2 or 1 -- 2: static assist turret (nano), 1: mobile builder
			end
			speed[unitDefID] = bs
		end
		if (ud.windGenerator or 0) > 0 then
			windCap[unitDefID] = ud.windGenerator
		end
	end
	bpTrack.defKind, bpTrack.defSpeed, bpTrack.defMperBP, bpTrack.defEperBP, bpTrack.defWindCap =
		kind, speed, mPerBP, ePerBP, windCap
end

-- forget everything and start measuring teamID (nil: BP disabled)
function bpTrack.reset(teamID)
	local t = bpTrack
	t.teamID = teamID
	t.ids, t.pos, t.speed, t.kind, t.winds = {}, {}, {}, {}, {}
	t.count, t.windCap = 0, 0
	local pass = t.pass
	for i = #pass, 1, -1 do
		pass[i] = nil
	end
	t.passCount, t.cursor, t.perPass, t.nextFrame = 0, 1, 1, 0
	t.accReserved, t.accUsed, t.accBuilding, t.accNonStalled, t.accMetal, t.accEnergy = 0, 0, 0, 0, 0, 0
	t.avgN, t.avgHead = 0, 0

	bp.teamID = teamID
	bp.total, bp.numBuilders, bp.numNanos, bp.numFactories, bp.numWindGenerators = 0, 0, 0, 0, 0
	bp.reservedInstant, bp.usedInstant, bp.buildingInstant, bp.stalledInstant = 0, 0, 0, 0
	bp.builderMetalExpense, bp.builderEnergyExpense = 0, 0
	bp.reserved, bp.used, bp.idle, bp.usedRatio, bp.reservedRatio = 0, 0, 0, 0, 0
	bp.metalPerBP, bp.energyPerBP = nil, nil
	bp.nonBuilderMetalExpense, bp.nonBuilderEnergyExpense = 0, 0
	bp.metalExpenseIfAllUsed, bp.energyExpenseIfAllUsed = nil, nil
	bp.mSupportRatio, bp.eSupportRatio, bp.supportStale = nil, nil, false
	bp.metalSupportedBP, bp.energySupportedBP, bp.surplusBP = nil, nil, nil
	bp.eSupportMinWind, bp.eSupportMaxWind, bp.windStrength = nil, nil, 0
	bp.currentSupplyMetal, bp.currentSupplyEnergy = 1, 1
	bp.stallingMetal, bp.stallingEnergy, bp.idleAlert, bp.needBuildpower, bp.tooMuchBuildpower = false, false, false, false, false
	bp.lastPassFrame, bp.hasData = 0, false
end

function bpTrack.track(unitID, unitDefID, teamID)
	local t = bpTrack
	if not unitDefID or teamID ~= t.teamID or t.pos[unitID] or t.winds[unitID] then
		return -- idempotent: UnitGiven and UnitTaken both fire for one transfer
	end
	if not t.defKind then
		t.buildDefs()
	end
	local kind, cap = t.defKind[unitDefID], t.defWindCap[unitDefID]
	if not kind and not cap then
		return
	end
	if t.GetUnitIsBeingBuilt(unitID) then
		return -- nanoframes are added by UnitFinished
	end
	if kind then
		local n = t.count + 1
		local S = t.defSpeed[unitDefID]
		t.count, t.ids[n], t.pos[unitID], t.speed[unitID], t.kind[unitID] = n, unitID, n, S, kind
		bp.total = bp.total + S
		if kind == 1 then
			bp.numBuilders = bp.numBuilders + 1
		elseif kind == 2 then
			bp.numNanos = bp.numNanos + 1
		else
			bp.numFactories = bp.numFactories + 1
		end
	else
		t.winds[unitID] = cap
		bp.numWindGenerators = bp.numWindGenerators + 1
		if cap > t.windCap then
			t.windCap = cap
		end
	end
end

function bpTrack.untrack(unitID)
	local t = bpTrack
	local p = t.pos[unitID]
	if p then
		local n = t.count
		local lastID = t.ids[n]
		t.ids[p], t.pos[lastID] = lastID, p -- swap-remove
		t.ids[n], t.pos[unitID], t.count = nil, nil, n - 1
		local kind = t.kind[unitID]
		bp.total = bp.total - t.speed[unitID]
		t.speed[unitID], t.kind[unitID] = nil, nil
		if kind == 1 then
			bp.numBuilders = bp.numBuilders - 1
		elseif kind == 2 then
			bp.numNanos = bp.numNanos - 1
		else
			bp.numFactories = bp.numFactories - 1
		end
		if t.count == 0 or bp.total < 0.5 then
			bp.total = t.count == 0 and 0 or mathMax(0, bp.total)
			bp.hasData = false
		end
	elseif t.winds and t.winds[unitID] then
		t.winds[unitID] = nil
		bp.numWindGenerators = bp.numWindGenerators - 1
	end
end

function bpTrack.rescan(teamID)
	if not bpTrack.defKind then
		bpTrack.buildDefs()
	end
	bpTrack.reset(teamID)
	if teamID then
		local units = bpTrack.GetTeamUnits(teamID)
		if units then
			for i = 1, #units do
				local unitID = units[i]
				bpTrack.track(unitID, bpTrack.GetUnitDefID(unitID), teamID)
			end
		end
	end
	bpUi.forceRebuild = true
	bpUi.lastTooltip = nil
end

-- rescans when the measured team changed (also covers the spectator switch in Update that does not call init)
function bpTrack.checkTeam()
	local want = bp.cfg.enabled and myTeamID or nil
	if want ~= bpTrack.teamID or not bpTrack.ids then
		bpTrack.rescan(want)
	end
end

-- one builder of the current pass; no tables are created here
function bpTrack.inspect(unitID)
	local t = bpTrack
	local S = t.speed[unitID]
	if not S then
		return -- untracked since the pass started
	end
	local kind = t.kind[unitID]
	local numCmds
	if kind == 3 then
		numCmds = t.GetFactoryCommands(unitID, 0)
		if type(numCmds) == "table" then
			numCmds = #numCmds
		end
	elseif t.GetUnitCommandCount then
		numCmds = t.GetUnitCommandCount(unitID)
	else
		numCmds = t.GetUnitCommands(unitID, 0)
	end
	if not numCmds then
		if not t.ValidUnitID(unitID) then
			t.untrack(unitID) -- missed destroy event
		end
		return
	end
	if numCmds == 0 then
		return -- idle
	end
	local target = t.GetUnitIsBuilding(unitID)
	if target and not t.GetUnitIsBeingBuilt(target) then
		target = nil -- repairing a finished unit: reserved, but not building
	end
	if not target and kind == 2 and numCmds == 1 and t.GetUnitCurrentCommand
		and t.GetUnitCurrentCommand(unitID) == t.CMD_FIGHT then
		return -- nano that only has its default fight order and is not building anything: idle
	end
	if not target and numCmds == 1 and t.GetUnitCurrentCommand then
		local cmdID, _, _, guarded = t.GetUnitCurrentCommand(unitID)
		if cmdID == t.CMD_GUARD and guarded and t.speed[guarded] and not t.GetUnitIsBuilding(guarded) then
			local n2
			if t.kind[guarded] == 3 then
				n2 = t.GetFactoryCommands(guarded, 0)
				if type(n2) == "table" then
					n2 = #n2
				end
			elseif t.GetUnitCommandCount then
				n2 = t.GetUnitCommandCount(guarded)
			else
				n2 = t.GetUnitCommands(guarded, 0)
			end
			if n2 == 0 then
				return -- guarding an idle builder: idle itself (one level only, so guard loops are safe)
			end
		end
	end
	t.accReserved = t.accReserved + S
	if not target then
		return
	end
	local targetDefID = t.GetUnitDefID(target)
	local mPerBP = targetDefID and t.defMperBP[targetDefID]
	if not mPerBP then
		return
	end
	local ePerBP = t.defEperBP[targetDefID]
	local _, mUse, _, eUse = t.GetUnitResources(unitID)
	mUse, eUse = mUse or 0, eUse or 0
	t.accMetal = t.accMetal + mUse
	t.accEnergy = t.accEnergy + eUse
	t.accBuilding = t.accBuilding + S
	-- used BP: the BP that actually turned metal into progress (stall lowers it)
	local used
	if mPerBP > 0 then
		used = mUse / mPerBP
	elseif ePerBP > 0 then
		used = eUse / ePerBP
	else
		used = S
	end
	if used > S then
		used = S
	elseif used < 0 then
		used = 0
	end
	t.accUsed = t.accUsed + used
	-- non-stalled share of this builder: actual over wanted use of the scarcer resource
	local rate = 1
	if mPerBP > 0 then
		rate = mUse / (mPerBP * S)
	end
	if ePerBP > 0 and eUse / (ePerBP * S) < rate then
		rate = eUse / (ePerBP * S)
	end
	if rate > 1 then
		rate = 1
	elseif rate < 0 then
		rate = 0
	end
	t.accNonStalled = t.accNonStalled + S * rate
end

-- from widget:GameFrame: at most perFrame builders per call, then a pause of frameStep frames after each pass
function bpTrack.gameFrame(n)
	local t = bpTrack
	if not t.teamID or n < t.nextFrame then
		return
	end
	if t.cursor > t.passCount then -- start a pass on a snapshot of the builder list
		local ids, pass, count = t.ids, t.pass, t.count
		for i = 1, count do
			pass[i] = ids[i]
		end
		for i = count + 1, t.passCount do
			pass[i] = nil
		end
		t.passCount, t.cursor = count, 1
		t.perPass = mathMin(t.perFrame, mathMax(1, mathCeil(count / t.frameStep)))
		t.accReserved, t.accUsed, t.accBuilding, t.accNonStalled, t.accMetal, t.accEnergy = 0, 0, 0, 0, 0, 0
	end
	local last = mathMin(t.passCount, t.cursor + t.perPass - 1)
	local pass = t.pass
	for i = t.cursor, last do
		t.inspect(pass[i])
	end
	t.cursor = last + 1
	if t.cursor > t.passCount then
		t.finishPass(n)
		t.nextFrame = n + t.frameStep
	else
		t.nextFrame = n + 1
	end
end

-- exactly once per pass
function bpTrack.finishPass(n)
	local t = bpTrack
	bp.reservedInstant = t.accReserved
	bp.usedInstant = t.accUsed
	bp.buildingInstant = t.accBuilding
	bp.stalledInstant = mathMax(0, t.accBuilding - t.accNonStalled)
	bp.builderMetalExpense = t.accMetal
	bp.builderEnergyExpense = t.accEnergy
	bp.lastPassFrame = n
	t.updateAverages(n)
	bp.hasData = bp.total > 0
end

-- sums series k1..k2 over the samples of the last avgWindow frames
function bpTrack.sumAverages(n, k1, k2)
	local t = bpTrack
	local SV, SW, V, W, T = t.avgSV, t.avgSW, t.avgV, t.avgW, t.avgT
	for k = k1, k2 do
		SV[k], SW[k] = 0, 0
	end
	local minFrame = n - t.avgWindow
	local h = t.avgHead
	for _ = 1, t.avgN do
		if T[h] < minFrame then
			break -- going back from the newest sample, so everything further is older
		end
		for k = k1, k2 do
			local w = W[k][h]
			SV[k] = SV[k] + V[k][h] * w
			SW[k] = SW[k] + w
		end
		h = h - 1
		if h < 1 then
			h = t.avgCap
		end
	end
end

function bpTrack.average(k)
	local sw = bpTrack.avgSW[k]
	if sw < 0.01 then
		return nil
	end
	return bpTrack.avgSV[k] / sw
end

function bpTrack.clamp01(v)
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

-- averages and projections, once per pass (spec sections 3, 4 and 11)
function bpTrack.updateAverages(n)
	local t = bpTrack
	local _, _, _, mInc, mExp = t.GetTeamResources(t.teamID, "metal")
	local _, _, _, eInc, eExp = t.GetTeamResources(t.teamID, "energy")
	if not mInc or not eInc then
		return
	end
	local total, U = bp.total, bp.usedInstant
	if U >= 1 then -- else keep the last value
		bp.metalPerBP = bp.builderMetalExpense / U
		bp.energyPerBP = bp.builderEnergyExpense / U
	end
	local nW, cap = bp.numWindGenerators, t.windCap
	local wind = select(4, t.GetWind()) or 0
	if cap > 0 and wind > cap then
		wind = cap
	end
	bp.windStrength = wind

	local h = t.avgHead % t.avgCap + 1
	t.avgHead = h
	if t.avgN < t.avgCap then
		t.avgN = t.avgN + 1
	end
	t.avgT[h] = n
	local V, W = t.avgV, t.avgW
	V[1][h], W[1][h] = bp.reservedInstant, 1
	V[2][h], W[2][h] = U, 1
	V[3][h], W[3][h] = mathMax(0, (mExp or 0) - bp.builderMetalExpense), 1
	V[4][h], W[4][h] = mathMax(0, (eExp or 0) - bp.builderEnergyExpense), 1
	t.sumAverages(n, 1, 4)
	bp.reserved = t.average(1) or 0
	bp.used = t.average(2) or 0
	local nbM, nbE = t.average(3) or 0, t.average(4) or 0
	bp.nonBuilderMetalExpense, bp.nonBuilderEnergyExpense = nbM, nbE

	-- model B (markers): share of the demand with all BP working that income can feed
	-- model A (alerts): BP the income left over after non-builders can feed
	local mR, eR, eMin, eMax, wM, wE, wWind = 1, 1, 1, 1, 0, 0, 0
	local mPer, ePer = bp.metalPerBP, bp.energyPerBP
	if mPer and mPer > 0 then
		local mAll = nbM + mPer * total
		bp.metalExpenseIfAllUsed = mAll
		mR = mAll > 0 and t.clamp01(mInc / mAll) or 1
		bp.metalSupportedBP = mathMax(0, (mInc - nbM) / mPer)
		if U >= 1 then
			wM = U
		end
	end
	if ePer and ePer > 0 then
		local eAll = nbE + ePer * total
		bp.energyExpenseIfAllUsed = eAll
		eR = eAll > 0 and t.clamp01(eInc / eAll) or 1
		bp.energySupportedBP = mathMax(0, (eInc - nbE) / ePer)
		if U >= 1 then
			wE = U
		end
		if nW > 0 and cap > 0 and eAll > 0 then
			local noWindIncome = eInc - nW * wind
			eMin = t.clamp01((noWindIncome + nW * mathMin(minWind, cap)) / eAll)
			eMax = t.clamp01((noWindIncome + nW * mathMin(maxWind, cap)) / eAll)
			wWind = wE
		end
	end
	V[5][h], W[5][h] = mR, wM
	V[6][h], W[6][h] = eR, wE
	V[7][h], W[7][h] = eMin, wWind
	V[8][h], W[8][h] = eMax, wWind
	t.sumAverages(n, 5, 8)
	local m, e = t.average(5), t.average(6)
	bp.supportStale = (m == nil and bp.mSupportRatio ~= nil) or (e == nil and bp.eSupportRatio ~= nil)
	bp.mSupportRatio = m or bp.mSupportRatio -- nothing built for 2 s: keep the last value, drawn greyed out
	bp.eSupportRatio = e or bp.eSupportRatio
	if nW > 0 then
		bp.eSupportMinWind = t.average(7) or bp.eSupportMinWind
		bp.eSupportMaxWind = t.average(8) or bp.eSupportMaxWind
	else
		bp.eSupportMinWind, bp.eSupportMaxWind = nil, nil
	end

	local supported = bp.metalSupportedBP
	if bp.energySupportedBP and (not supported or bp.energySupportedBP < supported) then
		supported = bp.energySupportedBP
	end
	bp.surplusBP = (supported and total > 0) and mathCeil((total - supported) / 10) * 10 or nil

	bp.idle = mathMax(0, total - bp.reserved)
	bp.usedRatio = total > 0 and mathMin(1, bp.used / total) or 0
	bp.reservedRatio = total > 0 and mathMin(1, bp.reserved / total) or 0
end

-- once per second, from bpUi.slowUpdate right after the stock code refreshed `r`
function bpTrack.updateFlags()
	local m, e = r.metal, r.energy
	if not bp.hasData or not m[3] or not e[3] then
		bp.stallingMetal, bp.stallingEnergy, bp.idleAlert, bp.needBuildpower, bp.tooMuchBuildpower = false, false, false, false, false
		return
	end
	bp.currentSupplyMetal = m[3] > 0 and mathMin(1, m[4] / m[3]) or 1
	bp.currentSupplyEnergy = e[3] > 0 and mathMin(1, e[4] / e[3]) or 1
	-- projected support below 80 % and less than 2 s of pull in storage
	bp.stallingMetal = bp.mSupportRatio ~= nil and bp.mSupportRatio < 0.8 and m[1] < 2 * m[3]
	bp.stallingEnergy = bp.eSupportRatio ~= nil and bp.eSupportRatio < 0.8 and e[1] < 2 * e[3]
	local total, reserved = bp.total, bp.reserved
	bp.idleAlert = total > 0 and reserved / total <= 0.5 and total - reserved > 300
	local surplus = bp.surplusBP
	bp.needBuildpower = surplus ~= nil and surplus < 0
	bp.tooMuchBuildpower = surplus ~= nil and surplus > 400
		and ((bp.mSupportRatio or 1) < 0.4 or (bp.eSupportRatio or 1) < 0.4)
end

--------------------------------------------------------------------------------
-- BP drawing
--------------------------------------------------------------------------------

-- ND: the look of the mockup (design/mockup_measurements.md), in units of the strip height H.
-- x: distance from the gauge centre (metal side negative where noted by the name), y: down from the strip top.
bpUi.D = {
	metalL = 5.825, metalTan = 0.95, -- metal: top left corner, slope of the outer edge (43.5 deg from vertical)
	energyR = 5.655, energyTan = 0.8875, -- energy: top right corner, 41.6 deg
	gaugeW = 0.883, gaugeH = 1.203, chamfer = 0.152, -- gauge panel: half width, height, run of the bottom chamfers
	smallX = 5.875, smallH = 0.64, smallTanL = 0.876, smallTanR = 0.871, stub = 0.07, -- wind / tidal / coms panel: left edge, slopes, cut corner
	windW = 1.93, tidalW = 1.694, comsW = 1.694, -- segment widths
	zoneH = 0.4375, zoneM = { 4.116, 3.806 }, zoneE = { 4.127, 3.833 }, -- darker bar zone: height, x of its slanted boundary (top, bottom)
	shadowSide = 0.14, shadowDown = 0.094, gaugeShadowX = 0.039, gaugeShadowY = 0.11, -- hard drop shadows
	barInM = 1.109, barInE = 1.094, barLen = 2.773, barTop = 0.211, barH = 0.148, -- tracks
	barChamferX = 0.055, barChamferY = 0.07, barShadow = 0.0625,
	knobW = 0.234, knobH = 0.3125,
	lineTop = 0.298, lineBot = 0.673, -- centres of the two text lines
	fsPI = 0.308, fsSt = 0.26, fsCur = 0.368, fsPct = 0.287, fsRange = 0.223, -- font sizes
	piSignM = 4.711, piNumM = 4.539, piSignE = 4.07, piNumE = 4.682, -- income / pull: sign centre, number edge
	glyphM = 3.913, storTextM = 3.498, storTextE = 3.845, storGapE = 0.139, glyphW = 0.228, glyphH = 0.227, glyphY = 0.676,
	curM = 1.5625, curE = 1.523, -- current value: metal right edge, energy left edge
	plateX = 1.295, plateY = 0.68, plateS = 0.29, boltX = 1.269, boltY = 0.6875, boltS = 0.37, -- icons: centre, visible size
	ringX = 0.011, ringY = 0.7206, rIn = 0.437, rOut = 0.583, sweep = 216, -- ring: centre offset, radii, start angle (tip)
	ringShadowX = 0.023, ringShadowY = 0.0625,
	windR = 0.70, windT = 0.031, -- wind range arc
	markApex = 0.605, markBase = 0.72, markHalf = 7.5, -- energy support marker (radii, half angle in degrees)
	pointR = { 0.369, 0.416, 0.32 }, pointA = { 17.8, -0.5, -14.6 }, -- metal support pointer: polar corners around its angle
	pctX = 0.706, pctY = 1.119, iconX = 0.02, iconY = 0.648, iconS = 0.38, -- "50%" right edge and baseline, centre icon
	windIconX = 0.258, windIconS = 0.244, windY = 0.3125, windTextX = 0.523, rangeGap = 0.115, rangeY = 0.307,
	tidalIconX = 0.359, tidalIconY = 0.336, tidalIconW = 0.28, tidalIconH = 0.25, tidalTextX = 0.588,
	comsIconX = 0.359, comsIconS = 0.4, comsTextX = 0.62,
}
bpUi.C = {
	-- vertical gradients: { v (down from the top, in H), r, g, b, ... }
	mLower = { 0.4375, 46, 50, 48, 0.7, 51, 56, 53, 0.98, 48, 53, 50 },
	eLower = { 0.4375, 44, 48, 46, 0.7, 48, 53, 50, 0.98, 47, 52, 49 },
	mIncome = { 0, 61, 68, 64, 0.4375, 57, 63, 60 },
	eIncome = { 0, 55, 61, 58, 0.4375, 54, 60, 57 },
	barZone = { 0, 37, 40, 38, 0.17, 40, 43, 41, 0.4375, 41, 44, 42 },
	gauge = { 0, 42, 46, 44, 0.12, 44, 49, 46, 0.3, 48, 54, 51, 0.85, 49, 55, 52, 1.0, 47, 53, 50, 1.203, 43, 49, 47 },
	small = { 0, 56, 62, 58, 0.2, 55, 61, 58, 0.36, 51, 57, 54, 0.48, 49, 55, 52, 0.64, 42, 47, 44 },
	track = { 0, 58, 58, 58, 0.25, 62, 62, 62, 0.75, 88, 88, 88, 1, 91, 91, 91 }, -- v in track heights
	outline = { 0.243, 0.243, 0.243, 1 },
	outlineSmall = { 0.235, 0.235, 0.235, 1 },
	outlineGR = { 0.212, 0.212, 0.212, 1 },
	outlineGB = { 0.227, 0.227, 0.227, 1 },
	topRow = { 0, 0, 0, 0.15 },
	shadow = { 0, 0, 0, 0.23 },
	shadowGauge = { 0, 0, 0, 0.28 },
	shadowSmall = { 0, 0, 0, 0.25 },
	shadowBar = { 0, 0, 0, 0.13 },
	shadowRing = { 0, 0, 0, 0.21 },
	divider = { 0, 0, 0, 0.16 },
	clear = { 0, 0, 0, 0 },
	gaugeEdge = { 0, 0, 0, 0.1 },
	metalEdge = { 1, 1, 1, 0.032 },
	metalFill = { 0.851, 0.851, 0.851, 1 },
	energyFill = { 0.93, 0.84, 0.4, 1 },
	-- knobs (mockup pixels): outline columns and rows, body gradient, left / right inner columns, the darker part right
	-- of the glossy stripe, the stripe; { bottom, top } pairs are vertical gradients
	knob = { left = { { 0.22, 0.22, 0.22, 1 }, { 0.1, 0.1, 0.1, 1 } }, right = { { 0.37, 0.37, 0.37, 1 }, { 0.26, 0.26, 0.26, 1 } },
		top = { 0.13, 0.14, 0.14, 1 }, topIn = { 0.44, 0.44, 0.44, 1 }, bottom = { 0.57, 0.57, 0.57, 1 },
		body = { { 0.94, 0.94, 0.94, 1 }, { 0.71, 0.71, 0.71, 1 } }, lin = { { 0.68, 0.68, 0.68, 1 }, { 0.53, 0.53, 0.53, 1 } },
		rin = { { 0.65, 0.65, 0.65, 1 }, { 0.43, 0.43, 0.43, 1 } }, dark = { { 0.71, 0.71, 0.71, 1 }, { 0.8, 0.8, 0.8, 1 } },
		shine = { { 0.97, 0.97, 0.97, 1 }, { 0.86, 0.86, 0.86, 1 } } },
	knobRed = { left = { { 0.28, 0.16, 0.16, 1 }, { 0.18, 0.07, 0.07, 1 } }, right = { { 0.14, 0.07, 0.07, 1 }, { 0.13, 0.04, 0.04, 1 } },
		top = { 0.13, 0.14, 0.14, 1 }, topIn = { 0.584, 0.043, 0.043, 1 }, bottom = { 0.61, 0.38, 0.38, 1 },
		body = { { 0.98, 0.52, 0.52, 1 }, { 0.941, 0.098, 0.098, 1 } },
		rin = { { 0.85, 0.27, 0.27, 1 }, { 0.74, 0.04, 0.04, 1 } }, dark = { { 0.89, 0.37, 0.37, 1 }, { 0.92, 0.3, 0.3, 1 } },
		shine = { { 1, 0.66, 0.66, 1 }, { 0.97, 0.35, 0.35, 1 } } },
	glyphM = { 0.8, 0.8, 0.8, 1 },
	glyphE = { 0.91, 0.855, 0.675, 1 },
	green = { 0.627, 0.925, 0.49, 1 },
	red = { 1, 0.486, 0.486, 1 },
	storM = { 0.737, 0.737, 0.737, 1 },
	storE = { 0.851, 0.816, 0.694, 1 },
	curM = { 0.757, 0.757, 0.757, 1 },
	cream = { 0.906, 0.863, 0.71, 1 },
	ringUsed = { 0.035, 1, 0.882, 1 },
	ringReserved = { 0, 0.588, 0.518, 1 },
	ringRest = { 0.353, 0.353, 0.353, 1 },
	ringRestOut = { 0.25, 0.25, 0.25, 1 },
	wind = { 0.651, 0.549, 0, 1 },
	mark = { 1, 0.753, 0.278, 1 },
	markHi = { 1, 0.914, 0.463, 1 },
	markEdge = { 0.651, 0.502, 0.2, 1 },
	point = { 0.5, 0.5, 0.5, 1 },
	pointHi = { 0.984, 0.984, 0.984, 1 },
	pointMid = { 0.6, 0.6, 0.6, 1 },
	pointTip = { 0.72, 0.72, 0.72, 1 },
	stale = { 0.55, 0.55, 0.55, 0.6 },
	staleHi = { 0.7, 0.7, 0.7, 0.6 },
	-- alert boxes (bpUi.drawAlerts)
	outer = { 1, 1, 1, 0.15 },
	outerInner = { 1, 1, 1, 0 },
}
bpUi.col = bpUi.C -- the alert boxes read bpUi.col.outer / outerInner
-- alert boxes under the BP gauge, right to left in this order
bpUi.alerts = {
	{ text = "   Need metal   ", colors = { { 0.35, 0.1, 0.1, 1 }, { 0.25, 0.05, 0.05, 1 }, { 1, 0.3, 0.3, 0.25 }, { 1, 0.3, 0.3, 0.44 } } },
	{ text = "   Need energy   ", colors = { { 0.35, 0.1, 0.1, 1 }, { 0.25, 0.05, 0.05, 1 }, { 1, 0.3, 0.3, 0.25 }, { 1, 0.3, 0.3, 0.44 } } },
	{ text = "   Idle buildpower   ", colors = { { 0.35, 0.35, 0.35, 1 }, { 0.25, 0.25, 0.25, 1 }, { 1, 1, 1, 0.25 }, { 1, 1, 1, 0.44 } } },
	{ text = "   Need buildpower   ", colors = { { 0.12, 0.3, 0.1, 1 }, { 0.07, 0.2, 0.05, 1 }, { 0.4, 1, 0.3, 0.25 }, { 0.4, 1, 0.3, 0.44 } } },
	{ text = "   Too much buildpower   ", colors = { { 0.35, 0.35, 0.35, 1 }, { 0.25, 0.25, 0.25, 1 }, { 1, 1, 1, 0.25 }, { 1, 1, 1, 0.44 } } },
}
bpUi.alertOn = { false, false, false, false, false }
bpUi.alertBits = { 1, 2, 4, 8, 16 }
bpUi.alertMask = 0
bpUi.pctStrings = {}
bpUi.capH = 0.668 -- digit height relative to the font size (font2, Exo 2 SemiBold, at Spring's 0.95 px per size unit)
bpUi.sweep = bpUi.D.sweep -- ring sweep in degrees, clockwise from 216 deg (lower left) over the top to 0 deg (3 o'clock)
bpUi.rad = PI / 180
bpUi.cos = math.cos
bpUi.sin = mathSin
bpUi.g = {} -- ND geometry in screen pixels, from bpUi.layout

-- ND drawing helpers. Shapes are convex polygons as flat arrays { x1, y1, x2, y2, ... } in GL coordinates,
-- counter-clockwise. Called only while display lists are built (or render-to-texture), never per frame.
-- They leave the blending alone: inside render-to-texture the helper's blend function (separate alpha) applies.

-- the part of polygon p with a * x + b * y <= c
function bpUi.clip(p, a, b, c)
	local out, n = {}, #p
	if n < 6 then
		return out
	end
	local px, py = p[n - 1], p[n]
	local pd = a * px + b * py - c
	for i = 1, n, 2 do
		local x, y = p[i], p[i + 1]
		local d = a * x + b * y - c
		if (d <= 0) ~= (pd <= 0) then
			local t = pd / (pd - d)
			out[#out + 1] = px + (x - px) * t
			out[#out + 1] = py + (y - py) * t
		end
		if d <= 0 then
			out[#out + 1] = x
			out[#out + 1] = y
		end
		px, py, pd = x, y, d
	end
	return out
end

-- vertices of a fan; colour c1 at coordinate v1 to c2 at v2 (y, or x when horizontal), none when c1 is nil
function bpUi.fanVerts(p, v1, v2, c1, c2, horizontal)
	local vertex = gl.Vertex
	local span = v2 - v1
	for i = 1, #p, 2 do
		local x, y = p[i], p[i + 1]
		if c1 then
			local t = 0
			if span ~= 0 then
				t = ((horizontal and x or y) - v1) / span
				t = t < 0 and 0 or (t > 1 and 1 or t)
			end
			glColor(c1[1] + (c2[1] - c1[1]) * t, c1[2] + (c2[2] - c1[2]) * t, c1[3] + (c2[3] - c1[3]) * t,
				c1[4] + (c2[4] - c1[4]) * t)
		end
		vertex(x, y)
	end
end

-- fill polygon p: flat c1, or c1 at v1 to c2 at v2; no colour at all (shape for tints and blur) without c1
function bpUi.fill(p, c1, c2, v1, v2, horizontal)
	if #p >= 6 then
		gl.BeginEnd(GL.TRIANGLE_FAN, bpUi.fanVerts, p, v1 or 0, v2 or 0, c1, c2 or c1, horizontal)
	end
end

-- gradient stops { v, r, g, b, ... } (v down from top in units of `unit`) -> { y1, colour1, y2, colour2, ... }, y ascending
function bpUi.stops(l, top, unit)
	local s = {}
	for i = #l - 3, 1, -4 do
		s[#s + 1] = top - l[i] * unit
		s[#s + 1] = { l[i + 1] / 255, l[i + 2] / 255, l[i + 3] / 255, 1 }
	end
	return s
end

-- fill polygon p with a vertical multi-stop gradient (stops from bpUi.stops); colours clamp beyond the ends
function bpUi.grad(p, s)
	local n = #s
	if n == 2 then
		return bpUi.fill(p, s[2])
	end
	for i = 1, n - 2, 2 do
		local band = p
		if i > 1 then
			band = bpUi.clip(band, 0, -1, -s[i])
		end
		if i < n - 3 then
			band = bpUi.clip(band, 0, 1, s[i + 2])
		end
		bpUi.fill(band, s[i + 1], s[i + 3], s[i], s[i + 2])
	end
end

-- band of width w inside polygon p along its edge (x1, y1) -> (x2, y2) (counter-clockwise order)
function bpUi.edge(p, x1, y1, x2, y2, w, col)
	local dx, dy = x2 - x1, y2 - y1
	local l = math.sqrt(dx * dx + dy * dy)
	local nx, ny = -dy / l, dx / l
	bpUi.fill(bpUi.clip(p, nx, ny, nx * x1 + ny * y1 + w), col)
end

-- polygon p moved by (dx, dy)
function bpUi.move(p, dx, dy)
	local q = {}
	for i = 1, #p, 2 do
		q[i], q[i + 1] = p[i] + dx, p[i + 1] + dy
	end
	return q
end

function bpUi.rect(x1, y1, x2, y2)
	return { x1, y1, x2, y1, x2, y2, x1, y2 }
end

-- part of a disc between angles a0 and a1 (degrees): the round caps of the ring
function bpUi.discVerts(x, y, r, n, a0, a1)
	local vertex, cos, sin, rad = gl.Vertex, bpUi.cos, bpUi.sin, bpUi.rad
	vertex(x, y)
	for i = 0, n do
		local a = (a0 + (a1 - a0) * i / n) * rad
		vertex(x + r * cos(a), y + r * sin(a))
	end
end

-- ring strip between angles a0 and a1 (degrees, 0 = right, counter-clockwise), radii r1 < r2, colours c1 (inner) / c2 (outer)
function bpUi.arcVerts(cx, cy, a0, a1, r1, r2, c1, c2, n)
	local vertex, cos, sin, rad = gl.Vertex, bpUi.cos, bpUi.sin, bpUi.rad
	for i = 0, n do
		local a = (a0 + (a1 - a0) * i / n) * rad
		local ca, sa = cos(a), sin(a)
		glColor(c2[1], c2[2], c2[3], c2[4])
		vertex(cx + r2 * ca, cy + r2 * sa)
		glColor(c1[1], c1[2], c1[3], c1[4])
		vertex(cx + r1 * ca, cy + r1 * sa)
	end
end

function bpUi.arc(cx, cy, a0, a1, r1, r2, c1, c2)
	local n = mathMax(1, mathCeil(math.abs(a0 - a1) / 3))
	gl.BeginEnd(GL.TRIANGLE_STRIP, bpUi.arcVerts, cx, cy, a0, a1, r1, r2, c1, c2 or c1, n)
end

-- ring segment with round caps whose visible tips are at angles t0 > t1 (clockwise from t0 to t1), moved by (ox, oy).
-- With cOut the outer half of the ring shades from col to cOut.
function bpUi.ring(t0, t1, col, cOut, ox, oy)
	local di = resbarDrawinfo.BP
	local ri, ro, cap = di.rIn, di.rOut, di.capDeg
	local cx, cy = di.cx + ox, di.cy + oy
	local c0, c1 = t0 - cap, t1 + cap
	if c1 > c0 then
		c1 = c0
	end
	local rm, rc = (ri + ro) * 0.5, (ro - ri) * 0.5
	if c0 - c1 > 0.01 then
		if cOut then
			bpUi.arc(cx, cy, c0, c1, ri, rm, col)
			bpUi.arc(cx, cy, c0, c1, rm, ro, col, cOut)
		else
			bpUi.arc(cx, cy, c0, c1, ri, ro, col)
		end
	end
	glColor(col[1], col[2], col[3], col[4])
	local rad, cos, sin = bpUi.rad, bpUi.cos, bpUi.sin
	-- half discs beyond the strip ends, so a translucent colour (the shadow) is not doubled where they meet
	gl.BeginEnd(GL.TRIANGLE_FAN, bpUi.discVerts, cx + rm * cos(c0 * rad), cy + rm * sin(c0 * rad), rc, 12, c0, c0 + 180)
	gl.BeginEnd(GL.TRIANGLE_FAN, bpUi.discVerts, cx + rm * cos(c1 * rad), cy + rm * sin(c1 * rad), rc, 12, c1 + 180, c1 + 360)
end

-- point at radius r and angle a (degrees) around the ring centre
function bpUi.polar(r, a)
	local di = resbarDrawinfo.BP
	return di.cx + r * bpUi.cos(a * bpUi.rad), di.cy + r * bpUi.sin(a * bpUi.rad)
end

function bpUi.triVerts(x1, y1, x2, y2, x3, y3, c1, c2, c3)
	local vertex = gl.Vertex
	glColor(c1[1], c1[2], c1[3], c1[4])
	vertex(x1, y1)
	glColor(c2[1], c2[2], c2[3], c2[4])
	vertex(x2, y2)
	glColor(c3[1], c3[2], c3[3], c3[4])
	vertex(x3, y3)
end

-- the storage glyph: three stacked discs in line art (top ellipse, two lower rims, the sides), left bottom at (x, y)
function bpUi.ellVerts(cx, cy, rx, ry, lw, a0, a1, n)
	local vertex, cos, sin, rad = gl.Vertex, bpUi.cos, bpUi.sin, bpUi.rad
	for i = 0, n do
		local a = (a0 + (a1 - a0) * i / n) * rad
		local ca, sa = cos(a), sin(a)
		vertex(cx + (rx + lw) * ca, cy + (ry + lw) * sa)
		vertex(cx + (rx - lw) * ca, cy + (ry - lw) * sa)
	end
end

function bpUi.glyph(x, y, w, h, col)
	local lw = mathMax(0.6, h * 0.045) -- half the line width
	local rx = w * 0.5 - lw
	local ry = h * 0.17
	local cx = x + w * 0.5
	local top = y + h - lw - ry
	local step = (top - (y + lw + ry)) * 0.5
	glColor(col[1], col[2], col[3], col[4])
	gl.BeginEnd(GL.TRIANGLE_STRIP, bpUi.ellVerts, cx, top, rx, ry, lw, 0, 360, 24)
	gl.BeginEnd(GL.TRIANGLE_STRIP, bpUi.ellVerts, cx, top - step, rx, ry, lw, 180, 360, 12)
	gl.BeginEnd(GL.TRIANGLE_STRIP, bpUi.ellVerts, cx, top - 2 * step, rx, ry, lw, 180, 360, 12)
	bpUi.fill(bpUi.rect(cx - rx - lw, top - 2 * step, cx - rx + lw, top))
	bpUi.fill(bpUi.rect(cx + rx - lw, top - 2 * step, cx + rx + lw, top))
end

function bpUi.clearLists()
	local l = dlist.resbar.BP
	for n, _ in pairs(l) do
		l[n] = glDeleteList(l[n])
	end
	if dlist.resValuesBar.BP then
		dlist.resValuesBar.BP = glDeleteList(dlist.resValuesBar.BP)
	end
	bpUi.removeGuishader()
	bpUi.pct = nil
	bpUi.hang, bpUi.hoverArea = 0, nil
	bpUi.alertMask, bpUi.alertsShown, bpUi.alertSince = 0, false, nil
	if WG.tooltip then
		WG.tooltip.RemoveTooltip("top_bar_nd_bp")
	end
	bpUi.lastTooltip = nil
end

-- the blur of the part under the bar has its own guishader list (uiBgTex covers only topbarArea)
function bpUi.removeGuishader()
	if bpUi.gsList then
		if WG.guishader then
			WG.guishader.RemoveDlist("top_bar_nd_bp_hang")
		end
		bpUi.gsList = glDeleteList(bpUi.gsList)
	end
end


-- ND: from init. Places metal | gauge | energy after the mockup (sizes in units of the strip height H, metal starting at
-- the stock left edge) and sets resbarArea.metal / .energy / .BP; returns the x where the wind / tidal / coms panel
-- starts. When the design does not fit in front of the area the Top Bar Buttons widget reserves (a quarter of the
-- width; narrow screens, large ui_scale), everything horizontal is compressed to fit.
function bpUi.layout(width)
	local D, g = bpUi.D, bpUi.g
	local H = topbarArea[4] - topbarArea[2]
	local totalWidth = topbarArea[3] - topbarArea[1]
	-- everything scales with k except the small panel's shadow (whole px) and the wind text, which bpUi.smallWidth
	-- measures unscaled; 2 px cover the rounding of the segment widths
	local scaled = D.metalL + D.smallX + (displayTidalSpeed and D.tidalW or 0) + (displayComCounter and D.comsW or 0)
	local windText = (font2:GetTextWidth(maxWind .. ".0") * D.fsCur
		+ font2:GetTextWidth(minWind .. "-" .. maxWind) * D.fsRange + 0.08) * H
	local avail = totalWidth - mathFloor(totalWidth / 4) - 2 * widgetSpaceMargin - mathFloor(D.shadowSide * H + 0.5) - 2
	local k = mathMin(1, avail / ((scaled + D.windW) * H), (avail - windText) / ((scaled + D.windTextX + D.rangeGap) * H))
	local x0 = topbarArea[1]
	local gc = x0 + D.metalL * H * k
	g.H, g.T, g.B, g.k, g.hx, g.gc = H, topbarArea[4], topbarArea[2], k, H * k, gc
	local on = bp.cfg.enabled
	local hw = on and D.gaugeW * H * k or 0
	g.gL, g.gR = mathFloor(gc - hw + 0.5), mathFloor(gc + hw + 0.5)
	g.mL, g.eR = x0, mathFloor(gc + D.energyR * H * k + 0.5)
	g.mTan, g.eTan = D.metalTan, D.energyTan
	g.yBot = g.T - mathFloor(D.gaugeH * H + 0.5)
	g.ch = on and mathFloor(D.chamfer * H + 0.5) or 0
	resbarArea.metal = { g.mL, g.B, g.gL, g.T }
	resbarArea.energy = { g.gR, g.B, g.eR, g.T }
	bpUi.polys()
	if on then
		resbarArea.BP = { g.gL, g.B, g.gR, g.T }
		updateResbar("BP")
	else
		resbarArea.BP = {} -- every BP code path checks resbarArea.BP[1]
		bpUi.clearLists()
	end
	if bpUi.belowList then
		glDeleteList(bpUi.belowList)
	end
	bpUi.belowList = glCreateList(bpUi.drawBelow)
	return mathFloor(gc + D.smallX * H * k + 0.5)
end

-- the outlines of metal, energy and the gauge, and their hard drop shadows
function bpUi.polys()
	local g, D = bpUi.g, bpUi.D
	local T, B, H = g.T, g.B, g.H
	local mBL, eBR = g.mL + g.mTan * H, g.eR - g.eTan * H
	-- the inner edges reach 1 px under the gauge outline
	g.pm = { mBL, B, g.gL + 1, B, g.gL + 1, T, g.mL, T }
	g.pe = { g.gR - 1, B, eBR, B, g.eR, T, g.gR - 1, T }
	local s, d = mathFloor(D.shadowSide * H + 0.5), mathFloor(D.shadowDown * H + 0.5)
	g.shadowD = d
	-- shadows: the outer edges moved out by s, the bottom down by d; energy's reaches under the right chamfer
	g.sm = { mBL - s + g.mTan * d, B - d, g.gL, B - d, g.gL, T, g.mL - s, T }
	g.se = { g.gR - g.ch, B - d, eBR + s - g.eTan * d, B - d, g.eR + s, T, g.gR - g.ch, T }
	if g.gR > g.gL then
		g.pg = { g.gL + g.ch, g.yBot, g.gR - g.ch, g.yBot, g.gR, B, g.gR, T, g.gL, T, g.gL, B }
		g.sg = bpUi.move(g.pg, D.gaugeShadowX * H, -D.gaugeShadowY * H)
	else
		g.pg, g.sg = nil, nil
	end
end

-- ND: from init, after windArea / tidalarea / comsArea: one panel holding the three as segments, x1 .. x2 at the top
function bpUi.smallLayout(x1, x2, yb)
	local g, D = bpUi.g, bpUi.D
	if not g.H then
		return
	end
	local T, H = g.T, g.H
	local h = T - yb
	local stub = mathFloor(D.stub * H + 0.5)
	local tl, tr = D.smallTanL, D.smallTanR
	local sx = x1 - tl * (h - stub) -- the slanted left edge ends in a short vertical cut at the bottom
	g.ps = { sx, yb, x2 - tr * h, yb, x2, T, x1, T, sx, yb + stub }
	local s, d = mathFloor(D.shadowSide * H + 0.5), mathFloor(D.shadowDown * H + 0.5)
	g.ss = { sx, yb - d, x2 - tr * (h + d) + s, yb - d, x2 + s, T, x1, T, sx, yb }
	g.psTanL, g.psTanR, g.psB, g.psX1, g.psX2, g.psStub = tl, tr, yb, x1, x2, stub
end

-- segment width of the wind / tidal / coms panel
function bpUi.smallWidth(kind)
	local D, g = bpUi.D, bpUi.g
	local hx, H = g.hx, g.H
	if kind == "wind" then
		-- room for the highest wind speed, the range after it and a small margin
		local need = D.windTextX * hx + (font2:GetTextWidth(maxWind .. ".0") * D.fsCur + font2:GetTextWidth(minWind .. "-" .. maxWind) * D.fsRange) * H
			+ D.rangeGap * hx + 0.08 * H
		return mathFloor(mathMax(D.windW * hx, need) + 0.5)
	end
	return mathFloor((kind == "tidal" and D.tidalW or D.comsW) * hx + 0.5)
end

-- metal or energy panel: lighter lower zone, a darker zone around the bar bounded by a slanted line, a lighter
-- income zone outside it, a 1 px darker top row and a 1 px outline on the bottom and the outer edge
function bpUi.drawRes(res)
	local g, C, D = bpUi.g, bpUi.C, bpUi.D
	local isMetal = res == "metal"
	local p = isMetal and g.pm or g.pe
	local T, B, H, gc, hx = g.T, g.B, g.H, g.gc, g.hx
	local yz = T - mathFloor(D.zoneH * H + 0.5)
	bpUi.grad(bpUi.clip(p, 0, 1, yz), bpUi.stops(isMetal and C.mLower or C.eLower, T, H))
	local upper = bpUi.clip(p, 0, -1, -yz)
	local z = isMetal and D.zoneM or D.zoneE
	local sgn = isMetal and -1 or 1
	local xt, xb = gc + sgn * z[1] * hx, gc + sgn * z[2] * hx
	local kx = (xb - xt) / (T - yz) -- boundary: x = xt + kx * (T - y), i.e. x - kx * y = xt - kx * T
	local cst = xt + kx * T
	local left = bpUi.clip(upper, 1, kx, cst)
	local right = bpUi.clip(upper, -1, -kx, -cst)
	local zone = bpUi.stops(C.barZone, T, H)
	bpUi.grad(isMetal and right or left, zone)
	bpUi.grad(isMetal and left or right, bpUi.stops(isMetal and C.mIncome or C.eIncome, T, H))
	bpUi.fill(bpUi.clip(p, 0, -1, -(T - 1)), C.topRow)
	local w = isMetal and math.cos(math.atan(g.mTan)) or math.cos(math.atan(g.eTan)) -- 1 px wide in x
	bpUi.edge(p, p[1], p[2], p[3], p[4], 1, C.outline)
	if isMetal then
		bpUi.edge(p, p[7], p[8], p[1], p[2], w, C.outline)
	else
		bpUi.edge(p, p[3], p[4], p[5], p[6], w, C.outline)
	end
end

-- gauge panel (whole, or only its shape)
function bpUi.drawGauge(shapeOnly)
	local g, C = bpUi.g, bpUi.C
	local p = g.pg
	if not p then
		return
	end
	if shapeOnly then
		return bpUi.fill(p)
	end
	bpUi.grad(p, bpUi.stops(C.gauge, g.T, g.H))
	local e = mathMax(2, mathFloor(g.H * 0.094 + 0.5)) -- darker inner band along the left side
	bpUi.fill(bpUi.clip(p, 1, 0, g.gL + e), C.gaugeEdge, C.clear, g.gL, g.gL + e, true)
	bpUi.fill(bpUi.clip(p, 0, -1, -(g.T - 1)), C.topRow)
	local edge = bpUi.edge
	edge(p, p[1], p[2], p[3], p[4], 1, C.outlineGB) -- bottom
	edge(p, p[3], p[4], p[5], p[6], 1, C.outlineGB) -- right chamfer
	edge(p, p[5], p[6], p[7], p[8], 1, C.outlineGR) -- right
	edge(p, p[9], p[10], p[11], p[12], 1, C.outline) -- left
	edge(p, p[11], p[12], p[1], p[2], 1, C.outlineGB) -- left chamfer
end

-- wind / tidal / coms panel with the dividers between the segments
function bpUi.drawSmall()
	local g, C = bpUi.g, bpUi.C
	local p = g.ps
	if not p then
		return
	end
	local T = g.T
	bpUi.grad(p, bpUi.stops(C.small, T, g.H))
	bpUi.fill(bpUi.clip(p, 0, -1, -(T - 1)), C.topRow)
	local wl, wr = math.cos(math.atan(g.psTanL)), math.cos(math.atan(g.psTanR))
	bpUi.edge(p, p[1], p[2], p[3], p[4], 1, C.outlineSmall)
	bpUi.edge(p, p[3], p[4], p[5], p[6], wr, C.outlineSmall)
	bpUi.edge(p, p[7], p[8], p[9], p[10], wl, C.outlineSmall)
	bpUi.edge(p, p[9], p[10], p[1], p[2], 1, C.outlineSmall)
	local yb = g.psB + 2
	if displayTidalSpeed and tidalarea[1] then
		bpUi.fill(bpUi.rect(tidalarea[1] - 1, yb, tidalarea[1] + 1, T), C.clear, C.divider, yb, T)
	end
	if displayComCounter and comsArea[1] then
		bpUi.fill(bpUi.rect(comsArea[1] - 1, yb, comsArea[1] + 1, T), C.clear, C.divider, yb, T)
	end
end

-- uiBgTex (drawUiBackground): shadows first, then the panels; the gauge casts its shadow onto energy
function bpUi.drawBackground()
	local g, C = bpUi.g, bpUi.C
	if not g.pm then
		return
	end
	local small = cache.showIndicators and g.ps
	if small then
		bpUi.fill(g.ss, C.shadowSmall)
	end
	if showResourceBars then
		bpUi.fill(g.sm, C.shadow)
		bpUi.fill(g.se, C.shadow)
		bpUi.drawRes("metal")
		bpUi.drawRes("energy")
		if g.pg then
			bpUi.fill(g.sg, C.shadowGauge)
			bpUi.fill(bpUi.rect(g.gL - 2, g.B, g.gL, g.T), C.metalEdge)
			bpUi.drawGauge()
		else
			bpUi.fill(bpUi.rect(g.gL - 1, g.B, g.gL, g.T), C.outline) -- metal | energy without the gauge
		end
	end
	if small then
		bpUi.drawSmall()
	end
end

-- per frame under a scissor (drawResBars): what lies below the strip, which uiBgTex cannot hold
function bpUi.drawBelow()
	local g, C = bpUi.g, bpUi.C
	if not g.pm then
		return
	end
	bpUi.fill(g.sm, C.shadow)
	bpUi.fill(g.se, C.shadow)
	if g.pg then
		bpUi.fill(bpUi.clip(g.sg, 0, 1, g.B - g.shadowD), C.shadowGauge) -- below the strip's shadow band
		bpUi.drawGauge()
	end
end

-- ND: metal / energy content, from updateResbar (returns barArea, the track rect, recomputed on every call).
-- Both mirror each other around the gauge: income over pull at the outer side, the bar on the upper row (metal
-- fills from the gauge outward, right to left), storage and the current value with the resource icon on the
-- lower row. With refreshUi it also sets the text positions, the static shapes, the tooltip rects and the
-- render-to-texture clear rects: the column rect spans both rows and stays outside the track, the lower row rect
-- stays below the track's shadow and next to the icon. drawBars couples the three text flags of a resource, so a
-- clear never erases text without it being drawn again.
function bpUi.resLayout(res)
	local D, g = bpUi.D, bpUi.g
	local di = resbarDrawinfo[res]
	local H, T, gc, hx = g.H, g.T, g.gc, g.hx
	local isMetal = res == "metal"
	local ty = T - mathFloor(D.barTop * H + 0.5)
	local by = ty - mathFloor(D.barH * H + 0.5)
	local barArea
	if isMetal then
		barArea = { mathFloor(gc - (D.barInM + D.barLen) * hx + 0.5), by, mathFloor(gc - D.barInM * hx + 0.5), ty }
	else
		barArea = { mathFloor(gc + D.barInE * hx + 0.5), by, mathFloor(gc + (D.barInE + D.barLen) * hx + 0.5), ty }
	end
	if di.textCurrent and not refreshUi then
		return barArea
	end
	local x0, y0, capH = topbarArea[1], topbarArea[2], bpUi.capH
	local x1, x2 = barArea[1], barArea[3]
	-- track with a small chamfer at its outer bottom corner, and its shadow
	local cx, cy = mathMax(1, D.barChamferX * H), mathMax(1, D.barChamferY * H)
	if isMetal then
		di.track = { x1 + cx, by, x2, by, x2, ty, x1, ty, x1, by + cy }
	else
		di.track = { x1, by, x2 - cx, by, x2, by + cy, x2, ty, x1, ty }
	end
	di.trackShadow = bpUi.move(di.track, 0, -mathFloor(D.barShadow * H + 0.5))
	di.trackStops = bpUi.stops(bpUi.C.track, ty, ty - by)
	-- texts: sizes (compressed with the positions), baselines (digits centred on the line), anchors
	local sPI, sSt, sCur = D.fsPI * H * g.k, D.fsSt * H * g.k, D.fsCur * H * g.k
	di.fsPI, di.fsSt, di.fsCur = sPI, sSt, sCur
	local lineTop, lineBot = T - D.lineTop * H, T - D.lineBot * H
	di.baseTopPI, di.baseBotPI = lineTop - capH * sPI * 0.5, lineBot - capH * sPI * 0.5
	di.baseSt, di.baseCur = lineBot - capH * sSt * 0.5, lineBot - capH * sCur * 0.5
	local gw, gh = D.glyphW * H, D.glyphH * H
	local glyphY = T - D.glyphY * H - gh * 0.5
	local icon, iconS, iconVis
	local m = mathMax(1, mathFloor(H * 0.03 + 0.5)) -- margin of the clear rects
	local lowTop = mathFloor(T - (D.barTop + D.barH + D.barShadow) * H - m) -- below the track shadow
	-- income / pull column (bpUi.printSigned shrinks numbers wider than piMaxWTop / piMaxWBot): the upper row stays
	-- clear of the share knob at share level 1 (at the outer end of the track; 1.2 x as big when hovered), the lower
	-- row of the storage text, and both stay inside clearPI. The knobs keep their size when the layout is compressed.
	local knobHalf = D.knobW * H * 0.5
	if isMetal then
		di.piRight, di.piSignX, di.piNumX = false, gc - D.piSignM * hx, gc - D.piNumM * hx
		local glyphX = gc - D.glyphM * hx
		di.glyph = { glyphX, glyphY, gw, gh }
		local clearR = mathFloor(glyphX - m) -- right edge of clearPI
		di.piMaxWBot = clearR - 1 - di.piNumX
		di.piMaxWTop = mathMin(clearR - 1, x1 - knobHalf * 1.2 - m) - di.piNumX
		di.storX, di.storRight = gc - D.storTextM * hx, false
		di.curX, di.curRight = gc - D.curM * hx, true
		iconVis = D.plateS * H
		iconS = iconVis / 0.606 -- metal.png: the plate covers 0.606 of the texture
		icon = { gc - D.plateX * hx, T - D.plateY * H }
		di.iconTex = ":lr" .. mathFloor(iconS * 2) .. "," .. mathFloor(iconS * 2) .. ":LuaUI/Images/metal.png"
		di.clearPI = { 0, 0, clearR - x0, H }
		local iconLeft = mathFloor(icon[1] - iconVis * 0.5 - 1)
		di.clearCurrent = { clearR - x0, 0, iconLeft - clearR, lowTop - y0 }
	else
		-- the sign keeps its mockup place, moved right as far as the hovered knob at share level 1 needs (about 1 px
		-- at k = 1, more in compressed layouts), and the number, right aligned, may grow left up to it
		local signHalf = mathMax(font2:GetTextWidth("+"), font2:GetTextWidth("-")) * sPI * 0.5
		local signX = mathMax(gc + D.piSignE * hx, x2 + knobHalf * 1.2 + signHalf) -- also keeps the sign inside clearPI
		di.piRight, di.piSignX, di.piNumX = true, signX, gc + D.piNumE * hx
		di.piMaxWTop = di.piNumX - (signX + signHalf + m)
		di.piMaxWBot = di.piMaxWTop
		di.glyph = { 0, glyphY, gw, gh }
		di.storX, di.storRight, di.storGap = gc + D.storTextE * hx, true, D.storGapE * hx
		di.curX, di.curRight = gc + D.curE * hx, false
		iconS = D.boltS * H
		iconVis = iconS * 0.785 -- energy.png: the bolt covers 0.785 of the texture width
		icon = { gc + D.boltX * hx, T - D.boltY * H }
		di.iconTex = ":lr" .. mathFloor(iconS * 2) .. "," .. mathFloor(iconS * 2) .. ":LuaUI/Images/energy.png"
		di.clearPI = { x2 + 1 - x0, 0, g.eR + 1 - x2, H }
		local iconRight = mathCeil(icon[1] + iconVis * 0.5 + 1)
		di.clearCurrent = { iconRight - x0, 0, x2 + 1 - iconRight, lowTop - y0 }
	end
	di.clearStorage = di.clearCurrent -- one rect for the lower row (the flags are coupled)
	di.icon = { icon[1] - iconS * 0.5, icon[2] - iconS * 0.5, icon[1] + iconS * 0.5, icon[2] + iconS * 0.5 }
	-- the stock text records (fields 2 to 5 are no longer read for drawing)
	di.textCurrent = { "", di.curX, di.baseCur, sCur, di.curRight and "rs" or "s" }
	di.textStorage = { "", di.storX, di.baseSt, sSt, di.storRight and "rs" or "s" }
	di.textPull = { "", di.piNumX, di.baseBotPI, sPI, "s" }
	di.textExpense = di.textPull
	di.textIncome = { "", di.piNumX, di.baseTopPI, sPI, "s" }
	-- tooltips
	local c = di.clearPI
	local cl, cr = c[1] + x0, c[1] + c[3] + x0
	local sep = (lineTop + lineBot) * 0.5
	di.tipIncome = { cl, sep, cr, T }
	di.tipPull = { cl, g.B, cr, sep }
	c = di.clearCurrent
	di.tipStorage = isMetal and { c[1] + x0, g.B, (gc - D.storTextM * hx) + font2:GetTextWidth("9999") * sSt, lowTop }
		or { gc + D.storTextE * hx - font2:GetTextWidth("9999") * sSt - gw - di.storGap, g.B, x2, lowTop }
	return barArea
end

-- static part of a resource in uiTex: icon, track and the track's shadow
function bpUi.drawResStatic(res)
	local di, C = resbarDrawinfo[res], bpUi.C
	local ic = di.icon
	glColor(1, 1, 1, 1)
	glTexture(di.iconTex)
	glTexRect(ic[1], ic[2], ic[3], ic[4])
	glTexture(false)
	bpUi.fill(di.trackShadow, C.shadowBar)
	bpUi.grad(di.track, di.trackStops)
end

-- value fill (per frame list): flat, from the inner (gauge) end outward, inside the track shape
function bpUi.drawFill(res, w)
	local di = resbarDrawinfo[res]
	local t = di.track
	if not t or w < 1 then
		return
	end
	local a = di.barArea
	if res == "metal" then
		bpUi.fill(bpUi.clip(t, -1, 0, -(a[3] - w)), bpUi.C.metalFill)
	else
		bpUi.fill(bpUi.clip(t, 1, 0, a[1] + w), bpUi.C.energyFill)
	end
end

-- a square-cornered slider knob with a 1 px outline, a vertical gradient, a darker right part and a glossy stripe
function bpUi.knob(cx, cy, w, h, red)
	local k = red and bpUi.C.knobRed or bpUi.C.knob
	local fill, rect = bpUi.fill, bpUi.rect
	local x1 = mathFloor(cx - w * 0.5 + 0.5)
	local y1 = mathFloor(cy - h * 0.5 + 0.5)
	local x2, y2 = x1 + w, y1 + h
	fill(rect(x1, y1, x1 + 1, y2), k.left[1], k.left[2], y1, y2)
	fill(rect(x2 - 1, y1, x2, y2), k.right[1], k.right[2], y1, y2)
	fill(rect(x1 + 1, y2 - 1, x2 - 1, y2), k.top)
	fill(rect(x1 + 1, y1, x2 - 1, y1 + 1), k.bottom) -- the bottom row is half covered in the mockup
	local ix1, iy1, ix2, iy2 = x1 + 1, y1 + 1, x2 - 1, y2 - 2
	fill(rect(ix1, iy1, ix2, iy2), k.body[1], k.body[2], iy1, iy2)
	if k.lin then
		fill(rect(ix1, iy1, ix1 + 1, iy2), k.lin[1], k.lin[2], iy1, iy2)
	end
	local iw = ix2 - ix1
	local sT, sB = ix1 + iw * 0.8, ix1 + iw * 0.56 -- the stripe runs from 80 % of the width at the top to 56 % at the bottom
	local sw = mathMax(1, iw * 0.15)
	fill({ sB, iy1, ix2, iy1, ix2, iy2, sT, iy2 }, k.dark[1], k.dark[2], iy1, iy2)
	fill({ sB - sw, iy1, sB, iy1, sT, iy2, sT - sw, iy2 }, k.shine[1], k.shine[2], iy1, iy2)
	fill(rect(ix2 - 1, iy1, ix2, iy2), k.rin[1], k.rin[2], iy1, iy2)
	fill(rect(ix1, iy2, ix2, iy2 + 1), k.topIn)
	return { x1, y1, x2, y2 }
end

-- slider knobs (per frame list [2]): energy has the conversion knob (white) and the share knob (red), metal the
-- share knob (red, measured from the gauge end like its fill). Always drawn, also in single-player teams.
function bpUi.drawKnobs(res, barArea, big)
	local D, H = bpUi.D, bpUi.g.H
	local mult = big and 1.2 or 1
	local w = mathFloor(D.knobW * H * mult + 0.5)
	local h = mathFloor(D.knobH * H * mult + 0.5)
	local barW = barArea[3] - barArea[1]
	local cy = (barArea[2] + barArea[4]) * 0.5
	if res == "energy" then
		mmLevel = sp.GetTeamRulesParam(myTeamID, "mmLevel")
		local conv = mmLevel
		if draggingConversionIndicatorValue then
			conv = draggingConversionIndicatorValue / 100
		end
		if conv == nil then
			conv = 1
		end
		conversionIndicatorArea = bpUi.knob(barArea[1] + conv * barW, cy, w, h, false)
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
	local x = res == "metal" and barArea[3] - value * barW or barArea[1] + value * barW
	shareIndicatorArea[res] = bpUi.knob(x, cy, w, h, true)
end

-- texts (render-to-texture into uiTex, from renderResbarText); shadow instead of an outline
-- income / pull: the sign at a fixed centre, the number from a fixed edge (metal: left, energy: right) into the
-- column of width maxW; longer numbers are shrunk, sign included
function bpUi.printSigned(di, sign, num, y, col, maxW)
	local s = di.fsPI
	local w = font2:GetTextWidth(num) * s
	if w > maxW then
		s = s * maxW / w
	end
	font2:SetTextColor(col[1], col[2], col[3], col[4])
	font2:Print(sign, di.piSignX, y, s, "cs")
	font2:Print(num, di.piNumX, y, s, di.piRight and "rs" or "s")
end

function bpUi.drawPullIncome(res)
	local di, C = resbarDrawinfo[res], bpUi.C
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 0.6)
	bpUi.printSigned(di, "+", bpUi.piText(r[res][4]), di.baseTopPI, C.green, di.piMaxWTop)
	bpUi.printSigned(di, "-", bpUi.piText(r[res][3]), di.baseBotPI, C.red, di.piMaxWBot)
	font2:End()
end

function bpUi.drawStorage(res)
	local di, C = resbarDrawinfo[res], bpUi.C
	local text = cache.lastStorageText[res]
	local s = di.fsSt
	local w = font2:GetTextWidth(text) * s
	cache.lastStorageWidth[res] = w
	local gg = di.glyph
	local isMetal = res == "metal"
	local gx = isMetal and gg[1] or di.storX - w - di.storGap - gg[3]
	bpUi.glyph(gx, gg[2], gg[3], gg[4], isMetal and C.glyphM or C.glyphE)
	local col = isMetal and C.storM or C.storE
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 0.6)
	font2:SetTextColor(col[1], col[2], col[3], col[4])
	font2:Print(text, di.storX, di.baseSt, s, di.storRight and "rs" or "s")
	font2:End()
end

function bpUi.drawValue(res, value)
	local di = resbarDrawinfo[res]
	local col = res == "metal" and bpUi.C.curM or bpUi.C.cream
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 0.6)
	font2:SetTextColor(col[1], col[2], col[3], col[4])
	font2:Print(value, di.curX, di.baseCur, di.fsCur, di.curRight and "rs" or "s")
	font2:End()
end

-- gauge geometry, static lists, tint shape and the guishader list of the hanging part; via updateResbar("BP") from init
function bpUi.updateBar()
	local a = resbarArea.BP
	if not a[1] then
		return
	end
	local di, g, D = resbarDrawinfo.BP, bpUi.g, bpUi.D
	local H, k, T = g.H, g.k, g.T
	di.cx, di.cy = (g.gL + g.gR) * 0.5 + D.ringX * g.hx, T - D.ringY * H
	di.rIn, di.rOut = D.rIn * H * k, D.rOut * H * k -- a compressed layout (k < 1) makes the ring smaller too
	di.capDeg = (di.rOut - di.rIn) / (di.rOut + di.rIn) / bpUi.rad -- cap radius over the mid radius, in degrees
	di.shadowX, di.shadowY = D.ringShadowX * H, -D.ringShadowY * H
	di.windR1, di.windR2 = (D.windR - D.windT * 0.5) * H * k, (D.windR + D.windT * 0.5) * H * k
	di.yBot = g.yBot
	di.textPct = { di.cx - D.ringX * g.hx + D.pctX * g.hx, T - D.pctY * H, D.fsPct * H, "rs" } -- y is the baseline
	local iconS = mathFloor(D.iconS * H * k + 0.5)
	local ix, iy = mathFloor(di.cx + D.iconX * g.hx - iconS * 0.5 + 0.5), mathFloor(T - D.iconY * H - iconS * 0.5 + 0.5)
	di.iconRect = { ix, iy, ix + iconS, iy + iconS }
	di.iconShown = bp.cfg.icon and iconS >= 6
	di.iconInTex = iy >= a[2] -- inside the bar: baked into uiTex, otherwise drawn per frame
	bpUi.hang = a[2] - g.yBot
	bpUi.hoverArea = { a[1], g.yBot, a[3], a[4] }

	local l = dlist.resbar.BP
	for n = 1, 7 do -- 1: icon (uiTex), 3: icon (per frame), 4: tint shape, 5: percent text, 7: alerts
		if l[n] then
			l[n] = glDeleteList(l[n])
		end
	end
	l[1] = glCreateList(bpUi.drawFrame)
	if di.iconShown and not di.iconInTex then
		l[3] = glCreateList(bpUi.drawIcon)
	end
	l[4] = glCreateList(bpUi.drawGauge, true)
	bpUi.removeGuishader()
	if WG.guishader then
		bpUi.gsList = glCreateList(bpUi.drawHangShape)
		WG.guishader.InsertDlist(bpUi.gsList, "top_bar_nd_bp_hang", nil, widget)
	end
	bpUi.alertMask = 0 -- alert boxes depend on the geometry: rebuilt by the next slowUpdate
	bpUi.pct = nil -- percent text: rebuilt by the next refreshValues
	bpUi.forceRebuild = true
	bpUi.lastTooltip = nil -- the area table is new: register it again
	bpUi.updateTooltip()
end

-- static part in uiTex (drawUi): the builder icon, when it lies inside the bar
function bpUi.drawFrame()
	local di = resbarDrawinfo.BP
	if di.iconShown and di.iconInTex then
		bpUi.drawIcon()
	end
end

-- the centre icon: a hexagon nut in the used colour with three bars around it (vector, no texture)
function bpUi.drawIcon()
	local di, C = resbarDrawinfo.BP, bpUi.C
	local ir = di.iconRect
	local cx, cy, S = (ir[1] + ir[3]) * 0.5, (ir[2] + ir[4]) * 0.5, ir[3] - ir[1]
	local rad, cos, sin = bpUi.rad, bpUi.cos, bpUi.sin
	local ro, lw = S * 0.43, S * 0.11 -- hexagon circumradius, line width
	local ri = ro - lw / 0.866
	local col = C.ringUsed
	for i = 0, 5 do -- pointy top: corners at 30 + 60 i degrees
		local a1, a2 = (30 + 60 * i) * rad, (90 + 60 * i) * rad
		bpUi.fill({ cx + ri * cos(a1), cy + ri * sin(a1), cx + ro * cos(a1), cy + ro * sin(a1), cx + ro * cos(a2), cy + ro * sin(a2),
			cx + ri * cos(a2), cy + ri * sin(a2) }, col)
	end
	glColor(col[1], col[2], col[3], col[4])
	gl.BeginEnd(GL.TRIANGLE_FAN, bpUi.discVerts, cx, cy, S * 0.15, 6, 30, 390) -- small hexagon in the middle
	for i = 0, 2 do -- bars parallel to the left, upper right and lower right edges
		local a = (180 - 120 * i) * rad
		local d, l, t = S * 0.5, S * 0.17, lw * 0.5
		local bx, by, ux, uy = cx + d * cos(a), cy + d * sin(a), -sin(a), cos(a)
		local nx, ny = cos(a) * t, sin(a) * t
		bpUi.fill({ bx - ux * l - nx, by - uy * l - ny, bx - ux * l + nx, by - uy * l + ny, bx + ux * l + nx, by + uy * l + ny,
			bx + ux * l - nx, by + uy * l - ny }, col)
	end
	glColor(1, 1, 1, 1)
end

-- guishader blur shape of the part below the bar
function bpUi.drawHangShape()
	local g = bpUi.g
	if g.pg then
		bpUi.fill(bpUi.clip(g.pg, 0, 1, g.B + 1))
	end
end

-- smoothing of a displayed ratio towards its target, same factor as the stock smoothResources
function bpUi.smooth(cur, target)
	if not cur then
		return target
	end
	local d = target - cur
	if d < 0.002 and d > -0.002 then
		return target
	end
	return cur + 0.5 * d
end

function bpUi.percent(v)
	return mathFloor(bpTrack.clamp01(v) * 100 + 0.5)
end

-- position on the ring in whole degrees of the sweep (0 = start at 216 deg, 216 = end at 0 deg)
function bpUi.deg(v)
	return mathFloor(bpTrack.clamp01(v) * bpUi.sweep + 0.5)
end

-- on the stock 0.05 s bar tick (so at most every 0.05 s): quantize, rebuild the ring list only when the rounded
-- percents, the marker angles (whole degrees) or a flag changed, the percent text only when its number changed
function bpUi.refreshValues()
	local di = resbarDrawinfo.BP
	if not di.rIn then
		return
	end
	local L, s, cfgBP = bpUi.last, bpUi.s, bp.cfg
	local has = bp.hasData
	local deg = bpUi.deg

	s.used = bpUi.smooth(s.used, has and bp.usedRatio or 0)
	s.reserved = bpUi.smooth(s.reserved, has and bp.reservedRatio or 0)
	local usedP, resP = deg(s.used), deg(s.reserved) -- whole degrees of the sweep
	local mA, eA, wMinA, wMaxA = -1, -1, -1, -1
	if cfgBP.indicators and has then
		if bp.mSupportRatio then
			s.m = bpUi.smooth(s.m, bp.mSupportRatio)
			mA = deg(s.m)
		end
		if bp.eSupportRatio then
			s.e = bpUi.smooth(s.e, bp.eSupportRatio)
			eA = deg(s.e)
			if cfgBP.windRange and bp.numWindGenerators > 0 and bp.eSupportMinWind and bp.eSupportMaxWind then
				s.wMin = bpUi.smooth(s.wMin, bp.eSupportMinWind)
				s.wMax = bpUi.smooth(s.wMax, bp.eSupportMaxWind)
				wMinA, wMaxA = deg(s.wMin), deg(s.wMax)
			end
		end
	end
	local stallM, stallE, stale = bp.stallingMetal, bp.stallingEnergy, bp.supportStale
	local hover = hoveringTopbar == "BP" and not showingQuitscreen()

	if bpUi.forceRebuild or not dlist.resValuesBar.BP or usedP ~= L.usedP or resP ~= L.resP
		or mA ~= L.mA or eA ~= L.eA or wMinA ~= L.wMinA or wMaxA ~= L.wMaxA
		or stallM ~= L.stallM or stallE ~= L.stallE or stale ~= L.stale or hover ~= L.hover then
		bpUi.forceRebuild = false
		L.usedP, L.resP, L.mA, L.eA, L.wMinA, L.wMaxA = usedP, resP, mA, eA, wMinA, wMaxA
		L.stallM, L.stallE, L.stale, L.hover = stallM, stallE, stale, hover
		if dlist.resValuesBar.BP then
			glDeleteList(dlist.resValuesBar.BP)
		end
		dlist.resValuesBar.BP = glCreateList(bpUi.buildValueList)
	end

	-- percent text (used / total, not smoothed); no text while there is no data
	local pct = has and bpUi.percent(bp.usedRatio) or nil
	local l = dlist.resbar.BP
	if pct ~= bpUi.pct or (pct and not l[5]) then
		bpUi.pct = pct
		if l[5] then
			l[5] = glDeleteList(l[5])
		end
		if pct then
			if not bpUi.pctStrings[pct] then
				bpUi.pctStrings[pct] = pct .. "%"
			end
			l[5] = glCreateList(bpUi.drawPct)
		end
	end
end

-- the ring list (per frame): shadow, idle track, reserved and used arcs (round caps, each over the previous one),
-- the wind range arc and the energy support marker outside the ring, the metal support pointer inside it
function bpUi.buildValueList()
	local di, L, C, D = resbarDrawinfo.BP, bpUi.last, bpUi.C, bpUi.D
	local a0 = bpUi.sweep
	local ring = bpUi.ring
	ring(a0, 0, C.shadowRing, nil, di.shadowX, di.shadowY)
	ring(a0, 0, C.ringRest, C.ringRestOut, 0, 0)
	if L.resP > 0 then
		ring(a0, a0 - L.resP, C.ringReserved, nil, 0, 0)
	end
	if L.usedP > 0 then
		ring(a0, a0 - L.usedP, C.ringUsed, nil, 0, 0)
	end
	local hoverMult = L.hover and 1.25 or 1
	if L.wMinA >= 0 and L.wMaxA >= 0 then
		local w1, w2 = a0 - mathMax(L.wMinA, L.wMaxA), a0 - mathMin(L.wMinA, L.wMaxA)
		if w2 - w1 < 2 then
			w1, w2 = w1 - 1, w2 + 1
		end
		local sx, sy = di.shadowX * 0.5, di.shadowY * 0.5
		bpUi.arc(di.cx + sx, di.cy + sy, w2, w1, di.windR1, di.windR2, C.shadowRing)
		bpUi.arc(di.cx, di.cy, w2, w1, di.windR1, di.windR2, L.stale and C.stale or C.wind)
	end
	local H = bpUi.g.H * bpUi.g.k
	if L.eA >= 0 then -- triangle with its flat side outward, pointing in at the ring
		local mult = (L.stallE and 1.2 or 1) * hoverMult
		local a = a0 - L.eA
		local rm = (D.markApex + D.markBase) * 0.5 * H
		local half = (D.markBase - D.markApex) * 0.5 * H * mult
		local ra, rb, ha = rm - half, rm + half, D.markHalf * mult
		local e = 1 / (rb * bpUi.rad) -- one pixel in degrees at the base
		local x1, y1 = bpUi.polar(ra - 1, a)
		local x2, y2 = bpUi.polar(rb + 1, a - ha - e)
		local x3, y3 = bpUi.polar(rb + 1, a + ha + e)
		local edge = L.stale and C.stale or C.markEdge
		gl.BeginEnd(GL.TRIANGLES, bpUi.triVerts, x1, y1, x2, y2, x3, y3, edge, edge, edge)
		x1, y1 = bpUi.polar(ra, a)
		x2, y2 = bpUi.polar(rb, a - ha)
		x3, y3 = bpUi.polar(rb, a + ha)
		local c1, c2 = C.mark, C.markHi
		if L.stale then
			c1, c2 = C.stale, C.staleHi
		end
		gl.BeginEnd(GL.TRIANGLES, bpUi.triVerts, x1, y1, x2, y2, x3, y3, c1, c2, c2)
	end
	if L.mA >= 0 then -- small pointer inside the ring
		local mult = (L.stallM and 1.2 or 1) * hoverMult
		local a = a0 - L.mA
		local pr, pa = D.pointR, D.pointA
		local rc = (pr[1] + pr[2] + pr[3]) / 3 * H
		local function corner(i) -- (not per frame: the list is rebuilt only on change)
			local r = rc + (pr[i] * H - rc) * mult
			return bpUi.polar(r, a + pa[i] * mult)
		end
		local x1, y1 = corner(1)
		local x2, y2 = corner(2)
		local x3, y3 = corner(3)
		local xc, yc = (x1 + x2 + x3) / 3, (y1 + y2 + y3) / 3
		local c1, c2, c3, ch = C.point, C.pointMid, C.pointTip, C.pointHi -- grey left corner, bright middle
		if L.stale then
			c1, c2, c3, ch = C.stale, C.stale, C.stale, C.staleHi
		end
		local tri = bpUi.triVerts
		gl.BeginEnd(GL.TRIANGLES, tri, xc, yc, x1, y1, x2, y2, ch, c1, c2)
		gl.BeginEnd(GL.TRIANGLES, tri, xc, yc, x2, y2, x3, y3, ch, c2, c3)
		gl.BeginEnd(GL.TRIANGLES, tri, xc, yc, x3, y3, x1, y1, ch, c3, c1)
	end
	glColor(1, 1, 1, 1)
end

-- percent text list (per frame; it lies partly under the bar, outside uiTex)
function bpUi.drawPct()
	local t, c = resbarDrawinfo.BP.textPct, bpUi.C.ringUsed
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 0.6)
	font2:SetTextColor(c[1], c[2], c[3], 1)
	font2:Print(bpUi.pctStrings[bpUi.pct], t[1], t[2], t[3], t[4])
	font2:End()
end

-- what lies below the strip (shadows, the hanging part of the gauge), per frame from drawResBars under a scissor
function bpUi.drawBelowStrip()
	local g = bpUi.g
	if bpUi.belowList and g.B then
		gl.Scissor(0, 0, vsx, g.B)
		glCallList(bpUi.belowList)
		gl.Scissor(false)
	end
end

-- every frame from drawResBars (behind showResourceBars)
function bpUi.drawBars(update)
	if update then
		-- ND: the clear rects of the income/pull column and of the lower row (storage + current value) touch each
		-- other, so whenever one text of a resource is re-rendered all three are
		for i = 1, 2 do
			local u = updateRes[resourceNames[i]]
			if u[1] or u[2] or u[3] then
				u[1], u[2], u[3] = true, true, true
			end
		end
	end
	local l = dlist.resbar.BP
	if not resbarArea.BP[1] then
		return
	end
	if update then
		bpUi.refreshValues()
	end
	if (bp.stallingMetal or bp.stallingEnergy) and not spec and gameFrame > cfg.spawnWarpInFrame and l[4] then
		glBlending(GL.SRC_ALPHA, GL.ONE)
		if bp.stallingMetal then
			glColor(1, 0.3, 0.3, 0.1 * blinkProgress)
		else
			glColor(1, 0.75, 0.2, 0.1 * blinkProgress)
		end
		glCallList(l[4]) -- stall flash
		glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	end
	if l[3] then
		glCallList(l[3]) -- icon, when it reaches below the bar
	end
	if dlist.resValuesBar.BP then
		glCallList(dlist.resValuesBar.BP) -- ring
	end
	if l[5] then
		glCallList(l[5]) -- percent text
	end
	if bpUi.alertsShown and l[7] then
		glCallList(l[7])
	end
end

-- ND: wind / tidal / coms segments: icon at the left, the value next to it, a small second value after it
-- (wind: the min-max range, coms: the enemy count); all on the line 0.31 H below the top

-- wind blades (per frame, rotating): wind1 moves to the shadow, wind2 draws it and moves to the icon, wind3 draws
-- the icon; DrawScreen rotates before wind2 and wind3
function bpUi.windLists(area)
	local D, g = bpUi.D, bpUi.g
	local cx, cy = area[1] + D.windIconX * g.hx, g.T - D.windY * g.H
	local s = D.windIconS * g.H
	local ox, oy = mathMax(1, g.H * 0.016), -mathMax(1, g.H * 0.023)
	for i = 1, 3 do
		if dlist["wind" .. i] then
			glDeleteList(dlist["wind" .. i])
		end
	end
	dlist.wind1 = glCreateList(function()
		glPushMatrix()
		glTranslate(cx + ox, cy + oy, 0)
		glColor(0, 0, 0, 0.45)
		glTexture(textures.blades)
	end)
	dlist.wind2 = glCreateList(function()
		glTexRect(-s, -s, s, s)
		glPopMatrix()
		glPushMatrix()
		glTranslate(cx, cy, 0)
		glColor(1, 1, 1, 1)
	end)
	dlist.wind3 = glCreateList(function()
		glTexRect(-s, -s, s, s)
		glTexture(false)
		glPopMatrix()
	end)
	cache.windRange = "\255\255\255\255" .. tostring(minWind) .. "-" .. tostring(maxWind)
end

-- current wind and the range (render-to-texture into uiTex, scissor = the wind segment)
function bpUi.drawWindText()
	local D, g = bpUi.D, bpUi.g
	local H, capH = g.H, bpUi.capH
	local x = windArea[1] + D.windTextX * g.hx
	local s1, s2 = D.fsCur * H, D.fsRange * H
	local w = font2:GetTextWidth("0.0") * s1
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 0.6)
	if gameFrame > 0 then
		font2:Print(currentWindText, x, g.T - D.windY * H - capH * s1 * 0.5, s1, "s")
		w = font2:GetTextWidth(currentWind) * s1
	end
	font2:Print(cache.windRange, x + w + D.rangeGap * g.hx, g.T - D.rangeY * H - capH * s2 * 0.5, s2, "s")
	font2:End()
end

-- tidal icon (per frame list, DrawScreen translates to the stock origin first): the waves, 1 px black outline
function bpUi.tidalList(area)
	local D, g = bpUi.D, bpUi.g
	local ox = area[1] + ((area[3] - area[1]) / 2) - (cfg.useSkew and (area[4] - area[2]) * skewTan * 0.5 or 0)
	local oy = area[2] + (bgpadding / 2) + ((area[4] - area[2]) / 2)
	local cx, cy = area[1] + D.tidalIconX * g.hx - ox, g.T - D.tidalIconY * g.H - oy
	local hw, hh = D.tidalIconW * g.H * 0.5, D.tidalIconH * g.H * 0.5
	glTexture(textures.waves)
	glColor(0, 0, 0, 1)
	for i = 0, 7 do
		local a = i * PI / 4
		local dx, dy = bpUi.cos(a), mathSin(a)
		glTexRect(cx - hw + dx, cy - hh + dy, cx + hw + dx, cy + hh + dy, 0, 0.71, 1, 0.29)
	end
	glColor(1, 1, 1, 1)
	glTexRect(cx - hw, cy - hh, cx + hw, cy + hh, 0, 0.71, 1, 0.29)
	glTexture(false)
	glPopMatrix()
end

-- tidal speed (static, drawUi)
function bpUi.drawTidalText()
	local D, g = bpUi.D, bpUi.g
	local s, c = D.fsCur * g.H, bpUi.C.cream
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 0.6)
	font2:SetTextColor(c[1], c[2], c[3], c[4])
	font2:Print(tostring(tidalSpeed), tidalarea[1] + D.tidalTextX * g.hx, g.T - D.windY * g.H - bpUi.capH * s * 0.5, s, "s")
	font2:End()
end

-- commander counter (list, render-to-texture into uiTex): icon in the colour set by renderComCounter, own count,
-- enemy count small after it
function bpUi.drawComs(area, texPath, showText)
	local D, g = bpUi.D, bpUi.g
	local H, capH = g.H, bpUi.capH
	local s = D.comsIconS * H * 0.5
	local cx, cy = area[1] + D.comsIconX * g.hx, g.T - D.windY * H
	if VFS.FileExists(texPath) then
		glTexture(textures.com)
		glTexRect(cx - s, cy - s, cx + s, cy + s)
		glTexture(false)
	end
	if showText then
		local C = bpUi.C
		local s1, s2 = D.fsCur * H, D.fsRange * H
		local x = area[1] + D.comsTextX * g.hx
		local own = tostring(allyComs)
		font2:Begin(true)
		font2:SetOutlineColor(0, 0, 0, 0.6)
		font2:SetTextColor(C.green[1], C.green[2], C.green[3], 1)
		font2:Print(own, x, cy - capH * s1 * 0.5, s1, "s")
		font2:SetTextColor(C.red[1], C.red[2], C.red[3], 1)
		font2:Print(tostring(enemyComCount), x + font2:GetTextWidth(own) * s1 + D.rangeGap * g.hx,
			g.T - D.rangeY * H - capH * s2 * 0.5, s2, "s")
		font2:End()
	end
end

-- alert boxes under the hanging part of the gauge, styled like the stock overflow banner
function bpUi.drawAlerts()
	local a = resbarArea.BP
	if not a[1] then
		return
	end
	local ws = widgetScale
	local fs = (orgHeight * (1 + (ui_scale - 1) / 1.33) / 4) * ws
	local bannerH = 15.5 * ws
	local pad = 2.2 * ws
	local x, top = a[3], resbarDrawinfo.BP.yBot
	if dlist.resbar.metal[7] then -- the metal overflow banner hangs under metal: start below it
		top = mathMin(top, bpUi.g.B - bannerH - 1)
	end
	local c = bpUi.col
	for i = 1, #bpUi.alerts do
		if bpUi.alertOn[i] then
			local alert = bpUi.alerts[i]
			local col = alert.colors
			local textWidth = font2:GetTextWidth(alert.text) * fs
			RectRound(x - textWidth, top - bannerH, x, top, 3.7 * ws, 0, 0, 1, 1, col[1], col[2])
			RectRound(x - textWidth + pad, top - bannerH + pad, x - pad, top, 2.8 * ws, 0, 0, 1, 1, col[3], col[4])
			RectRoundOutline(x - textWidth + pad, top - bannerH + pad, x - pad, top, 2.8 * ws, pad * 1.33,
				0, 0, 1, 1, c.outer, c.outerInner)
			font2:Begin(true)
			font2:SetTextColor(1, 0.88, 0.88, 1)
			font2:SetOutlineColor(0.2, 0, 0, 0.6)
			font2:Print(alert.text, x, top - 9.3 * ws, fs, "or")
			font2:End()
			x = x - textWidth - pad
		end
	end
end

function bpUi.hideAlerts()
	if dlist.resbar.BP[7] then
		dlist.resbar.BP[7] = glDeleteList(dlist.resbar.BP[7])
	end
	bpUi.alertMask, bpUi.alertsShown, bpUi.alertSince = 0, false, nil
end

-- from the stock 0.25 s block of Update
function bpUi.slowUpdate()
	bpTrack.checkTeam()
	if not showResourceBars and bpUi.gsList then
		bpUi.removeGuishader() -- bars hidden (quick start): no blur under the bar; init re-registers it when they come back
	end
	if not bp.cfg.enabled or not resbarArea.BP[1] then
		return
	end
	if now > (bpUi.nextFlags or 0) then
		bpUi.nextFlags = now + 1
		bpTrack.updateFlags()
	end

	-- alerts: same 1.1 s debounce as the stock overflow banner, list rebuilt only when the set changes
	local on = bpUi.alertOn
	local want = bp.cfg.alerts and not spec and gameFrame > cfg.spawnWarpInFrame and showResourceBars
	on[1] = want and bp.stallingMetal or false
	on[2] = want and bp.stallingEnergy or false
	on[3] = want and bp.idleAlert or false
	on[4] = want and bp.needBuildpower or false
	on[5] = want and bp.tooMuchBuildpower and not on[1] and not on[2] or false -- "Need metal/energy" already says it
	local mask = 0
	for i = 1, #on do
		if on[i] then
			mask = mask + bpUi.alertBits[i]
		end
	end
	if mask > 0 then
		if not bpUi.alertSince then
			bpUi.alertSince = now + 1.1
		end
		if bpUi.alertSince < now then
			local banner = dlist.resbar.metal[7] ~= nil -- bpUi.drawAlerts moves the boxes below it
			if mask ~= bpUi.alertMask or banner ~= bpUi.alertBanner or not dlist.resbar.BP[7] then
				bpUi.alertMask, bpUi.alertBanner = mask, banner
				if dlist.resbar.BP[7] then
					glDeleteList(dlist.resbar.BP[7])
				end
				dlist.resbar.BP[7] = glCreateList(bpUi.drawAlerts)
			end
			bpUi.alertsShown = true
		end
	elseif bpUi.alertSince or dlist.resbar.BP[7] then
		bpUi.hideAlerts()
	end

	-- tooltip text only while hovered (and once after every updateBar)
	if hoveringTopbar == "BP" or not bpUi.lastTooltip then
		bpUi.updateTooltip()
	end
end

-- from the stock 0.5 s block of Update: another resource top bar overwrote our WG.topbar closures
function bpUi.checkConflict()
	if bpUi.checkButtons then
		bpUi.checkButtons()
	end
	if bpUi.warned or not bpUi.ownGetPosition or not WG.topbar then
		return
	end
	if WG.topbar.GetPosition ~= bpUi.ownGetPosition then
		bpUi.warn()
	end
end

-- from Initialize, before our WG.topbar functions are assigned
function bpUi.checkStartConflict()
	local orders = widgetHandler and widgetHandler.orderList
	local order = orders and orders["Top Bar"]
	local orderBP = orders and orders["Top Bar with Buildpower"]
	if (type(order) == "number" and order > 0) or (type(orderBP) == "number" and orderBP > 0)
		or (WG.topbar and WG.topbar.getResourceBarsVisible and WG.topbar.getResourceBarsVisible()) then
		bpUi.warn()
	end
end

function bpUi.warn()
	if not bpUi.warned then
		bpUi.warned = true
		Spring.Echo("Top Bar New Design: another resource top bar (the stock \"Top Bar\" or \"Top Bar with Buildpower\") is enabled too. Disable it in the widget list (F11), both bars draw at the same place.")
	end
end

function bpUi.fmt(v)
	if v == nil then
		return "nil"
	end
	return stringFormat("%.3f", v)
end

function bpUi.tooltipText()
	local tc, hc = "\255\215\215\215", "\255\255\255\255"
	local total = bp.total
	if not bp.hasData or total <= 0 then
		return tc .. "Your total buildpower (BP) is " .. hc .. stringFormat("%d", total + 0.5) .. tc .. "."
	end
	local reservedPct = mathMax(0, mathFloor(bp.reserved / total * 100 + 0.5))
	local usedPct = mathMax(0, mathFloor(bp.used / total * 100 + 0.5))
	local idlePct = mathMax(0, mathFloor(bp.idle / total * 100 + 0.5))
	local text = tc .. "Your total buildpower (BP) is " .. hc .. stringFormat("%d", total + 0.5) .. tc .. ", of which:\n"
		.. hc .. reservedPct .. "%" .. tc .. " is assigned to tasks or moving to jobs (dark teal arc).\n"
		.. hc .. usedPct .. "%" .. tc .. " is currently active and being used (teal arc). This is the number shown.\n"
		.. hc .. idlePct .. "%" .. tc .. " is idle with no BP tasks (grey part of the ring)."
	if bp.cfg.indicators and bp.mSupportRatio and bp.eSupportRatio then
		text = text .. "\n\nThe grey and yellow ticks around the ring show you that, if all BP were fully engaged:\n"
			.. "Metal income would support " .. hc .. mathCeil(bp.mSupportRatio * 100) .. "%" .. tc .. " of BP.\n"
			.. "Energy income would support " .. hc .. mathCeil(bp.eSupportRatio * 100) .. "%" .. tc .. " of BP."
		if bp.cfg.windRange and bp.numWindGenerators > 0 and bp.eSupportMinWind and bp.eSupportMaxWind then
			text = text .. "\nDepending on the wind, energy would support " .. hc .. mathCeil(bp.eSupportMinWind * 100) .. "%"
				.. tc .. " to " .. hc .. mathCeil(bp.eSupportMaxWind * 100) .. "%" .. tc .. " (thin yellow arc)."
		end
		if bp.supportStale then
			text = text .. "\n(Nothing is being built right now: these are the last known values.)"
		end
	end
	local surplus = bp.surplusBP
	if surplus then
		if surplus == 0 then
			text = text .. "\n\nYou have just enough buildpower to keep up with your income."
		elseif surplus > 0 then
			text = text .. "\n\nYou have about " .. hc .. surplus .. tc .. " buildpower more than you need to keep up with your income."
		else
			text = text .. "\n\nYou need about " .. hc .. -surplus .. tc .. " more buildpower to keep up with your income."
		end
	end
	if bp.cfg.debugTooltip then
		local f = bpUi.fmt
		text = text .. "\n\nDEBUG:\n"
			.. f(bp.used) .. " BP used (averaged), " .. f(bp.usedInstant) .. " last pass\n"
			.. f(bp.reserved) .. " BP reserved (averaged), " .. f(bp.reservedInstant) .. " last pass\n"
			.. f(bp.buildingInstant) .. " BP building if no stall, " .. f(bp.stalledInstant) .. " BP stalled\n"
			.. bp.numBuilders .. " builders, " .. bp.numNanos .. " nanos, " .. bp.numFactories .. " factories, "
			.. bp.numWindGenerators .. " wind generators\n"
			.. f(bp.builderMetalExpense) .. " M / " .. f(bp.builderEnergyExpense) .. " E spent by builders\n"
			.. f(bp.nonBuilderMetalExpense) .. " M / " .. f(bp.nonBuilderEnergyExpense) .. " E spent by non-builders\n"
			.. f(bp.metalPerBP) .. " M / " .. f(bp.energyPerBP) .. " E expense per BP\n"
			.. f(r.metal[4]) .. " M / " .. f(r.energy[4]) .. " E income, wind " .. f(bp.windStrength) .. "\n"
			.. "projections:\n"
			.. f(bp.metalExpenseIfAllUsed) .. " M spent if all BP is used\n"
			.. f(bp.energyExpenseIfAllUsed) .. " E spent if all BP is used\n"
			.. f(bp.metalSupportedBP) .. " BP supported by M income\n"
			.. f(bp.energySupportedBP) .. " BP supported by E income\n"
			.. f(bp.mSupportRatio) .. " / " .. f(bp.eSupportRatio) .. " M / E support ratio\n"
			.. f(bp.eSupportMinWind) .. " / " .. f(bp.eSupportMaxWind) .. " E support at min / max wind\n"
			.. tostring(bp.surplusBP) .. " surplus BP, last pass at frame " .. bp.lastPassFrame
	end
	return text
end

function bpUi.updateTooltip()
	if not WG.tooltip or not resbarArea.BP[1] or not bpUi.hoverArea or not showResourceBars then
		return
	end
	local text = bpUi.tooltipText()
	if text ~= bpUi.lastTooltip then -- the tooltip widget drops its cached list on every call with a text
		bpUi.lastTooltip = text
		WG.tooltip.AddTooltip("top_bar_nd_bp", bpUi.hoverArea, text, nil, "Buildpower")
	end
end

-- options (registered through WG.options in one call; values persisted by GetConfigData)
bpUi.optionSpecs = {
	{ key = "enabled", type = "bool", relayout = true, name = "Buildpower gauge",
		description = "Show the round buildpower gauge between metal and energy" },
	{ key = "indicators", type = "bool", name = "Eco support indicators",
		description = "Estimate how much buildpower is supported by your metal and energy income" },
	{ key = "windRange", type = "bool", name = "Wind range indicator",
		description = "Show how energy-supported buildpower might vary with wind speed (thin arc around the gauge)" },
	{ key = "alerts", type = "bool", name = "Buildpower alerts",
		description = "Need metal / Need energy / Idle buildpower / Need buildpower / Too much buildpower" },
	{ key = "icon", type = "bool", relayout = true, name = "Buildpower icon",
		description = "Builder icon in the centre of the buildpower gauge" },
	{ key = "debugTooltip", type = "bool", name = "Buildpower debug data",
		description = "Show debug data in the tooltip of the buildpower gauge" },
}

function bpUi.addOptions()
	if not WG.options or not (WG.options.addOptions or WG.options.addOption) then
		return
	end
	local list, ids = {}, {}
	local widgetName = widget:GetInfo().name
	for i, spec_ in ipairs(bpUi.optionSpecs) do
		local key, relayout = spec_.key, spec_.relayout
		ids[i] = "top_bar_nd_" .. key
		list[i] = {
			id = ids[i],
			name = spec_.name,
			description = spec_.description,
			type = spec_.type,
			min = spec_.min,
			max = spec_.max,
			step = spec_.step,
			value = bp.cfg[key],
			widgetname = widgetName,
			onchange = function(_, value)
				if type(value) ~= type(bp.cfg[key]) then
					return
				end
				bp.cfg[key] = value
				if relayout then
					widget:ViewResize() -- not init(): resets cache.lastValueWidth so the metal/energy fill lists move too
				else
					bpUi.forceRebuild = true
					bpUi.lastTooltip = nil
				end
			end,
		}
	end
	bpUi.optionIds = ids
	if WG.options.addOptions then
		WG.options.addOptions(list)
	else
		WG.options.addOption(list[1]) -- very old options widget: one call per option
		for i = 2, #list do
			WG.options.addOption(list[i])
		end
	end
end

function bpUi.getData()
	return bp
end

-- from Initialize (SetConfigData already ran)
function bpUi.initialize()
	bpUi.addOptions()
	WG.buildpower = { GetData = bpUi.getData, version = 1 }
end

-- from Shutdown
function bpUi.shutdown()
	bpUi.clearLists()
	if bpUi.belowList then
		bpUi.belowList = glDeleteList(bpUi.belowList)
	end
	if WG.options and bpUi.optionIds then
		if WG.options.removeOptions then
			WG.options.removeOptions(bpUi.optionIds)
		elseif WG.options.removeOption then
			for i = 1, #bpUi.optionIds do
				WG.options.removeOption(bpUi.optionIds[i])
			end
		end
		bpUi.optionIds = nil
	end
	if WG.buildpower and WG.buildpower.GetData == bpUi.getData then
		WG.buildpower = nil
	end
end

bpTrack.reset(nil)

function init()
	refreshUi = true

	r = { metal = { sp.GetTeamResources(myTeamID, "metal") }, energy = { sp.GetTeamResources(myTeamID, "energy") } }
	topbarArea =
		{ mathFloor(xPos + (cfg.borderPadding * widgetScale)), mathFloor(vsy - (height * widgetScale)), vsx, vsy }

	local filledWidth = 0
	local totalWidth = topbarArea[3] - topbarArea[1]

	skewTan = math.tan(math.rad(cfg.skewAngleDeg)) -- refresh in case cfg changed

	-- metal, BP gauge, energy (ND: proportions of the mockup, in the stock metal + energy span at most)
	local width = mathFloor(totalWidth / 4.4)
	filledWidth = bpUi.layout(width) - topbarArea[1] -- sets resbarArea.metal / .BP / .energy
	updateResbar("metal")
	updateResbar("energy")

	-- wind
	-- Small elements (wind, tidal, coms, buttons) — height fraction from cfg, top-aligned.
	-- ND: wind, tidal and coms are segments of one slanted panel (no gaps), always slanted
	local smallVPad = mathFloor((topbarArea[4] - topbarArea[2]) * (1 - cfg.smallElementHeightFraction) + 0.5)
	width = bpUi.smallWidth("wind")
	windArea =
		{ topbarArea[1] + filledWidth, topbarArea[2] + smallVPad, topbarArea[1] + filledWidth + width, topbarArea[4] }
	filledWidth = filledWidth + width
	updateWind()

	-- tidal
	if displayTidalSpeed then
		if not checkTidalRelevant() then
			displayTidalSpeed = false
		else
			width = bpUi.smallWidth("tidal")
			tidalarea = {
				topbarArea[1] + filledWidth,
				topbarArea[2] + smallVPad,
				topbarArea[1] + filledWidth + width,
				topbarArea[4],
			}
			filledWidth = filledWidth + width
			updateTidal()
		end
	end

	-- coms
	if displayComCounter then
		width = bpUi.smallWidth("coms")
		comsArea = {
			topbarArea[1] + filledWidth,
			topbarArea[2] + smallVPad,
			topbarArea[1] + filledWidth + width,
			topbarArea[4],
		}
		filledWidth = filledWidth + width
		updateComs()
	end
	bpUi.smallLayout(windArea[1], topbarArea[1] + filledWidth, topbarArea[2] + smallVPad) -- ND: the joined panel
	-- ND: the free area starts after the panel's drop shadow
	filledWidth = filledWidth + mathFloor(bpUi.D.shadowSide * (topbarArea[4] - topbarArea[2]) + 0.5) + widgetSpaceMargin

	-- the button strip is drawn by the Top Bar Buttons widget; this is the width it
	-- reserves on the right, which GetFreeArea and GetPosition below report
	width = mathFloor(totalWidth / 4)
	local buttonsBottom = topbarArea[2] + smallVPad

	if WG.topbar then
		WG.topbar.GetPosition = function()
			-- ND: metal's bottom left corner; the panels are slanted also on builds without the skew drawers
			local leftSkewOffset = mathFloor((topbarArea[4] - topbarArea[2]) * bpUi.D.metalTan)
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
			local x2 = topbarArea[3] - width - widgetSpaceMargin
			return {
				mathMin(topbarArea[1] + filledWidth, x2), -- ND: an empty area rather than an inverted one
				topbarArea[2],
				x2,
				topbarArea[4],
				widgetScale,
			}
		end
		-- ND: always slanted; skewTan is the slope of the small panel's right edge, which the element placed in the
		-- free area (the converter usage) continues; leftSkewTan is metal's outer edge (GetPosition's left offset)
		WG.topbar.GetSkewConfig = function()
			return {
				useSkew = true,
				skewTan = bpUi.D.smallTanR,
				leftSkewTan = bpUi.D.metalTan,
				smallElementHeightFraction = cfg.smallElementHeightFraction,
			}
		end
		bpUi.ownGetPosition = WG.topbar.GetPosition -- BP
	end

	bpTrack.checkTeam() -- BP
	updateResbarText("metal", true)
	updateResbarText("energy", true)

	updateRes = { metal = { true, true, true, true }, energy = { true, true, true, true } }
	prevComAlert = nil
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
	bpTrack.gameFrame(n) -- BP
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
	local teams = sp.GetTeamList(myAllyTeamID)
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
	local bpArea = bpUi.hoverArea -- BP: the gauge, including the part that hangs under the bar
	if bpArea and showResourceBars and mathIsInRect(x, y, bpArea[1], bpArea[2], bpArea[3], bpArea[4]) then
		return "BP"
	end
	if
		resbarArea.energy[1]
		and mathIsInRect(x, y, resbarArea.energy[1], resbarArea.energy[2], resbarArea.energy[3], resbarArea.energy[4])
	then
		return "energy"
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
-- API has to answer "there are no buttons" rather than be missing. Checked from Update,
-- which runs after every widget's Initialize and again if it is disabled mid-game.
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

-- BP: called every 0.5 s; warns once if, after about 10 s, no "Top Bar Buttons" widget has taken over
-- its half of WG.topbar. Game builds before Sep 2026 have the buttons inside the stock Top Bar,
-- so this fork cannot show them there.
function bpUi.checkButtons()
	if bpUi.buttonsChecked then
		return
	end
	bpUi.buttonsTicks = (bpUi.buttonsTicks or 0) + 1
	if bpUi.buttonsTicks < 20 then
		return
	end
	bpUi.buttonsChecked = true
	if WG.topbar and fallback.showingQuit and WG.topbar.showingQuit == fallback.showingQuit then
		Spring.Echo(widget:GetInfo().name .. ': no "Top Bar Buttons" widget found. Your game build keeps the menu buttons inside the stock "Top Bar", so they are missing while this widget replaces it. Copy stock_reference/gui_top_bar_buttons.lua from the repository into LuaUI/Widgets to get them back.')
	end
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

function widget:Update(dt)
	now = osClock()

	provideButtonFallbacks()
	timers.deferResourceUpdate = timers.gameFrameHappened and now - timers.lastUpdateTime < (1 / 30)
	timers.gameFrameHappened = false
	timers.lastUpdateTime = now

	windRotation = windRotation + (currentWind * cfg.bladeSpeedMultiplier * dt * 30)

	if now > timers.nextStateCheck then
		timers.nextStateCheck = now + 0.0333

		local prevMyTeamID = myTeamID
		local newMyTeamID = sp.GetMyTeamID()
		if spec and newMyTeamID ~= prevMyTeamID then
			-- check if the team that we are spectating changed
			myTeamID = newMyTeamID
			checkSelfStatus()
			init()
		end

		mx, my = sp.GetMouseState()

		hoveringTopbar = false
		if mx > topbarArea[1] and my > topbarArea[2] - bpUi.hang then -- checking if the cursor is high enough, too (BP: the gauge hangs lower)
			hoveringTopbar = hoveringElement(mx, my)
		end

		local _, _, isPaused = sp.GetGameSpeed()

		if not isPaused then
			if blinkDirection then
				blinkProgress = blinkProgress + (dt * 9)
				if blinkProgress > 1 then
					blinkProgress = 1
					blinkDirection = false
				end
			else
				blinkProgress = blinkProgress - (dt / (blinkProgress * 1.5))
				if blinkProgress < 0 then
					blinkProgress = 0
					blinkDirection = true
				end
			end
		end
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
		bpUi.checkConflict() -- BP
	end

	if now > timers.nextResBarUpdate then
		timers.nextResBarUpdate = now + 0.05
		if not spec and not showingQuitscreen() then
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
		elseif spec then
			local prevMyTeamID = myTeamID
			local newMyTeamID = sp.GetMyTeamID()
			if newMyTeamID ~= prevMyTeamID then
				-- check if the team that we are spectating changed
				myTeamID = newMyTeamID
				draggingShareIndicatorValue = {}
				draggingConversionIndicatorValue = nil
				updateResbar("metal")
				updateResbar("energy")
			else
				-- make sure conversion/overflow sliders are adjusted
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
		else
			-- make sure conversion/overflow sliders are adjusted
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
	end

	if now > timers.nextSmoothUpdate then
		timers.nextSmoothUpdate = now + 0.07
		smoothResources()
	end

	if now > timers.nextSlowUpdate then
		timers.nextSlowUpdate = now + 0.25
		local prevR = r
		r = { metal = { sp.GetTeamResources(myTeamID, "metal") }, energy = { sp.GetTeamResources(myTeamID, "energy") } }
		-- check if we need to smooth the resources
		local metalDiff7 = r.metal[7] - prevR.metal[7]
		local metalDiff8 = r.metal[8] - prevR.metal[8]
		local energyDiff7 = r.energy[7] - prevR.energy[7]
		local energyDiff8 = r.energy[8] - prevR.energy[8]
		local metalStorage = r.metal[2]
		local energyStorage = r.energy[2]

		if
			(r.metal[7] > 1 and metalDiff7 ~= 0 and r.metal[7] / metalStorage > 0.05)
			or (r.metal[8] > 1 and metalDiff8 ~= 0 and r.metal[8] / metalStorage > 0.05)
			or (r.energy[7] > 1 and energyDiff7 ~= 0 and r.energy[7] / energyStorage > 0.05)
			or (r.energy[8] > 1 and energyDiff8 ~= 0 and r.energy[8] / energyStorage > 0.05)
		then
			smoothedResources = r
		end

		-- resbar values and overflow
		updateAllyTeamOverflowing()
		updateResbarText("metal")
		updateResbarText("energy")
		bpUi.slowUpdate() -- BP

		-- wind
		currentWind = stringFormat("%.1f", select(4, sp.GetWind()))
		currentWindText = "\255\231\220\181" .. currentWind -- ND: cream

		-- coms
		if displayComCounter then
			countComs()
		end
	end
end

-- --- OPTIMIZATION: Pre-defined function for RenderToTexture to avoid creating a closure.
local function clearFn() end -- no-op used for pre-clearing regions in uiTex
local function renderResbarText()
	glTranslate(-1, -1, 0)
	glScale(2 / (topbarArea[3] - topbarArea[1]), 2 / (topbarArea[4] - topbarArea[2]), 0)
	glTranslate(-topbarArea[1], -topbarArea[2], 0)

	local res = "metal"
	if updateRes[res][1] then
		updateRes[res][1] = false
		drawResbarValue(res)
	end
	if updateRes[res][2] then
		updateRes[res][2] = false
		drawResbarPullIncome(res)
	end
	if updateRes[res][3] then
		updateRes[res][3] = false
		drawResbarStorage(res)
	end

	res = "energy"
	if updateRes[res][1] then
		updateRes[res][1] = false
		drawResbarValue(res)
	end
	if updateRes[res][2] then
		updateRes[res][2] = false
		drawResbarPullIncome(res)
	end
	if updateRes[res][3] then
		updateRes[res][3] = false
		drawResbarStorage(res)
	end
end

local function drawResBars()
	if not showResourceBars then
		return
	end
	bpUi.drawBelowStrip() -- ND: shadows and the hanging gauge below the strip (uiBgTex ends at the strip bottom)

	-- (no matrix push/pop needed: nothing in here touches the modelview matrix)
	local update = false

	if now > timers.nextBarsUpdate and (not timers.deferResourceUpdate or now > timers.nextForcedBarsUpdate) then
		timers.nextBarsUpdate = now + 0.05
		timers.nextForcedBarsUpdate = now + 0.03
		update = true
	end

	local res = "metal"
	if dlist.resbar[res][1] and dlist.resbar[res][2] then
		if not spec and gameFrame > cfg.spawnWarpInFrame and dlist.resbar[res][4] then
			-- only touch blending state when a flash actually gets drawn
			local fr, fg, fb, fa
			if allyteamOverflowingMetal then
				fr, fg, fb, fa = 1, 0, 0, 0.1 * allyteamOverflowingMetal * blinkProgress
			elseif overflowingMetal then
				fr, fg, fb, fa = 1, 1, 1, 0.04 * overflowingMetal * (0.6 + (blinkProgress * 0.4))
			elseif r[res][1] < 1000 then
				local process = fillRatio(r[res][1], r[res][2]) * 13
				if process < 1 then
					fr, fg, fb, fa = 0.9, 0.4, 1, 0.045 * (1 - process)
				end
			end
			if fa then
				glBlending(GL.SRC_ALPHA, GL.ONE)
				glColor(fr, fg, fb, fa)
				glCallList(dlist.resbar[res][4]) -- flash bar
				glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
			end
		end

		if update then
			updateResbarValues(res, update)
		end
		if dlist.resValuesBar[res] then
			glCallList(dlist.resValuesBar[res]) -- res bar
		end
		if dlist.resbar[res][2] then
			glCallList(dlist.resbar[res][2]) -- sliders
		end

		if showOverflowTooltip[res] and dlist.resbar[res][7] then
			glCallList(dlist.resbar[res][7])
		end -- overflow warning
	end

	res = "energy"
	if dlist.resbar[res][1] and dlist.resbar[res][2] then
		if not spec and gameFrame > cfg.spawnWarpInFrame and dlist.resbar[res][4] then
			-- only touch blending state when a flash actually gets drawn
			local fr, fg, fb, fa
			if allyteamOverflowingEnergy then
				fr, fg, fb, fa = 1, 0, 0, 0.1 * allyteamOverflowingEnergy * blinkProgress
			elseif overflowingEnergy then
				fr, fg, fb, fa = 1, 1, 0, 0.04 * overflowingEnergy * (0.6 + (blinkProgress * 0.4))
			elseif r[res][1] < 2000 then
				local process = fillRatio(r[res][1], r[res][2]) * 13
				if process < 1 then
					fr, fg, fb, fa = 0.9, 0.55, 1, 0.045 * (1 - process)
				end
			end
			if fa then
				glBlending(GL.SRC_ALPHA, GL.ONE)
				glColor(fr, fg, fb, fa)
				glCallList(dlist.resbar[res][4]) -- flash bar
				glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
			end
		end

		if update then
			updateResbarValues(res, update)
		end
		if dlist.resValuesBar[res] then
			glCallList(dlist.resValuesBar[res]) -- res bar
		end
		local glow = dlist.energyGlow
		if glow then
			-- animate the texture scroll via the texture matrix instead of rebaking
			-- the display lists each update (offsets match the old -now/80 etc bakes).
			-- glow[1] bakes color/blending/texture-bind, glow[4] bakes the unbind,
			-- colorize overlay and blending restore; translates compose so each layer
			-- needs only the delta from the previous one.
			-- NOTE: no Push/PopMatrix here! gl.CallList resets the engine's *tracked*
			-- matrix mode to the one recorded at list creation (MODELVIEW), so a
			-- push/pop pair around CallList desyncs the tracker and underflows the
			-- modelview stack. Translate/LoadIdentity are raw GL calls and stay safe.
			local o1 = -now / 80
			local o2 = now / 70
			local o3 = -now / 55
			glMatrixMode(GL.TEXTURE)
			glTranslate(o1, o1, 0)
			glCallList(glow[1])
			glTranslate(o2 - o1, o2 - o1, 0)
			glCallList(glow[2])
			glTranslate(o3 - o2, o3 - o2, 0)
			glCallList(glow[3])
			glLoadIdentity()
			glMatrixMode(GL.MODELVIEW)
			glCallList(glow[4])
		end
		if dlist.resbar[res][2] then
			glCallList(dlist.resbar[res][2]) -- sliders
		end

		if showOverflowTooltip[res] and dlist.resbar[res][7] then
			glCallList(dlist.resbar[res][7])
		end -- overflow warning
	end

	bpUi.drawBars(update) -- BP

	if update then
		-- ND: the clear rects (uiTex coordinates) are kept in resbarDrawinfo by bpUi.resLayout / bpUi.setClear:
		-- [1] current value and [3] storage on the lower row (coupled in bpUi.drawBars), [2] the income/pull column
		local scissors = {}
		res = "metal"
		if updateRes[res][1] then
			scissors[#scissors + 1] = resbarDrawinfo[res].clearCurrent
		end
		if updateRes[res][2] then
			scissors[#scissors + 1] = resbarDrawinfo[res].clearPI
		end
		if updateRes[res][3] then
			scissors[#scissors + 1] = resbarDrawinfo[res].clearStorage
		end
		res = "energy"
		if updateRes[res][1] then
			scissors[#scissors + 1] = resbarDrawinfo[res].clearCurrent
		end
		if updateRes[res][2] then
			scissors[#scissors + 1] = resbarDrawinfo[res].clearPI
		end
		if updateRes[res][3] then
			scissors[#scissors + 1] = resbarDrawinfo[res].clearStorage
		end

		-- skip the whole FBO roundtrip when no text region actually changed
		-- (an empty scissors list would clear the entire texture!)
		if scissors[1] then
			r2tHelper.RenderToTexture(uiTex, renderResbarText, true, scissors)
		end
	end
end


local function drawUiBackground()
	-- ND: metal, gauge, energy and the wind / tidal / coms panel are drawn after the mockup (opaque, sharp
	-- corners, hard shadows) instead of with FlowUI's element, see bpUi.drawBackground
	bpUi.drawBackground()
end

local function drawUi()
	if showResourceBars and dlist.resbar.energy and dlist.resbar.energy[1] then
		glCallList(dlist.resbar.energy[1])
		glCallList(dlist.resbar.metal[1])
		if dlist.resbar.BP[1] then -- BP
			glCallList(dlist.resbar.BP[1])
		end
	end

	-- min and max wind (rendered per-frame via renderWindText; nowind fallback below)
	local windH = windArea[4] - windArea[2]
	local fontsize = windH / 3.2
	local windSkewCX = windArea[1] + ((windArea[3] - windArea[1]) * 0.6) -- ND: right of the blades
	if cache.showIndicators and noWind then
		font2:Begin(true)
		font2:Print(
			noWindText1,
			windSkewCX,
			windArea[2] + ((windArea[4] - windArea[2]) / 1.5) - (fontsize / 5),
			fontsize * 1.06,
			"cs"
		) -- Wind speed text
		font2:Print(
			noWindText2,
			windSkewCX,
			windArea[2] + ((windArea[4] - windArea[2]) / 2.8) - (fontsize / 5),
			fontsize * 1.06,
			"cs"
		) -- Wind speed text
		font2:End()
	end

	-- tidal speed
	if cache.showIndicators and displayTidalSpeed then
		bpUi.drawTidalText() -- ND
	end
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
	um[1], um[2], um[3] = true, true, true
	ue[1], ue[2], ue[3] = true, true, true
end

local function renderWindText()
	glTranslate(-1, -1, 0)
	glScale(2 / (topbarArea[3] - topbarArea[1]), 2 / (topbarArea[4] - topbarArea[2]), 0)
	glTranslate(-topbarArea[1], -topbarArea[2], 0)

	bpUi.drawWindText() -- ND: current wind and the min-max range in a row
end

local function renderComCounter()
	glTranslate(-1, -1, 0)
	glScale(2 / (topbarArea[3] - topbarArea[1]), 2 / (topbarArea[4] - topbarArea[2]), 0)
	glTranslate(-topbarArea[1], -topbarArea[2], 0)

	if allyComs == 1 and (gameFrame % 12 < 6) then
		glColor(1, 0.6, 0, 1)
	else
		glColor(1, 1, 1, 1) -- ND: a plain white icon like the wind and tidal icons
	end
	glCallList(dlist.coms)
end

function widget:DrawScreen()
	now = osClock()
	local topbarHeight = topbarArea[4] - topbarArea[2]

	if hoveringTopbar then
		sp.SetMouseCursor("cursornormal")
	end

	if refreshUi then
		if uiBgTex then
			gl.DeleteTexture(uiBgTex)
		end
		uiBgTex = gl.CreateTexture(mathFloor(topbarArea[3] - topbarArea[1]), mathFloor(topbarArea[4] - topbarArea[2]), {
			target = GL.TEXTURE_2D,
			format = GL.ALPHA,
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
				format = GL.ALPHA,
				fbo = true,
			}
		)

		if uiBgTex then
			r2tHelper.RenderToTexture(uiBgTex, renderUiBackground, true)
		end
		if uiTex then
			r2tHelper.RenderToTexture(uiTex, renderUi, true)
		end

		-- bake the two per-frame texture blits (was r2tHelper.BlendTexRect: 6 gl calls
		-- each) into display lists: 1 gl call each per frame. The lists bake the
		-- texture binds by id, so they must be recreated here alongside the textures.
		-- (gl.* globals used on purpose: local aliases would add DrawScreen upvalues)
		if dlist.blendBg then
			glDeleteList(dlist.blendBg)
		end
		dlist.blendBg = glCreateList(function()
			gl.Blending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA)
			gl.Color(1, 1, 1, 1)
			gl.Texture(uiBgTex)
			gl.TexRect(topbarArea[1], topbarArea[2], topbarArea[3], topbarArea[4], false, true)
			gl.Texture(false)
			gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
		end)
		if dlist.blendUi then
			glDeleteList(dlist.blendUi)
		end
		dlist.blendUi = glCreateList(function()
			gl.Blending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA)
			gl.Color(1, 1, 1, 1)
			gl.Texture(uiTex)
			gl.TexRect(topbarArea[1], topbarArea[2], topbarArea[3], topbarArea[4], false, true)
			gl.Texture(false)
			gl.Blending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
		end)

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
			WG.guishader.InsertDlist(uiBgList, "top_bar_nd_background", nil, self)
		end
	end

	if dlist.blendBg then
		glCallList(dlist.blendBg)
	end

	if cache.showIndicators and dlist.wind1 then
		glPushMatrix()
		glCallList(dlist.wind1)
		glRotate(windRotation, 0, 0, 1)
		glCallList(dlist.wind2) -- ND: the shadow, then the blades over it
		glRotate(windRotation, 0, 0, 1)
		glCallList(dlist.wind3)
		glPopMatrix()
	end

	if cache.showIndicators and displayTidalSpeed and dlist.tidal2 then
		local tidalSkewCX = tidalarea[1]
			+ ((tidalarea[3] - tidalarea[1]) / 2)
			- (cfg.useSkew and (tidalarea[4] - tidalarea[2]) * skewTan * 0.5 or 0)
		glPushMatrix()
		glTranslate(
			tidalSkewCX,
			mathSin(now / PI) * tidalWaveAnimationHeight
				+ tidalarea[2]
				+ (bgpadding / 2)
				+ ((tidalarea[4] - tidalarea[2]) / 2),
			0
		)
		glCallList(dlist.tidal2)
	end

	-- Pre-clear storage text from uiTex before rendering it to screen.
	-- drawResBars() updates uiTex AFTER BlendTexRect each frame, so without this
	-- the stale storage text is visible for up to ~50ms when the warning first activates.
	-- Only done ONCE per warning activation (cache.warningCleared); the region stays
	-- cleared since drawResbarStorage skips drawing while the warning is showing.
	if
		uiTex
		and (
			(showingWarning.metal and not cache.warningCleared.metal)
			or (showingWarning.energy and not cache.warningCleared.energy)
		)
	then
		local scissorsCount = 0
		for i = 1, 2 do
			local res = resourceNames[i]
			if
				showingWarning[res]
				and not cache.warningCleared[res]
				and resbarDrawinfo[res]
				and resbarDrawinfo[res].clearStorage
			then
				cache.warningCleared[res] = true
				scissorsCount = scissorsCount + 1
				local scissor = storageScissors[scissorsCount]
				local c = resbarDrawinfo[res].clearStorage -- ND: the same rect as the storage re-render in drawResBars
				scissor[1], scissor[2], scissor[3], scissor[4] = c[1], c[2], c[3], c[4]
			end
		end
		if scissorsCount > 0 then
			for i = 1, scissorsCount do
				activeStorageScissors[i] = storageScissors[i]
			end
			activeStorageScissors[scissorsCount + 1] = nil
			r2tHelper.RenderToTexture(uiTex, clearFn, true, activeStorageScissors)
		end
	end

	if dlist.blendUi then
		glCallList(dlist.blendUi)
	end

	-- current wind
	if cache.showIndicators and not noWind then
		if currentWind ~= prevWind or refreshUi then
			prevWind = currentWind
			windTextScissor[1] = windArea[1] - topbarArea[1]
			windTextScissor[2] = windArea[2] - topbarArea[2]
			windTextScissor[3] = windArea[3] - windArea[1]
			windTextScissor[4] = windArea[4] - windArea[2]

			r2tHelper.RenderToTexture(uiTex, renderWindText, true, windTextScissor)
		end
	end

	drawResBars()

	glPushMatrix()
	if cache.showIndicators and displayComCounter and dlist.coms then
		-- commander counter
		if
			refreshUi
			or comsDlistUpdate
			or prevComAlert == nil
			or (prevComAlert ~= (allyComs == 1 and (gameFrame % 12 < 6)))
		then
			prevComAlert = (allyComs == 1 and (gameFrame % 12 < 6))
			comsDlistUpdate = nil
			comCounterScissor[1] = comsArea[1] - topbarArea[1]
			comCounterScissor[2] = 0
			comCounterScissor[3] = comsArea[3] - comsArea[1]
			comCounterScissor[4] = topbarHeight

			r2tHelper.RenderToTexture(uiTex, renderComCounter, true, comCounterScissor)
		end
	end



	glColor(1, 1, 1, 1)
	glPopMatrix()

	refreshUi = false
end

local function adjustSliders(x, y)
	if draggingShareIndicator and not spec then
		local shareValue = (x - resbarDrawinfo[draggingShareIndicator].barArea[1])
			/ (resbarDrawinfo[draggingShareIndicator].barArea[3] - resbarDrawinfo[draggingShareIndicator].barArea[1])
		if draggingShareIndicator == "metal" then
			shareValue = 1 - shareValue -- ND: the metal bar runs from the gauge (right) to the left
		end
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
	adjustSliders(x, y)
end




function widget:MousePress(x, y, button)
	if button == 1 and showResourceBars then -- ND: the knobs are not there while the bars are hidden
		if not spec then
			do -- ND: the share knobs are shown (and work) in single-player teams too
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
			smoothedResources = r
		end
	end

	if not prevSpec and prevSpec ~= spec then
		init()
	end
	bpTrack.checkTeam() -- BP
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

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam, weaponDefID)
	bpTrack.untrack(unitID) -- BP
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
	bpUi.checkStartConflict() -- BP: before our own WG.topbar functions are assigned

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

	guishaderEnabled = WG.guishader ~= nil
	widget:ViewResize()
	bpUi.initialize() -- BP: options, WG.buildpower (after ViewResize: a relayout from onchange needs fonts and margins)

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
	bpUi.shutdown() -- BP

	if dlist.blendBg then
		dlist.wind1 = glDeleteList(dlist.wind1)
		dlist.wind2 = glDeleteList(dlist.wind2)
		dlist.wind3 = glDeleteList(dlist.wind3)
		dlist.tidal2 = glDeleteList(dlist.tidal2)
		dlist.coms = glDeleteList(dlist.coms)
		dlist.blendBg = glDeleteList(dlist.blendBg)
		dlist.blendUi = glDeleteList(dlist.blendUi)

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
		WG.guishader.DeleteDlist("top_bar_nd_background")
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
	end

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

--------------------------------------------------------------------------------
-- Buildpower call-ins (no stock counterparts)
--------------------------------------------------------------------------------

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if unitTeam == bpTrack.teamID then
		bpTrack.track(unitID, unitDefID, unitTeam)
	end
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
	if oldTeam == bpTrack.teamID then
		bpTrack.untrack(unitID)
	end
	if newTeam == bpTrack.teamID then
		bpTrack.track(unitID, unitDefID, newTeam)
	end
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	if oldTeam == bpTrack.teamID then
		bpTrack.untrack(unitID)
	end
end

function widget:GetConfigData()
	return { bp = bp.cfg }
end

function widget:SetConfigData(data)
	if type(data) == "table" and type(data.bp) == "table" then
		for k, v in pairs(data.bp) do
			if bp.cfg[k] ~= nil and type(v) == type(bp.cfg[k]) then -- unknown keys (the old widthFraction) are dropped
				bp.cfg[k] = v
			end
		end
	end
end
