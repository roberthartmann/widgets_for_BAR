local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Top Bar with Buildpower",
		desc = "The stock top bar plus a buildpower bar between metal and energy. Disable the stock \"Top Bar\" when using this.",
		author = "Floris, Robert82",
		date = "Oct, 2026",
		license = "GNU GPL, v2 or later",
		layer = -95000,
		enabled = false,
		handler = true, --can use widgetHandler:x()
	}
end

--------------------------------------------------------------------------------
-- Top Bar with Buildpower
-- This file is the stock gui_top_bar.lua (see stock_reference/COMMIT.txt for the
-- exact BAR revision) plus a buildpower (BP) bar between the metal and energy bars:
-- total / reserved / used BP of your (or the spectated) team, eco support markers,
-- a wind range strip, stall and idle alerts, a tooltip and a few options.
-- Stock code is left as is; the BP additions are one-line hooks in stock functions
-- (marked "-- BP"), the tables bp / bpTrack / bpUi, one block of BP functions after
-- updateResbarValues, and new call-ins appended at the end of the file, so future
-- stock changes can be merged with a 3-way diff.
-- Disable the stock "Top Bar" widget when enabling this one.
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
local prevWind = nil
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

-- Reused scratch tables for DrawScreen to avoid per-frame allocations.
local resourceNames = { "metal", "energy" }
local windTextScissor = { 0, 0, 0, 0 }
local comCounterScissor = { 0, 0, 0, 0 }
local storageScissors = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
local activeStorageScissors = { nil, nil }

-- Buildpower (all BP state lives in these three tables; see design/integration_design.md)
local bp = { cfg = { enabled = true, widthFraction = 1 / 6, indicators = true, windRange = true,
	alerts = true, icon = true, debugTooltip = false } } -- data fields: bpTrack.reset, spec section 11
local bpTrack = { perFrame = 20, frameStep = 3 } -- unit tracking state, filled by bpTrack.reset
local bpUi = { last = {}, s = {}, textDirty = false } -- render caches and draw functions

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


local function updateComs(forceText)
	local area = comsArea

	local texPath = string.lower(string.gsub(textures.com, ":.:", ""))

	if dlist.coms then
		glDeleteList(dlist.coms)
	end
	comsDlistUpdate = true
	dlist.coms = glCreateList(function()
		-- Commander icon
		local areaH = area[4] - area[2]
		local sizeHalf = areaH / 2.44
		local yOffset = ((area[3] - area[1]) * 0.025)
		-- Parallelogram visual center is shifted left; correct content to the right.
		local skewCenterOffset = cfg.useSkew and areaH * skewTan * 0.5 or 0
		local cx = area[1] + ((area[3] - area[1]) / 2) - skewCenterOffset
		if VFS.FileExists(texPath) then
			glTexture(textures.com)
			glTexRect(
				cx - sizeHalf,
				area[2] + (areaH / 2) - sizeHalf + yOffset,
				cx + sizeHalf,
				area[2] + (areaH / 2) + sizeHalf + yOffset
			)
			glTexture(false)
		end
		-- Text
		if gameFrame > 0 or forceText then
			font2:Begin(true)
			local fontsize = areaH / 2.5
			font2:SetOutlineColor(0, 0, 0, 1)
			-- Enemy count: anchor to actual bottom-right corner of parallelogram with small padding
			local brCornerX = area[3] - (cfg.useSkew and areaH * skewTan or 0)
			font2:Print(
				"\255\255\000\000" .. enemyComCount,
				brCornerX - (1.2 * widgetScale),
				area[2] + (4.5 * widgetScale),
				fontsize,
				"or"
			)
			fontSize = areaH / 1.9
			font2:Print("\255\000\255\000" .. allyComs, cx, area[2] + (areaH / 1.77) - (fontSize / 5), fontSize, "oc")
			font2:End()
		end
	end)

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

	local bladesSize = (area[4] - area[2]) * 0.57

	if dlist.wind1 then
		glDeleteList(dlist.wind1)
	end
	dlist.wind1 = glCreateList(function()
		-- blades icon
		local skewCenterOffset = cfg.useSkew and (area[4] - area[2]) * skewTan * 0.5 or 0
		glPushMatrix()
		glTranslate(
			area[1] + ((area[3] - area[1]) / 2) - skewCenterOffset,
			area[2] + (bgpadding / 2) + ((area[4] - area[2]) / 2),
			0
		)
		glColor(1, 1, 1, 0.2)
		glTexture(textures.blades)
		-- gl.Rotate is done after displaying this dl, and before dl2
	end)

	if dlist.wind2 then
		glDeleteList(dlist.wind2)
	end
	dlist.wind2 = glCreateList(function()
		glTexRect(-bladesSize, -bladesSize, bladesSize, bladesSize)
		glTexture(false)
		glPopMatrix()
	end)

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
	local wavesSize = (area[4] - area[2]) * 0.59
	tidalWaveAnimationHeight = (area[4] - area[2]) * 0.1

	dlist.tidal2 = glCreateList(function()
		glColor(1, 1, 1, 0.2)
		glTexture(textures.waves)
		glTexRect(-wavesSize, -wavesSize, wavesSize, wavesSize)
		glTexture(false)
		glPopMatrix()
	end)

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
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 1)
	-- Text: pull
	font2:Print(
		"\255\240\125\125" .. "-" .. short(r[res][3]),
		resbarDrawinfo[res].textPull[2],
		resbarDrawinfo[res].textPull[3],
		resbarDrawinfo[res].textPull[4],
		resbarDrawinfo[res].textPull[5]
	)
	-- Text: expense
	--font2:Print("\255\240\180\145" .. "-" .. short(r[res][5]), resbarDrawinfo[res].textExpense[2], resbarDrawinfo[res].textExpense[3], resbarDrawinfo[res].textExpense[4], resbarDrawinfo[res].textExpense[5])
	-- income
	font2:Print(
		"\255\120\235\120" .. "+" .. short(r[res][4]),
		resbarDrawinfo[res].textIncome[2],
		resbarDrawinfo[res].textIncome[3],
		resbarDrawinfo[res].textIncome[4],
		resbarDrawinfo[res].textIncome[5]
	)
	font2:End()
