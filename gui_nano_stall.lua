local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Nano Stall Indicator",
		desc = "TA-style stall indicator: shows the share of time your nanolathes actually get resources (engine measured per builder, buildpower weighted). Top bar element plus optional labels above stalled builders.",
		author = "Robert82",
		date = "Nov 2026",
		license = "GNU GPL, v2 or later",
		layer = -1,
		enabled = true,
	}
end

--------------------------------------------------------------------------------
-- Measurement (see gui_nano_stall_poc.lua for the engine side explanation):
-- Spring.GetUnitCurrentBuildPower(unitID) is the fraction of the last 15 sim
-- frames in which the builder's AddBuildPower succeeded, i.e. exactly the
-- "nanolathe beam on-time" Total Annihilation used to show stalls. We read it
-- for every own builder that currently has a job, weight it by buildSpeed and
-- show the result in the free area of the top bar.
--
-- Chat commands:
--   /nanostall_labels   toggle percentage labels above stalled builders
--   /nanostall_element  toggle the top bar element
--------------------------------------------------------------------------------

local config = {
	showElement = true,
	showLabels = true,
	labelThreshold = 0.9, -- only label builders that are served less than this
}

local SAMPLE_EVERY_FRAMES = 3
local SMOOTH_SAMPLES = 10 -- 10 * 3 frames = 1 second
local LABEL_DIST_FULL = 900 -- elmos; labels fully visible closer than this
local LABEL_DIST_FADE = 1800 -- elmos; labels hidden beyond this
local LABEL_FONT_CLOSE = 24
local LABEL_FONT_FAR = 12

local spGetUnitCurrentBuildPower = Spring.GetUnitCurrentBuildPower
local spGetUnitWorkerTask = Spring.GetUnitWorkerTask
local spGetUnitCurrentCommand = Spring.GetUnitCurrentCommand
local spGetUnitIsStunned = Spring.GetUnitIsStunned
local spGetUnitViewPosition = Spring.GetUnitViewPosition
local spWorldToScreenCoords = Spring.WorldToScreenCoords
local spGetCameraPosition = Spring.GetCameraPosition
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spIsGUIHidden = Spring.IsGUIHidden
local spGetSpectatingState = Spring.GetSpectatingState

local glCreateList, glDeleteList, glCallList = gl.CreateList, gl.DeleteList, gl.CallList
local glColor, glPushMatrix, glPopMatrix, glTranslate = gl.Color, gl.PushMatrix, gl.PopMatrix, gl.Translate
local glRect, glText = gl.Rect, gl.Text

local CMD_WAIT = CMD.WAIT
local mathMin, mathMax, mathFloor, mathSqrt = math.min, math.max, math.floor, math.sqrt
local strFormat, strChar = string.format, string.char

local vsx, vsy = Spring.GetViewGeometry()
local myTeamID = spGetMyTeamID()
local spec = spGetSpectatingState()

-- UI helpers (filled in ViewResize from FlowUI / fonts when available)
local RectRound, RectRoundOutline, UiElement
local font, font2
local elementArea -- { x1, y1, x2, y2 } in the top bar, nil when not placed
local elementScale = 1
local skewConfig
local dlist = { background = nil, value = nil }
local guishaderActive = false
local lastAreaKey = ""
local nextLayoutCheck = 0
local nextTooltipUpdate = 0

--------------------------------------------------------------------------------
-- builder tracking

local builderSpeed, unitHeight = {}, {}
for unitDefID, unitDef in pairs(UnitDefs) do
	if unitDef.isBuilder and unitDef.buildSpeed and unitDef.buildSpeed > 0 then
		builderSpeed[unitDefID] = unitDef.buildSpeed
	end
	unitHeight[unitDefID] = unitDef.height or 20
end

local builders = {} -- unitID -> { speed, defID }
local working = {} -- unitID -> duty for builders with a job
local stats = { active = 0, buildpower = 0, served = 0, duty = 1, dutySmooth = 1 }
local history, historyIndex = {}, 0
local shownPercent = -1

local function addBuilder(unitID, unitDefID, unitTeam)
	if unitTeam == myTeamID and builderSpeed[unitDefID] then
		builders[unitID] = { speed = builderSpeed[unitDefID], defID = unitDefID }
	end
end

local function removeBuilder(unitID)
	builders[unitID] = nil
	working[unitID] = nil
end

local function rebuildBuilders()
	builders, working = {}, {}
	history, historyIndex = {}, 0
	local units = spGetTeamUnits(myTeamID)
	for i = 1, #units do
		local unitID = units[i]
		addBuilder(unitID, spGetUnitDefID(unitID), myTeamID)
	end
end

