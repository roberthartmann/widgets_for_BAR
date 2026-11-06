local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Nano Stall PoC",
		desc = "Proof of concept: shows the TA-style nanolathe duty cycle (share of time a builder actually gets resources) using Spring.GetUnitCurrentBuildPower",
		author = "Robert82",
		date = "Nov 2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = false,
	}
end

--------------------------------------------------------------------------------
-- What this PoC demonstrates
--
-- In Total Annihilation a stalled builder's nanolathe beam was simply switched
-- off for the frames in which the builder got no resources: at a 90% stall the
-- beam was visible 10% of the time. That duty cycle *is* the stall ratio.
--
-- Recoil (the BAR engine) still works exactly like that at the simulation level:
--
--   CBuilder::UpdateBuild  -> curBuildee->AddBuildPower(this, buildSpeed)
--                             returns false when the team cannot pay this
--                             frame's resource step (CTeam::HaveResources)
--                          -> CreateNanoParticle() is ONLY called on success
--   NanoPieceCache         -> every successful frame sets a bit in a 15 bit
--                             mask, the mask is shifted once per frame
--   GetBuildPower()        -> popcount(mask) / 15  = fraction of the last half
--                             second in which the beam was "on"
--   Spring.GetUnitCurrentBuildPower(unitID) exposes exactly that number to Lua
--   (it works for mobile builders, nano turrets and factories).
--
-- So the "beam on-time" is already measured by the engine, per builder, and a
-- widget only has to read and aggregate it. Nothing needs to be derived from
-- income/pull estimates.
--
-- This file keeps it as small as possible: track my builders, poll the value a
-- few times per second, print a summary on screen and a percentage above every
-- builder that is currently working. gui_nano_stall.lua is the "proper" widget
-- that uses the same measurement with BAR's UI conventions.
--------------------------------------------------------------------------------

local SAMPLE_EVERY_FRAMES = 3 -- engine mask covers 15 frames, sampling every 3 is plenty
local SMOOTH_SAMPLES = 10 -- 10 samples * 3 frames = 1 second display smoothing
local ECHO_EVERY_FRAMES = 0 -- set to e.g. 60 to also log the numbers to the console (/nanostall_poc_echo toggles 60)
local SHOW_UNIT_LABELS = true -- percentage above each working builder (/nanostall_poc_labels)
local LABEL_MAX_DIST = 2500 -- elmos from camera; beyond this no per-unit labels

local spGetUnitCurrentBuildPower = Spring.GetUnitCurrentBuildPower
local spGetUnitWorkerTask = Spring.GetUnitWorkerTask
local spGetUnitCurrentCommand = Spring.GetUnitCurrentCommand
local spGetUnitIsStunned = Spring.GetUnitIsStunned
local spGetUnitViewPosition = Spring.GetUnitViewPosition
local spWorldToScreenCoords = Spring.WorldToScreenCoords
local spGetCameraPosition = Spring.GetCameraPosition
local spGetTeamResources = Spring.GetTeamResources
local spGetMyTeamID = Spring.GetMyTeamID
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitDefID = Spring.GetUnitDefID
local spIsGUIHidden = Spring.IsGUIHidden
local spEcho = Spring.Echo

local CMD_WAIT = CMD.WAIT
local mathMin, mathMax, mathFloor, mathSqrt = math.min, math.max, math.floor, math.sqrt
local strFormat = string.format

local myTeamID = spGetMyTeamID()
local vsx, vsy = Spring.GetViewGeometry()

-- unitDefID -> buildSpeed for everything that can nanolathe (builders, nano turrets, factories)
local builderSpeed = {}
for unitDefID, unitDef in pairs(UnitDefs) do
	if unitDef.isBuilder and unitDef.buildSpeed and unitDef.buildSpeed > 0 then
		builderSpeed[unitDefID] = unitDef.buildSpeed
	end
end
local unitHeight = {}
for unitDefID, unitDef in pairs(UnitDefs) do
	unitHeight[unitDefID] = unitDef.height or 20
end

local builders = {} -- unitID -> { speed = buildSpeed, defID = unitDefID }
local working = {} -- unitID -> duty (0..1) for builders that currently have a job
local stats = {
	active = 0, -- builders with a job
	buildpower = 0, -- their summed buildSpeed
	served = 0, -- buildSpeed-weighted sum of duty cycles
	duty = 1, -- served / buildpower (instant, half-second engine window)
	dutySmooth = 1, -- 1 second rolling average of duty
	meanDuty = 1, -- unweighted mean of per-unit duty
	ecoEstimate = 1, -- what a resource based estimate (income/pull) would say
}
local history, historyIndex = {}, 0

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
	local units = spGetTeamUnits(myTeamID)
	for i = 1, #units do
		local unitID = units[i]
		addBuilder(unitID, spGetUnitDefID(unitID), myTeamID)
	end
end

-- resource based estimate for comparison: with empty storage the share of pull
-- that income can cover; with storage left there is no stall
local function ecoEstimate(res)
	local cur, _, pull, income = spGetTeamResources(myTeamID, res)
	if not cur then
		return 1
	end
	if cur > 1 or pull <= 0 then
		return 1
	end
	return mathMin(1, income / pull)
end