end

local function drawResbarStorage(res)
	if showingWarning[res] then
		return
	end
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 1)
	if res == "metal" then
		font2:SetTextColor(0.55, 0.55, 0.55, 1)
	else
		font2:SetTextColor(0.57, 0.57, 0.45, 1)
	end
	font2:Print(
		cache.lastStorageText[res],
		resbarDrawinfo[res].textStorage[2],
		resbarDrawinfo[res].textStorage[3],
		resbarDrawinfo[res].textStorage[4],
		resbarDrawinfo[res].textStorage[5]
	)
	font2:End()
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
		dlist.resbar[res][4] = glCreateList(function()
			if res == "metal" then
				local skew = cfg.useSkew and { blx = (resbarArea[res][4] - resbarArea[res][2]) * skewTan } or nil
				WG.FlowUI.Draw.RectRoundQuad(
					resbarArea[res][1] + bgpadding,
					resbarArea[res][2] + bgpadding,
					resbarArea[res][3] - bgpadding,
					resbarArea[res][4],
					bgpadding * 1.25,
					0,
					0,
					1,
					1,
					nil,
					nil,
					skew
				)
				WG.FlowUI.Draw.RectRoundQuad(
					resbarArea[res][1],
					resbarArea[res][2],
					resbarArea[res][3],
					resbarArea[res][4],
					5.5 * widgetScale,
					0,
					0,
					1,
					1,
					nil,
					nil,
					skew
				)
			else
				local skew = cfg.useSkew and { brx = -((resbarArea[res][4] - resbarArea[res][2]) * skewTan) } or nil
				WG.FlowUI.Draw.RectRoundQuad(
					resbarArea[res][1] + bgpadding,
					resbarArea[res][2] + bgpadding,
					resbarArea[res][3] - bgpadding,
					resbarArea[res][4],
					bgpadding * 1.25,
					0,
					0,
					1,
					1,
					nil,
					nil,
					skew
				)
				WG.FlowUI.Draw.RectRoundQuad(
					resbarArea[res][1],
					resbarArea[res][2],
					resbarArea[res][3],
					resbarArea[res][4],
					5.5 * widgetScale,
					0,
					0,
					1,
					1,
					nil,
					nil,
					skew
				)
			end
		end)
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

	if cache.lastPullIncomeText[res] ~= short(r[res][3]) .. " " .. short(r[res][4]) then
		cache.lastPullIncomeText[res] = short(r[res][3]) .. " " .. short(r[res][4])
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