local function sample()
	local active, buildpower, served = 0, 0, 0
	for unitID, b in pairs(builders) do
		local task = spGetUnitWorkerTask(unitID) -- negative cmdID = constructing (incl. assist / factory)
		if task and task < 0 then
			local _, stunned = spGetUnitIsStunned(unitID)
			if stunned or spGetUnitCurrentCommand(unitID) == CMD_WAIT then
				working[unitID] = nil
			else
				local duty = spGetUnitCurrentBuildPower(unitID) or 0
				working[unitID] = duty
				active = active + 1
				buildpower = buildpower + b.speed
				served = served + b.speed * duty
			end
		else
			working[unitID] = nil
		end
	end
	stats.active, stats.buildpower, stats.served = active, buildpower, served
	stats.duty = (buildpower > 0) and (served / buildpower) or 1

	historyIndex = (historyIndex % SMOOTH_SAMPLES) + 1
	history[historyIndex] = stats.duty
	local sum, n = 0, 0
	for i = 1, #history do
		sum = sum + history[i]
		n = n + 1
	end
	stats.dutySmooth = (n > 0) and (sum / n) or 1
end

--------------------------------------------------------------------------------
-- colors / text helpers

local function dutyColor(duty)
	-- red (0) -> yellow (0.5) -> green (1), same ramp as the PoC
	if duty < 0.5 then
		return 1, duty * 2, 0.15
	end
	return 1 - (duty - 0.5) * 2, 1, 0.15
end

local function colorCode(r, g, b)
	return strChar(255, mathFloor(r * 254) + 1, mathFloor(g * 254) + 1, mathFloor(b * 254) + 1)
end

--------------------------------------------------------------------------------
-- top bar element

local function clearElement()
	if dlist.background then
		dlist.background = glDeleteList(dlist.background)
	end
	if dlist.value then
		dlist.value = glDeleteList(dlist.value)
	end
	if guishaderActive and WG.guishader then
		WG.guishader.RemoveDlist("nanostall")
	end
	guishaderActive = false
	if WG.tooltip then
		WG.tooltip.RemoveTooltip("nanostall")
	end
	elementArea = nil
	lastAreaKey = ""
	shownPercent = -1
end

local function updateTooltip()
	if not (WG.tooltip and elementArea) then
		return
	end
	local text
	if stats.active == 0 then
		text = "No builder is working right now."
	else
		text = strFormat(
			"Your working builders receive resources %.0f%% of the time (buildpower weighted).\n"
				.. "Working builders: %d\nDemanded buildpower: %d\nServed buildpower: %d\n\n"
				.. "Measured by the engine per builder: a nanolathe only fires in frames the team can pay for, "
				.. "like the beam flicker in Total Annihilation. 100%% = no stall.",
			stats.dutySmooth * 100,
			stats.active,
			stats.buildpower,
			stats.served
		)
	end
	WG.tooltip.AddTooltip("nanostall", elementArea, text, nil, "Nanolathe stall")
end

local function updateValueDlist()
	if not elementArea then
		return
	end
	if dlist.value then
		glDeleteList(dlist.value)
	end
	local area = elementArea
	local H = area[4] - area[2]
	local skewInset = skewConfig and (H * skewConfig.skewTan) or 0
	local cx = area[1] + ((area[3] - area[1]) / 2) - skewInset * 0.5
	local duty = stats.dutySmooth
	local idle = stats.active == 0
	local percent = idle and -1 or mathFloor(duty * 100 + 0.5)
	shownPercent = percent

	dlist.value = glCreateList(function()
		-- value bar (same proportions as the resource bars)
		local barHeight = mathMax(2, mathFloor(H / 7 + 0.5))
		local padX = mathFloor(H * 0.22)
		local x1 = area[1] + padX
		local x2 = area[3] - padX - skewInset
		local y1 = area[2] + mathFloor(H * 0.17)
		local y2 = y1 + barHeight
		local cs = barHeight * 0.33
		if RectRound then
			RectRound(x1, y1, x2, y2, cs, 1, 1, 1, 1, { 0, 0, 0, 0.15 }, { 0, 0, 0, 0.2 })
			if RectRoundOutline then
				RectRoundOutline(x1 - 1, y1 - 1, x2 + 1, y2 + 1, cs, 1, 1, 1, 1, 1, { 0, 0, 0, 0 }, { 0, 0, 0, 0.5 })
			end
			if not idle and duty > 0 then
				local r, g, b = dutyColor(duty)
				local fillX2 = x1 + mathMax(cs * 2, (x2 - x1) * duty)
				RectRound(x1, y1, fillX2, y2, cs, 1, 1, 1, 1, { r * 0.55, g * 0.55, b * 0.55, 1 }, { r, g, b, 1 })
			end
		else
			glColor(0, 0, 0, 0.35)
			glRect(x1, y1, x2, y2)
			if not idle and duty > 0 then
				glColor(dutyColor(duty))
				glRect(x1, y1, x1 + (x2 - x1) * duty, y2)
			end
			glColor(1, 1, 1, 1)
		end

		-- value text
		local text = idle and "\255\150\150\150--" or (colorCode(dutyColor(duty)) .. percent .. "%")
		local fontSize = H / 2.3
		local textY = area[2] + (H * 0.56) - (fontSize * 0.05)
		if font2 then
			font2:Begin(true)
			font2:SetOutlineColor(0, 0, 0, 1)
			font2:Print(text, cx, textY, fontSize, "oc")
			font2:End()
		else
			glText(text, cx, textY, fontSize, "oc")
		end
	end)