local function sample()
	local active, buildpower, served, dutySum = 0, 0, 0, 0
	for unitID, b in pairs(builders) do
		-- nil while idle / walking to the job; negative = constructing a unit (also assist and
		-- factory production). Reclaim, repair, capture and terraform do not pay per frame, so
		-- they cannot stall and are left out of the ratio.
		local task = spGetUnitWorkerTask(unitID)
		if task and task < 0 then
			local _, stunned = spGetUnitIsStunned(unitID)
			local cmdID = spGetUnitCurrentCommand(unitID)
			if stunned or cmdID == CMD_WAIT then
				working[unitID] = nil -- not asking for resources at all, not a stall
			else
				local duty = spGetUnitCurrentBuildPower(unitID) or 0
				working[unitID] = duty
				active = active + 1
				buildpower = buildpower + b.speed
				served = served + b.speed * duty
				dutySum = dutySum + duty
			end
		else
			working[unitID] = nil
		end
	end
	stats.active = active
	stats.buildpower = buildpower
	stats.served = served
	stats.duty = (buildpower > 0) and (served / buildpower) or 1
	stats.meanDuty = (active > 0) and (dutySum / active) or 1
	stats.ecoEstimate = mathMin(ecoEstimate("metal"), ecoEstimate("energy"))

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
-- callins

function widget:Initialize()
	myTeamID = spGetMyTeamID()
	rebuildBuilders()
	widgetHandler:AddAction("nanostall_poc_labels", function()
		SHOW_UNIT_LABELS = not SHOW_UNIT_LABELS
		spEcho("Nano Stall PoC: unit labels " .. (SHOW_UNIT_LABELS and "on" or "off"))
	end, nil, "t")
	widgetHandler:AddAction("nanostall_poc_echo", function()
		ECHO_EVERY_FRAMES = (ECHO_EVERY_FRAMES > 0) and 0 or 60
		spEcho("Nano Stall PoC: console echo " .. (ECHO_EVERY_FRAMES > 0 and "on" or "off"))
	end, nil, "t")
end

function widget:Shutdown()
	widgetHandler:RemoveAction("nanostall_poc_labels")
	widgetHandler:RemoveAction("nanostall_poc_echo")
end

function widget:ViewResize(newX, newY)
	vsx, vsy = newX, newY
end

function widget:PlayerChanged()
	local newTeam = spGetMyTeamID()
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
function widget:UnitTaken(unitID, unitDefID, unitTeam, newTeam)
	removeBuilder(unitID)
end
function widget:UnitDestroyed(unitID)
	removeBuilder(unitID)
end

function widget:GameFrame(frame)
	if frame % SAMPLE_EVERY_FRAMES == 0 then
		sample()
	end
	if ECHO_EVERY_FRAMES > 0 and frame % ECHO_EVERY_FRAMES == 0 then
		spEcho(
			strFormat(
				"NanoStall f%d: duty %.0f%% (1s avg %.0f%%, mean %.0f%%) builders %d bp %d | eco estimate %.0f%%",
				frame,
				stats.duty * 100,
				stats.dutySmooth * 100,
				stats.meanDuty * 100,
				stats.active,
				stats.buildpower,
				stats.ecoEstimate * 100
			)
		)
	end
end

--------------------------------------------------------------------------------
-- drawing (deliberately plain gl.Text, this is a PoC)

local function dutyColor(duty)
	-- red (0) -> yellow (0.5) -> green (1)
	if duty < 0.5 then
		return 1, duty * 2, 0.15
	end
	return 1 - (duty - 0.5) * 2, 1, 0.15
end

local function colorCode(r, g, b)
	return string.char(255, mathFloor(r * 254) + 1, mathFloor(g * 254) + 1, mathFloor(b * 254) + 1)
end

function widget:DrawScreen()
	if spIsGUIHidden() then
		return
	end
	local x = 12
	local y = vsy - 70
	if WG.topbar and WG.topbar.GetPosition then
		local area = WG.topbar.GetPosition()
		if area and area[2] then
			y = area[2] - 24
		end
	end
	local fontSize = 14
	local line = fontSize * 1.35

	local r, g, b = dutyColor(stats.dutySmooth)
	gl.Text(
		strFormat(
			"%sNano duty cycle: %.0f%%\255\255\255\255  (instant %.0f%%, unweighted mean %.0f%%)",
			colorCode(r, g, b),
			stats.dutySmooth * 100,
			stats.duty * 100,
			stats.meanDuty * 100
		),
		x,
		y,
		fontSize,
		"o"
	)
	gl.Text(
		strFormat(
			"\255\200\200\200working builders: %d   demanded buildpower: %d   served: %d",
			stats.active,
			stats.buildpower,
			stats.served
		),
		x,
		y - line,
		fontSize,
		"o"
	)
	gl.Text(
		strFormat("\255\200\200\200resource based estimate (income/pull): %.0f%%", stats.ecoEstimate * 100),
		x,
		y - line * 2,
		fontSize,
		"o"
	)
end

function widget:DrawScreenEffects()
	if not SHOW_UNIT_LABELS or spIsGUIHidden() then
		return
	end
	local cx, cy, cz = spGetCameraPosition()
	for unitID, duty in pairs(working) do
		local ux, uy, uz = spGetUnitViewPosition(unitID)
		if ux then
			local dx, dy, dz = ux - cx, uy - cy, uz - cz
			if mathSqrt(dx * dx + dy * dy + dz * dz) < LABEL_MAX_DIST then
				local b = builders[unitID]
				local sx, sy = spWorldToScreenCoords(ux, uy + unitHeight[b.defID] + 10, uz)
				if sx and sx > -50 and sx < vsx + 50 and sy > -50 and sy < vsy + 50 then
					local r, g, bl = dutyColor(duty)
					gl.Text(colorCode(r, g, bl) .. strFormat("%.0f%%", duty * 100), sx, sy, 13, "oc")
				end
			end
		end
	end
end