local function drawResbarValue(res)
	local value = short(smoothedResources[res][1])
	cache.lastDrawnValue[res] = value
	cache.lastResbarValueWidth[res] = font2:GetTextWidth(value) * resbarDrawinfo[res].textCurrent[4]
	font2:Begin(true)
	if res == "metal" then
		font2:SetTextColor(0.95, 0.95, 0.95, 1)
	else
		font2:SetTextColor(1, 1, 0.74, 1)
	end
	font2:SetOutlineColor(0, 0, 0, 1)
	font2:Print(
		value,
		resbarDrawinfo[res].textCurrent[2],
		resbarDrawinfo[res].textCurrent[3],
		resbarDrawinfo[res].textCurrent[4],
		resbarDrawinfo[res].textCurrent[5]
	)
	font2:End()
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

	local area = resbarArea[res]

	if dlist.resbar[res][1] then
		glDeleteList(dlist.resbar[res][1])
		glDeleteList(dlist.resbar[res][2])
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

	dlist.resbar[res][2] = glCreateList(function()
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

			UiSliderKnob(
				mathFloor(conversionIndicatorArea[1] + ((conversionIndicatorArea[3] - conversionIndicatorArea[1]) / 2)),
				mathFloor(conversionIndicatorArea[2] + ((conversionIndicatorArea[4] - conversionIndicatorArea[2]) / 2)),
				mathFloor((conversionIndicatorArea[3] - conversionIndicatorArea[1]) / 2),
				{ 0.95, 0.95, 0.7, 1 }
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

			UiSliderKnob(
				mathFloor(shareIndicatorArea[res][1] + ((shareIndicatorArea[res][3] - shareIndicatorArea[res][1]) / 2)),
				mathFloor(shareIndicatorArea[res][2] + ((shareIndicatorArea[res][4] - shareIndicatorArea[res][2]) / 2)),
				mathFloor((shareIndicatorArea[res][3] - shareIndicatorArea[res][1]) / 2),
				{ 0.85, 0, 0, 1 }
			)
		end
	end)

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
		local barSize = barHeight * 0.2
		local valueWidth = mathFloor(fillRatio(cappedCurRes, maxStorageRes) * barWidth)
		if valueWidth < mathCeil(barSize) then
			valueWidth = mathCeil(barSize)
		end
		if valueWidth ~= cache.lastValueWidth[res] then -- only recalc if the width changed
			cache.lastValueWidth[res] = valueWidth

			-- resbar
			if dlist.resValuesBar[res] then
				glDeleteList(dlist.resValuesBar[res])
			end
			dlist.resValuesBar[res] = glCreateList(function()
				local glowSize = barHeight * 7
				local color1, color2, glowAlpha

				if res == "metal" then
					color1 = { 0.51, 0.51, 0.5, 1 }
					color2 = { 0.95, 0.95, 0.95, 1 }
					glowAlpha = 0.025 + (0.05 * mathMin(1, fillRatio(cappedCurRes, r[res][2]) * 40))
				else
					color1 = { 0.5, 0.45, 0, 1 }
					color2 = { 0.8, 0.75, 0, 1 }
					glowAlpha = 0.035 + (0.07 * mathMin(1, fillRatio(cappedCurRes, r[res][2]) * 40))
				end

				RectRound(
					resbarDrawinfo[res].barTexRect[1],
					resbarDrawinfo[res].barTexRect[2],
					resbarDrawinfo[res].barTexRect[1] + valueWidth,
					resbarDrawinfo[res].barTexRect[4],
					barSize,
					1,
					1,
					1,
					1,
					color1,
					color2
				)
				local borderSize = 1
				RectRound(
					resbarDrawinfo[res].barTexRect[1] + borderSize,
					resbarDrawinfo[res].barTexRect[2] + borderSize,
					resbarDrawinfo[res].barTexRect[1] + valueWidth - borderSize,
					resbarDrawinfo[res].barTexRect[4] - borderSize,
					barSize,
					1,
					1,
					1,
					1,
					{ 0, 0, 0, 0.1 },
					{ 0, 0, 0, 0.17 }
				)

				-- Bar value glow (recalculate glow rects dynamically based on current bar fill)
				local barLeft = resbarDrawinfo[res].barArea[1]
				local barTop = resbarDrawinfo[res].barArea[2]
				local barBottom = resbarDrawinfo[res].barArea[4]
				local currentGlowRight = barLeft + valueWidth

				glBlending(GL.SRC_ALPHA, GL.ONE)
				glColor(
					resbarDrawinfo[res].barColor[1],
					resbarDrawinfo[res].barColor[2],
					resbarDrawinfo[res].barColor[3],
					glowAlpha
				)
				glTexture(textures.barGlowCenter)
				-- Middle glow follows the filled portion
				DrawRect(barLeft, barTop - glowSize, currentGlowRight, barBottom + glowSize, 0.008)
				glTexture(textures.barGlowEdge)
				-- Left edge glow
				DrawRect(barLeft - (glowSize * 2.5), barTop - glowSize, barLeft, barBottom + glowSize, 0.008)
				-- Right edge glow follows the filled portion
				DrawRect(
					currentGlowRight + (glowSize * 3),
					barTop - glowSize,
					currentGlowRight,
					barBottom + glowSize,
					0.008
				)
				glTexture(false)

				if res == "metal" then
					glTexture(textures.noiseBackground)
					glColor(1, 1, 1, 0.37)
					TexturedRectRound(
						resbarDrawinfo[res].barTexRect[1],
						resbarDrawinfo[res].barTexRect[2],
						resbarDrawinfo[res].barTexRect[1] + valueWidth,
						resbarDrawinfo[res].barTexRect[4],
						barSize,
						1,
						1,
						1,
						1,
						barWidth * 0.33,
						0
					)
					glTexture(false)
				end

				glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
			end)

			-- energy glow effect: static geometry lists (texture offset baked at 0); the
			-- slow texture scroll is applied per-frame via the texture matrix in
			-- drawResBars, so the lists no longer get rebuilt at the 20Hz update rate
			if res == "energy" then
				local glow = dlist.energyGlow
				if glow then
					glDeleteList(glow[1])
					glDeleteList(glow[2])
					glDeleteList(glow[3])
					glDeleteList(glow[4])
				end
				local gx1 = resbarDrawinfo[res].barTexRect[1]
				local gy1 = resbarDrawinfo[res].barTexRect[2]
				local gx2 = gx1 + valueWidth
				local gy2 = resbarDrawinfo[res].barTexRect[4]
				glow = {}
				glow[1] = glCreateList(function()
					glColor(1, 1, 1, 0.33)
					glBlending(GL.SRC_ALPHA, GL.ONE)
					glTexture(textures.energyGlow)
					TexturedRectRound(gx1, gy1, gx2, gy2, barSize, 0, 0, 1, 1, barWidth / 0.5, 0)
				end)
				glow[2] = glCreateList(function()
					TexturedRectRound(gx1, gy1, gx2, gy2, barSize, 0, 0, 1, 1, barWidth / 0.33, 0)
				end)
				glow[3] = glCreateList(function()
					TexturedRectRound(gx1, gy1, gx2, gy2, barSize, 0, 0, 1, 1, barWidth / 0.45, 0)
				end)
				-- colorize a bit more (with added size)
				local addedSize = mathFloor((barHeight * 0.15) + 0.5)
				glow[4] = glCreateList(function()
					glTexture(false)
					glColor(1, 1, 0, 0.14)
					RectRound(gx1 - addedSize, gy1 - addedSize, gx2 + addedSize, gy2 + addedSize, barHeight * 0.33)
					glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
				end)
				dlist.energyGlow = glow
			end
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

bpUi.col = {
	usedLo = { 0.2, 0.65, 0, 1 },
	usedHi = { 0.5, 0.75, 0, 1 },
	shadeLo = { 0, 0, 0, 0.1 },
	shadeHi = { 0, 0, 0, 0.17 },
	reservedLo = { 0.1, 0.55, 0, 0.5 },
	reservedHi = { 0.3, 0.65, 0, 0.5 },
	metalLo = { 0.6, 0.6, 0.6, 1 },
	metalHi = { 1, 1, 1, 1 },
	metalStaleLo = { 0.4, 0.4, 0.4, 0.55 },
	metalStaleHi = { 0.6, 0.6, 0.6, 0.55 },
	energyLo = { 0.8, 0.8, 0, 1 },
	energyHi = { 1, 1, 0.2, 1 },
	energyStaleLo = { 0.45, 0.45, 0.2, 0.55 },
	energyStaleHi = { 0.6, 0.6, 0.3, 0.55 },
	windLo = { 0.8, 0.8, 0, 1 },
	windHi = { 0.4, 0.4, 0, 1 },
	pctRed = { 0.82, 0.39, 0.39 },
	pctOrange = { 1, 0.6, 0.2 },
	pctYellow = { 1, 1, 0.39 },
	pctGreen = { 0.47, 0.92, 0.47 },
	outer = { 1, 1, 1, 0.15 },
	outerInner = { 1, 1, 1, 0 },
}
-- alert boxes under the BP section, right to left in this order
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

-- from init: splits the stock metal + energy span into metal | BP | energy; returns the metal/energy width
function bpUi.layout(width)
	if not bp.cfg.enabled then
		resbarArea.BP = {} -- every BP code path checks resbarArea.BP[1]
		bpUi.clearLists()
		return width
	end
	local margin = widgetSpaceMargin
	local span = 2 * width + margin -- stock metal..energy footprint, never changes
	local bpW = mathFloor(2 * width * bp.cfg.widthFraction)
	local meW = mathFloor((span - 2 * margin - bpW) / 2)
	bpW = span - 2 * margin - 2 * meW -- rounding remainder goes to BP
	local x = topbarArea[1] + meW + margin
	resbarArea.BP = { x, topbarArea[2], x + bpW, topbarArea[4] }
	updateResbar("BP")
	return meW
end

function bpUi.clearLists()
	local l = dlist.resbar.BP
	for n, _ in pairs(l) do
		l[n] = glDeleteList(l[n])
	end
	if dlist.resValuesBar.BP then
		dlist.resValuesBar.BP = glDeleteList(dlist.resValuesBar.BP)
	end
	bpUi.textScissor = nil -- an empty BP scissor must never reach RenderToTexture
	bpUi.pct = nil
	bpUi.alertMask, bpUi.alertsShown, bpUi.alertSince = 0, false, nil
	if WG.tooltip then
		WG.tooltip.RemoveTooltip("BP_bar")
	end
	bpUi.lastTooltip = nil
end

-- geometry, static frame list and tint shape (design section 2.3); via updateResbar("BP") from init
function bpUi.updateBar()
	local a = resbarArea.BP
	if not a[1] then
		return
	end
	local di = resbarDrawinfo.BP
	local ws = widgetScale
	local H = a[4] - a[2]
	local barH = mathFloor((height * ws / 7) + 0.5)
	local barPadY = mathFloor(((height / 4.4) * ws) + 0.5)
	local padX = mathFloor(12 * ws)
	local barArea = { a[1] + padX, a[2] + barPadY, a[3] - padX, a[2] + barPadY + barH }
	di.barArea = barArea

	-- percent text, centred right of the optional icon; the icon is dropped when it would reach into the text clear rect
	local iconS = mathFloor((height / 3.2) * ws)
	local textSize = (height / 2.5) * ws
	local pctMaxW = font2:GetTextWidth("100%") * textSize
	local iconShown = bp.cfg.icon
	local cx, sx, sw
	for _ = 1, 2 do
		cx = (barArea[1] + (iconShown and iconS + 2 or 0) + barArea[3]) / 2
		sx = mathMax(a[1], cx - pctMaxW / 2 - 2)
		sw = mathMin(a[3], cx + pctMaxW / 2 + 2) - sx
		if iconShown and barArea[1] + iconS >= sx then
			iconShown = false
		else
			break
		end
	end
	di.iconShown = iconShown
	di.iconRect = { barArea[1], a[4] - bgpadding - iconS, barArea[1] + iconS, a[4] - bgpadding }
	di.textPct = { cx, barArea[2] + barH * 1.8, textSize, "ocd" }
	bpUi.textScissor = { sx - topbarArea[1], H * 0.48, sw, H } -- texture coordinates of uiTex; keep static BP content out of it

	local l = dlist.resbar.BP
	if l[1] then
		glDeleteList(l[1])
	end
	l[1] = glCreateList(bpUi.drawFrame)
	if l[4] then
		glDeleteList(l[4])
	end
	l[4] = glCreateList(bpUi.drawTint)
	if l[7] then -- alert boxes depend on the geometry: rebuilt by the next slowUpdate
		l[7] = glDeleteList(l[7])
	end
	bpUi.alertMask = 0
	bpUi.forceRebuild = true
	bpUi.textDirty = true
	bpUi.lastTooltip = nil -- the area table is new: register it again
	bpUi.updateTooltip()
end

function bpUi.drawFrame()
	local di = resbarDrawinfo.BP
	local barArea = di.barArea
	local barHeight = barArea[4] - barArea[2]
	local barWidth = barArea[3] - barArea[1]
	local edgeWidth = mathMax(1, mathFloor(vsy / 1100))
	glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

	if di.iconShown then
		local ir = di.iconRect
		local texSize = mathFloor((ir[3] - ir[1]) * 2)
		glColor(0.75, 0.9, 0.75, 1)
		glTexture(":lr" .. texSize .. "," .. texSize .. ":LuaUI/Images/groupicons/builder.png")
		glTexRect(ir[1], ir[2], ir[3], ir[4])
		glTexture(false)
		glColor(1, 1, 1, 1)
	end

	-- copied from updateResbar (stock "Bar background" .. "gloss"), keep in sync; only the first rect differs:
	-- red idle background, so the part of the bar that is neither reserved nor used reads red
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
		{ 1, 0, 0, 0.22 },
		{ 1, 0, 0, 0.25 }
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
end

-- stall flash shape (drawn additively with an explicit colour, like the stock overflow tint)
function bpUi.drawTint()
	local a = resbarArea.BP
	RectRound(a[1] + bgpadding, a[2] + bgpadding, a[3] - bgpadding, a[4], bgpadding * 1.25, 0, 0, 1, 1)
	RectRound(a[1], a[2], a[3], a[4], 5.5 * widgetScale, 0, 0, 1, 1)
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

-- on the stock 0.05 s bar tick (so at most every 0.05 s): quantize to pixels, rebuild the value list only when something visible changed
function bpUi.refreshValues()
	local barArea = resbarDrawinfo.BP.barArea
	if not barArea then
		return
	end
	local L, s, cfgBP = bpUi.last, bpUi.s, bp.cfg
	local x0 = barArea[1]
	local barW = barArea[3] - x0
	local barH = barArea[4] - barArea[2]
	local minW = mathCeil(barH * 0.2)
	local has = bp.hasData

	s.used = bpUi.smooth(s.used, has and bp.usedRatio or 0)
	s.reserved = bpUi.smooth(s.reserved, has and bp.reservedRatio or 0)
	local usedW = mathMax(minW, mathFloor(s.used * barW))
	local reservedW = mathFloor(s.reserved * barW)
	if reservedW - usedW < minW then
		reservedW = -1
	end
	local mX, eX, wMinX, wMaxX = -1, -1, -1, -1
	if cfgBP.indicators and has then
		if bp.mSupportRatio then
			s.m = bpUi.smooth(s.m, bp.mSupportRatio)
			mX = mathFloor(x0 + s.m * barW + 0.5)
		end
		if bp.eSupportRatio then
			s.e = bpUi.smooth(s.e, bp.eSupportRatio)
			eX = mathFloor(x0 + s.e * barW + 0.5)
			if cfgBP.windRange and bp.numWindGenerators > 0 and bp.eSupportMinWind and bp.eSupportMaxWind then
				s.wMin = bpUi.smooth(s.wMin, bp.eSupportMinWind)
				s.wMax = bpUi.smooth(s.wMax, bp.eSupportMaxWind)
				wMinX = mathFloor(x0 + s.wMin * barW + 0.5)
				wMaxX = mathFloor(x0 + s.wMax * barW + 0.5)
			end
		end
	end
	local stallM, stallE, stale = bp.stallingMetal, bp.stallingEnergy, bp.supportStale
	local hover = hoveringTopbar == "BP" and not showingQuitscreen()

	if bpUi.forceRebuild or not dlist.resValuesBar.BP or usedW ~= L.usedW or reservedW ~= L.reservedW
		or mX ~= L.mX or eX ~= L.eX or wMinX ~= L.wMinX or wMaxX ~= L.wMaxX
		or stallM ~= L.stallM or stallE ~= L.stallE or stale ~= L.stale or hover ~= L.hover then
		bpUi.forceRebuild = false
		L.usedW, L.reservedW, L.mX, L.eX, L.wMinX, L.wMaxX = usedW, reservedW, mX, eX, wMinX, wMaxX
		L.stallM, L.stallE, L.stale, L.hover = stallM, stallE, stale, hover
		if dlist.resValuesBar.BP then
			glDeleteList(dlist.resValuesBar.BP)
		end
		dlist.resValuesBar.BP = glCreateList(bpUi.buildValueList)
	end

	-- percent text: only when the rounded percent changes
	local pct = nil
	if has then
		pct = mathFloor(bp.usedRatio * 100 + 0.5)
		if pct > 100 then
			pct = 100
		elseif pct < 0 then
			pct = 0
		end
	end
	if pct ~= bpUi.pct then
		bpUi.pct = pct
		if pct then
			local c = bpUi.col
			bpUi.pctColor = pct < 40 and c.pctRed or pct < 60 and c.pctOrange or pct < 80 and c.pctYellow or c.pctGreen
			if not bpUi.pctStrings[pct] then
				bpUi.pctStrings[pct] = pct .. "%"
			end
		end
		bpUi.textDirty = true
	end
end

-- the per-frame value list: used fill, reserved fill, wind strip, metal and energy markers
function bpUi.buildValueList()
	local barArea = resbarDrawinfo.BP.barArea
	local L, c = bpUi.last, bpUi.col
	local x0, y0, y1 = barArea[1], barArea[2], barArea[4]
	local barH = y1 - y0
	local barSize = barH * 0.2
	glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

	-- used (green)
	RectRound(x0, y0, x0 + L.usedW, y1, barSize, 1, 1, 1, 1, c.usedLo, c.usedHi)
	RectRound(x0 + 1, y0 + 1, x0 + L.usedW - 1, y1 - 1, barSize, 1, 1, 1, 1, c.shadeLo, c.shadeHi)
	-- reserved (paler green, on top of the used part)
	if L.reservedW > 0 then
		RectRound(x0, y0, x0 + L.reservedW, y1, barSize, 1, 1, 1, 1, c.reservedLo, c.reservedHi)
	end

	if L.mX < 0 and L.eX < 0 then
		return
	end
	local hoverMult = L.hover and 1.25 or 1
	local intrusion = barH * 0.4
	-- wind range strip (energy support between min and max wind), a thin band above the bar
	if L.wMinX >= 0 and L.wMaxX >= 0 then
		local halfW = 0.6 * barH * hoverMult
		local wx1, wx2 = L.wMinX, L.wMaxX
		if wx2 < wx1 then
			wx1, wx2 = wx2, wx1
		end
		RectRound(wx1 - halfW, y1 + intrusion, wx2 + halfW, y1 + barH * 0.6, barH * 0.1, 0, 0, 0, 0, c.windLo, c.windHi)
	end
	-- metal support (grey, bottom edge, pointing up)
	if L.mX >= 0 then
		local mult = (L.stallM and 1.4 or 1) * hoverMult
		local halfW = 0.6 * barH * mult
		RectRound(L.mX - halfW, y0 + intrusion - barH * mult, L.mX + halfW, y0 + intrusion, barH * 0.5 * mult,
			1, 1, 0, 0, L.stale and c.metalStaleLo or c.metalLo, L.stale and c.metalStaleHi or c.metalHi)
	end
	-- energy support (yellow, top edge, pointing down)
	if L.eX >= 0 then
		local mult = (L.stallE and 1.4 or 1) * hoverMult
		local halfW = 0.6 * barH * mult
		RectRound(L.eX - halfW, y1 - intrusion, L.eX + halfW, y1 - intrusion + barH * mult, barH * 0.5 * mult,
			0, 0, 1, 1, L.stale and c.energyStaleLo or c.energyLo, L.stale and c.energyStaleHi or c.energyHi)
	end
end

-- percent text, inside the stock renderResbarText (uiTex render-to-texture transform)
function bpUi.drawText()
	if not bpUi.textDirty then
		return
	end
	bpUi.textDirty = false
	local t = resbarDrawinfo.BP.textPct
	local pct = bpUi.pct
	if not t or not pct or not resbarArea.BP[1] then
		return -- the scissor clear already removed the old text
	end
	local c = bpUi.pctColor
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 1)
	font2:SetTextColor(c[1], c[2], c[3], 1)
	font2:Print(bpUi.pctStrings[pct], t[1], t[2], t[3], t[4])
	font2:End()