end

local function updateBackgroundDlist()
	if dlist.background then
		glDeleteList(dlist.background)
	end
	local area = elementArea
	local H = area[4] - area[2]
	local skew = skewConfig and { blx = -(H * skewConfig.skewTan), brx = -(H * skewConfig.skewTan) } or nil
	dlist.background = glCreateList(function()
		if UiElement then
			UiElement(area[1], area[2], area[3], area[4], 0, 0, 1, 1, nil, nil, nil, nil, nil, nil, nil, nil, nil, skew)
		else
			glColor(0, 0, 0, 0.66)
			glRect(area[1], area[2], area[3], area[4])
			glColor(1, 1, 1, 1)
		end
		-- small caption like the other top bar elements do with their icons
		local fontSize = H / 5.2
		local skewInset = skew and (H * skewConfig.skewTan) or 0
		local cx = area[1] + ((area[3] - area[1]) / 2) - skewInset * 0.5
		local text = "\255\185\185\185nano"
		if font then
			font:Begin(true)
			font:SetOutlineColor(0, 0, 0, 1)
			font:Print(text, cx, area[4] - fontSize * 1.35, fontSize, "oc")
			font:End()
		else
			glText(text, cx, area[4] - fontSize * 1.35, fontSize, "oc")
		end
	end)
	if WG.guishader then
		if guishaderActive then
			WG.guishader.RemoveDlist("nanostall")
		end
		WG.guishader.InsertDlist(dlist.background, "nanostall")
		guishaderActive = true
	end
end

-- Place the element in the free area of the top bar (works with the stock top
-- bar and with "Top Bar with Buildpower" which exposes the same WG.topbar API).
local function updateLayout()
	if not config.showElement or not (WG.topbar and WG.topbar.GetFreeArea) then
		if elementArea then
			clearElement()
		end
		return
	end
	local free = WG.topbar.GetFreeArea()
	local pos = WG.topbar.GetPosition and WG.topbar.GetPosition()
	if not (free and free[1] and pos and pos[1]) then
		if elementArea then
			clearElement()
		end
		return
	end
	elementScale = free[5] or pos[5] or 1
	skewConfig = WG.topbar.GetSkewConfig and WG.topbar.GetSkewConfig() or nil
	if skewConfig and not skewConfig.useSkew then
		skewConfig = nil
	end

	local barH = pos[4] - pos[2]
	local smallVPad = skewConfig and mathFloor(barH * (1 - (skewConfig.smallElementHeightFraction or 1))) or 0
	local width = mathFloor(barH * 1.45) -- a bit wider than the wind element to fit "100%" plus the bar
	local margin = WG.FlowUI and WG.FlowUI.elementMargin or 4
	local x1 = free[1]
	local x2 = x1 + width
	if x2 > free[3] - margin then
		-- no room left in the bar, hide the element rather than overlapping the buttons
		if elementArea then
			clearElement()
		end
		return
	end
	local area = { x1, free[2] + smallVPad, x2, free[4] }
	local key = table.concat(area, ":") .. ":" .. tostring(skewConfig and skewConfig.skewTan or 0)
	if key == lastAreaKey then
		return
	end
	lastAreaKey = key
	elementArea = area
	updateBackgroundDlist()
	updateValueDlist()
	updateTooltip()
end

--------------------------------------------------------------------------------
-- callins

function widget:ViewResize()
	vsx, vsy = Spring.GetViewGeometry()
	if WG.FlowUI and WG.FlowUI.Draw then
		RectRound = WG.FlowUI.Draw.RectRound
		RectRoundOutline = WG.FlowUI.Draw.RectRoundOutline
		UiElement = WG.FlowUI.Draw.Element
	end
	if WG.fonts and WG.fonts.getFont then
		font = WG.fonts.getFont()
		font2 = WG.fonts.getFont(2)
	end
	lastAreaKey = ""
	updateLayout()
end

function widget:Initialize()
	myTeamID = spGetMyTeamID()
	spec = spGetSpectatingState()
	rebuildBuilders()
	widget:ViewResize()
	widgetHandler:AddAction("nanostall_labels", function()
		config.showLabels = not config.showLabels
		Spring.Echo("Nano Stall Indicator: labels " .. (config.showLabels and "on" or "off"))
	end, nil, "t")
	widgetHandler:AddAction("nanostall_element", function()
		config.showElement = not config.showElement
		lastAreaKey = ""
		updateLayout()
		Spring.Echo("Nano Stall Indicator: top bar element " .. (config.showElement and "on" or "off"))
	end, nil, "t")
end

function widget:Shutdown()
	clearElement()
	widgetHandler:RemoveAction("nanostall_labels")
	widgetHandler:RemoveAction("nanostall_element")
end

function widget:GetConfigData()
	return { showElement = config.showElement, showLabels = config.showLabels, labelThreshold = config.labelThreshold }
end

function widget:SetConfigData(data)
	if type(data) ~= "table" then
		return
	end
	if data.showElement ~= nil then
		config.showElement = data.showElement
	end
	if data.showLabels ~= nil then
		config.showLabels = data.showLabels
	end
	if data.labelThreshold ~= nil then
		config.labelThreshold = data.labelThreshold
	end
end

function widget:PlayerChanged()
	local newTeam = spGetMyTeamID()
	spec = spGetSpectatingState()
	if newTeam ~= myTeamID then
		myTeamID = newTeam
		rebuildBuilders()
	end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
	addBuilder(unitID, unitDefID, unitTeam)
end
function widget:UnitGiven(unitID, unitDefID, unitTeam)
	addBuilder(unitID, unitDefID, unitTeam)
end
function widget:UnitTaken(unitID)
	removeBuilder(unitID)
end
function widget:UnitDestroyed(unitID)
	removeBuilder(unitID)
end

function widget:GameFrame(frame)
	if frame % SAMPLE_EVERY_FRAMES == 0 then
		sample()
	end
end

function widget:Update(dt)
	local now = os.clock()
	if now > nextLayoutCheck then
		nextLayoutCheck = now + 1
		updateLayout()
	end
	if not elementArea then
		return
	end
	local percent = (stats.active == 0) and -1 or mathFloor(stats.dutySmooth * 100 + 0.5)
	if percent ~= shownPercent then
		updateValueDlist()
	end
	if now > nextTooltipUpdate then
		nextTooltipUpdate = now + 1
		updateTooltip()
	end
end

function widget:DrawScreen()
	if not elementArea or spIsGUIHidden() then
		return
	end
	if WG.topbar and WG.topbar.showingQuit and WG.topbar.showingQuit() then
		return
	end
	if dlist.background then
		glCallList(dlist.background)
	end
	if dlist.value then
		glCallList(dlist.value)
	end
end

-- labels above builders that are being starved, drawn like BuildETA does it
function widget:DrawScreenEffects()
	if not config.showLabels or spIsGUIHidden() then
		return
	end
	local cx, cy, cz = spGetCameraPosition()
	local threshold = config.labelThreshold
	local started = false
	for unitID, duty in pairs(working) do
		if duty < threshold then
			local ux, uy, uz = spGetUnitViewPosition(unitID)
			if ux then
				local dx, dy, dz = ux - cx, uy - cy, uz - cz
				local dist = mathSqrt(dx * dx + dy * dy + dz * dz)
				if dist < LABEL_DIST_FADE then
					local alpha, fontSize
					if dist <= LABEL_DIST_FULL then
						alpha, fontSize = 1, LABEL_FONT_CLOSE
					else
						local t = (dist - LABEL_DIST_FULL) / (LABEL_DIST_FADE - LABEL_DIST_FULL)
						alpha = 1 - t
						fontSize = LABEL_FONT_CLOSE + t * (LABEL_FONT_FAR - LABEL_FONT_CLOSE)
					end
					local b = builders[unitID]
					local sx, sy = spWorldToScreenCoords(ux, uy + unitHeight[b.defID] + 14, uz)
					if sx and sx > -100 and sx < vsx + 100 and sy > -50 and sy < vsy + 50 then
						local text = colorCode(dutyColor(duty)) .. strFormat("%.0f%%", duty * 100)
						if font then
							if not started then
								font:Begin()
								started = true
							end
							font:SetTextColor(1, 1, 1, alpha)
							font:Print(text, sx, sy, fontSize, "oc")
						else
							glColor(1, 1, 1, alpha)
							glText(text, sx, sy, fontSize, "oc")
						end
					end
				end
			end
		end
	end
	if started then
		font:End()
	end
	glColor(1, 1, 1, 1)
end