end

-- every frame from drawResBars (behind showResourceBars)
function bpUi.drawBars(update)
	if not resbarArea.BP[1] or not dlist.resbar.BP[1] then
		return
	end
	if update then
		bpUi.refreshValues()
		-- narrower metal/energy bars: the stock clear rectangles of the current value and the
		-- storage text overlap, so whenever one of them is re-rendered the other must be too
		for i = 1, 2 do
			local u = updateRes[resourceNames[i]]
			if u[1] or u[3] then
				u[1], u[3] = true, true
			end
		end
	end
	if (bp.stallingMetal or bp.stallingEnergy) and not spec and gameFrame > cfg.spawnWarpInFrame and dlist.resbar.BP[4] then
		glBlending(GL.SRC_ALPHA, GL.ONE)
		if bp.stallingMetal then
			glColor(1, 0.3, 0.3, 0.1 * blinkProgress)
		else
			glColor(1, 0.75, 0.2, 0.1 * blinkProgress)
		end
		glCallList(dlist.resbar.BP[4]) -- stall flash
		glBlending(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
	end
	if dlist.resValuesBar.BP then
		glCallList(dlist.resValuesBar.BP)
	end
	if bpUi.alertsShown and dlist.resbar.BP[7] then
		glCallList(dlist.resbar.BP[7])
	end
end

-- alert boxes under the BP section, styled like the stock overflow banner
function bpUi.drawAlerts()
	local a = resbarArea.BP
	if not a[1] then
		return
	end
	local ws = widgetScale
	local fs = (orgHeight * (1 + (ui_scale - 1) / 1.33) / 4) * ws
	local bannerH = 15.5 * ws
	local pad = 2.2 * ws
	local x, top = a[3], a[2]
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
			if mask ~= bpUi.alertMask or not dlist.resbar.BP[7] then
				bpUi.alertMask = mask
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
	if bpUi.warned or not bpUi.ownGetPosition or not WG.topbar then
		return
	end
	if WG.topbar.GetPosition ~= bpUi.ownGetPosition then
		bpUi.warn()
	end
end

-- from Initialize, before our WG.topbar functions are assigned
function bpUi.checkStartConflict()
	local order = widgetHandler and widgetHandler.orderList and widgetHandler.orderList["Top Bar"]
	if (type(order) == "number" and order > 0)
		or (WG.topbar and WG.topbar.getResourceBarsVisible and WG.topbar.getResourceBarsVisible()) then
		bpUi.warn()
	end
end

function bpUi.warn()
	if not bpUi.warned then
		bpUi.warned = true
		Spring.Echo("Top Bar with Buildpower: the stock \"Top Bar\" widget is enabled too. Disable it in the widget list (F11), both bars draw at the same place.")
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
		.. hc .. reservedPct .. "%" .. tc .. " is assigned to tasks or moving to jobs (dark green bar).\n"
		.. hc .. usedPct .. "%" .. tc .. " is currently active and being used (green bar). This is the number shown.\n"
		.. hc .. idlePct .. "%" .. tc .. " is idle with no BP tasks (red part)."
	if bp.cfg.indicators and bp.mSupportRatio and bp.eSupportRatio then
		text = text .. "\n\nThe grey and yellow indicators show you that, if all BP were fully engaged:\n"
			.. "Metal income would support " .. hc .. mathCeil(bp.mSupportRatio * 100) .. "%" .. tc .. " of BP.\n"
			.. "Energy income would support " .. hc .. mathCeil(bp.eSupportRatio * 100) .. "%" .. tc .. " of BP."
		if bp.cfg.windRange and bp.numWindGenerators > 0 and bp.eSupportMinWind and bp.eSupportMaxWind then
			text = text .. "\nDepending on the wind, energy would support " .. hc .. mathCeil(bp.eSupportMinWind * 100) .. "%"
				.. tc .. " to " .. hc .. mathCeil(bp.eSupportMaxWind * 100) .. "%" .. tc .. " (thin yellow strip)."
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
	if not WG.tooltip or not resbarArea.BP[1] or not showResourceBars then
		return
	end
	local text = bpUi.tooltipText()
	if text ~= bpUi.lastTooltip then -- the tooltip widget drops its cached list on every call with a text
		bpUi.lastTooltip = text
		WG.tooltip.AddTooltip("BP_bar", resbarArea.BP, text, nil, "Buildpower")
	end
end

-- options (registered through WG.options in one call; values persisted by GetConfigData)
bpUi.optionSpecs = {
	{ key = "enabled", type = "bool", relayout = true, name = "Buildpower bar",
		description = "Show the buildpower bar between metal and energy" },
	{ key = "widthFraction", type = "slider", min = 0.10, max = 0.25, step = 0.01, relayout = true,
		name = "Buildpower bar width", description = "Share of the metal and energy width given to the buildpower bar" },
	{ key = "indicators", type = "bool", name = "Eco support indicators",
		description = "Estimate how much buildpower is supported by your metal and energy income" },
	{ key = "windRange", type = "bool", name = "Wind range indicator",
		description = "Show how energy-supported buildpower might vary with wind speed" },
	{ key = "alerts", type = "bool", name = "Buildpower alerts",
		description = "Need metal / Need energy / Idle buildpower / Need buildpower / Too much buildpower" },
	{ key = "icon", type = "bool", relayout = true, name = "Buildpower icon",
		description = "Small builder icon in the buildpower bar" },
	{ key = "debugTooltip", type = "bool", name = "Buildpower debug data",
		description = "Show debug data in the tooltip of the buildpower bar" },
}

function bpUi.addOptions()
	if not WG.options or not (WG.options.addOptions or WG.options.addOption) then
		return
	end
	local list, ids = {}, {}
	local widgetName = widget:GetInfo().name
	for i, spec_ in ipairs(bpUi.optionSpecs) do
		local key, relayout = spec_.key, spec_.relayout
		ids[i] = "top_bar_bp_" .. key
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
	bp.cfg.widthFraction = mathMin(0.25, mathMax(0.10, bp.cfg.widthFraction))
	bpUi.addOptions()
	WG.buildpower = { GetData = bpUi.getData, version = 1 }
end

-- from Shutdown
function bpUi.shutdown()
	bpUi.clearLists()
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

	-- metal
	local width = mathFloor(totalWidth / 4.4)
	local meW = bpUi.layout(width) -- BP: metal/energy width; places the BP section in the stock metal+energy span
	resbarArea.metal =
		{ topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
	resbarArea.metal[3] = resbarArea.metal[1] + meW -- BP: metal keeps its left edge, BP follows
	filledWidth = filledWidth + width + widgetSpaceMargin
	updateResbar("metal")

	--energy
	resbarArea.energy =
		{ topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
	resbarArea.energy[1] = resbarArea.energy[3] - meW -- BP: energy keeps its right edge
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
	if resbarArea.BP[1] and mathIsInRect(x, y, resbarArea.BP[1], resbarArea.BP[2], resbarArea.BP[3], resbarArea.BP[4]) then -- BP
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
		if mx > topbarArea[1] and my > topbarArea[2] then -- checking if the cursor is high enough, too
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
		currentWindText = "\255\255\255\255" .. currentWind

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
	bpUi.drawText() -- BP
end

local function drawResBars()
	if not showResourceBars then
		return
	end

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
		local scissors = {}
		res = "metal"
		if updateRes[res][1] then
			scissors[#scissors + 1] = {
				(resbarDrawinfo[res].textCurrent[2] - topbarArea[1]) - (cache.lastResbarValueWidth[res] * 0.75),
				(topbarArea[4] - topbarArea[2]) * 0.48,
				resbarDrawinfo[res].textCurrent[4] + cache.lastResbarValueWidth[res],
				topbarArea[4] - topbarArea[2],
			}
		end
		if updateRes[res][2] then
			scissors[#scissors + 1] = {
				(resbarDrawinfo[res].textPull[2] - topbarArea[1]) - (resbarDrawinfo[res].textPull[4] * 3.4),
				0,
				resbarDrawinfo[res].textPull[4] * 3.5,
				topbarArea[4] - topbarArea[2],
			}
		end
		if updateRes[res][3] then
			scissors[#scissors + 1] = {
				(resbarDrawinfo[res].textStorage[2] - topbarArea[1]) - (resbarDrawinfo[res].textStorage[4] * 4),
				(topbarArea[4] - topbarArea[2]) * 0.48,
				resbarDrawinfo[res].textStorage[4] * 4.1,
				topbarArea[4] - topbarArea[2],
			}
		end
		res = "energy"
		if updateRes[res][1] then
			scissors[#scissors + 1] = {
				(resbarDrawinfo[res].textCurrent[2] - topbarArea[1]) - (cache.lastResbarValueWidth[res] * 0.75),
				(topbarArea[4] - topbarArea[2]) * 0.48,
				resbarDrawinfo[res].textCurrent[4] + cache.lastResbarValueWidth[res],
				topbarArea[4] - topbarArea[2],
			}
		end
		if updateRes[res][2] then
			scissors[#scissors + 1] = {
				(resbarDrawinfo[res].textPull[2] - topbarArea[1]) - (resbarDrawinfo[res].textPull[4] * 3.4),
				0,
				resbarDrawinfo[res].textPull[4] * 3.5,
				topbarArea[4] - topbarArea[2],
			}
		end
		if updateRes[res][3] then
			scissors[#scissors + 1] = {
				(resbarDrawinfo[res].textStorage[2] - topbarArea[1]) - (resbarDrawinfo[res].textStorage[4] * 4),
				(topbarArea[4] - topbarArea[2]) * 0.48,
				resbarDrawinfo[res].textStorage[4] * 4.1,
				topbarArea[4] - topbarArea[2],
			}
		end
		if bpUi.textDirty and bpUi.textScissor then -- BP
			scissors[#scissors + 1] = bpUi.textScissor
		end

		-- skip the whole FBO roundtrip when no text region actually changed
		-- (an empty scissors list would clear the entire texture!)
		if scissors[1] then
			r2tHelper.RenderToTexture(uiTex, renderResbarText, true, scissors)
		end
	end
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
		if resbarArea.BP[1] then -- BP: plain rectangle, both edges face the vertical inner edges of metal and energy
			UiElement(resbarArea.BP[1], resbarArea.BP[2], resbarArea.BP[3], resbarArea.BP[4], 0, 0, 1, 1)
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
		if dlist.resbar.BP[1] then -- BP
			glCallList(dlist.resbar.BP[1])
		end
	end

	-- min and max wind (rendered per-frame via renderWindText; nowind fallback below)
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

	-- tidal speed
	if cache.showIndicators and displayTidalSpeed then
		local fontSize = (tidalarea[4] - tidalarea[2]) / 2.3
		local skewCenterOffset = cfg.useSkew and (tidalarea[4] - tidalarea[2]) * skewTan * 0.5 or 0
		font2:Begin(true)
		font2:Print(
			tidalSpeedText,
			tidalarea[1] + ((tidalarea[3] - tidalarea[1]) / 2) - skewCenterOffset,
			tidalarea[2] + ((tidalarea[4] - tidalarea[2]) / 2.05) - (fontSize / 5),
			fontSize,
			"oc"
		) -- Tidal speed text
		font2:End()
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
	bpUi.textDirty = true -- BP
end

local function renderWindText()
	glTranslate(-1, -1, 0)
	glScale(2 / (topbarArea[3] - topbarArea[1]), 2 / (topbarArea[4] - topbarArea[2]), 0)
	glTranslate(-topbarArea[1], -topbarArea[2], 0)

	local windH = windArea[4] - windArea[2]
	local fontSize = windH / 2.3
	local skewCenterOffset = cfg.useSkew and windH * skewTan * 0.5 or 0
	font2:Begin(true)
	font2:SetOutlineColor(0, 0, 0, 1)
	-- current wind (large, centered) - only once game has started
	if gameFrame > 0 then
		font2:Print(
			currentWindText,
			windArea[1] + ((windArea[3] - windArea[1]) / 2.1) - skewCenterOffset,
			windArea[2] + (windH / 1.85) - (fontSize / 5),
			fontSize,
			"oc"
		)
	end
	-- min wind: top area, x corrected for slope at text height
	local smallFS = windH / 3.4
	local minBaseline = windArea[4] - smallFS + (1 * widgetScale)
	local minWindX = windArea[3] - (cfg.useSkew and skewTan * (windArea[4] - minBaseline) or 0) - (4.5 * widgetScale)
	font2:Print(minWindText, minWindX, minBaseline, smallFS, "or")
	-- max wind: bottom-right corner
	local brWindX = windArea[3] - (cfg.useSkew and windH * skewTan or 0)
	font2:Print(maxWindText, brWindX - (1.2 * widgetScale), windArea[2] + (4.5 * widgetScale), smallFS, "or")
	font2:End()
end

local function renderComCounter()
	glTranslate(-1, -1, 0)
	glScale(2 / (topbarArea[3] - topbarArea[1]), 2 / (topbarArea[4] - topbarArea[2]), 0)
	glTranslate(-topbarArea[1], -topbarArea[2], 0)

	if allyComs == 1 and (gameFrame % 12 < 6) then
		glColor(1, 0.6, 0, 0.45)
	else
		glColor(1, 1, 1, 0.22)
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
			WG.guishader.InsertDlist(uiBgList, "topbar_background", nil, self)
		end
	end

	if dlist.blendBg then
		glCallList(dlist.blendBg)
	end

	if cache.showIndicators and dlist.wind1 then
		glPushMatrix()
		glCallList(dlist.wind1)
		glRotate(windRotation, 0, 0, 1)
		glCallList(dlist.wind2)
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
				and resbarDrawinfo[res].textStorage
			then
				cache.warningCleared[res] = true
				scissorsCount = scissorsCount + 1
				local scissor = storageScissors[scissorsCount]
				scissor[1] = (resbarDrawinfo[res].textStorage[2] - topbarArea[1])
					- (resbarDrawinfo[res].textStorage[4] * 4)
				scissor[2] = topbarHeight * 0.48
				scissor[3] = resbarDrawinfo[res].textStorage[4] * 4.1
				scissor[4] = topbarHeight
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
			if bp.cfg[k] ~= nil and type(v) == type(bp.cfg[k]) then
				bp.cfg[k] = v
			end
		end
	end
	bp.cfg.widthFraction = math.min(0.25, math.max(0.10, bp.cfg.widthFraction))
end
