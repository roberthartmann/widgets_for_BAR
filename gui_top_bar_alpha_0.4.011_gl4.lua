local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Top Bar with Buildpower 0.4.011 gl4",
		desc = "Shows resources, buildpower, wind speed, commander counter, and various options. GL4 variant: the resource bars are GPU instances drawn with one shader.",
		author = "Floris, Robert82",
		date = "Nov, 2025",
		license = "GNU GPL, v2 or later",
		layer = -999999,
		enabled = true, --enabled by default
		handler = true, --can use widgetHandler:x()
	}
end

--[[ Architecture and changes vs 0.4.010 (gl4 variant)

Goal: the resource bars cost about as little per displayed object as units do: geometry lives on
the GPU, only small per-instance values change, and a few instanced draw calls render everything.

Architecture
- One instance VBO (gl.InstanceVBOTable.makeInstanceVBOTable + makeRectVBO unit quad + makeVAOandAttach)
  holds every rectangle of the metal / energy / BP bars: bar background layers, overflow and low
  resource tints, value bar + inner border, glow (center + 2 edges), BP reserved overlay, metal noise,
  energy/BP flow effect, flow glow, share/conversion slider knobs (4 instances each) and the 3 BP
  indicators. Instance = 6 x vec4: rect, color1 (bottom), color2 (top), shape (chamfer, corner mask,
  outline width, visible), fill (fraction, min width, bar width, mode), tex (mode, tile size,
  additive, blink mode). The fill fraction is applied in the vertex shader.
- One GLSL 4.20 shader (gl.LuaShader, inline sources via CheckShaderUpdates): pixel -> NDC with a
  viewSize uniform; fragment shader = FlowUI chamfered rect (45 degree cut corners, per corner mask),
  vertical gradient, RectRoundOutline ramp, textured modes (3 scrolling flow layers with uniform
  time, noise, glow center / edge / flipped edge on texture units 1..4), blink uniform.
  Output is premultiplied, so normal and additive layers share one pass (blend ONE, 1-SRC_ALPHA).
- Draw per frame: per resource bar: static panel/icon list, 1 instanced draw (bars), value/storage/
  pull text lists, 1 instanced draw (knobs, above the text as before) -> 6 instanced draws in total.
  No glCreateList/glDeleteList and no table allocation in DrawScreen.
- 30 Hz tick (widget:Update accumulator): refills the resource tables in place, writes fill
  fractions / glow alpha / tint colors into the Lua instance mirror; only changed instances are
  pushed (pushElementInstance with the same key, no upload) and uploaded once before drawing.
  Instances are rebuilt only on init / ViewResize / config change; hover changes only move knobs.
- Text: font display lists keyed by the printed string, bounded ring-buffer caches (48 per cache).
- Hover (resource bars, topbar, buttons, quit dialog) is evaluated in the 30 Hz tick and in
  MousePress; the button hover highlight and the changelog highlight are display lists built on
  change. The quit dialog list is rebuilt at most 30x/s while fading in, then only on hover change.
- Fallback: if gl.InstanceVBOTable / gl.LuaShader / VBO / VAO are missing or the shader fails to
  compile, the widget echoes the reason, recommends the light variant and removes itself. The first
  GL4 draw is pcall-protected and does the same on failure.
- Shutdown finalizes the shader, deletes the instance VBO + VAO, the quad VBO and all display lists.

Changes in behaviour / look (intentional or unavoidable)
- Removed: per-frame flow effect display list rebuild, per-pixel-width value bar lists, per-tick
  r-table allocation, per-second rebuild of the static tint lists, per-frame hover tests and
  immediate mode button highlight, per-frame quit dialog rebuild.
- Flow scrolling is continuous (0.4.010 stepped every <=3 frames). Chamfer diagonals are anti-aliased.
- Additive layers no longer add to destination alpha (premultiplied blending); colors are the same.
- Omitted no-ops: the additive pure black background rect, and the BP stall tint (0.4.010 drew it
  with a leftover alpha 0 color, i.e. invisible).
- Bug fixes: storage text is rebuilt only when storage changes (the old check never stored the value),
  value/wind text caches are bounded and cleared on layout changes, BP value list no longer leaks,
  wind text is formatted once per game frame instead of every Update.
- Button hover / pressed highlight updates at 30 Hz (up to ~33 ms later than before).
- The overflow warning boxes under the bars stay in the 1 Hz pull/expense/income text list.
- Main chunk is at Lua 5.1's 200 local limit: new state lives in the tables TC, ui, gl4 and K.

NOT verified in-engine (only syntax check, glslangValidator compile/link of both shaders, and a
mocked lupa run with BAR's real modules/graphics/instancevbotable.lua)
- gl.InstanceVBOTable.makeInstanceVBOTable / makeRectVBO / makeVAOandAttach / fillVAOSlots /
  pushElementInstance / uploadAllElements / clearInstanceTable as found in BAR master.
- VAO:DrawArrays(GL.TRIANGLES, 6, 0, count, firstInstance) with firstInstance > 0
  (glDrawArraysInstancedBaseInstance, RecoilEngine LuaVAOImpl.cpp).
- gl.LuaShader.CheckShaderUpdates with inline vsSrc/fsSrc + forceupdate; SetUniform("viewSize", x, y).
- gl.Texture(1..4, name) bindings staying valid for the shader; real driver GLSL compile.
- DrawScreen space == gl.GetViewSizes() pixels; visual parity with 0.4.010 (colors, glow, flow
  scale/direction, texture orientation) has not been compared on screen.
]]

-------------------------------CONFIG------------------------------------------
-------------------------------------------------------------------------------


local config = {
	drawBPBar = true,
	autoHideButtons = false,
	debugTooltip = true,
	-- Show markers on the buildpower bar that indicate how much buildpower our metal and energy income could support.
	drawBPIndicators = true,
	drawBPWindRangeIndicators = true,
	barScale = 1,
	barWidth = 1,
}

-- used to identify when config values have changed
local prevConfig = {}

local OPTION_SPECS = {
	{
		configVariable = "drawBPBar",
		name = "buildpower bar",
		description = "Draw the buildpower bar (requires reload)",
		type = "bool",
	},
	{
		configVariable = "drawBPIndicators",
		name = "eco support indicators",
		description = "Estimate how much buildpower is supported by your metal and energy income",
		type = "bool",
	},
	{
		configVariable = "drawBPWindRangeIndicators",
		name = "wind range indicators",
		description = "Show how energy-supported buildpower might vary with wind speed",
		type = "bool",
	},
	{
		configVariable = "autoHideButtons",
		name = "auto hide buttons",
		description = "",
		type = "bool",
	},
	{
		configVariable = "debugTooltip",
		name = "debug data",
		description = "Show debug data in tooltip when hovering over the buildpower bar",
		type = "bool",
	},
	{
		configVariable = "barScale",
		name = "top bar height",
		description = "height of the top bar (requires reload)",
		type = "slider",
		min = 0.5,
		max = 2,
		step = 0.01,
		value = 1,
	},
	{
		configVariable = "barWidth",
		name = "top bar width",
		description = "width of the top bar (requires reload)",
		type = "slider",
		min = 1,
		max = 3,
		step = 0.01,
		value = 1,
	},
}

local function setOptionValue(optionSpec, value)
	if optionSpec.type == "slider" then
		config[optionSpec.configVariable] = value
	elseif optionSpec.type == "bool" then
		config[optionSpec.configVariable] = value
	elseif optionSpec.type == "select" then
	-- we have index, we need text
		config[optionSpec.configVariable] = optionSpec.options[value]
	end
end

local function addOptionFromSpec(optionSpec)
	local option = table.copy(optionSpec)
	option.id = "top_bar_bp_" .. option.configVariable  -- Festlegung der ID, bevor configVariable gelöscht wird
	option.configVariable = nil  -- Löscht configVariable, nachdem die ID festgelegt wurde
	option.enabled = nil
	option.widgetname = widget:GetInfo().name

	if optionSpec.type == "slider" or optionSpec.type == "bool" then  -- Wert holen für option.value
		option.value = config[optionSpec.configVariable]
	elseif optionSpec.type == "select" then
		for i, v in ipairs(optionSpec.options) do
			if config[optionSpec.configVariable] == v then
				option.value = i
				break
			end
		end
	end

	option.onchange = function(i, value, force)
		setOptionValue(optionSpec, value)
	end

	WG['options'].addOption(option)
end


function widget:GetConfigData()
	return config
end

function configHasChanged()
	local anyChange = false
	for k, v in pairs(config) do
		if prevConfig[k] ~= nil and prevConfig[k] ~= v then
			anyChange = true
		end
		prevConfig[k] = v
	end
	return anyChange
end

function widget:SetConfigData(data)
	if data ~= nil then
		for k, v in pairs(data) do
			if config[k] ~= nil then
				config[k] = v
			end
		end
	end
end

--------------------------------average calculations----------------------------------


function initWeightedAverage(maxN) -- Use circular queues so we don't have to repeatedly shift the tables' contents.
	return {
		maxn = maxN,-- max number of elements
		i = 1, -- next index to write to
		curn = 0, -- current number of elements
		sum_vw = 0, -- sum(sample*weight)
		sum_w = 0, -- sum(weight)
		v = {}, -- samples
		w = {}, -- weights
	}
end

function addValueAndGetWeightedAverage(t, newValue, newWeight)
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

		-- update the table's size
		if t.curn < t.maxn then
			t.curn = t.curn + 1
		end

		-- move i ahead
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

----------------------------  handling BP --------------------------------

-- used for res[BP]
local BP = {0, 1, 0, 0, 0} -- BP[2] = 1 to make sure the bar gets drawn propperly because r[res][2] = 0 -> no bar

-- is used for visualisation purposed in old top bar design  ql
--BP[1] = BP['empty1']
--BP[2] ^= BP['totalMetalCostOfBuilders']  -- will be discontinued
--BP[3] ^= avgTotalReservedBP
--BP[4] ^= BP['totalAvailableBP']																						--BeHe
--BP[5] ^= BP['avgTotalUsedBP']																							--BeHe


-- Used to store recent positions of the M/E-supported sliders on the BP bar so they can be moved more smoothly.
--BP['energyIncome'] = 0 -- r['energy'][4]
--BP['energyExpense'] = 0 -- r['energy'][5]
--BP['metalIncome'] = 0 -- r['metal'][4]
--BP['metalExpense'] = 0 -- r['metal'][5]


-- Lists of recent datapoints, used for smoothing. The first element is the number of datapoints to keep, the second is the datapoints themselves.
BP['history_usedBP'] = initWeightedAverage(30) -- used to calculate the average used BP
BP['history_reservedBP'] = initWeightedAverage(30) -- used to calculate the average reserved BP
BP['history_nonBuilderMetalExpense'] = initWeightedAverage(30) -- average metal expense from non-builders
BP['history_nonBuilderEnergyExpense'] = initWeightedAverage(30) -- average energy expense from non-builders
BP['history_mSliderPosition'] = initWeightedAverage(30) -- average metal expense from non-builders

-- How much of our buildpower can be supported by our energy income, expressed as a ratio from 0 to 1?
BP['history_eSliderPosition'] = initWeightedAverage(30)
--BP['history_eSliderPosition_minWind'] = initWeightedAverage(30) -- if wind is at its minimum?
--BP['history_eSliderPosition_maxWind'] = initWeightedAverage(30) -- if wind is at its maximum?
--BP['history_eIncomeNoWind'] = initWeightedAverage(30) -- how much energy income is from non-wind sources?

BP['reservedBP_instant'] = 0 -- it's basically cacheDataBase['reservedBP_instant']  only for reading purposes ql							-- BeHe
BP['usedBP_instant'] = 0 -- it's basically cacheDataBase['usedBP_instant'] only for reading purposes ql								-- BeHe

BP['eSliderPosition_minWind'] = 0
BP['eSliderPosition_maxWind'] = 0
------------------------ performance saving  --------------------------------
--go through the orders of units to calculate reserved BP
local builderCoroutine
local cacheDataBase = {} -- used for coroutine
cacheDataBase['usedBP_instant'] = 0																						--formaly [3]
cacheDataBase['reservedBP_instant'] = 0																					--formaly [5]
cacheDataBase['usedBPMetalExpense'] = 0  																				-- BeHe
cacheDataBase['usedBPEnergyExpense'] = 0 																				-- BeHe
cacheDataBase['usedBPExceptStalled'] = 0 																				-- BeHe
cacheDataBase['usedBPIfNoStall'] = 0 																					-- BeHe

local unitTracking = {}
unitTracking['frameCheckInterval'] = 3
unitTracking['maxUnitsPerFrame'] = 20
unitTracking['nextCheckFrame'] = 0
unitTracking['totalUnits'] = 0
unitTracking['unitsPerFrame'] = 20 --limit processed units per frame to improve performance
unitTracking['trackedNum'] = 0

local trackedBuilders = {} -- stores units of the player and their BP

local trackedWinds = {}
local numWindGenerators = 0

local unitCostData = {} --data of all units regarding the building costs, M/BP and E/BP
local stalling = {}
stalling['lowPrioEnergy'] = 0 -- totalStallingM = 0
stalling['lowPrioMetal'] = 0 --totalStallingE = 0

----------------------------------------- build power/ res calc entries end here  ------------------------------------------------

local allowSavegame = true--Spring.Utilities.ShowDevUI()

local ui_scale = config.barScale * tonumber(Spring.GetConfigFloat("ui_scale", 1) or 1)

local fontfile = "fonts/" .. Spring.GetConfigString("bar_font", "Poppins-Regular.otf")
local fontfile2 = "fonts/" .. Spring.GetConfigString("bar_font2", "Exo2-SemiBold.otf")

local textWarnColor = "\255\255\215\215"

local vsx, vsy = Spring.GetViewGeometry()

local orgHeight = 46
local height = orgHeight * (1 + (ui_scale - 1) / 1.7)

local escapeKeyPressesQuit = false

local relXpos = 0.3
local borderPadding = 5

local wholeTeamWastingMetalCount = 0


local noiseBackgroundTexture = ":g:LuaUI/Images/rgbnoise.png"
local showButtons = true

local playSounds = true
local leftclick = 'LuaUI/Sounds/tock.wav'
local resourceclick = 'LuaUI/Sounds/buildbar_click.wav'

local barGlowCenterTexture = ":l:LuaUI/Images/barglow-center.png"
local barGlowEdgeTexture = ":l:LuaUI/Images/barglow-edge.png"
local bladesTexture = ":n:LuaUI/Images/wind-blades.png"
local wavesTexture = ":n:LuaUI/Images/tidal-waves.png"
local comTexture = ":n:Icons/corcom.png"
if UnitDefs[Spring.GetTeamRulesParam(Spring.GetMyTeamID(), 'startUnit')] then
	comTexture = ':n:Icons/'..UnitDefs[Spring.GetTeamRulesParam(Spring.GetMyTeamID(), 'startUnit')].name..'.png'
end

-- Local variables for function names improve performance. See page 17 of https://www.lua.org/gems/sample.pdf ("Lua Performance Tips", by Roberto Ierusalimschy)
local math_ceil = math.ceil
local math_floor = math.floor
local math_round = math.round
local math_min = math.min
--local math_max = math.max
local math_isInRect = math.isInRect

local widgetScale = (0.80 + (vsx * vsy / 6000000))
local xPos = math_floor(vsx * relXpos)
local currentWind = 0
local gameStarted = (Spring.GetGameFrame() > 0)
local displayComCounter = false
local displayTidalSpeed = not (Spring.GetModOptions().map_waterislava or Game.waterDamage > 0)
local updateTextClock = os.clock()

local glTranslate = gl.Translate
local glColor = gl.Color
local glPushMatrix = gl.PushMatrix
local glPopMatrix = gl.PopMatrix
local glTexture = gl.Texture
local glRect = gl.Rect
local glTexRect = gl.TexRect
local glRotate = gl.Rotate
local glCreateList = gl.CreateList
local glCallList = gl.CallList
local glDeleteList = gl.DeleteList

local glBlending = gl.Blending
local GL_SRC_ALPHA = GL.SRC_ALPHA
local GL_ONE_MINUS_SRC_ALPHA = GL.ONE_MINUS_SRC_ALPHA
local GL_ONE = GL.ONE

local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spGetUnitDefID = Spring.GetUnitDefID
local spGetSpectatingState = Spring.GetSpectatingState
local spGetTeamResources = Spring.GetTeamResources
local spGetMyTeamID = Spring.GetMyTeamID
local spGetMouseState = Spring.GetMouseState
local spGetWind = Spring.GetWind
local spGetUnitResources = Spring.GetUnitResources
local spGetUnitCommands = Spring.GetUnitCommands
local spGetFactoryCommands = Spring.GetFactoryCommands

local isMetalmap = false

local widgetSpaceMargin, bgpadding, RectRound, TexturedRectRound, UiElement, UiButton, UiSliderKnob

local gaiaTeamID = Spring.GetGaiaTeamID()
local spec = spGetSpectatingState()
local myAllyTeamID = Spring.GetMyAllyTeamID()
local myTeamID = Spring.GetMyTeamID()
local myPlayerID = Spring.GetMyPlayerID()

local myAllyTeamList = Spring.GetTeamList(myAllyTeamID)
local numTeamsInAllyTeam = #myAllyTeamList

local supressOverflowNotifs = false
for _, teamID in ipairs(myAllyTeamList) do
	if select(4,Spring.GetTeamInfo(teamID,false)) then	-- is AI?
		local luaAI = Spring.GetTeamLuaAI(teamID)
		if luaAI and luaAI ~= "" then
			if string.find(luaAI, 'Scavengers') or string.find(luaAI, 'Raptors') then
				supressOverflowNotifs = true
				break
			end
		end
	end
end

local sformat = string.format

local minWind = Game.windMin
local maxWind = Game.windMax
-- precomputed average wind values, from wind random monte carlo simulation, given minWind and maxWind
local avgWind = {[0]={[1]="0.8",[2]="1.5",[3]="2.2",[4]="3.0",[5]="3.7",[6]="4.5",[7]="5.2",[8]="6.0",[9]="6.7",[10]="7.5",[11]="8.2",[12]="9.0",[13]="9.7",[14]="10.4",[15]="11.2",[16]="11.9",[17]="12.7",[18]="13.4",[19]="14.2",[20]="14.9",[21]="15.7",[22]="16.4",[23]="17.2",[24]="17.9",[25]="18.6",[26]="19.2",[27]="19.6",[28]="20.0",[29]="20.4",[30]="20.7",},[1]={[2]="1.6",[3]="2.3",[4]="3.0",[5]="3.8",[6]="4.5",[7]="5.2",[8]="6.0",[9]="6.7",[10]="7.5",[11]="8.2",[12]="9.0",[13]="9.7",[14]="10.4",[15]="11.2",[16]="11.9",[17]="12.7",[18]="13.4",[19]="14.2",[20]="14.9",[21]="15.7",[22]="16.4",[23]="17.2",[24]="17.9",[25]="18.6",[26]="19.2",[27]="19.6",[28]="20.0",[29]="20.4",[30]="20.7",},[2]={[3]="2.6",[4]="3.2",[5]="3.9",[6]="4.6",[7]="5.3",[8]="6.0",[9]="6.8",[10]="7.5",[11]="8.2",[12]="9.0",[13]="9.7",[14]="10.5",[15]="11.2",[16]="12.0",[17]="12.7",[18]="13.4",[19]="14.2",[20]="14.9",[21]="15.7",[22]="16.4",[23]="17.2",[24]="17.9",[25]="18.6",[26]="19.2",[27]="19.6",[28]="20.0",[29]="20.4",[30]="20.7",},[3]={[4]="3.6",[5]="4.2",[6]="4.8",[7]="5.5",[8]="6.2",[9]="6.9",[10]="7.6",[11]="8.3",[12]="9.0",[13]="9.8",[14]="10.5",[15]="11.2",[16]="12.0",[17]="12.7",[18]="13.5",[19]="14.2",[20]="15.0",[21]="15.7",[22]="16.4",[23]="17.2",[24]="17.9",[25]="18.7",[26]="19.2",[27]="19.7",[28]="20.0",[29]="20.4",[30]="20.7",},[4]={[5]="4.6",[6]="5.2",[7]="5.8",[8]="6.4",[9]="7.1",[10]="7.8",[11]="8.5",[12]="9.2",[13]="9.9",[14]="10.6",[15]="11.3",[16]="12.1",[17]="12.8",[18]="13.5",[19]="14.3",[20]="15.0",[21]="15.7",[22]="16.5",[23]="17.2",[24]="18.0",[25]="18.7",[26]="19.2",[27]="19.7",[28]="20.1",[29]="20.4",[30]="20.7",},[5]={[6]="5.5",[7]="6.1",[8]="6.8",[9]="7.4",[10]="8.0",[11]="8.7",[12]="9.4",[13]="10.1",[14]="10.8",[15]="11.5",[16]="12.2",[17]="12.9",[18]="13.6",[19]="14.4",[20]="15.1",[21]="15.8",[22]="16.5",[23]="17.3",[24]="18.0",[25]="18.8",[26]="19.3",[27]="19.7",[28]="20.1",[29]="20.4",[30]="20.7",},[6]={[7]="6.5",[8]="7.1",[9]="7.7",[10]="8.4",[11]="9.0",[12]="9.7",[13]="10.3",[14]="11.0",[15]="11.7",[16]="12.4",[17]="13.1",[18]="13.8",[19]="14.5",[20]="15.2",[21]="15.9",[22]="16.7",[23]="17.4",[24]="18.1",[25]="18.8",[26]="19.4",[27]="19.8",[28]="20.2",[29]="20.5",[30]="20.8",},[7]={[8]="7.5",[9]="8.1",[10]="8.7",[11]="9.3",[12]="10.0",[13]="10.6",[14]="11.3",[15]="11.9",[16]="12.6",[17]="13.3",[18]="14.0",[19]="14.7",[20]="15.4",[21]="16.1",[22]="16.8",[23]="17.5",[24]="18.2",[25]="19.0",[26]="19.5",[27]="19.9",[28]="20.3",[29]="20.6",[30]="20.9",},[8]={[9]="8.5",[10]="9.1",[11]="9.7",[12]="10.3",[13]="11.0",[14]="11.6",[15]="12.2",[16]="12.9",[17]="13.6",[18]="14.2",[19]="14.9",[20]="15.6",[21]="16.3",[22]="17.0",[23]="17.7",[24]="18.4",[25]="19.1",[26]="19.6",[27]="20.0",[28]="20.4",[29]="20.7",[30]="21.0",},[9]={[10]="9.5",[11]="10.1",[12]="10.7",[13]="11.3",[14]="11.9",[15]="12.6",[16]="13.2",[17]="13.8",[18]="14.5",[19]="15.2",[20]="15.8",[21]="16.5",[22]="17.2",[23]="17.9",[24]="18.6",[25]="19.3",[26]="19.8",[27]="20.2",[28]="20.5",[29]="20.8",[30]="21.1",},[10]={[11]="10.5",[12]="11.1",[13]="11.7",[14]="12.3",[15]="12.9",[16]="13.5",[17]="14.2",[18]="14.8",[19]="15.4",[20]="16.1",[21]="16.8",[22]="17.4",[23]="18.1",[24]="18.8",[25]="19.5",[26]="20.0",[27]="20.4",[28]="20.7",[29]="21.0",[30]="21.2",},[11]={[12]="11.5",[13]="12.1",[14]="12.7",[15]="13.3",[16]="13.9",[17]="14.5",[18]="15.1",[19]="15.8",[20]="16.4",[21]="17.1",[22]="17.7",[23]="18.4",[24]="19.1",[25]="19.7",[26]="20.2",[27]="20.6",[28]="20.9",[29]="21.2",[30]="21.4",},[12]={[13]="12.5",[14]="13.1",[15]="13.6",[16]="14.2",[17]="14.9",[18]="15.5",[19]="16.1",[20]="16.7",[21]="17.4",[22]="18.0",[23]="18.7",[24]="19.3",[25]="20.0",[26]="20.4",[27]="20.8",[28]="21.1",[29]="21.4",[30]="21.6",},[13]={[14]="13.5",[15]="14.1",[16]="14.6",[17]="15.2",[18]="15.8",[19]="16.5",[20]="17.1",[21]="17.7",[22]="18.4",[23]="19.0",[24]="19.6",[25]="20.3",[26]="20.7",[27]="21.1",[28]="21.4",[29]="21.6",[30]="21.8",},[14]={[15]="14.5",[16]="15.0",[17]="15.6",[18]="16.2",[19]="16.8",[20]="17.4",[21]="18.1",[22]="18.7",[23]="19.3",[24]="20.0",[25]="20.6",[26]="21.0",[27]="21.3",[28]="21.6",[29]="21.8",[30]="22.0",},[15]={[16]="15.5",[17]="16.0",[18]="16.6",[19]="17.2",[20]="17.8",[21]="18.4",[22]="19.0",[23]="19.6",[24]="20.3",[25]="20.9",[26]="21.3",[27]="21.6",[28]="21.9",[29]="22.1",[30]="22.3",},[16]={[17]="16.5",[18]="17.0",[19]="17.6",[20]="18.2",[21]="18.8",[22]="19.4",[23]="20.0",[24]="20.6",[25]="21.3",[26]="21.7",[27]="21.9",[28]="22.2",[29]="22.4",[30]="22.5",},[17]={[18]="17.5",[19]="18.0",[20]="18.6",[21]="19.2",[22]="19.8",[23]="20.4",[24]="21.0",[25]="21.6",[26]="22.0",[27]="22.3",[28]="22.5",[29]="22.7",[30]="22.8",},[18]={[19]="18.5",[20]="19.0",[21]="19.6",[22]="20.2",[23]="20.8",[24]="21.4",[25]="22.0",[26]="22.4",[27]="22.6",[28]="22.8",[29]="23.0",[30]="23.1",},[19]={[20]="19.5",[21]="20.0",[22]="20.6",[23]="21.2",[24]="21.8",[25]="22.4",[26]="22.7",[27]="22.9",[28]="23.1",[29]="23.2",[30]="23.4",},[20]={[21]="20.4",[22]="21.0",[23]="21.6",[24]="22.2",[25]="22.8",[26]="23.1",[27]="23.3",[28]="23.4",[29]="23.6",[30]="23.7",},[21]={[22]="21.4",[23]="22.0",[24]="22.6",[25]="23.2",[26]="23.5",[27]="23.6",[28]="23.8",[29]="23.9",[30]="24.0",},[22]={[23]="22.4",[24]="23.0",[25]="23.6",[26]="23.8",[27]="24.0",[28]="24.1",[29]="24.2",[30]="24.2",},[23]={[24]="23.4",[25]="24.0",[26]="24.2",[27]="24.4",[28]="24.4",[29]="24.5",[30]="24.5",},[24]={[25]="24.4",[26]="24.6",[27]="24.7",[28]="24.7",[29]="24.8",[30]="24.8",},}
-- precomputed percentage of time wind is less than 6, from wind random monte carlo simulation, given minWind and maxWind
local riskWind = {[0]={[1]="100",[2]="100",[3]="100",[4]="100",[5]="100",[6]="100",[7]="56",[8]="42",[9]="33",[10]="27",[11]="22",[12]="18.5",[13]="15.8",[14]="13.6",[15]="11.8",[16]="10.4",[17]="9.2",[18]="8.2",[19]="7.4",[20]="6.7",[21]="6.0",[22]="5.5",[23]="5.0",[24]="4.6",[25]="4.3",[26]="4.0",[27]="3.7",[28]="3.4",[29]="3.2",[30]="3.0",},[1]={[2]="100",[3]="100",[4]="100",[5]="100",[6]="100",[7]="56",[8]="42",[9]="33",[10]="27",[11]="22",[12]="18.5",[13]="15.7",[14]="13.6",[15]="11.8",[16]="10.4",[17]="9.2",[18]="8.2",[19]="7.4",[20]="6.7",[21]="6.0",[22]="5.5",[23]="5.0",[24]="4.6",[25]="4.3",[26]="4.0",[27]="3.7",[28]="3.4",[29]="3.2",[30]="3.0",},[2]={[3]="100",[4]="100",[5]="100",[6]="100",[7]="55",[8]="42",[9]="33",[10]="27",[11]="22",[12]="18.4",[13]="15.6",[14]="13.5",[15]="11.8",[16]="10.4",[17]="9.2",[18]="8.2",[19]="7.4",[20]="6.6",[21]="6.0",[22]="5.5",[23]="5.0",[24]="4.6",[25]="4.3",[26]="3.9",[27]="3.6",[28]="3.4",[29]="3.1",[30]="2.9",},[3]={[4]="100",[5]="100",[6]="100",[7]="53",[8]="40",[9]="32",[10]="25",[11]="21",[12]="17.8",[13]="15.2",[14]="13.2",[15]="11.5",[16]="10.2",[17]="9.1",[18]="8.1",[19]="7.3",[20]="6.6",[21]="6.0",[22]="5.4",[23]="5.0",[24]="4.6",[25]="4.2",[26]="3.9",[27]="3.6",[28]="3.4",[29]="3.1",[30]="2.9",},[4]={[5]="100",[6]="100",[7]="49",[8]="36",[9]="29",[10]="23",[11]="19.4",[12]="16.4",[13]="14.0",[14]="12.2",[15]="10.8",[16]="9.6",[17]="8.6",[18]="7.7",[19]="7.0",[20]="6.3",[21]="5.8",[22]="5.3",[23]="4.8",[24]="4.4",[25]="4.1",[26]="3.8",[27]="3.5",[28]="3.3",[29]="3.0",[30]="2.8",},[5]={[6]="100",[7]="41",[8]="30",[9]="24",[10]="19.5",[11]="16.2",[12]="13.9",[13]="11.9",[14]="10.4",[15]="9.3",[16]="8.3",[17]="7.5",[18]="6.8",[19]="6.2",[20]="5.7",[21]="5.2",[22]="4.8",[23]="4.4",[24]="4.1",[25]="3.8",[26]="3.5",[27]="3.2",[28]="3.0",[29]="2.8",[30]="2.6",},[6]={[7]="16.0",[8]="12.4",[9]="10.5",[10]="9.0",[11]="8.0",[12]="7.3",[13]="6.6",[14]="6.0",[15]="5.5",[16]="5.1",[17]="4.7",[18]="4.4",[19]="4.2",[20]="3.9",[21]="3.6",[22]="3.4",[23]="3.2",[24]="3.0",[25]="2.8",[26]="2.7",[27]="2.5",[28]="2.4",[29]="2.2",[30]="2.1",},}
-- pull average wind from precomputed table, if it exists
local avgWindValue = avgWind[minWind]
if avgWindValue ~= nil then
	avgWindValue=avgWindValue[maxWind]
end
if avgWindValue == nil then
	avgWindValue="~" .. tostring(math.max(minWind,maxWind*.75)) --fallback approximation
end
-- pull wind risk from precomputed table, if it exists
local riskWindValue = riskWind[minWind]
if riskWindValue ~= nil then
	riskWindValue=riskWindValue[maxWind]
end
if riskWindValue == nil then
	if minWind+maxWind >= 0.5 then
		riskWindValue = "0"
	else
		riskWindValue = "100"
	end
end
local tidalSpeed = Spring.GetTidal() -- for now assumed that it is not dynamiccally changed
local tidalWaveAnimationHeight = 10
local windRotation = 0

local lastFrame = -1
local topbarArea = {}
local resbarArea = { metal = {}, energy = {}, BP = {} }
local resbarDrawinfo = { metal = {}, energy = {}, BP = {} }
local shareIndicatorArea = { metal = {}, energy = {}, BP = {} }
local dlistResbar = { metal = {}, energy = {}, BP = {} }
local windArea = {}
local tidalarea = {}
local comsArea = {}
local buttonsArea = {}
local currentResValue = { metal = 1000, energy = 1000, BP = 0 }-- total BP
local currentStorageValue = { metal = -1, energy = -1, BP = 0.1 } -- usage of BP

local r = { metal = { spGetTeamResources(myTeamID, 'metal') }, energy = { spGetTeamResources(myTeamID, 'energy'), }}

-- NOTE: the main chunk of this file is at Lua 5.1's limit of 200 locals; new state therefore lives in a few
-- tables (TC, ui, gl4, K) and helper functions are scoped in do ... end blocks.

-- refill the resource tables in place (0.4.010 allocated new tables every 0.033 s)
local function refillResources()
	local m, e = r.metal, r.energy
	m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8] = spGetTeamResources(myTeamID, 'metal')
	e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8] = spGetTeamResources(myTeamID, 'energy')
end

--------------------------------------------------------------------------------
-- TC: bounded display list caches for text (keyed by the printed string)
--------------------------------------------------------------------------------
local TC = {}
do
	local function newTextCache(maxEntries)
		return { lists = {}, keys = {}, head = 1, count = 0, max = maxEntries }
	end

	function TC.clear(cache)
		for key, list in pairs(cache.lists) do
			glDeleteList(list)
		end
		cache.lists = {}
		cache.keys = {}
		cache.head = 1
		cache.count = 0
	end

	-- ring buffer: once full, every insert evicts (and deletes) the oldest entry
	function TC.put(cache, key, list)
		if cache.count >= cache.max then
			local oldKey = cache.keys[cache.head]
			if oldKey ~= nil and cache.lists[oldKey] then
				glDeleteList(cache.lists[oldKey])
				cache.lists[oldKey] = nil
			end
		else
			cache.count = cache.count + 1
		end
		cache.keys[cache.head] = key
		cache.head = (cache.head % cache.max) + 1
		cache.lists[key] = list
	end

	local size = 48
	TC.wind = newTextCache(size)
	TC.res = { metal = newTextCache(size), energy = newTextCache(size), BP = newTextCache(size) }
	TC.resKey = {} -- key of the current value text per resource
end

--------------------------------------------------------------------------------
-- ui: hover state evaluated in the 30 Hz tick, and the lists built from it
--------------------------------------------------------------------------------
local ui = {
	hoverButton = nil,
	hoverPressed = false,
	changelogHasChanges = false,
	dlistHover = nil,
	dlistChangelog = nil,
	quitHoverKey = 0,
	quitBuiltHoverKey = -1,
	quitBuiltClock = 0,
	quitBuiltFade = 0,
	quitBuiltFor = nil,
	quitRebuildInterval = 1 / 30,
}

--------------------------------------------------------------------------------
-- gl4: resource bar renderer
--
-- Every rectangle-like element of the metal / energy / BP bars is one instance in a
-- single instance VBO (unit quad x instances). Per instance: rect, two gradient
-- colors, chamfer size + corner mask, outline width, visibility, fill fraction
-- (applied in the vertex shader), texture mode, additive flag and blink mode.
-- One shader (premultiplied alpha output) reproduces FlowUI RectRound,
-- RectRoundOutline and TexturedRectRound, so normal and additive layers can be
-- drawn in the same draw call with gl.Blending(GL.ONE, GL.ONE_MINUS_SRC_ALPHA).
--
-- instance layout: 6 x vec4 = 24 floats. Attribute 0 is the quad (makeRectVBO).
-- [1..4]   rect      x, y, w, h (screen px; for FILL_WIDTH w is extra width added to the fill width)
-- [5..8]   color1    bottom color (outer color for outlines)
-- [9..12]  color2    top color (inner color for outlines)
-- [13..16] shape     chamfer size, corner mask (1=tl 2=tr 4=br 8=bl), outline width (0 = filled), visible
-- [17..20] fillp     fill fraction, min fill width px, full bar width px, fill mode
-- [21..24] texp      texture mode, tile size px, additive (0/1), blink mode
--------------------------------------------------------------------------------
local gl4 = {
	vbo = nil,
	shader = nil,
	quad = nil,
	verified = false,
	time = 0,
	flowTexture = "LuaUI/Images/paralyzed.png",
	-- texture units 1..4 (unit 0 stays with fonts / FlowUI)
	TEXUNIT_FLOW = 1, TEXUNIT_NOISE = 2, TEXUNIT_GLOWCENTER = 3, TEXUNIT_GLOWEDGE = 4,
	TEXMODE_NONE = 0, TEXMODE_FLOW = 1, TEXMODE_NOISE = 2, TEXMODE_GLOWCENTER = 3, TEXMODE_GLOWEDGE = 4, TEXMODE_GLOWEDGE_FLIP = 5,
	FILL_NONE = 0, FILL_WIDTH = 1, FILL_OFFSET = 2,
	BLINK_NONE = 0, BLINK_FULL = 1, BLINK_SOFT = 2,
	RES_DRAW_ORDER = { 'metal', 'energy', 'BP' },
	templates = {}, -- key -> 24 float array (Lua mirror, used for change detection)
	order = {},     -- keys in draw order
	dirty = {},     -- keys changed since the last flush
	range = { metal = { 0, 0, 0, 0 }, energy = { 0, 0, 0, 0 }, BP = { 0, 0, 0, 0 } }, -- barsFirst, barsCount, knobsFirst, knobsCount (0 based)
}

-- instance keys, built once: K[res].fill == res .. '_fill' etc.
local K = {}

do
	local InstanceVBOTable = (type(gl.InstanceVBOTable) == "table") and gl.InstanceVBOTable or nil
	local pushElementInstance = InstanceVBOTable and InstanceVBOTable.pushElementInstance
	local uploadAllElements = InstanceVBOTable and InstanceVBOTable.uploadAllElements
	local clearInstanceTable = InstanceVBOTable and InstanceVBOTable.clearInstanceTable
	gl4.uploadAllElements = uploadAllElements
	gl4.pushElementInstance = pushElementInstance
	gl4.clearInstanceTable = clearInstanceTable

	local instanceLayout = {
		{ id = 1, name = "rect", size = 4 },
		{ id = 2, name = "color1", size = 4 },
		{ id = 3, name = "color2", size = 4 },
		{ id = 4, name = "shape", size = 4 },
		{ id = 5, name = "fillp", size = 4 },
		{ id = 6, name = "texp", size = 4 },
	}

	local shaderSourceCache = {
		vsSrc = [=[
#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require

layout (location = 0) in vec4 position_xy_uv; // unit quad 0..1
layout (location = 1) in vec4 rect;
layout (location = 2) in vec4 color1;
layout (location = 3) in vec4 color2;
layout (location = 4) in vec4 shape;
layout (location = 5) in vec4 fillp;
layout (location = 6) in vec4 texp;

uniform vec2 viewSize;

out vec2 v_local;
flat out vec2 v_size;
flat out vec4 v_color1;
flat out vec4 v_color2;
flat out vec4 v_shape;
flat out vec4 v_tex;

void main() {
	float x = rect.x;
	float w = rect.z;
	if (fillp.w > 0.5) {
		// same rule as 0.4.010: valueWidth = max(minWidth, floor(fraction * barWidth))
		float fw = max(fillp.y, floor(fillp.x * fillp.z));
		if (fillp.w < 1.5) {
			w = fw + rect.z;
		} else {
			x = rect.x + fw;
		}
	}
	vec2 sz = vec2(w, rect.w);
	v_local = position_xy_uv.xy * sz;
	v_size = sz;
	v_color1 = color1;
	v_color2 = color2;
	v_shape = shape;
	v_tex = texp;
	vec2 screenPos = vec2(x, rect.y) + v_local;
	gl_Position = vec4((screenPos / viewSize) * 2.0 - 1.0, 0.0, 1.0);
	if (shape.w < 0.5 || sz.x <= 0.0 || sz.y <= 0.0) {
		gl_Position = vec4(2.0, 2.0, 2.0, 1.0); // hidden: degenerate, outside the clip volume
	}
}
]=],
		fsSrc = [=[
#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require

uniform sampler2D flowTex;
uniform sampler2D noiseTex;
uniform sampler2D glowCenterTex;
uniform sampler2D glowEdgeTex;
uniform float time;
uniform float blink;

in vec2 v_local;
flat in vec2 v_size;
flat in vec4 v_color1;
flat in vec4 v_color2;
flat in vec4 v_shape;
flat in vec4 v_tex;

out vec4 fragColor;

void main() {
	vec2 p = v_local;
	vec2 s = v_size;

	// inside distance of a FlowUI style chamfered rect (45 degree cut corners)
	float d = min(min(p.x, s.x - p.x), min(p.y, s.y - p.y));
	float cs = v_shape.x;
	if (cs > 0.0) {
		int mask = int(v_shape.y + 0.5);
		const float k = 0.70710678;
		if ((mask & 1) != 0) { d = min(d, (p.x + (s.y - p.y) - cs) * k); }         // top left
		if ((mask & 2) != 0) { d = min(d, ((s.x - p.x) + (s.y - p.y) - cs) * k); } // top right
		if ((mask & 4) != 0) { d = min(d, ((s.x - p.x) + p.y - cs) * k); }         // bottom right
		if ((mask & 8) != 0) { d = min(d, (p.x + p.y - cs) * k); }                 // bottom left
	}
	float coverage = clamp(d + 0.5, 0.0, 1.0);
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
		// RectRound: color1 bottom -> color2 top
		col = mix(v_color1, v_color2, clamp(p.y / max(s.y, 0.0001), 0.0, 1.0));
	}

	int texMode = int(v_tex.x + 0.5);
	vec3 pm;      // premultiplied rgb
	float alpha;
	if (texMode == 0) {
		pm = col.rgb * col.a;
		alpha = col.a;
	} else if (texMode == 1) {
		// energy / BP flow: the three scrolling TexturedRectRound layers of 0.4.010
		vec2 base = vec2(p.x, s.y - p.y);
		float tile = max(v_tex.y, 1.0);
		vec4 t1 = texture(flowTex, base / (tile / 0.5) + vec2(-time / 80.0));
		vec4 t2 = texture(flowTex, base / (tile / 0.33) + vec2(time / 70.0));
		vec4 t3 = texture(flowTex, base / (tile / 0.45) + vec2(-time / 55.0));
		pm = col.rgb * col.a * (t1.rgb * t1.a + t2.rgb * t2.a + t3.rgb * t3.a);
		alpha = col.a * clamp(t1.a + t2.a + t3.a, 0.0, 1.0);
	} else if (texMode == 2) {
		// noise: TexturedRectRound(size = tile, offset = 0)
		vec4 t = texture(noiseTex, vec2(p.x, s.y - p.y) / max(v_tex.y, 1.0));
		pm = col.rgb * t.rgb * col.a * t.a;
		alpha = col.a * t.a;
	} else {
		// glow quads (DrawRect with 0.008 texcoord inset)
		vec2 n = p / max(s, vec2(0.0001));
		float v = 0.992 - 0.984 * n.y;
		vec4 t;
		if (texMode == 3) {
			t = texture(glowCenterTex, vec2(0.008 + 0.984 * n.x, v));
		} else if (texMode == 4) {
			t = texture(glowEdgeTex, vec2(0.008 + 0.984 * n.x, v));
		} else {
			t = texture(glowEdgeTex, vec2(0.992 - 0.984 * n.x, v));
		}
		pm = col.rgb * t.rgb * col.a * t.a;
		alpha = col.a * t.a;
	}

	int blinkMode = int(v_tex.w + 0.5);
	float alphaMult = coverage;
	if (blinkMode == 1) {
		alphaMult *= blink;
	} else if (blinkMode == 2) {
		alphaMult *= (0.6 + blink * 0.4);
	}
	pm *= alphaMult;
	alpha *= alphaMult;
	if (alpha <= 0.0 && (pm.r + pm.g + pm.b) <= 0.0) {
		discard;
	}
	// additive layers keep the destination alpha (blend func is ONE, ONE_MINUS_SRC_ALPHA)
	fragColor = vec4(pm, (v_tex.z > 0.5) ? 0.0 : alpha);
}
]=],
		forceupdate = true, -- inline sources: without this CheckShaderUpdates sees "no change" and returns nil
		shaderName = "Top Bar Resbars GL4",
		uniformInt = {
			flowTex = gl4.TEXUNIT_FLOW,
			noiseTex = gl4.TEXUNIT_NOISE,
			glowCenterTex = gl4.TEXUNIT_GLOWCENTER,
			glowEdgeTex = gl4.TEXUNIT_GLOWEDGE,
		},
		uniformFloat = {
			time = 0,
			blink = 0,
		},
		shaderConfig = {},
	}
	local vsSrc, fsSrc = shaderSourceCache.vsSrc, shaderSourceCache.fsSrc

	local names = {
		'bg1', 'bg2', 'bg4', 'bg5', 'bg6', 'tint1', 'tint2', 'tintLow',
		'fill', 'fillBorder', 'glowMid', 'glowLeft', 'glowRight', 'reserved', 'noise', 'flow', 'flowGlow',
		'conv1', 'conv2', 'conv3', 'conv4', 'share1', 'share2', 'share3', 'share4', 'indM', 'indW', 'indE',
	}
	for _, res in ipairs(gl4.RES_DRAW_ORDER) do
		local k = {}
		for _, n in ipairs(names) do
			k[n] = res .. '_' .. n
		end
		k.fillKeys = { k.fill, k.fillBorder, k.glowMid, k.glowRight, k.noise, k.flow, k.flowGlow }
		k.glowKeys = { k.glowMid, k.glowLeft, k.glowRight }
		K[res] = k
	end

	function gl4.cornerMask(tl, tr, br, bl)
		local m = 0
		if tl ~= 0 then m = m + 1 end
		if tr ~= 0 then m = m + 2 end
		if br ~= 0 then m = m + 4 end
		if bl ~= 0 then m = m + 8 end
		return m
	end

	-- generic instance (TexturedRectRound / DrawRect semantics: chamfer used as is)
	local function addInst(key, px, py, sx, sy, cs, mask, c1, c2)
		local t = {}
		gl4.templates[key] = t
		c2 = c2 or c1
		t[1], t[2], t[3], t[4] = px, py, sx - px, sy - py
		t[5], t[6], t[7], t[8] = c1[1], c1[2], c1[3], c1[4]
		t[9], t[10], t[11], t[12] = c2[1], c2[2], c2[3], c2[4]
		t[13], t[14], t[15], t[16] = cs or 0, mask or 0, 0, 1
		t[17], t[18], t[19], t[20] = 0, 0, 0, gl4.FILL_NONE
		t[21], t[22], t[23], t[24] = gl4.TEXMODE_NONE, 0, 0, gl4.BLINK_NONE
		gl4.order[#gl4.order + 1] = key
		return t
	end
	gl4.addInst = addInst

	-- RectRound semantics: chamfer is at least 1
	function gl4.addRect(key, px, py, sx, sy, cs, mask, c1, c2)
		return addInst(key, px, py, sx, sy, math.max(cs or 1, 1), mask, c1, c2)
	end

	local function setInst(key, i, v)
		local t = gl4.templates[key]
		if t and t[i] ~= v then
			t[i] = v
			gl4.dirty[key] = true
		end
	end
	gl4.setInst = setInst

	function gl4.setInstRect(key, px, py, sx, sy)
		setInst(key, 1, px)
		setInst(key, 2, py)
		setInst(key, 3, sx - px)
		setInst(key, 4, sy - py)
	end

	function gl4.setInstColor(key, cr, cg, cb, ca)
		setInst(key, 5, cr)
		setInst(key, 6, cg)
		setInst(key, 7, cb)
		setInst(key, 8, ca)
		setInst(key, 9, cr)
		setInst(key, 10, cg)
		setInst(key, 11, cb)
		setInst(key, 12, ca)
	end

	function gl4.setInstVisible(key, visible)
		setInst(key, 16, visible and 1 or 0)
	end

	-- push changed instances into the VBO table (in place, same key); the upload happens once before drawing
	function gl4.flush()
		local vbo = gl4.vbo
		if not vbo then
			return
		end
		local idx = vbo.instanceIDtoIndex
		local dirty = gl4.dirty
		local templates = gl4.templates
		for key in pairs(dirty) do
			if idx[key] then
				pushElementInstance(vbo, templates[key], key, true, true)
			end
			dirty[key] = nil
		end
	end

	function gl4.init()
		local LuaShader = gl.LuaShader
		if type(LuaShader) ~= "table" then
			LuaShader = nil
		end
		if not (InstanceVBOTable and LuaShader and gl.GetVBO and gl.GetVAO and gl.CreateShader) then
			return false, "gl.InstanceVBOTable, gl.LuaShader or GL4 VBO/VAO/shader support is not available"
		end
		if not (InstanceVBOTable.makeInstanceVBOTable and InstanceVBOTable.makeVAOandAttach and InstanceVBOTable.makeRectVBO and pushElementInstance and uploadAllElements and clearInstanceTable) then
			return false, "gl.InstanceVBOTable is missing functions this widget needs"
		end

		if LuaShader.CheckShaderUpdates then
			gl4.shader = LuaShader.CheckShaderUpdates(shaderSourceCache)
		else
			local shader = LuaShader({
				vertex = vsSrc,
				fragment = fsSrc,
				uniformInt = shaderSourceCache.uniformInt,
				uniformFloat = shaderSourceCache.uniformFloat,
			}, shaderSourceCache.shaderName)
			if shader and shader:Initialize() then
				gl4.shader = shader
			end
		end
		if not gl4.shader then
			return false, "the resource bar shader failed to compile (see the shader log above)"
		end

		local quadVBO, numVertices = InstanceVBOTable.makeRectVBO(0, 0, 1, 1, 0, 0, 1, 1, "topbarQuadVBO")
		if not quadVBO then
			return false, "could not create the quad VBO"
		end
		gl4.quad = quadVBO

		local vbo = InstanceVBOTable.makeInstanceVBOTable(instanceLayout, 128, "topbarResbarVBO")
		if not vbo then
			return false, "could not create the instance VBO"
		end
		gl4.vbo = vbo
		vbo.numVertices = numVertices or 6
		vbo.primitiveType = GL.TRIANGLES

		local vao = InstanceVBOTable.makeVAOandAttach(quadVBO, vbo.instanceVBO)
		if not vao then
			return false, "could not create the VAO"
		end
		if InstanceVBOTable.fillVAOSlots then
			vao = InstanceVBOTable.fillVAOSlots(vao, false, true)
		end
		vbo.VAO = vao
		vbo.vertexVBO = quadVBO -- so a resize can rebuild the VAO
		return true
	end

	function gl4.shutdown()
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

local showOverflowTooltip = {}

local allyComs = 0
local enemyComs = 0 -- if we are counting ourselves because we are a spec
local enemyComCount = 0 -- if we are receiving a count from the gadget part (needs modoption on)
local prevEnemyComCount = 0

local guishaderEnabled = false
local guishaderCheckUpdateRate = 0.5
local nextGuishaderCheck = guishaderCheckUpdateRate
local now = os.clock()
local gameFrame = Spring.GetGameFrame()

local draggingShareIndicatorValue = {}

local font, font2, firstButton, fontSize, comcountChanged, showQuitscreen, resbarHover
local draggingConversionIndicatorValue, draggingShareIndicator, draggingConversionIndicator
local conversionIndicatorArea, quitscreenArea, quitscreenStayArea, quitscreenQuitArea, quitscreenResignArea, hoveringTopbar, hideQuitWindow
local dlistButtonsGuishader, dlistComsGuishader, dlistButtonsGuishader, dlistWindGuishader, dlistTidalGuishader, dlistQuit
--local dlistButtons1, dlistButtons2, dlistComs1, dlistComs2, dlistWind1, dlistWind2

local chobbyLoaded = false
if Spring.GetMenuName and string.find(string.lower(Spring.GetMenuName()), 'chobby') ~= nil then
	chobbyLoaded = true
	Spring.SendLuaMenuMsg("disableLobbyButton")
end

-- compat: current BAR moved Spring.Utilities to BAR.Utilities; older builds only have Spring.Utilities.
-- Fall back to counting the players on non-AI teams ourselves if neither helper exists.
local numPlayers, isSinglePlayer
do
	local utilities = (BAR and BAR.Utilities) or Spring.Utilities
	if utilities and utilities.GetPlayerCount then
		numPlayers = utilities.GetPlayerCount()
	end
	if utilities and utilities.Gametype and utilities.Gametype.IsSinglePlayer then
		isSinglePlayer = utilities.Gametype.IsSinglePlayer()
	end
	if numPlayers == nil or isSinglePlayer == nil then
		local count = 0
		local gaiaTeamID = Spring.GetGaiaTeamID()
		for _, teamID in ipairs(Spring.GetTeamList() or {}) do
			local isAI = select(4, Spring.GetTeamInfo(teamID, false))
			if teamID ~= gaiaTeamID and not isAI then
				count = count + #(Spring.GetPlayerList(teamID) or {})
			end
		end
		if numPlayers == nil then
			numPlayers = count
		end
		if isSinglePlayer == nil then
			isSinglePlayer = (count <= 1)
		end
	end
	numPlayers = numPlayers or 0
end

local isSingle = false
if not spec then
	local teamList = Spring.GetTeamList(myAllyTeamID) or {}
	isSingle = #teamList == 1
end

local allyteamOverflowingMetal = false
local allyteamOverflowingEnergy = false
local overflowingMetal = false
local overflowingEnergy = false
local playerStallingMetal = false
local playerStallingEnergy = false

local isCommander = {}
for unitDefID, unitDef in pairs(UnitDefs) do
	if unitDef.customParams.iscommander then
		isCommander[unitDefID] = true
	end
end

--------------------------------------------------------------------------------
-- Graphs window
--------------------------------------------------------------------------------

local gameIsOver = false
local graphsWindowVisible = false

function widget:ViewResize()
	vsx, vsy = gl.GetViewSizes()
	widgetScale = (vsy / height) * 0.0425
	widgetScale = widgetScale * ui_scale
	xPos = math_floor(vsx * relXpos)

	widgetSpaceMargin = WG.FlowUI.elementMargin
	bgpadding = WG.FlowUI.elementPadding

	RectRound = WG.FlowUI.Draw.RectRound
	TexturedRectRound = WG.FlowUI.Draw.TexturedRectRound
	UiElement = WG.FlowUI.Draw.Element
	UiButton = WG.FlowUI.Draw.Button
	UiSliderKnob = WG.FlowUI.Draw.SliderKnob

	font = WG['fonts'].getFont(fontfile)
	font2 = WG['fonts'].getFont(fontfile2)

	TC.clear(TC.wind)
	for res, cache in pairs(TC.res) do
		TC.clear(cache)
		TC.resKey[res] = nil
	end

	init()
end

local function short(n, f)
	if f == nil then
		f = 0
	end
	if n > 9999999 then
		return sformat("%." .. f .. "fm", n / 1000000)
	elseif n > 9999 then
		return sformat("%." .. f .. "fk", n / 1000)
	else
		return sformat("%." .. f .. "f", n)
	end
end

local function updateButtons()

	local fontsize = (height * widgetScale) / 3

	if dlistButtons1 ~= nil then
		glDeleteList(dlistButtons1)
	end
	dlistButtons1 = glCreateList(function()

		-- if buttonsArea['buttons'] == nil then -- With this condition it doesn't actually update buttons if they were already added
		buttonsArea['buttons'] = {}

		local margin = bgpadding
		local textPadding = math_floor(fontsize*0.8)
		local sidePadding = textPadding
		local offset = sidePadding
		local lastbutton
		local function addButton(name, text)
			local width = math_floor((font2:GetTextWidth(text) * fontsize) + textPadding)
			buttonsArea['buttons'][name] = { buttonsArea[3] - offset - width, buttonsArea[2] + margin, buttonsArea[3] - offset, buttonsArea[4], text, buttonsArea[3] - offset - (width/2) }
			if not lastbutton then
				buttonsArea['buttons'][name][3] = buttonsArea[3]
			end
			offset = math_floor(offset + width + 0.5)
			lastbutton = name
		end

		if not gameIsOver and chobbyLoaded then
			addButton('quit', Spring.I18N('ui.topbar.button.lobby'))
			if not spec and gameStarted and not isSinglePlayer then
				addButton('resign', Spring.I18N('ui.topbar.button.resign'))
			end
		else
			addButton('quit', Spring.I18N('ui.topbar.button.quit'))
		end
		if WG['options'] ~= nil then
			addButton('options', Spring.I18N('ui.topbar.button.settings'))
		end
		if WG['keybinds'] ~= nil then
			addButton('keybinds', Spring.I18N('ui.topbar.button.keys'))
		end
		if WG['changelog'] ~= nil then
			addButton('changelog', Spring.I18N('ui.topbar.button.changes'))
		end
		if WG['teamstats'] ~= nil then
			addButton('stats', Spring.I18N('ui.topbar.button.stats'))
		end
		if gameIsOver then
			addButton('graphs', Spring.I18N('ui.topbar.button.graphs'))
		end
		if WG['scavengerinfo'] ~= nil then
			addButton('scavengers', Spring.I18N('ui.topbar.button.scavengers'))
		end
		if isSinglePlayer and allowSavegame and WG['savegame'] ~= nil then
			addButton('save', Spring.I18N('ui.topbar.button.save'))
		end

		buttonsArea['buttons'][lastbutton][1] = buttonsArea['buttons'][lastbutton][1] - sidePadding
		offset = offset + sidePadding

		buttonsArea[1] = buttonsArea[3]-offset-margin
		UiElement(buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4], 0, 0, 0, 1)

	end)

	-- add background blur
	if dlistButtonsGuishader ~= nil then
		if WG['guishader'] then
			WG['guishader'].RemoveDlist('topbar_buttons')
		end
		glDeleteList(dlistButtonsGuishader)
	end
	if showButtons then
		dlistButtonsGuishader = glCreateList(function()
			RectRound(buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4], 5.5 * widgetScale, 0,0,1,1)
		end)
		if WG['guishader'] then
			WG['guishader'].InsertDlist(dlistButtonsGuishader, 'topbar_buttons')
		end
	end

	if dlistButtons2 ~= nil then
		glDeleteList(dlistButtons2)
	end
	dlistButtons2 = glCreateList(function()
		font2:Begin()
		font2:SetTextColor(0.92, 0.92, 0.92, 1)
		font2:SetOutlineColor(0, 0, 0, 1)
		for name, params in pairs(buttonsArea['buttons']) do
			font2:Print(params[5], params[6], params[2] + ((params[4] - params[2]) * 0.5) - (fontsize / 5), fontsize, 'co')
		end
		font2:End()
	end)

	-- GL4 variant: the changelog highlight and the hover highlight are display lists built on change
	-- (0.4.010 drew them with immediate mode RectRound calls every frame)
	if ui.dlistChangelog ~= nil then
		glDeleteList(ui.dlistChangelog)
		ui.dlistChangelog = nil
	end
	if buttonsArea['buttons'] and buttonsArea['buttons']['changelog'] then
		local button = 'changelog'
		ui.dlistChangelog = glCreateList(function()
			local paddingsize = 1
			-- no color given: uses the gl.Color set before calling the list (0.1 * blinkProgress)
			RectRound(buttonsArea['buttons'][button][1]+paddingsize, buttonsArea['buttons'][button][2]+paddingsize, buttonsArea['buttons'][button][3]-paddingsize, buttonsArea['buttons'][button][4]-paddingsize, 3.5 * widgetScale, 0, 0, 0, button == firstButton and 1 or 0)
		end)
	end
	if ui.dlistHover ~= nil then
		glDeleteList(ui.dlistHover)
		ui.dlistHover = nil
	end
	ui.hoverButton = nil
end

local function updateComs(forceText)
	local area = comsArea

	-- add background blur
	if dlistComsGuishader ~= nil then
		if WG['guishader'] then
			WG['guishader'].RemoveDlist('topbar_coms')
		end
		glDeleteList(dlistComsGuishader)
	end
	dlistComsGuishader = glCreateList(function()
		RectRound(area[1], area[2], area[3], area[4], 5.5 * widgetScale, 0,0,1,1)
	end)

	if dlistComs1 ~= nil then
		glDeleteList(dlistComs1)
	end
	dlistComs1 = glCreateList(function()

		UiElement(area[1], area[2], area[3], area[4], 0, 0, 1, 1)

		if WG['guishader'] then
			WG['guishader'].InsertDlist(dlistComsGuishader, 'topbar_coms')
		end
	end)

	if dlistComs2 ~= nil then
		glDeleteList(dlistComs2)
	end
	dlistComs2 = glCreateList(function()
		-- Commander icon
		local sizeHalf = (height / 2.44) * widgetScale
		local yOffset = ((area[3] - area[1]) * 0.025)
		glTexture(comTexture)
		glTexRect(area[1] + ((area[3] - area[1]) / 2) - sizeHalf, area[2] + ((area[4] - area[2]) / 2) - sizeHalf +yOffset, area[1] + ((area[3] - area[1]) / 2) + sizeHalf, area[2] + ((area[4] - area[2]) / 2) + sizeHalf+yOffset)
		glTexture(false)

		-- Text
		if gameFrame > 0 or forceText then
			font2:Begin()
			local fontsize = (height / 2.85) * widgetScale
			font2:Print('\255\255\000\000' .. enemyComCount, area[3] - (2.8 * widgetScale), area[2] + (4.5 * widgetScale), fontsize, 'or')

			fontSize = (height / 2.15) * widgetScale
			font2:Print("\255\000\255\000" .. allyComs, area[1] + ((area[3] - area[1]) / 2), area[2] + ((area[4] - area[2]) / 2.05) - (fontSize / 5), fontSize, 'oc')
			font2:End()
		end
	end)
	comcountChanged = nil

	if WG['tooltip'] ~= nil then
		WG['tooltip'].AddTooltip('coms', area, Spring.I18N('ui.topbar.commanderCountTooltip'), nil, Spring.I18N('ui.topbar.commanderCount'))
	end
end

local function updateWind()
	local area = windArea

	local bladesSize = height*0.53 * widgetScale

	-- add background blur
	if dlistWindGuishader ~= nil then
		if WG['guishader'] then
			WG['guishader'].RemoveDlist('topbar_wind')
		end
		glDeleteList(dlistWindGuishader)
	end
	dlistWindGuishader = glCreateList(function()
		RectRound(area[1], area[2], area[3], area[4], 5.5 * widgetScale, 0,0,1,1)
	end)

	if dlistWind1 ~= nil then
		glDeleteList(dlistWind1)
	end
	dlistWind1 = glCreateList(function()

		UiElement(area[1], area[2], area[3], area[4], 0, 0, 1, 1)

		if WG['guishader'] then
			WG['guishader'].InsertDlist(dlistWindGuishader, 'topbar_wind')
		end

		-- blades icon
		glPushMatrix()
		glTranslate(area[1] + ((area[3] - area[1]) / 2), area[2] + (bgpadding/2) + ((area[4] - area[2]) / 2), 0)
		glColor(1, 1, 1, 0.2)
		glTexture(bladesTexture)
		-- glRotate is done after displaying this dl, and before dl2
	end)

	if dlistWind2 ~= nil then
		glDeleteList(dlistWind2)
	end
	dlistWind2 = glCreateList(function()
		glTexRect(-bladesSize, -bladesSize, bladesSize, bladesSize)
		glTexture(false)
		glPopMatrix()

		-- min and max wind
		local fontsize = (height / 3.7) * widgetScale
		if minWind+maxWind >= 0.5 then
			font2:Begin()
			font2:Print("\255\210\210\210" .. minWind, area[3] - (2.8 * widgetScale), area[4] - (4.5 * widgetScale) - (fontsize / 2), fontsize, 'or')
			font2:Print("\255\210\210\210" .. maxWind, area[3] - (2.8 * widgetScale), area[2] + (4.5 * widgetScale), fontsize, 'or')
			-- uncomment below to display average wind speed on UI
			-- font2:Print("\255\210\210\210" .. avgWindValue, area[1] + (2.8 * widgetScale), area[2] + (4.5 * widgetScale), fontsize, '')
			font2:End()
		else
			font2:Begin()
			--font2:Print("\255\200\200\200no wind", windArea[1] + ((windArea[3] - windArea[1]) / 2), windArea[2] + ((windArea[4] - windArea[2]) / 2.05) - (fontsize / 5), fontsize, 'oc') -- Wind speed text
			font2:Print("\255\200\200\200" .. Spring.I18N('ui.topbar.wind.nowind1'), windArea[1] + ((windArea[3] - windArea[1]) / 2), windArea[2] + ((windArea[4] - windArea[2]) / 1.5) - (fontsize / 5), fontsize*1.06, 'oc') -- Wind speed text
			font2:Print("\255\200\200\200" .. Spring.I18N('ui.topbar.wind.nowind2'), windArea[1] + ((windArea[3] - windArea[1]) / 2), windArea[2] + ((windArea[4] - windArea[2]) / 2.8) - (fontsize / 5), fontsize*1.06, 'oc') -- Wind speed text
			font2:End()
		end
	end)

	if WG['tooltip'] ~= nil then
		WG['tooltip'].AddTooltip('wind', area, Spring.I18N('ui.topbar.windspeedTooltip', { avgWindValue = avgWindValue, riskWindValue = riskWindValue, warnColor = textWarnColor }), nil, Spring.I18N('ui.topbar.windspeed'))
	end
end

-- return true if tidal speed is *relevant*, enough water in the world (>= 10%)
local function checkTidalRelevant()
	local mapMinHeight = 0
	-- account for invertmap to the best of our abiltiy
	if string.find(Spring.GetModOptions().debugcommands,"invertmap") then
		if string.find(Spring.GetModOptions().debugcommands,"wet") then
			-- assume that they want water if keyword "wet" is involved, too violitile between initilization and subsequent post terraform checks
			return true
		--else
		--	mapMinHeight = 0
		end
	else
		mapMinHeight = select(3,Spring.GetGroundExtremes())
	end
	mapMinHeight = mapMinHeight - (Spring.GetModOptions().map_waterlevel or 0)
	return mapMinHeight <= -20	-- armtide/cortide can be built from 20 waterdepth (hardcoded here cause am too lazy to auto cycle trhough unitdefs and read it from there)
end

local function updateTidal()
	local area = tidalarea

	-- add background blur
	if dlistTidalGuishader ~= nil then
		if WG['guishader'] then
			WG['guishader'].RemoveDlist('topbar_tidal')
		end
		glDeleteList(dlistTidalGuishader)
	end
	dlistTidalGuishader = glCreateList(function()
		RectRound(area[1], area[2], area[3], area[4], 5.5 * widgetScale, 0,0,1,1)
	end)

	if tidaldlist1 ~= nil then
		glDeleteList(tidaldlist1)
	end
	if tidaldlist2 ~= nil then
		glDeleteList(tidaldlist2)
	end
	local wavesSize = height*0.53 * widgetScale
	tidalWaveAnimationHeight = height*0.1 * widgetScale
	tidaldlist1 = glCreateList(function()
		UiElement(area[1], area[2], area[3], area[4], 0, 0, 1, 1)
		if WG['guishader'] then
			WG['guishader'].InsertDlist(dlistTidalGuishader, 'topbar_tidal')
		end
		-- waves icon
		glPushMatrix()
				-- translate will be done between this and tidaldlist2
	end)
	tidaldlist2 = glCreateList(function()
		glColor(1, 1, 1, 0.2)
		glTexture(wavesTexture)
		glTexRect(-wavesSize, -wavesSize, wavesSize, wavesSize)
		glTexture(false)
		glPopMatrix()
		-- tidal speed
		local fontSize = (height / 2.66) * widgetScale
		font2:Begin()
		font2:Print("\255\255\255\255" .. tidalSpeed, area[1] + ((area[3] - area[1]) / 2), area[2] + ((area[4] - area[2]) / 2.05) - (fontSize / 5), fontSize, 'oc') -- Tidal speed text
		font2:End()
	end)

	if WG['tooltip'] ~= nil then
		WG['tooltip'].AddTooltip('tidal', area, Spring.I18N('ui.topbar.tidalspeedTooltip'), nil, Spring.I18N('ui.topbar.tidalspeed'))
	end
end


local function updateResbarText(res)
	-- (0.4.010 re-created the static overflow / low resource tint lists [4] and [5] here every second;
	--  they are GL4 instances now, built once in buildBarInstances)

	-- storage changed! (0.4.010 never stored the value, so this ran every second)
	if currentStorageValue[res] ~= r[res][2] then
		currentStorageValue[res] = r[res][2]
		-- (the value text cache is bounded now, so no flush is needed here)

		-- storage
		if dlistResbar[res][6] ~= nil then
			glDeleteList(dlistResbar[res][6])
		end
		dlistResbar[res][6] = glCreateList(function()
			font2:Begin()
			if res == 'metal' then
				font2:SetTextColor(0.55, 0.55, 0.55, 1)
			elseif res == 'energy' then
				font2:SetTextColor(0.57, 0.57, 0.45, 1)
			--elseif res == 'BP' and config.drawBPBar then
			--	font2:SetTextColor(0.45, 0.6, 0.45, 1)
			end
			if res ~= 'BP' then-- Text: Storage
				font2:Print(short(r[res][2]), resbarDrawinfo[res].textStorage[2], resbarDrawinfo[res].textStorage[3], resbarDrawinfo[res].textStorage[4], resbarDrawinfo[res].textStorage[5])
			end
			font2:End()
		end)
	end

	if dlistResbar[res][3] ~= nil then
		glDeleteList(dlistResbar[res][3])
	end
	-- Add stalling M/E for any low-priority builders
	if res == 'metal' then
		r[res][3] = r[res][3] + stalling['lowPrioMetal'] 
	elseif res == 'energy' then
		r[res][3] = r[res][3] + stalling['lowPrioEnergy']
	end

	if res ~= 'BP' or config.drawBPBar then
		dlistResbar[res][3] = glCreateList(function() 
			font2:Begin()
			-- Text: pull
			if res ~= 'BP' then
				font2:Print("\255\240\125\125" .. "-" .. short(r[res][3]), resbarDrawinfo[res].textPull[2], resbarDrawinfo[res].textPull[3], resbarDrawinfo[res].textPull[4], resbarDrawinfo[res].textPull[5])
			end
			-- Text: expense
			local textcolor = "\255\240\180\145"
			if r[res][3] == r[res][5] then
				textcolor = "\255\200\140\130"
			end
			if res ~= 'BP' then
				font2:Print(textcolor .. "-" .. short(r[res][5]), resbarDrawinfo[res].textExpense[2], resbarDrawinfo[res].textExpense[3], resbarDrawinfo[res].textExpense[4], resbarDrawinfo[res].textExpense[5])
			-- income
				font2:Print("\255\120\235\120" .. "+" .. short(r[res][4]), resbarDrawinfo[res].textIncome[2], resbarDrawinfo[res].textIncome[3], resbarDrawinfo[res].textIncome[4], resbarDrawinfo[res].textIncome[5])
			end
			font2:End()

			local startingFrame = 90
			if debugMode then
				startingFrame = 1
			end
			if not spec and gameFrame > startingFrame then
				-- display overflow notification
				local reservedBP = BP[3]
				local totalBP = BP[4]
				local notifyBPIdle = reservedBP / totalBP <= 0.5 and (totalBP - reservedBP) > 300

				if (res == 'metal' and (allyteamOverflowingMetal or overflowingMetal))
						or (res == 'energy' and (allyteamOverflowingEnergy or overflowingEnergy))
						or (res == 'BP' and config.drawBPBar and (playerStallingMetal or playerStallingEnergy or notifyBPIdle)) then
					if showOverflowTooltip[res] == nil then
						showOverflowTooltip[res] = os.clock() + 1.1
					end
					if showOverflowTooltip[res] < os.clock() then
						local bgpadding2 = 2.2 * widgetScale
						local text = ''
						if res == 'metal' then
							text = (allyteamOverflowingMetal and '   ' .. Spring.I18N('ui.topbar.resources.wastingMetal') .. '   ' or '   ' .. Spring.I18N('ui.topbar.resources.overflowing') .. '   ')
							if not supressOverflowNotifs and  WG['notifications'] and not isMetalmap and (not WG.sharedMetalFrame or WG.sharedMetalFrame+60 < gameFrame) then
								if allyteamOverflowingMetal then
									if numTeamsInAllyTeam > 1 then
										if wholeTeamWastingMetalCount < 5 then
											wholeTeamWastingMetalCount = wholeTeamWastingMetalCount + 1
											WG['notifications'].addEvent('WholeTeamWastingMetal')
										end
									else
										--WG['notifications'].addEvent('YouAreWastingMetal')
									end
								elseif r[res][6] > 0.75 then	-- supress if you are deliberately overflowing by adjustingthe share slider down
									WG['notifications'].addEvent('YouAreOverflowingMetal')
								end
							end
						elseif res == 'energy' then
							text = (allyteamOverflowingEnergy and '   ' .. Spring.I18N('ui.topbar.resources.wastingEnergy') .. '   '  or '   ' .. Spring.I18N('ui.topbar.resources.overflowing') .. '   ')
							if not supressOverflowNotifs and WG['notifications'] and (not WG.sharedEnergyFrame or WG.sharedEnergyFrame+60 < gameFrame) then
								if allyteamOverflowingEnergy then
									if numTeamsInAllyTeam > 3 then
										--WG['notifications'].addEvent('WholeTeamWastingEnergy')
									else
										--WG['notifications'].addEvent('YouAreWastingEnergy')
									end
								elseif r[res][6] > 0.75 then	-- supress if you are deliberately overflowing by adjustingthe share slider down
									--WG['notifications'].addEvent('YouAreOverflowingEnergy')	-- this annoys the fuck out of em and makes them build energystoages too much
								end
							end
						end
						local fontSize = (orgHeight * (1 + (ui_scale - 1) / 1.33) / 4) * widgetScale
						local textWidth = font2:GetTextWidth(text) * fontSize

						-- background
						local color1, color2
						if res == 'metal' or res == 'energy' then
							if res == 'metal' then
								if allyteamOverflowingMetal then
									color1 = { 0.35, 0.1, 0.1, 1 }
									color2 = { 0.25, 0.05, 0.05, 1 }
								else
									color1 = { 0.35, 0.35, 0.35, 1 }
									color2 = { 0.25, 0.25, 0.25, 1 }
								end
							else
								if allyteamOverflowingEnergy then
									color1 = { 0.35, 0.1, 0.1, 1 }
									color2 = { 0.25, 0.05, 0.05, 1 }
								else
									color1 = { 0.35, 0.25, 0, 1 }
									color2 = { 0.25, 0.16, 0, 1 }
								end
							end
							RectRound(resbarArea[res][3] - textWidth, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3], resbarArea[res][2], 3.7 * widgetScale, 0, 0, 1, 1, color1, color2)  -- moved it under the bar so it doesn't obscure the numbers
							if res == 'metal' then
								if allyteamOverflowingMetal then
									color1 = { 1, 0.3, 0.3, 0.25 }
									color2 = { 1, 0.3, 0.3, 0.44 }
								else
									color1 = { 1, 1, 1, 0.25 }
									color2 = { 1, 1, 1, 0.44 }
								end
							else
								if allyteamOverflowingEnergy then
									color1 = { 1, 0.3, 0.3, 0.25 }
									color2 = { 1, 0.3, 0.3, 0.44 }
								else
									color1 = { 1, 0.88, 0, 0.25 }
									color2 = { 1, 0.88, 0, 0.44 }
								end
							end
							RectRound(resbarArea[res][3] - textWidth + bgpadding2, resbarArea[res][2] - 15.5 * widgetScale + bgpadding2, resbarArea[res][3] - bgpadding2, resbarArea[res][2], 2.8 * widgetScale, 0, 0, 1, 1, color1, color2)
						end

						font2:Begin()
						font2:SetTextColor(1, 0.88, 0.88, 1)
						font2:SetOutlineColor(0.2, 0, 0, 0.6)
						if res ~= 'BP' then
							font2:Print(text, resbarArea[res][3], resbarArea[res][2] - 9.3 * widgetScale, fontSize, 'or')
						elseif config.drawBPBar then
							local offset = 0

							local warning_lowlight = { 0.35, 0.1, 0.1, 1 }
							local warning_highlight = { 0.25, 0.05, 0.05, 1 }
							local info_lowlight = { 0.20, 0.20, 0.20, 1 }
							local info_highlight = { 0.12, 0.12, 0.12, 1 }
							if playerStallingMetal then
								offset = showBuildpowerAlert(resbarArea[res], 'Need metal', fontSize, warning_lowlight, warning_highlight, offset, bgpadding2)
							end

							if playerStallingEnergy then
								offset = showBuildpowerAlert(resbarArea[res], 'Need energy', fontSize, warning_lowlight, warning_highlight, offset, bgpadding2)
							end

							if notifyBPIdle then
								offset = showBuildpowerAlert(resbarArea[res], 'Idle buildpower', fontSize, info_lowlight, info_highlight, offset, bgpadding2)
							end
						end

						font2:End()
					end
				else
					showOverflowTooltip[res] = nil
				end
			end
		end)
	end
end

function showBuildpowerAlert(resourceArea, text, fontSize, lowlightColor, highlightColor, offset, padding)
	text = '   ' .. text .. '   '
	local textWidth = font2:GetTextWidth(text) * fontSize
	-- The gradient has the lowlight color at the bottom and the highlight color at the top.
	RectRound(resourceArea[3] - (offset + textWidth) + padding, resourceArea[2] - 15.5 * widgetScale + padding, resourceArea[3] - offset - padding, resourceArea[2], 2.8 * widgetScale, 0, 0, 1, 1, lowlightColor, highlightColor)
	font2:Print(text, resourceArea[3] - offset, resourceArea[2] - 9.3 * widgetScale , fontSize, 'or')
	return offset + textWidth
end

-- Layout + static display lists of one resource bar (init / resize / config change only).
-- The bar background, value bar, glow, flow effect and knobs are GL4 instances (buildBarInstances / updateResbar).
function gl4.layoutResbar(res)
	local area = resbarArea[res]

	if dlistResbar[res][1] ~= nil then
		glDeleteList(dlistResbar[res][1])
		dlistResbar[res][1] = nil
	end
	local barHeight = math_floor((height * widgetScale / 7) + 0.5)
	local barHeightPadding = math_floor(((height / 4.4) * widgetScale) + 0.5) --formaly ((height/2) * widgetScale) - (barHeight/2)
	--local barLeftPadding = 2 * widgetScale
	local barLeftPadding = math_floor(47 * widgetScale) -- formaly 53*
	local barRightPadding = math_floor(14.5 * widgetScale)
	local barHorizontalPadding_BP = barRightPadding
	local barArea = { area[1] + math_floor((height * widgetScale) + barLeftPadding), area[2] + barHeightPadding, area[3] - barRightPadding, area[2] + barHeight + barHeightPadding }
	local sliderHeightAdd = math_floor(barHeight / 1.55)
	local shareSliderWidth = barHeight + sliderHeightAdd + sliderHeightAdd
	local barWidth = barArea[3] - barArea[1]
	local glowSize = barHeight * 7
	local edgeWidth = math.max(1, math_floor(vsy / 1100))

	if not showQuitscreen and resbarHover ~= nil and resbarHover == res then
		sliderHeightAdd = barHeight / 0.75
		shareSliderWidth = barHeight + sliderHeightAdd + sliderHeightAdd
	end
	shareSliderWidth = math_ceil(shareSliderWidth)

	if res == 'metal' then
		resbarDrawinfo[res].barColor = { 1, 1, 1, 1 }
	elseif res == 'energy' then
		resbarDrawinfo[res].barColor = { 1, 1, 0, 1 }
	elseif res == 'BP'  and config.drawBPBar == true then
		resbarDrawinfo[res].barColor = { 0, 1, 0, 1 }
	end
	resbarDrawinfo[res].barArea = barArea

	resbarDrawinfo[res].barTexRect = { barArea[1], barArea[2], barArea[1] + ((r[res][1] / r[res][2]) * barWidth), barArea[4] }
	resbarDrawinfo[res].barGlowMiddleTexRect = { resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[2] - glowSize, resbarDrawinfo[res].barTexRect[3], resbarDrawinfo[res].barTexRect[4] + glowSize }
	resbarDrawinfo[res].barGlowLeftTexRect = { resbarDrawinfo[res].barTexRect[1] - (glowSize * 2.5), resbarDrawinfo[res].barTexRect[2] - glowSize, resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[4] + glowSize }
	resbarDrawinfo[res].barGlowRightTexRect = { resbarDrawinfo[res].barTexRect[3] + (glowSize * 2.5), resbarDrawinfo[res].barTexRect[2] - glowSize, resbarDrawinfo[res].barTexRect[3], resbarDrawinfo[res].barTexRect[4] + glowSize }

	local storageColor = "\255\150\150\100"
	local pullColor = "\255\210\100\100"
	local expenseColor = "\255\210\100\100"
	local incomeColor = "\255\100\210\100"


	resbarDrawinfo[res].textStorage = { storageColor .. short(r[res][2]), barArea[3], barArea[2] + barHeight * 2.1, (height / 3.2) * widgetScale, 'ord' }
	resbarDrawinfo[res].textPull = { pullColor .. short(r[res][3]), barArea[1] - (10 * widgetScale), barArea[2] + barHeight * 2.15, (height / 3) * widgetScale, 'ord' }
	resbarDrawinfo[res].textExpense = { expenseColor .. short(r[res][5]), barArea[1] + (10 * widgetScale), barArea[2] + barHeight * 2.15, (height / 3) * widgetScale, 'old' }   
	resbarDrawinfo[res].textIncome = { incomeColor .. short(r[res][4]), barArea[1] - (10 * widgetScale), barArea[2] - (barHeight * 0.55), (height / 3) * widgetScale, 'ord' }
	if res ~= 'BP' then
		resbarDrawinfo[res].textCurrent = { short(r[res][1]), barArea[1] + barWidth / 2, barArea[2] + barHeight * 1.8, (height / 2.5) * widgetScale, 'ocd' }
	end
	if res == 'BP' and config.drawBPBar == true then
		resbarDrawinfo[res].textCurrent = { short(r[res][1]), barArea[1] + barWidth / 2 - 10 * widgetScale, barArea[2] + barHeight * 1.8, (height / 2.5) * widgetScale, 'ocd' }
		resbarDrawinfo[res].barArea = { area[1] + barHorizontalPadding_BP, barArea[2], area[3] - barHorizontalPadding_BP, barArea[4] }
		barArea = resbarDrawinfo[res].barArea
		barWidth = barArea[3] - barArea[1]
	end
	resbarDrawinfo[res].barHeight = barHeight
	resbarDrawinfo[res].edgeWidth = edgeWidth
	currentStorageValue[res] = -1 -- positions changed: rebuild the storage text
	TC.clear(TC.res[res]) -- and the cached value texts (0.4.010 flushed them every second)
	TC.resKey[res] = nil

	-- add background blur
	if dlistResbar[res][0] ~= nil then
		if WG['guishader'] then
			WG['guishader'].RemoveDlist('topbar_' .. res)
		end
		glDeleteList(dlistResbar[res][0])
	end
	dlistResbar[res][0] = glCreateList(function()
		RectRound(area[1], area[2], area[3], area[4], 5.5 * widgetScale, 0,0,1,1)
	end)

	dlistResbar[res][1] = glCreateList(function()
		UiElement(area[1], area[2], area[3], area[4], 0, 0, 1, 1)

		if WG['guishader'] then
			WG['guishader'].InsertDlist(dlistResbar[res][0], 'topbar_' .. res)
		end

		-- Icon
		glColor(1, 1, 1, 1)
		local iconPadding = math_floor((area[4] - area[2]) / 9) --formaly /7
		local barHorizontalPadding_BP = math_floor(14.5 * widgetScale)
		local iconSize = math_floor(area[4] - area[2] - iconPadding - iconPadding)
		if res == 'BP' then
			iconSize = height / 3 * widgetScale
		end
		local bgpaddingHalf = math_floor((bgpadding * 0.5) + 0.5)
		local texSize = math_floor(iconSize * 2)
		if res == 'metal' then
			glTexture(":lr" .. texSize .. "," .. texSize .. ":LuaUI/Images/metal.png")
		elseif res == 'energy' then
			glTexture(":lr" .. texSize .. "," .. texSize .. ":LuaUI/Images/energy.png") 
		elseif config.drawBPBar == true then
			glColor(1, 0.9, 0.2, 1)
			glTexture(":lr" ..texSize ..", " ..texSize ..":LuaUI/images/stripes.png") --for bp bar only
		end

		if res == 'BP' then
			--TexturedRectRound(area[1] + barHorizontalPadding_BP, area[4] - bgpaddingHalf - iconPadding - iconSize, area[1] + barHorizontalPadding_BP + iconSize, area[4] - bgpaddingHalf - iconPadding,
			--	iconSize * 0.2, -- corner radius
			--	1, 1, 1, 1, -- corners
			--	iconSize * 1, 0)
			TexturedRectRound(area[1] + barHorizontalPadding_BP, area[4] - bgpaddingHalf - iconPadding - iconSize, area[1] + barHorizontalPadding_BP + iconSize, area[4] - bgpaddingHalf - iconPadding,
				iconSize * 0.2, -- corner radius
				1, 1, 1, 1, -- corners
				iconSize * 1, 0)
		else
			glTexRect(area[1] + bgpaddingHalf + iconPadding, area[2] + bgpaddingHalf + iconPadding, area[1] + bgpaddingHalf + iconPadding + iconSize, area[4] + bgpaddingHalf - iconPadding)
		end
		glTexture(false)
		-- (bar background moved to the GL4 instance VBO)
	end)
end


-- Static rectangles of one resource bar, in the draw order of 0.4.010.
-- Values that change at runtime (fill, glow alpha, tints) are written by gl4.updateBarInstances().
function gl4.buildBarInstances(res)
	local info = resbarDrawinfo[res]
	local k = K[res]
	local ba = info.barArea
	local barHeight = info.barHeight -- formula height, as used by the 0.4.010 bar background
	local barWidth = ba[3] - ba[1]
	local edgeWidth = info.edgeWidth
	local addedSize = math_floor(((ba[4] - ba[2]) * 0.15) + 0.5)
	local t

	-- bar background (was the tail of dlistResbar[res][1])
	gl4.addRect(k.bg1, ba[1] - edgeWidth + 1, ba[2] - edgeWidth + 1, ba[3] + edgeWidth - 1, ba[4] + edgeWidth - 1, barHeight * 0.2, 15, { 0, 0, 0, 0.12 }, { 0, 0, 0, 0.15 })
	t = gl4.addInst(k.bg2, ba[1] - edgeWidth, ba[2] - edgeWidth, ba[3] + edgeWidth, ba[4] + edgeWidth, barHeight * 0.33, 15, { 1, 1, 1, 0.16 })
	t[21], t[22] = gl4.TEXMODE_NOISE, barWidth * 0.33
	-- (0.4.010 also drew an additive pure black rect here; adding black changes nothing, so it is omitted)
	t = gl4.addRect(k.bg4, ba[1] - addedSize, ba[2] - addedSize, ba[3] + addedSize, ba[4] + addedSize, barHeight * 0.33, 15, { 0.15, 0.15, 0.15, 0.2 }, { 0.8, 0.8, 0.8, 0.16 })
	t[23] = 1
	-- gloss
	t = gl4.addRect(k.bg5, ba[1] - addedSize, ba[2] + addedSize, ba[3] + addedSize, ba[4] + addedSize, barHeight * 0.33, gl4.cornerMask(1, 1, 0, 0), { 1, 1, 1, 0 }, { 1, 1, 1, 0.07 })
	t[23] = 1
	t = gl4.addRect(k.bg6, ba[1] - addedSize, ba[2] - addedSize, ba[3] + addedSize, ba[2] + addedSize + addedSize + addedSize, barHeight * 0.2, gl4.cornerMask(0, 0, 1, 1), { 1, 1, 1, 0.1 }, { 1, 1, 1, 0.0 })
	t[23] = 1

	-- overflow tint (was dlistResbar[res][4]) and low resource tint (was dlistResbar[res][5]); hidden until needed
	-- (the BP bar's [4] was called with a leftover alpha 0 color in 0.4.010, i.e. it was invisible, so it has no instance)
	if res ~= 'BP' then
		local area = resbarArea[res]
		t = gl4.addRect(k.tint1, area[1] + bgpadding, area[2] + bgpadding, area[3] - bgpadding, area[4], bgpadding * 1.25, gl4.cornerMask(0, 0, 1, 1), { 1, 1, 1, 0 })
		t[16] = 0
		t = gl4.addRect(k.tint2, area[1], area[2], area[3], area[4], 5.5 * widgetScale, gl4.cornerMask(0, 0, 1, 1), { 1, 1, 1, 0 })
		t[16] = 0
		t = gl4.addRect(k.tintLow, area[1], area[2], area[3], area[4], 5.5 * widgetScale, gl4.cornerMask(0, 0, 1, 1), { 1, 1, 1, 0 })
		t[16] = 0
	end

	-- value bar (was dlistResValuesBar[res][valueWidth], one display list per pixel width)
	local h = ba[4] - ba[2]
	local minW = math_ceil(h * 0.2)
	local fx = ba[1]
	local color1, color2
	if res == 'metal' then
		color1 = { 0.51, 0.51, 0.5, 1 }
		color2 = { 0.95, 0.95, 0.95, 1 }
	elseif res == 'energy' then
		color1 = { 0.5, 0.45, 0, 1 }
		color2 = { 0.8, 0.75, 0, 1 }
	else
		color1 = { 0.2, 0.65, 0, 1 }
		color2 = { 0.5, 0.75, 0, 1 }
	end
	t = gl4.addRect(k.fill, fx, ba[2], fx, ba[4], h * 0.2, 15, color1, color2)
	t[18], t[19], t[20] = minW, barWidth, gl4.FILL_WIDTH
	t = gl4.addRect(k.fillBorder, fx + 1, ba[2] + 1, fx - 1, ba[4] - 1, h * 0.2, 15, { 0, 0, 0, 0.1 }, { 0, 0, 0, 0.17 }) -- width = fill - 2
	t[18], t[19], t[20] = minW, barWidth, gl4.FILL_WIDTH

	-- glow (additive), starts at barTexRect[1] like 0.4.010 (differs from barArea[1] for BP)
	local glowSize = h * 7
	local gx = info.barTexRect[1]
	local bc = info.barColor or { 1, 1, 1, 1 }
	t = gl4.addInst(k.glowMid, gx, ba[2] - glowSize, gx, ba[4] + glowSize, 0, 0, { bc[1], bc[2], bc[3], 0 })
	t[18], t[19], t[20] = minW, barWidth, gl4.FILL_WIDTH
	t[21], t[23] = gl4.TEXMODE_GLOWCENTER, 1
	t = gl4.addInst(k.glowLeft, gx - (glowSize * 2.5), ba[2] - glowSize, gx, ba[4] + glowSize, 0, 0, { bc[1], bc[2], bc[3], 0 })
	t[21], t[23] = gl4.TEXMODE_GLOWEDGE, 1
	t = gl4.addInst(k.glowRight, gx, ba[2] - glowSize, gx + (glowSize * 3), ba[4] + glowSize, 0, 0, { bc[1], bc[2], bc[3], 0 })
	t[18], t[19], t[20] = minW, barWidth, gl4.FILL_OFFSET
	t[21], t[23] = gl4.TEXMODE_GLOWEDGE_FLIP, 1

	if res == 'BP' then
		-- reserved BP overlay (additive in 0.4.010 because it was drawn while additive blending was active)
		t = gl4.addRect(k.reserved, fx, ba[2], fx, ba[4], h * 0.2, 15, { 0.1, 0.55, 0, 0.5 }, { 0.3, 0.65, 0, 0.5 })
		t[18], t[19], t[20] = minW, barWidth, gl4.FILL_WIDTH
		t[23] = 1
	end
	if res == 'metal' then
		-- noise (additive)
		t = gl4.addInst(k.noise, info.barTexRect[1], info.barTexRect[2], info.barTexRect[1], info.barTexRect[4], h * 0.2, 15, { 1, 1, 1, 0.37 })
		t[18], t[19], t[20] = minW, barWidth, gl4.FILL_WIDTH
		t[21], t[22], t[23] = gl4.TEXMODE_NOISE, barWidth * 0.33, 1
	end
	if res == 'energy' or res == 'BP' then
		-- flow effect (was createEffectDisplayList, rebuilt every 3 frames): 3 scrolling layers in one instance
		t = gl4.addInst(k.flow, fx, ba[2], fx, ba[4], h * 0.2, gl4.cornerMask(0, 0, 1, 1), { 1, 1, 1, 0.33 })
		t[18], t[19], t[20] = minW, barWidth, gl4.FILL_WIDTH
		t[21], t[22], t[23] = gl4.TEXMODE_FLOW, barWidth, 1
		t = gl4.addRect(k.flowGlow, fx - addedSize, ba[2] - addedSize, fx + addedSize, ba[4] + addedSize, h * 0.33, 15, { 1, 1, 0, 0.14 }) -- width = fill + 2 * addedSize
		t[18], t[19], t[20] = minW, barWidth, gl4.FILL_WIDTH
		t[23] = 1
	end
end

-- FlowUI SliderKnob = 4 instances (faint edge, dark outline, knob gradient, additive inner light edge)
function gl4.addKnob(k1, k2, k3, k4, color)
	local t
	t = gl4.addInst(k1, 0, 0, 0, 0, 1.1, 15, { 0, 0, 0, 0.12 })
	t[16] = 0
	t = gl4.addInst(k2, 0, 0, 0, 0, 1.1, 15, { 0, 0, 0, 0 }, { 0, 0, 0, 0.17 })
	t[15], t[16] = 2, 0
	t = gl4.addInst(k3, 0, 0, 0, 0, 1.1, 15, { color[1] * 0.55, color[2] * 0.55, color[3] * 0.55, color[4] }, color)
	t[16] = 0
	t = gl4.addInst(k4, 0, 0, 0, 0, 1.1, 15, { 1, 1, 1, 0.22 }, { 1, 1, 1, 0 })
	t[15], t[16], t[23] = 1, 0, 1
end

function gl4.setKnob(k1, k2, k3, k4, x, y, radius, visible)
	if not visible then
		gl4.setInstVisible(k1, false)
		gl4.setInstVisible(k2, false)
		gl4.setInstVisible(k3, false)
		gl4.setInstVisible(k4, false)
		return
	end
	local cs = math.max(1.1, radius * 0.15)
	local edge1 = math.max(1, math_floor(radius * 0.05))
	gl4.setInstRect(k1, x - radius - edge1, y - radius - edge1, x + radius + edge1, y + radius + edge1)
	gl4.setInst(k1, 13, cs)
	local edge2 = math.max(2, math_floor(radius * 0.3))
	gl4.setInstRect(k2, x - radius - edge2, y - radius - edge2, x + radius + edge2, y + radius + edge2)
	gl4.setInst(k2, 13, cs)
	gl4.setInst(k2, 15, edge2)
	gl4.setInstRect(k3, x - radius, y - radius, x + radius, y + radius)
	gl4.setInst(k3, 13, cs)
	gl4.setInstRect(k4, x - radius, y - radius, x + radius, y + radius)
	gl4.setInst(k4, 13, cs)
	gl4.setInst(k4, 15, math.max(0.01, radius * 0.17))
	gl4.setInstVisible(k1, true)
	gl4.setInstVisible(k2, true)
	gl4.setInstVisible(k3, true)
	gl4.setInstVisible(k4, true)
end

function gl4.buildKnobInstances(res)
	local k = K[res]
	if res == 'energy' then
		gl4.addKnob(k.conv1, k.conv2, k.conv3, k.conv4, { 0.95, 0.95, 0.7, 1 })
	end
	if res == 'BP' then
		local t
		t = gl4.addInst(k.indM, 0, 0, 0, 0, 1, gl4.cornerMask(1, 1, 0, 0), { 0.6, 0.6, 0.6, 1 }, { 1, 1, 1, 1 })
		t[16] = 0
		t = gl4.addInst(k.indW, 0, 0, 0, 0, 1, gl4.cornerMask(0, 0, 0, 0), { 0.8, 0.8, 0.0, 1 }, { 0.4, 0.4, 0.0, 1 })
		t[16] = 0
		t = gl4.addInst(k.indE, 0, 0, 0, 0, 1, gl4.cornerMask(0, 0, 1, 1), { 0.8, 0.8, 0.0, 1 }, { 1, 1, 0.2, 1 })
		t[16] = 0
	else
		gl4.addKnob(k.share1, k.share2, k.share3, k.share4, { 0.85, 0, 0, 1 })
	end
end

-- (Re)creates all instances in draw order. Only on init / resize / config change.
function gl4.rebuildInstances()
	if not gl4.vbo then
		return
	end
	gl4.templates = {}
	for i = #gl4.order, 1, -1 do
		gl4.order[i] = nil
	end
	for key in pairs(gl4.dirty) do
		gl4.dirty[key] = nil
	end
	for i = 1, #gl4.RES_DRAW_ORDER do
		local res = gl4.RES_DRAW_ORDER[i]
		local range = gl4.range[res]
		range[1], range[2], range[3], range[4] = #gl4.order, 0, #gl4.order, 0
		if (res ~= 'BP' or config.drawBPBar) and resbarDrawinfo[res].barArea and resbarDrawinfo[res].barHeight then
			gl4.buildBarInstances(res)
			range[2] = #gl4.order - range[1]
			range[3] = #gl4.order
			gl4.buildKnobInstances(res)
			range[4] = #gl4.order - range[3]
		end
	end
	gl4.clearInstanceTable(gl4.vbo)
	for i = 1, #gl4.order do
		local key = gl4.order[i]
		gl4.pushElementInstance(gl4.vbo, gl4.templates[key], key, true, true)
	end
	gl4.uploadAllElements(gl4.vbo)
end

function gl4.updateResbarTooltips(res)
	local resourceTranslations = {
		metal = Spring.I18N('ui.topbar.resources.metal'), 
		energy =  Spring.I18N('ui.topbar.resources.energy')
	}

	local resourceName = resourceTranslations[res]

	-- add tooltips
	if WG['tooltip'] ~= nil and conversionIndicatorArea then
		if res == 'energy' then
			WG['tooltip'].AddTooltip(res .. '_share_slider', { resbarDrawinfo[res].barArea[1], shareIndicatorArea[res][2], conversionIndicatorArea[1], shareIndicatorArea[res][4] }, Spring.I18N('ui.topbar.resources.shareEnergyTooltip'), nil, Spring.I18N('ui.topbar.resources.shareEnergyTooltipTitle'))
			WG['tooltip'].AddTooltip(res .. '_share_slider2', { conversionIndicatorArea[3], shareIndicatorArea[res][2], resbarDrawinfo[res].barArea[3], shareIndicatorArea[res][4] }, Spring.I18N('ui.topbar.resources.shareEnergyTooltip'), nil, Spring.I18N('ui.topbar.resources.shareEnergyTooltipTitle'))
			WG['tooltip'].AddTooltip(res .. '_metalmaker_slider', conversionIndicatorArea, Spring.I18N('ui.topbar.resources.conversionTooltip'), nil, Spring.I18N('ui.topbar.resources.conversionTooltipTitle'))
		else
			WG['tooltip'].AddTooltip(res .. '_share_slider', { resbarDrawinfo[res].barArea[1], shareIndicatorArea[res][2], resbarDrawinfo[res].barArea[3], shareIndicatorArea[res][4] }, Spring.I18N('ui.topbar.resources.shareMetalTooltip'), nil, Spring.I18N('ui.topbar.resources.shareMetalTooltipTitle'))
		end

		if res == 'BP' and config.drawBPBar == true then -- for bp bar only
			local textColor = '\255\215\215\215'
			local highlightColor = '\255\255\255\255'
			local avgTotalReservedBP = math_round(BP[3])
			local totalAvailableBP = BP[4]
			local avgTotalUsedBP = math_round(BP[5])

			local percentAssigned = math_floor((avgTotalReservedBP / totalAvailableBP * 100) + 0.5)
			local percentActive = math_floor((avgTotalUsedBP / totalAvailableBP * 100) + 0.5)
			local percentIdle = math_floor(((totalAvailableBP - avgTotalReservedBP) / totalAvailableBP * 100) + 0.5)

			if percentAssigned < 0 then
				percentAssigned = 0
			end
			if percentActive < 0 then
				percentActive = 0
			end
			if percentIdle < 0 then
				percentIdle = 0
			end

			local formattedAssigned = string.format("%3d", percentAssigned) .. "%"
			local formattedActive = string.format("%3d", percentActive) .. "%"
			local formattedIdle = string.format("%3d", percentIdle) .. "%"

			local bpTooltipText = textColor .. "Your total buildpower (BP) is " .. highlightColor .. totalAvailableBP .. textColor .. ", of which:\n"
				.. highlightColor .. formattedAssigned .. textColor .. " is assigned to tasks or moving to jobs (dark green bar).\n"
				.. highlightColor .. formattedActive .. textColor .. " is currently active and being used (green bar). This is the number shown.\n"
				.. highlightColor .. formattedIdle .. textColor .. " is idle with no BP tasks (red part)."
		
			if config.drawBPIndicators and BP['mSliderPosition'] ~= nil and BP['eSliderPosition'] ~= nil then
				bpTooltipText = bpTooltipText .. "\n\n"
					.. textColor .. "The grey and yellow indicators show you that, if all BP were fully engaged:\n"
					.. "Metal income would support " .. highlightColor .. math_ceil(BP['mSliderPosition'] * 100) .. textColor .. "% of BP.\n"
					.. "Energy income would support " .. highlightColor .. math_ceil(BP['eSliderPosition'] * 100) .. textColor .. "% of BP."
			end

			if config.debugTooltip then
				--local eIncomeNoWind = BP['energyIncomeNoWind']
				--if eIncomeNoWind == nil then
				--	eIncomeNoWind = 0
				--end

				local nBuilders = 0
				local nBuiltBuilders = 0
				for k, v in pairs(trackedBuilders) do
					currentUnitBP = v[1]
					unitIsBuilt = v[2]
					nBuilders = nBuilders + 1
					if unitIsBuilt then
						nBuiltBuilders = nBuiltBuilders + 1
					end
				end
				local function float_to_s(n)
					if n == nil then
						return "nil"
					end
					return sformat("%.3f", n)
				end
				bpTooltipText = bpTooltipText
			 		.."\n\nDEBUG:"
					.. float_to_s(avgTotalUsedBP) .. " BP used (smoothed), " .. float_to_s(BP['usedBP_instant']) .. " BP non-stalled ".. float_to_s(BP['usedBPIfNoStall']) .. " if no stall \n"
					.. tostring(nBuilders) .. " tracked builders\n"
					.. tostring(nBuiltBuilders) .. " built builders\n"
					.. tostring(BP[4]) .. " total BP \n"
					.. float_to_s(r['metal'][5]) .." M, " .. float_to_s(r['energy'][5]) .." E spent by all units\n"
					.. float_to_s(BP['usedBPMetalExpense']) .." M spent by builders, \n"
					.. float_to_s(BP['usedBPEnergyExpense']) .. " E spent by builders, \n"
					.. float_to_s(r['metal'][5]) .. " / " .. float_to_s(r['energy'][5]) .. " metal/energy expense, \n"
					.. float_to_s(BP['metalExpensePerBP']) .. " / " .. float_to_s(BP['energyExpensePerBP']) .. " M/E expense per BP, \n"
					.. float_to_s(r['energy'][4]) .." E income\n"
					.. float_to_s(numWindGenerators) .." wind generators\n"
					.. "\nprojections:\n"
					--.. float_to_s(eIncomeNoWind) .." E income without wind\n"
					.. float_to_s(BP['metalExpenseIfAllBPUsed']) .. " M spent if all BP is used, \n"
					.. float_to_s(BP['energyExpenseIfAllBPUsed']) .. " E spent if all BP is used, \n"
					.. float_to_s(BP['metalSupportedBP']) .. " BP supported by M income, \n"
					.. float_to_s(BP['energySupportedBP']) .. " BP supported by E income,\n\n"
			end

			WG['tooltip'].AddTooltip(res .. '_all', {
					resbarDrawinfo[res].barArea[1],--resbarArea[res][1],
					resbarDrawinfo[res].barArea[2],--resbarArea[res][2],
					resbarDrawinfo[res].barArea[3],--resbarArea[res][3],
					resbarDrawinfo[res].barArea[4],--resbarArea[res][4],
				},
				bpTooltipText, nil, bpTooltipTitle)

			local currentTooltipText = ""
			if BP[4] > 0 then
				currentTooltipText = textColor .. "You are using " .. highlightColor .. math_min(100, math_round(BP[5] * 100 / BP[4])) .. textColor .. "% of your buildpower."
			end
			if currentTooltipText ~= "" then
				WG['tooltip'].AddTooltip(res .. '_Current', {
					resbarDrawinfo[res].textCurrent[2] - (resbarDrawinfo[res].textCurrent[4] * 2.5),
					resbarDrawinfo[res].textCurrent[3],
					resbarDrawinfo[res].textCurrent[2] + (resbarDrawinfo[res].textCurrent[4] * 0.5),
					resbarDrawinfo[res].textCurrent[3] + resbarDrawinfo[res].textCurrent[4]
				}, currentTooltipText)
			else
				WG['tooltip'].RemoveTooltip(res .. '_Current')
			end

		elseif res ~= 'BP' then
			WG['tooltip'].AddTooltip(res .. '_pull', { resbarDrawinfo[res].textPull[2] - (resbarDrawinfo[res].textPull[4] * 2.5), resbarDrawinfo[res].textPull[3], resbarDrawinfo[res].textPull[2] + (resbarDrawinfo[res].textPull[4] * 0.5), resbarDrawinfo[res].textPull[3] + resbarDrawinfo[res].textPull[4] }, Spring.I18N('ui.topbar.resources.pullTooltip', { resource = resourceName }))  
			WG['tooltip'].AddTooltip(res .. '_income', { resbarDrawinfo[res].textIncome[2] - (resbarDrawinfo[res].textIncome[4] * 2.5), resbarDrawinfo[res].textIncome[3], resbarDrawinfo[res].textIncome[2] + (resbarDrawinfo[res].textIncome[4] * 0.5), resbarDrawinfo[res].textIncome[3] + resbarDrawinfo[res].textIncome[4] }, Spring.I18N('ui.topbar.resources.incomeTooltip', { resource = resourceName })) 
			WG['tooltip'].AddTooltip(res .. '_expense', { resbarDrawinfo[res].textExpense[2] - (4 * widgetScale), resbarDrawinfo[res].textExpense[3], resbarDrawinfo[res].textExpense[2] + (30 * widgetScale), resbarDrawinfo[res].textExpense[3] + resbarDrawinfo[res].textExpense[4] }, Spring.I18N('ui.topbar.resources.expenseTooltip', { resource = resourceName })) 
			WG['tooltip'].AddTooltip(res .. '_storage', { resbarDrawinfo[res].textStorage[2] - (resbarDrawinfo[res].textStorage[4] * 2.75), resbarDrawinfo[res].textStorage[3], resbarDrawinfo[res].textStorage[2], resbarDrawinfo[res].textStorage[3] + resbarDrawinfo[res].textStorage[4] }, Spring.I18N('ui.topbar.resources.storageTooltip', { resource = resourceName })) 
		end
	end
end

-- Cheap update of everything that 0.4.010 rebuilt through updateResbar(): slider knobs, BP indicators, tooltips.
-- Only instance values change; no display lists are created.
local function updateResbar(res)
	local info = resbarDrawinfo[res]
	local barArea = info.barArea
	if not barArea or not info.barHeight then
		return
	end
	local barHeight = info.barHeight
	local barWidth = barArea[3] - barArea[1]
	local sliderHeightAdd = math_floor(barHeight / 1.55)
	local shareSliderWidth = barHeight + sliderHeightAdd + sliderHeightAdd
	if not showQuitscreen and resbarHover ~= nil and resbarHover == res then
		sliderHeightAdd = barHeight / 0.75
		shareSliderWidth = barHeight + sliderHeightAdd + sliderHeightAdd
	end
	shareSliderWidth = math_ceil(shareSliderWidth)
	local k = K[res]

	-- Metalmaker Conversion slider
	if res == 'energy' then
		mmLevel = Spring.GetTeamRulesParam(myTeamID, 'mmLevel')
		local convValue = mmLevel
		if draggingConversionIndicatorValue then
			convValue = draggingConversionIndicatorValue / 100
		end
		if convValue == nil then
			convValue = 1
		end
		conversionIndicatorArea = { math_floor(barArea[1] + (convValue * barWidth) - (shareSliderWidth / 2)), math_floor(barArea[2] - sliderHeightAdd), math_floor(barArea[1] + (convValue * barWidth) + (shareSliderWidth / 2)), math_floor(barArea[4] + sliderHeightAdd) }
		gl4.setKnob(k.conv1, k.conv2, k.conv3, k.conv4,
			math_floor(conversionIndicatorArea[1]+((conversionIndicatorArea[3]-conversionIndicatorArea[1])/2)),
			math_floor(conversionIndicatorArea[2]+((conversionIndicatorArea[4]-conversionIndicatorArea[2])/2)),
			math_floor((conversionIndicatorArea[3]-conversionIndicatorArea[1])/2), true)
	end

	--show usefulBPFactor
	if res == 'BP' then
		local showM, showW, showE = false, false, false
		if config.drawBPIndicators then
			local indicatorPosM = BP['mSliderPosition']
			local indicatorPosE = BP['eSliderPosition']
			local indicatorAreaMultiplyerM = 1
			local indicatorAreaMultiplyerE = 1
			if playerStallingMetal == true then
				indicatorAreaMultiplyerM = 1.4
			end
			if playerStallingEnergy == true then
				indicatorAreaMultiplyerE = 1.4
			end
			local indicatorH = barHeight -- how tall are the metal-supported-BP and energy-supported-BP indicators?
			local barIntrusion = barHeight * 0.4 -- how much of the BP bar can be obscured (vertically) by one of these indicators?
			local indicatorW = indicatorH * 1.2
			local cornerSize = indicatorH / 2
			local metalIndicatorHalfWidth = indicatorW * indicatorAreaMultiplyerM / 2
			local energyIndicatorHalfWidth = indicatorW * indicatorAreaMultiplyerE / 2

			-- Indicator for buildpower that current METAL income can support (BOTTOM edge, pointing upward)
			if indicatorPosM ~= nil then
				showM = true
				gl4.setInstRect(k.indM,
					barArea[1] + (indicatorPosM * barWidth) - metalIndicatorHalfWidth,
					barArea[2] + (barIntrusion - indicatorH * indicatorAreaMultiplyerM),
					barArea[1] + (indicatorPosM * barWidth) + metalIndicatorHalfWidth,
					barArea[2] + barIntrusion)
				gl4.setInst(k.indM, 13, math.max(cornerSize * indicatorAreaMultiplyerM, 1))
			end
			if indicatorPosE ~= nil then
				-- range of buildpower that energy COULD support if the wind changes
				if config.drawBPWindRangeIndicators and numWindGenerators > 0 and BP['eSliderPosition_minWind'] ~= nil and BP['eSliderPosition_maxWind'] ~= nil then
					showW = true
					gl4.setInstRect(k.indW,
						barArea[1] + (BP['eSliderPosition_minWind'] * barWidth) - energyIndicatorHalfWidth,
						barArea[4] + barIntrusion,
						barArea[1] + (BP['eSliderPosition_maxWind'] * barWidth) + energyIndicatorHalfWidth,
						barArea[4] - barIntrusion + indicatorH)
					gl4.setInst(k.indW, 13, math.max((indicatorH * 1 - 2 * barIntrusion) / 2, 1))
				end
				-- buildpower that current ENERGY income can support (TOP edge, pointing downward)
				showE = true
				gl4.setInstRect(k.indE,
					barArea[1] + (indicatorPosE * barWidth) - energyIndicatorHalfWidth,
					barArea[4] - barIntrusion,
					barArea[1] + (indicatorPosE * barWidth) + energyIndicatorHalfWidth,
					barArea[4] - barIntrusion + indicatorH * indicatorAreaMultiplyerE)
				gl4.setInst(k.indE, 13, math.max(cornerSize * indicatorAreaMultiplyerE, 1))
			end
		end
		gl4.setInstVisible(k.indM, showM)
		gl4.setInstVisible(k.indW, showW)
		gl4.setInstVisible(k.indE, showE)
	end

	-- Share slider
	if res ~= 'BP' then
		if not isSingle then
			if res == 'energy' then
				eneryOverflowLevel = r[res][6]
			else
				metalOverflowLevel = r[res][6]
			end
			local value = r[res][6]
			if draggingShareIndicator and draggingShareIndicatorValue[res] ~= nil then
				value = draggingShareIndicatorValue[res]
			else
				draggingShareIndicatorValue[res] = value
			end
			shareIndicatorArea[res] = { math_floor(barArea[1] + (value * barWidth) - (shareSliderWidth / 2)), math_floor(barArea[2] - sliderHeightAdd), math_floor(barArea[1] + (value * barWidth) + (shareSliderWidth / 2)), math_floor(barArea[4] + sliderHeightAdd) }
			gl4.setKnob(k.share1, k.share2, k.share3, k.share4,
				math_floor(shareIndicatorArea[res][1]+((shareIndicatorArea[res][3]-shareIndicatorArea[res][1])/2)),
				math_floor(shareIndicatorArea[res][2]+((shareIndicatorArea[res][4]-shareIndicatorArea[res][2])/2)),
				math_floor((shareIndicatorArea[res][3]-shareIndicatorArea[res][1])/2), true)
		else
			gl4.setKnob(k.share1, k.share2, k.share3, k.share4, 0, 0, 0, false)
		end
	end

	gl4.updateResbarTooltips(res)
end

-- 30 Hz: fill fractions, glow alpha and tint colors. Only changed values mark an instance dirty.
function gl4.updateBarInstances()
	if not gl4.vbo then
		return
	end
	local showTints = not spec and gameFrame > 90
	for i = 1, #gl4.RES_DRAW_ORDER do
		local res = gl4.RES_DRAW_ORDER[i]
		local rr = r[res]
		local info = resbarDrawinfo[res]
		if (res ~= 'BP' or config.drawBPBar) and rr and rr[1] and rr[2] and info.barArea then
			local k = K[res]
			local cappedCurRes = rr[1]
			if rr[1] > rr[2] * 1.07 then
				cappedCurRes = rr[2] * 1.07
			end
			local fill
			if res ~= 'BP' then
				fill = 0
				if rr[2] ~= 0 then
					fill = cappedCurRes / rr[2]
					if fill ~= fill then
						fill = 0
					end
				end
			else
				local barWidth = info.barArea[3] - info.barArea[1]
				local barHeight = info.barArea[4] - info.barArea[2]
				local totalBP = math.max(1, rr[4])
				local reservedBP = math_min(totalBP, rr[3])
				local usedBP = math_min(totalBP, rr[5])
				fill = usedBP / totalBP
				-- reserved overlay width, same integer rules as 0.4.010
				local valueWidth = math_floor(fill * barWidth)
				if valueWidth > barWidth then
					valueWidth = barWidth
				end
				local additionalWidth = math_floor((reservedBP / totalBP) * barWidth) - valueWidth
				if additionalWidth < math_ceil(barHeight * 0.2) or math_ceil(barHeight * 0.2) > barWidth then
					additionalWidth = 0
				end
				if valueWidth < math_ceil(barHeight * 0.2) or rr[2] == 0 then
					valueWidth = math_ceil(barHeight * 0.2)
				end
				gl4.setInst(k.reserved, 18, valueWidth + additionalWidth)
			end
			local fillKeys = K[res].fillKeys
			for j = 1, #fillKeys do
				gl4.setInst(fillKeys[j], 17, fill)
			end
			if res == 'BP' then
				gl4.setInst(k.reserved, 17, 0) -- its exact width is carried in the min width field
			end

			local glowAlpha
			if res == 'metal' then
				glowAlpha = 0.025 + (0.05 * math_min(1, cappedCurRes / rr[2] * 40))
			elseif res == 'energy' then
				glowAlpha = 0.035 + (0.07 * math_min(1, cappedCurRes / rr[2] * 40))
			else
				glowAlpha = 0.035 + (0.06 * math_min(1, cappedCurRes / rr[2] * 40))
			end
			local glowKeys = K[res].glowKeys
			for j = 1, #glowKeys do
				gl4.setInst(glowKeys[j], 8, glowAlpha)
				gl4.setInst(glowKeys[j], 12, glowAlpha)
			end

			if res ~= 'BP' then
				-- overflow tint
				local level, cr, cg, cb, ca, blinkMode = false, 1, 1, 1, 0, gl4.BLINK_NONE
				if showTints then
					local allyOverflow, ownOverflow
					if res == 'metal' then
						allyOverflow, ownOverflow = allyteamOverflowingMetal, overflowingMetal
					else
						allyOverflow, ownOverflow = allyteamOverflowingEnergy, overflowingEnergy
					end
					if allyOverflow then
						level = true
						cr, cg, cb, ca, blinkMode = 1, 0, 0, 0.13 * allyOverflow, gl4.BLINK_FULL
					elseif ownOverflow then
						level = true
						if res == 'metal' then
							cr, cg, cb = 1, 1, 1
						else
							cr, cg, cb = 1, 1, 0
						end
						ca, blinkMode = 0.05 * ownOverflow, gl4.BLINK_SOFT
					end
				end
				gl4.setInstVisible(k.tint1, level)
				gl4.setInstVisible(k.tint2, level)
				if level then
					gl4.setInstColor(k.tint1, cr, cg, cb, ca)
					gl4.setInstColor(k.tint2, cr, cg, cb, ca)
					gl4.setInst(k.tint1, 24, blinkMode)
					gl4.setInst(k.tint2, 24, blinkMode)
				end

				-- low resource tint
				local low = false
				if res == 'metal' or showTints then
					local limit = (res == 'metal') and 1000 or 2000
					if rr[1] < limit then
						local process = (rr[1] / rr[2]) * 13
						if process < 1 then
							process = 1 - process
							low = true
							if res == 'metal' then
								gl4.setInstColor(k.tintLow, 0.9, 0.4, 1, 0.08 * process)
							else
								gl4.setInstColor(k.tintLow, 0.9, 0.55, 1, 0.08 * process)
							end
						end
					end
				end
				gl4.setInstVisible(k.tintLow, low)
			end
		end
	end
end

-- current value text (font display list, bounded cache keyed by the printed text)
function gl4.updateResValueText(res)
	local rr = r[res]
	local info = resbarDrawinfo[res]
	if not rr or not rr[1] or not info.textCurrent or not font2 then
		return
	end
	local cappedCurRes = rr[1]
	if rr[1] > rr[2] * 1.07 then
		cappedCurRes = rr[2] * 1.07
	end
	local text
	local cr, cg, cb, ca = 0.7, 0.7, 0.7, 1.0
	if res == 'BP' then
		text = ""
		if BP[4] > 0 then
			local pct = math_min(100, math_round(BP[5] * 100 / BP[4]))
			if     pct < 40 then cr, cg, cb, ca = 0.82, 0.39, 0.39, 1.0 --Red
			elseif pct < 60 then cr, cg, cb, ca = 1.0,  0.39, 0.39, 1.0 --Orange
			elseif pct < 80 then cr, cg, cb, ca = 1.0,  1.0,  0.39, 1.0 --Yellow
			else                 cr, cg, cb, ca = 0.47, 0.92, 0.47, 1.0 --Green
			end
			text = pct .. "%"
		end
	else
		text = short(cappedCurRes)
		if res == 'metal' then
			cr, cg, cb, ca = 0.95, 0.95, 0.95, 1
		else
			cr, cg, cb, ca = 1, 1, 0.74, 1
		end
	end
	currentResValue[res] = text
	TC.resKey[res] = text
	local cache = TC.res[res]
	if not cache.lists[text] then
		local tc = info.textCurrent
		TC.put(cache, text, glCreateList(function()
			font2:Begin()
			font2:SetTextColor(cr, cg, cb, ca)
			font2:SetOutlineColor(0, 0, 0, 1)
			font2:Print(text, tc[2], tc[3], tc[4], tc[5])
			font2:End()
		end))
	end
end

function init()

	TC.clear(TC.wind) -- the wind text position may move with the layout
	refillResources()
	if config.drawBPBar then
		r['BP'] = BP
	else
		r['BP'] = nil
	end
	ui_scale = config.barScale * tonumber(Spring.GetConfigFloat("ui_scale", 1) or 1)
	height = orgHeight * (1 + (ui_scale - 1) / 1.7)
	topbarArea = { math_floor(xPos + (borderPadding * widgetScale)), math_floor(vsy - (height * widgetScale)), vsx, vsy }

	local filledWidth = 0
	local totalWidth = topbarArea[3] - topbarArea[1]
	local width = math_floor(totalWidth / 4.4) * config.barWidth
	local bpWidth = 0 -- width of buildpower bar
	local buttonWidth = math_floor(totalWidth / 4) -- buttons

	local maxTopBarWidth = totalWidth - buttonWidth
	local smallSections = 1 -- wind

	if displayTidalSpeed and checkTidalRelevant() then
		smallSections = smallSections + 1
	end
	if displayComCounter then
		smallSections = smallSections + 1
	end
	-- need room for wind/tidal/coms
	local smallSectionsWidth = math_floor((height * 1.18) * widgetScale + widgetSpaceMargin) * smallSections
	local maxTopBarWidth = totalWidth - buttonWidth * 1.5 - smallSectionsWidth - widgetSpaceMargin

	-- How much space should be used by metal, energy, and buildpower bars combined?
	local mebCombinedWidth = math_min(width * 2, maxTopBarWidth)
	if config.drawBPBar then
		mebCombinedWidth = math_min(width * 2 - widgetSpaceMargin, maxTopBarWidth) -- need an extra widgetSpaceMargin since we have an extra element
		bpWidth = math_floor(mebCombinedWidth / 6)	-- 'width' is used for both metal and energy sections. We're stealing some of this space for buildpower.
	end
	width = math_floor((mebCombinedWidth - bpWidth) / 2)	-- Split the remaining width equally between metal and energy

	-- metal
	resbarArea['metal'] = { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
	filledWidth = filledWidth + width + widgetSpaceMargin
	gl4.layoutResbar('metal')
	-- buildpower
	if config.drawBPBar then -- change order here
		resbarArea['BP'] = { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + bpWidth, topbarArea[4] }
		filledWidth = filledWidth + bpWidth + widgetSpaceMargin
		gl4.layoutResbar('BP')
	end
	
	--energy
	resbarArea['energy'] = { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
	filledWidth = filledWidth + width + widgetSpaceMargin
	gl4.layoutResbar('energy')

	-- wind
	width = math_floor((height * 1.18) * widgetScale)
	windArea = { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
	filledWidth = filledWidth + width + widgetSpaceMargin
	updateWind()

	-- tidal
	if displayTidalSpeed then
		if not checkTidalRelevant() then
			displayTidalSpeed = false
		else
			width = math_floor((height * 1.18) * widgetScale)
			tidalarea = { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
			filledWidth = filledWidth + width + widgetSpaceMargin
			updateTidal()
		end
	end

	-- coms
	if displayComCounter then
		comsArea = { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
		filledWidth = filledWidth + width + widgetSpaceMargin
		updateComs()
	end

	-- buttons
	buttonsArea = { topbarArea[3] - buttonWidth, topbarArea[2], topbarArea[3], topbarArea[4] }
	updateButtons()

	if WG['topbar'] then
		WG['topbar'].GetPosition = function()
			return { topbarArea[1], topbarArea[2], topbarArea[3], topbarArea[4], widgetScale}
		end
		WG['topbar'].GetFreeArea = function()
			--return {1}
			return { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[3] - buttonWidth - widgetSpaceMargin, topbarArea[4], widgetScale}
		end
	end

	-- GL4: create all bar instances in draw order, then set knob positions (same order as 0.4.010, which
	-- matters for the tooltip registration that waits for conversionIndicatorArea)
	gl4.rebuildInstances()
	updateResbar('metal')
	if config.drawBPBar then
		updateResbar('BP')
	end
	updateResbar('energy')

	updateResbarText('metal')
	updateResbarText('energy')
	if config.drawBPBar == true then
		updateResbarText('BP')
	end
	gl4.updateBarInstances()
	gl4.updateResValueText('metal')
	gl4.updateResValueText('energy')
	if config.drawBPBar == true then
		gl4.updateResValueText('BP')
	end
end

local function checkSelfStatus()
	myAllyTeamID = Spring.GetMyAllyTeamID()
	myAllyTeamList = Spring.GetTeamList(myAllyTeamID)
	myTeamID = Spring.GetMyTeamID()
	myPlayerID = Spring.GetMyPlayerID()
	if myTeamID ~= gaiaTeamID and UnitDefs[Spring.GetTeamRulesParam(myTeamID, 'startUnit')] then
		comTexture = ':n:Icons/'..UnitDefs[Spring.GetTeamRulesParam(myTeamID, 'startUnit')].name..'.png'
	end
end

local function countComs(forceUpdate)
	-- recount my own ally team coms
	local prevAllyComs = allyComs
	local prevEnemyComs = enemyComs
	allyComs = 0
	for _, teamID in ipairs(myAllyTeamList) do
		for unitDefID,_ in pairs(isCommander) do
			allyComs = allyComs + Spring.GetTeamUnitDefCount(teamID, unitDefID)
		end
	end

	local newEnemyComCount = Spring.GetTeamRulesParam(myTeamID, "enemyComCount")
	if type(newEnemyComCount) == 'number' then
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
	gameStarted = true
	checkSelfStatus()
	if displayComCounter then
		countComs(true)
	end
	init()
end

local spGetTeamRulesParam = Spring.GetTeamRulesParam
local co_create = coroutine.create
local co_yield = coroutine.yield
local co_status = coroutine.status
local co_resume = coroutine.resume
local spValidUnitID = Spring.ValidUnitID

local function updateBPValues()
	if config.drawBPBar then
		BP['reservedBP_instant'] = cacheDataBase['reservedBP_instant']
		BP['usedBP_instant'] = cacheDataBase['usedBP_instant']
		BP['usedBPMetalExpense'] = cacheDataBase['usedBPMetalExpense']
		BP['usedBPEnergyExpense'] = cacheDataBase['usedBPEnergyExpense']
		BP['usedBPExceptStalled'] = cacheDataBase['usedBPExceptStalled']
		BP['usedBPIfNoStall'] = cacheDataBase['usedBPIfNoStall']


		cacheDataBase['reservedBP_instant'] = 0
		cacheDataBase['usedBP_instant'] = 0
		cacheDataBase['realWindStrength'] = 0
		cacheDataBase['usedBPMetalExpense'] = 0
		cacheDataBase['usedBPEnergyExpense'] = 0
		cacheDataBase['usedBPExceptStalled'] = 0
		cacheDataBase['usedBPIfNoStall'] = 0
	end
end

local function calculateAverages()
	if not config.drawBPBar then return end

	BP[3] = math_floor(addValueAndGetWeightedAverage(BP['history_reservedBP'], BP['reservedBP_instant'], 1) + 0.5)
	BP[5] = math_floor(addValueAndGetWeightedAverage(BP['history_usedBP'], BP['usedBP_instant'], 1) + 0.5)

	if config.drawBPWindRangeIndicators then
		BP['energyIncomeNoWind'] = r['energy'][4] - numWindGenerators * BP['realWindStrength_instant']
	end

	local bpRatioSupportedByMIncome = 1
	local bpRatioSupportedByEIncome = 1
	--Spring.Echo('-----------'  ..gameFrame)
	--Spring.Echo('usedBP_instant'  ..BP['usedBP_instant'])
	if BP['usedBP_instant'] >= 1 then

		local totalBP = BP[4]

		local m_per_bp = 0
		if BP['metalExpensePerBP'] ~= nil then
			m_per_bp = BP['metalExpensePerBP']
		end
		local e_per_bp = 0
		if BP['energyExpensePerBP'] ~= nil then
			e_per_bp = BP['energyExpensePerBP']
		end
		-- How much metal and energy are we spending _not_ due to builders?
		local metalExpenseMinusBuilders_instant  = r['metal'][5] - BP['usedBP_instant'] * m_per_bp
		local energyExpenseMinusBuilders_instant = r['energy'][5] - BP['usedBP_instant'] * e_per_bp

		-- TODO: How to handle metal-makers? They're a non-builder energy expense that will be turned off before we actually E-stall.
		-- We should consider a range of metal-supported BP just like we do for wind energy.

		local metalExpenseMinusBuilders = addValueAndGetWeightedAverage(BP['history_nonBuilderMetalExpense'], metalExpenseMinusBuilders_instant, 1)
		local energyExpenseMinusBuilders = addValueAndGetWeightedAverage(BP['history_nonBuilderEnergyExpense'], energyExpenseMinusBuilders_instant, 1)

		BP['metalExpensePerBP'] = BP['usedBPMetalExpense'] / BP['usedBP_instant']
		BP['energyExpensePerBP'] = BP['usedBPEnergyExpense'] / BP['usedBP_instant']

		
		BP['metalExpenseIfAllBPUsed'] = metalExpenseMinusBuilders + BP['metalExpensePerBP'] * totalBP
		BP['energyExpenseIfAllBPUsed'] = energyExpenseMinusBuilders + BP['energyExpensePerBP'] * totalBP

		BP['metalSupportedBP'] = nil
		BP['energySupportedBP'] = nil
		local minSupportedBP = 0

		if BP['metalExpensePerBP'] > 0 then
			BP['metalSupportedBP'] = r['metal'][4] / BP['metalExpenseIfAllBPUsed'] * totalBP
			minSupportedBP = BP['metalSupportedBP']
			bpRatioSupportedByMIncome = math.max(0, math_min(BP['metalSupportedBP'] / totalBP, 1))
		end

		if BP['energyExpensePerBP'] > 0 then
			BP['energySupportedBP'] = r['energy'][4] / BP['energyExpenseIfAllBPUsed'] * totalBP --ql
			minSupportedBP = BP['energySupportedBP']
			bpRatioSupportedByEIncome = math.max(0, math_min(BP['energySupportedBP'] / totalBP, 1))
		end

		if config.drawBPWindRangeIndicators then
			--eSupportedBP_minWind = (BP['energyIncomeNoWind'] - energyExpenseMinusBuilders) / BP['energyExpensePerBP']
			--local bpRatioSupportedByEIncome_minWind = math.max(0, math_min(eSupportedBP_minWind / totalBP, 1))

			--maxEPerWindGenerator = math_min(25, Game.windMax)
			--eSupportedBP_maxWind = (BP['energyIncomeNoWind'] + numWindGenerators * maxEPerWindGenerator - energyExpenseMinusBuilders) / BP['energyExpensePerBP']
			--local bpRatioSupportedByEIncome_maxWind = math.max(0, math_min(eSupportedBP_maxWind / totalBP, 1))

			--BP['eSliderPosition_minWind'] = addValueAndGetWeightedAverage(BP['history_eSliderPosition_minWind'], bpRatioSupportedByEIncome_minWind, BP['usedBP_instant'])
			
			local energyIncome
			if r['energy'][4] then
				energyIncome = r['energy'][4]
			else
				_, _, _, energyIncome, _, _, _ = spGetTeamResources(myTeamID, "energy")
			end
			--Spring.Echo('income'  ..energyIncome)
			local mycalc = ((energyIncome - numWindGenerators * BP['realWindStrength_instant']) / (BP['energyExpensePerBP'] * BP[4]))
			local smoothingFactor = 0.1 -- Wert zwischen 0 (keine Bewegung) und 1 (sofortiger Sprung)
			local smoothedWindMin = BP['eSliderPosition_minWind'] + (mycalc - BP['eSliderPosition_minWind']) * smoothingFactor
			BP['eSliderPosition_minWind'] =  math_min(1, math.max(0, smoothedWindMin))
			local myCalcMax = ((energyIncome + numWindGenerators * ( maxWind -BP['realWindStrength_instant'])) / (BP['energyExpensePerBP'] * BP[4]))
			--BP['eSliderPosition_maxWind'] = addValueAndGetWeightedAverage(BP['history_eSliderPosition_maxWind'], bpRatioSupportedByEIncome_maxWind, BP['usedBP_instant'])
			local smoothedWindMax = BP['eSliderPosition_maxWind'] + (myCalcMax - BP['eSliderPosition_maxWind']) * smoothingFactor
			BP['eSliderPosition_maxWind'] = math_min(1, math.max(0,smoothedWindMax))
			-----------------------XXXXXXXXXXXXXXXXX
			--Spring.Echo('energyExpensePerBP'  ..BP['energyExpensePerBP'])
			--Spring.Echo(tostring(mycalc) ..'         mycalc')
			--Spring.Echo(tostring(BP['eSliderPosition_minWind'])..'  eSliderPosition_minWind' )
			--Spring.Echo(tostring(myCalcMax) ..'         myCalcMax')
			--Spring.Echo(tostring(BP['eSliderPosition_maxWind'])..'  eSliderPosition_maxWind' )
		end

		if BP['metalSupportedBP'] ~= nil or BP['energySupportedBP'] ~= nil then
			if BP['metalSupportedBP'] ~= nil and BP['energySupportedBP'] ~= nil then
				minSupportedBP = math_min(BP['metalSupportedBP'], BP['energySupportedBP'])
			end
		end
	end

	BP['mSliderPosition'] = addValueAndGetWeightedAverage(BP['history_mSliderPosition'], 
		bpRatioSupportedByMIncome, BP['usedBP_instant'])
	BP['eSliderPosition'] = addValueAndGetWeightedAverage(BP['history_eSliderPosition'], 
		bpRatioSupportedByEIncome, BP['usedBP_instant'])
end

function widget:GameFrame(n)
	--Spring.Echo('_______________________')
	spec = spGetSpectatingState()

	local bladeSpeedMultiplier = 0.2
	windRotation = windRotation + (currentWind * bladeSpeedMultiplier)
	gameFrame = n
	local unp = unpack or table.unpack
	-- If we're supposed to draw the buildpower bar, do some calculations.
	if not config.drawBPBar or gameFrame < unitTracking.nextCheckFrame then
		return
	end

	if config.drawBPBar then -- calculations for the exact metal and energy draw value
		-- Log initial cache values
		local cacheTotalReservedBP = 0
		local cacheTotallyUsedBP = 0

		local usedBPMetalExpense = 0
		local usedBPEnergyExpense = 0
		local buildingBP = 0 -- how much BP is actively building, regardless of how stalled it is?
		local nonStalledBuildingBP = 0 -- how much BP is actively building and not stalled?


		local unitsReservedBP = {}
		if not builderCoroutine or co_status(builderCoroutine) == "dead" then -- init builderCoroutine
			builderCoroutine = co_create(function()
				for unitID, currentlyInspectedBuilder in pairs(trackedBuilders) do
					co_yield(unitID, currentlyInspectedBuilder)
				end
			end)
		end

		for i = 1, unitTracking.unitsPerFrame do -- use builderCoroutine, to work though builders
			local success, unitID, currentlyInspectedBuilder = co_resume(builderCoroutine)
			--if not success or not unitID then
			--	break
			--end
			if not spValidUnitID(unitID) then
				UntrackUnit(unitID)
			else

				local currentUnitBP, unitIsBuilt, unitDefID, unitTeamID = currentlyInspectedBuilder.buildSpeed, currentlyInspectedBuilder.isBuilt, currentlyInspectedBuilder.unitDefID, currentlyInspectedBuilder.unitTeamID
				if not unitIsBuilt then
					break
				end
				local unitType = currentlyInspectedBuilder.unitType
				local numCommands = 0
				if unitType ~= "factory" then
					numCommands = spGetUnitCommands(unitID, 0)
				else
					
					numCommands = spGetFactoryCommands(unitID, 0)
				end
				local builtUnitID = nil
				local builtUnitDefID =nil
				if numCommands == 0 then
				else
					local commands
					if unitType == "nano" then
						commands = spGetUnitCommands(unitID, 1)
					end
					if unitType == "nano" and numCommands == 1 and commands[1].id == 16 then
					else
						unitsReservedBP[unitID] = currentUnitBP
						builtUnitID = spGetUnitIsBuilding(unitID)
						if builtUnitID ~= nil then
							if builtUnitDefID == nil then
								builtUnitDefID = spGetUnitDefID(builtUnitID)
							end
						end

						if builtUnitDefID then
							local _, currentlyUsedM, _, currentlyUsedE = spGetUnitResources(unitID)
							usedBPMetalExpense = usedBPMetalExpense + currentlyUsedM
							usedBPEnergyExpense = usedBPEnergyExpense + currentlyUsedE

							currentlyUsedBP = currentlyUsedM / unitCostData[builtUnitDefID].MperBP -- everything costs at least 1 metal

							
							--XXXXXXXXX unit needs x metal = BP of unitID * unitCostData[builtUnitDefID].MperBP

							--XXXXXXXXX unit needs x e = BP of unitID * unitCostData[builtUnitDefID].EperBP
							--xxxxxxxxx unit has x BP

							--xxxxxxxxx sum of potential of BP currently building
							--xxxxxxxxx average MperBP= sum need metel/sumBP
							--xxxxxxxxx average EperBP= sum need energy/sumBP
							buildingBP = buildingBP + currentUnitBP

							local currentlyWantedM = unitCostData[builtUnitDefID].MperBP * currentUnitBP
							local currentlyWantedE = unitCostData[builtUnitDefID].EperBP * currentUnitBP

							-- Low-priority units don't have their pulled M/E reported correctly.
							local nonStalledRateM = 1 -- wanted M
							local nonStalledRateE = 1 -- wanted M
							if currentlyWantedM > 0 then
								nonStalledRateM = currentlyUsedM / currentlyWantedM
							end
							if currentlyWantedE > 0 then
								nonStalledRateE = currentlyUsedE / currentlyWantedE
							end
							nonStalledBuildingBP = nonStalledBuildingBP + currentUnitBP * math_min(nonStalledRateM, nonStalledRateE)  -- ROBERT BP at the right place

							if currentlyUsedBP and currentlyUsedBP >= 0 then
								cacheTotallyUsedBP = cacheTotallyUsedBP + currentlyUsedBP
							end
						end
					end
				end
			end
		end
		--Spring.Echo("Finished trackedBuilders loop")
		for unitID, unitReservedBP in pairs(unitsReservedBP) do
			cacheTotalReservedBP = cacheTotalReservedBP + unitReservedBP
		end
		cacheDataBase['reservedBP_instant'] = cacheDataBase['reservedBP_instant'] + cacheTotalReservedBP
		cacheDataBase['usedBP_instant'] = cacheDataBase['usedBP_instant'] + cacheTotallyUsedBP

		-- How much metal and energy are builders pulling? (This number will drop when they become resource-stalled, perhaps due to being low-priority.)
		cacheDataBase['usedBPMetalExpense'] = cacheDataBase['usedBPMetalExpense'] + usedBPMetalExpense
		cacheDataBase['usedBPEnergyExpense'] = cacheDataBase['usedBPEnergyExpense'] + usedBPEnergyExpense
		cacheDataBase['usedBPExceptStalled'] = cacheDataBase['usedBPExceptStalled'] + nonStalledBuildingBP
		cacheDataBase['usedBPIfNoStall'] = cacheDataBase['usedBPIfNoStall'] + buildingBP
	end

	if not builderCoroutine or co_status(builderCoroutine) == "dead" then
		unitTracking.totalUnits = 0
		for unitID, _ in pairs(trackedBuilders) do
			unitTracking.totalUnits = unitTracking.totalUnits + 1
		end
		local totalFrames = unitTracking.frameCheckInterval
		unitTracking.unitsPerFrame = math_min(unitTracking.maxUnitsPerFrame, math_ceil(unitTracking.totalUnits / totalFrames))
		unitTracking.nextCheckFrame = gameFrame + unitTracking.frameCheckInterval
		updateBPValues()
	end
	if config.drawBPWindRangeIndicators then
		local realWindStrength = 0
		for unitID in pairs(trackedWinds) do
			local metalMake, metalUse, energyMake, energyUse = spGetUnitResources(unitID)
			if energyMake ~= nil then
				realWindStrength = energyMake
				break
			end
		end
		BP['realWindStrength_instant'] = realWindStrength
	end
	calculateAverages()
	updateResbar('BP')
	
	local lowPrioNeededEnergy = spGetTeamRulesParam(myTeamID, "lowPrioNeededEnergy") 
	local lowPrioExpenseEnergy = spGetTeamRulesParam(myTeamID, "lowPrioExpenseEnergy")
	local lowPrioNeededMetal = spGetTeamRulesParam(myTeamID, "lowPrioNeededMetal")
	local lowPrioExpenseMetal = spGetTeamRulesParam(myTeamID, "lowPrioExpenseMetal")
	if lowPrioNeededEnergy and lowPrioExpenseEnergy and lowPrioNeededMetal and lowPrioExpenseMetal then
		stalling['lowPrioEnergy'] = lowPrioNeededEnergy + lowPrioExpenseEnergy
		stalling['lowPrioMetal'] = lowPrioNeededMetal + lowPrioExpenseMetal
	end	
end

local function updateAllyTeamOverflowing()
	allyteamOverflowingMetal = false
	allyteamOverflowingEnergy = false
	overflowingMetal = false
	overflowingEnergy = false
	playerStallingMetal = false
	playerStallingEnergy = false
	local totalEnergy = 0
	local totalEnergyStorage = 0
	local totalMetal = 0
	local totalMetalStorage = 0
	local energyPercentile, metalPercentile
	local teams = Spring.GetTeamList(myAllyTeamID)
	for i, teamID in pairs(teams) do
		local energy, energyStorage, energyPull, _, _, energyShare, energySent = spGetTeamResources(teamID, "energy")
		totalEnergy = totalEnergy + energy
		totalEnergyStorage = totalEnergyStorage + energyStorage
		local metal, metalStorage, metalPull, _, _, metalShare, metalSent = spGetTeamResources(teamID, "metal")
		totalMetal = totalMetal + metal
		totalMetalStorage = totalMetalStorage + metalStorage
		if teamID == myTeamID then
			energyPercentile = energySent / totalEnergyStorage
			metalPercentile = metalSent / totalMetalStorage
			if energyPercentile > 0.0001 then
				overflowingEnergy = energyPercentile * (1 / 0.025)
				if overflowingEnergy > 1 then
					overflowingEnergy = 1
				end
			end
			if metalPercentile > 0.0001 then
				overflowingMetal = metalPercentile * (1 / 0.025)
				if overflowingMetal > 1 then
					overflowingMetal = 1
				end
			end
			if res ~= 'BP' or config.drawBPBar == true then
				local metalIndicatorPos = BP['mSliderPosition']
				local energyIndicatorPos = BP['eSliderPosition']
				playerStallingMetal = (metalIndicatorPos ~= nil and metalIndicatorPos < 0.8 and metal < 2 * metalPull)
				playerStallingEnergy = (energyIndicatorPos ~= nil and energyIndicatorPos < 0.8 and energy < 2 * energyPull)
			end
		end
	end
	energyPercentile = totalEnergy / totalEnergyStorage
	metalPercentile = totalMetal / totalMetalStorage
	if energyPercentile > 0.975 then
		allyteamOverflowingEnergy = (energyPercentile - 0.975) * (1 / 0.025)
		if allyteamOverflowingEnergy > 1 then
			allyteamOverflowingEnergy = 1
		end
	end
	if metalPercentile > 0.975 then
		allyteamOverflowingMetal = (metalPercentile - 0.975) * (1 / 0.025)
		if allyteamOverflowingMetal > 1 then
			allyteamOverflowingMetal = 1
		end
	end
end

local sec = 0
local sec2 = 0
local secComCount = 0
local blinkDirection = true
local blinkProgress = 0

local function hoveringElement(x, y)
	if math_isInRect(x, y, topbarArea[1], topbarArea[2], topbarArea[3], topbarArea[4]) then
		if resbarArea.metal[1] and math_isInRect(x, y, resbarArea.metal[1], resbarArea.metal[2], resbarArea.metal[3], resbarArea.metal[4]) then
			return true
		end
		if resbarArea.energy[1] and math_isInRect(x, y, resbarArea.energy[1], resbarArea.energy[2], resbarArea.energy[3], resbarArea.energy[4]) then
			return true
		end
		if windArea[1] and math_isInRect(x, y, windArea[1], windArea[2], windArea[3], windArea[4]) then
			return true
		end
		if displayTidalSpeed and tidalarea[1] and math_isInRect(x, y, tidalarea[1], tidalarea[2], tidalarea[3], tidalarea[4]) then
			return true
		end
		if displayComCounter and comsArea[1] and math_isInRect(x, y, comsArea[1], comsArea[2], comsArea[3], comsArea[4]) then
			return true
		end
		if buttonsArea[1] and math_isInRect(x, y, buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4]) then
			return true
		end
		return false
	end
	return false
end

function ui.rebuildButtonHover()
	if ui.dlistHover ~= nil then
		glDeleteList(ui.dlistHover)
		ui.dlistHover = nil
	end
	local button = ui.hoverButton
	if not button or not buttonsArea['buttons'] or not buttonsArea['buttons'][button] then
		return
	end
	local mb = ui.hoverPressed
	ui.dlistHover = glCreateList(function()
		local paddingsize = 1
		RectRound(buttonsArea['buttons'][button][1]+paddingsize, buttonsArea['buttons'][button][2]+paddingsize, buttonsArea['buttons'][button][3]-paddingsize, buttonsArea['buttons'][button][4]-paddingsize, 3.5 * widgetScale, 0, 0, 0, button == firstButton and 1 or 0, { 0,0,0, 0.06 })
		glBlending(GL_SRC_ALPHA, GL_ONE)
		RectRound(buttonsArea['buttons'][button][1], buttonsArea['buttons'][button][2], buttonsArea['buttons'][button][3], buttonsArea['buttons'][button][4], 3.5 * widgetScale, 0, 0, 0, button == firstButton and 1 or 0, { 1, 1, 1, mb and 0.13 or 0.03 }, { 0.44, 0.44, 0.44, mb and 0.4 or 0.2 })
		local mult = 1
		RectRound(buttonsArea['buttons'][button][1], buttonsArea['buttons'][button][4] - ((buttonsArea['buttons'][button][4] - buttonsArea['buttons'][button][2]) * 0.4), buttonsArea['buttons'][button][3], buttonsArea['buttons'][button][4], 3.3 * widgetScale, 0, 0, 0, 0, { 1, 1, 1, 0 }, { 1, 1, 1, 0.18 * mult })
		RectRound(buttonsArea['buttons'][button][1], buttonsArea['buttons'][button][2], buttonsArea['buttons'][button][3], buttonsArea['buttons'][button][2] + ((buttonsArea['buttons'][button][4] - buttonsArea['buttons'][button][2]) * 0.25), 3.3 * widgetScale, 0, 0, 0, button == firstButton and 1 or 0, { 1, 1, 1, 0.045 * mult }, { 1, 1, 1, 0 })
		glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
	end)
end

-- hover state for the topbar, the buttons and the quit dialog (was evaluated every rendered frame in DrawScreen)
function ui.updateHover(mx, my, mb)
	hoveringTopbar = hoveringElement(mx, my)

	if config.autoHideButtons then
		if buttonsArea[1] and math_isInRect(mx, my, buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4]) then
			if not showButtons then
				showButtons = true
				dlistButtonsGuishader = glCreateList(function()
					RectRound(buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4], 5.5 * widgetScale, 0,0,1,1)
				end)
				if WG['guishader'] then
					WG['guishader'].InsertDlist(dlistButtonsGuishader, 'topbar_buttons')
				end
			end
		elseif showButtons then
			showButtons = false
			if dlistButtonsGuishader ~= nil then
				if WG['guishader'] then
					WG['guishader'].RemoveDlist('topbar_buttons')
				end
				glDeleteList(dlistButtonsGuishader)
			end
		end
	end

	ui.changelogHasChanges = (WG['changelog'] and WG['changelog'].haschanges()) and true or false

	local newHover = nil
	if not showQuitscreen and buttonsArea['buttons'] ~= nil and buttonsArea[1] and math_isInRect(mx, my, buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4]) then
		for button, pos in pairs(buttonsArea['buttons']) do
			if math_isInRect(mx, my, pos[1], pos[2], pos[3], pos[4]) then
				newHover = button
				break
			end
		end
	end
	local pressed = mb and true or false
	if newHover ~= ui.hoverButton or (newHover and (pressed ~= ui.hoverPressed or ui.dlistHover == nil)) then
		ui.hoverButton = newHover
		ui.hoverPressed = pressed
		ui.rebuildButtonHover()
	end

	local qk = 0
	if showQuitscreen ~= nil and quitscreenStayArea and quitscreenResignArea and quitscreenQuitArea then
		if math_isInRect(mx, my, quitscreenStayArea[1], quitscreenStayArea[2], quitscreenStayArea[3], quitscreenStayArea[4]) then
			qk = 1
		elseif math_isInRect(mx, my, quitscreenResignArea[1], quitscreenResignArea[2], quitscreenResignArea[3], quitscreenResignArea[4]) then
			qk = 2
		elseif math_isInRect(mx, my, quitscreenQuitArea[1], quitscreenQuitArea[2], quitscreenQuitArea[3], quitscreenQuitArea[4]) then
			qk = 3
		end
	end
	ui.quitHoverKey = qk
end

function widget:Update(dt)

	local prevMyTeamID = myTeamID
	if spec and spGetMyTeamID() ~= prevMyTeamID then
		-- check if the team that we are spectating changed
		checkSelfStatus()
		init()
	elseif configHasChanged() then
		init()
	end

	local speedFactor, _, isPaused = Spring.GetGameSpeed()
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

	now = os.clock()
	if now > nextGuishaderCheck and widgetHandler.orderList["GUI Shader"] ~= nil then
		nextGuishaderCheck = now + guishaderCheckUpdateRate
		if guishaderEnabled == false and widgetHandler.orderList["GUI Shader"] ~= 0 then
			guishaderEnabled = true
			init()
		elseif guishaderEnabled and (widgetHandler.orderList["GUI Shader"] == 0) then
			guishaderEnabled = false
		end
	end

	sec = sec + dt
	if sec > 0.033 then
		sec = 0
		local mx, my, mb = spGetMouseState()
		refillResources()
		r.BP = BP
		if not spec and not showQuitscreen then
			if config.drawBPBar == true then
				if math_isInRect(mx, my, resbarArea['BP'][1], resbarArea['BP'][2], resbarArea['BP'][3], resbarArea['BP'][4]) then -- for bp bar only
					if resbarHover == nil then
						resbarHover = 'BP'
						updateResbar('BP')
					end
				elseif resbarHover ~= nil and resbarHover == 'BP' then -- for bp bar only
					resbarHover = nil
					updateResbar('BP')
				end
			end
			if math_isInRect(mx, my, resbarArea['energy'][1], resbarArea['energy'][2], resbarArea['energy'][3], resbarArea['energy'][4]) then
				if resbarHover == nil then
					resbarHover = 'energy'
					updateResbar('energy')
				end
			elseif resbarHover ~= nil and resbarHover == 'energy' then
				resbarHover = nil
				updateResbar('energy')
			end
			if math_isInRect(mx, my, resbarArea['metal'][1], resbarArea['metal'][2], resbarArea['metal'][3], resbarArea['metal'][4]) then
				if resbarHover == nil then
					resbarHover = 'metal'
					updateResbar('metal')
				end
			elseif resbarHover ~= nil and resbarHover == 'metal' then
				resbarHover = nil
				updateResbar('metal')
			end
		elseif spec and myTeamID ~= prevMyTeamID then
			-- check if the team that we are spectating changed
			draggingShareIndicatorValue = {}
			draggingConversionIndicatorValue = nil
			updateResbar('metal')
			updateResbar('energy')
			if config.drawBPBar == true then
				updateResbar('BP')
			end
		else

			-- make sure conversion/overflow sliders are adjusted
			if mmLevel then
				if mmLevel ~= Spring.GetTeamRulesParam(myTeamID, 'mmLevel') or eneryOverflowLevel ~= r['energy'][6] then
					updateResbar('energy')
				end
				if metalOverflowLevel ~= r['metal'][6] then
					updateResbar('metal')
				end
			end
		end

		-- GL4: per-instance values (fill fractions, glow, tints); geometry is not rebuilt
		gl4.updateBarInstances()
		ui.updateHover(mx, my, mb)
	end

	-- current value texts (0.4.010 did this inside DrawScreen, every 0.1 s)
	if os.clock() - updateTextClock > 0.1 then
		updateTextClock = os.clock()
		gl4.updateResValueText('metal')
		gl4.updateResValueText('energy')
		if config.drawBPBar == true then
			gl4.updateResValueText('BP')
		end
	end

	sec2 = sec2 + dt
	if sec2 >= 1 then
		sec2 = 0
		updateResbarText('metal')
		updateResbarText('energy')
		if config.drawBPBar == true then
			updateResbarText('BP')
		end
		updateAllyTeamOverflowing()
	end

	-- wind (0.4.010 re-formatted this every Update because lastFrame was never set)
	if gameFrame ~= lastFrame then
		lastFrame = gameFrame
		currentWind = sformat('%.1f', select(4, spGetWind()))
	end
	if gameFrame > 0 and font2 and windArea[1] and minWind+maxWind >= 0.5 and not TC.wind.lists[currentWind] then
		local fontSize = (height / 2.66) * widgetScale
		local windText = currentWind
		TC.put(TC.wind, windText, glCreateList(function()
			font2:Begin()
			font2:Print("\255\255\255\255" .. windText, windArea[1] + ((windArea[3] - windArea[1]) / 2), windArea[2] + ((windArea[4] - windArea[2]) / 2.05) - (fontSize / 5), fontSize, 'oc') -- Wind speed text
			font2:End()
		end))
	end

	-- coms
	if displayComCounter then
		secComCount = secComCount + dt
		if secComCount > 0.5 then
			secComCount = 0
			countComs()
		end
	end
end

function widget:drawTidal()
	if displayTidalSpeed and tidaldlist1 then
		glPushMatrix()
		glCallList(tidaldlist1)
		glTranslate(tidalarea[1] + ((tidalarea[3] - tidalarea[1]) / 2), math.sin(now/math.pi) * tidalWaveAnimationHeight + tidalarea[2] + (bgpadding/2) + ((tidalarea[4] - tidalarea[2]) / 2), 0)
		glCallList(tidaldlist2)
		glPopMatrix()
	end
end

-- one instanced draw call for a contiguous range of bar instances
function gl4.drawBarRange(first, count, withTextures)
	if count <= 0 then
		return
	end
	if withTextures then
		glTexture(gl4.TEXUNIT_FLOW, gl4.flowTexture)
		glTexture(gl4.TEXUNIT_NOISE, noiseBackgroundTexture)
		glTexture(gl4.TEXUNIT_GLOWCENTER, barGlowCenterTexture)
		glTexture(gl4.TEXUNIT_GLOWEDGE, barGlowEdgeTexture)
	end
	gl4.shader:Activate()
	gl4.shader:SetUniform("viewSize", vsx, vsy)
	gl4.shader:SetUniform("time", gl4.time)
	gl4.shader:SetUniform("blink", blinkProgress)
	gl.Culling(false) -- the quad's winding must not matter
	glBlending(GL_ONE, GL_ONE_MINUS_SRC_ALPHA) -- premultiplied: normal and additive instances in one pass
	gl4.vbo.VAO:DrawArrays(GL.TRIANGLES, gl4.vbo.numVertices, 0, count, first)
	gl4.shader:Deactivate()
	glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
	if withTextures then
		glTexture(gl4.TEXUNIT_FLOW, false)
		glTexture(gl4.TEXUNIT_NOISE, false)
		glTexture(gl4.TEXUNIT_GLOWCENTER, false)
		glTexture(gl4.TEXUNIT_GLOWEDGE, false)
	end
end

local function drawResBars()
	local useGL4 = gl4.vbo ~= nil and gl4.shader ~= nil and gl4.vbo.VAO ~= nil
	if useGL4 then
		if next(gl4.dirty) ~= nil then
			gl4.flush()
		end
		if gl4.vbo.dirty then
			gl4.uploadAllElements(gl4.vbo)
		end
		gl4.time = os.clock()
	end

	glPushMatrix()
	for i = 1, #gl4.RES_DRAW_ORDER do
		local res = gl4.RES_DRAW_ORDER[i]
		if (res ~= 'BP' or config.drawBPBar == true) and dlistResbar[res][1] and dlistResbar[res][3] then
			-- panel + icon (static display list)
			glCallList(dlistResbar[res][1])
			local range = gl4.range[res]
			-- bar background, tints, value bar, glow, flow effect: one instanced draw
			if useGL4 then
				gl4.drawBarRange(range[1], range[2], true)
			end
			-- current value text
			local key = TC.resKey[res]
			local valueList = key and TC.res[res].lists[key]
			if valueList then
				glCallList(valueList)
			end
			if dlistResbar[res][6] then
				glCallList(dlistResbar[res][6])
			end
			glCallList(dlistResbar[res][3])
			-- slider knobs / BP indicators: one instanced draw (above the text, like 0.4.010)
			if useGL4 then
				gl4.drawBarRange(range[3], range[4], false)
			end
		end
	end
	glPopMatrix()
end

function gl4.drawResBarsChecked()
	if gl4.verified then
		drawResBars()
		return true
	end
	-- first frame: make sure the GL4 path really works on this engine / driver
	local ok, err = pcall(drawResBars)
	if ok then
		gl4.verified = true
		return true
	end
	if gl4.shader then
		pcall(gl4.shader.Deactivate, gl4.shader)
	end
	pcall(glPopMatrix)
	glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
	Spring.Echo("Top Bar with Buildpower 0.4.011 gl4: GL4 drawing failed (" .. tostring(err) .. "). Removing this widget - please enable 'Top Bar with Buildpower 0.4.011 light' instead.")
	widgetHandler:RemoveWidget(widget)
	return false
end

function widget:DrawScreen()

	if not gl4.drawResBarsChecked() then
		return
	end

	local now = os.clock()
	-- hover is evaluated in the 30 Hz tick; the cursor has to be set every frame though
	if hoveringTopbar then
		Spring.SetMouseCursor('cursornormal')
	end

	if dlistWind1 and dlistWind2 then
		glPushMatrix()
			glCallList(dlistWind1)
			glRotate(windRotation, 0, 0, 1)
			glCallList(dlistWind2)
		glPopMatrix()

		-- current wind
		if gameFrame > 0 then
			if minWind+maxWind >= 0.5 then
				local windList = TC.wind.lists[currentWind]
				if windList then
					glCallList(windList)
				end
			end
		end
	end

	self:drawTidal()

	glPushMatrix()
	if displayComCounter and dlistComs1 then
		glCallList(dlistComs1)
		if allyComs == 1 and (gameFrame % 12 < 6) then
			glColor(1, 0.6, 0, 0.45)
		else
			glColor(1, 1, 1, 0.22)
		end
		glCallList(dlistComs2)
	end

	if showButtons and dlistButtons1 and buttonsArea['buttons'] then
		glCallList(dlistButtons1)

		-- changelog changes highlight
		if ui.changelogHasChanges and ui.dlistChangelog then
			glColor(1, 1, 1, 0.1 * blinkProgress)
			glCallList(ui.dlistChangelog)
		end

		-- hovered? (list rebuilt in the tick when the hovered button / mouse button state changes)
		if not showQuitscreen and ui.hoverButton and ui.dlistHover then
			glCallList(ui.dlistHover)
		end
		glCallList(dlistButtons2)
	end

	if showQuitscreen == nil then
		if dlistQuit ~= nil then
			if WG['guishader'] then
				WG['guishader'].removeRenderDlist(dlistQuit)
			end
			glDeleteList(dlistQuit)
			dlistQuit = nil
		end
	else
		local fadeoutBonus = 0
		local fadeTime = 0.2
		local fadeProgress = (now - showQuitscreen) / fadeTime
		if fadeProgress > 1 then
			fadeProgress = 1
		end

		Spring.SetMouseCursor('cursornormal')

		-- rebuild at most 30x per second while fading in, afterwards only when the hovered button changes
		local rebuild = dlistQuit == nil or ui.quitBuiltFor ~= showQuitscreen or ui.quitBuiltHoverKey ~= ui.quitHoverKey
		if not rebuild and ui.quitBuiltFade < 1 and (now - ui.quitBuiltClock) >= ui.quitRebuildInterval then
			rebuild = true
		end
		if rebuild then
			if dlistQuit ~= nil then
				if WG['guishader'] then
					WG['guishader'].removeRenderDlist(dlistQuit)
				end
				glDeleteList(dlistQuit)
				dlistQuit = nil
			end
			ui.quitBuiltFor = showQuitscreen
			ui.quitBuiltHoverKey = ui.quitHoverKey
			ui.quitBuiltClock = now
			ui.quitBuiltFade = fadeProgress
			local mx, my = spGetMouseState()

			dlistQuit = glCreateList(function()
				if WG['guishader'] then
					glColor(0, 0, 0, (0.18 * fadeProgress))
				else
					glColor(0, 0, 0, (0.35 * fadeProgress))
				end
				glRect(0, 0, vsx, vsy)

				if hideQuitWindow == nil then
					-- when terminating spring, keep the faded screen

					local w = math_floor(320 * widgetScale)
					local h = math_floor(w / 3.5)

					local fontSize = h / 6
					local text = Spring.I18N('ui.topbar.quit.reallyQuit')
					if not spec then
						text = Spring.I18N('ui.topbar.quit.reallyQuitResign')
						if not gameIsOver and chobbyLoaded then
							if numPlayers < 3 then
								text = Spring.I18N('ui.topbar.quit.reallyResign')
							else
								text = Spring.I18N('ui.topbar.quit.reallyResignSpectate')
							end
						end
					end
					local padding = math_floor(w / 90)
					local textTopPadding = padding + padding + padding + padding + padding + fontSize
					local txtWidth = font:GetTextWidth(text) * fontSize
					w = math.max(w, txtWidth + textTopPadding + textTopPadding)

					local x = math_floor((vsx / 2) - (w / 2))
					local y = math_floor((vsy / 1.8) - (h / 2))
					local buttonMargin = math_floor(h / 9)
					local buttonWidth = math_floor((w - buttonMargin * 4) / 3) -- 4 margins for 3 buttons
					local buttonHeight = math_floor(h * 0.30)

					quitscreenArea = {
						x, 
						y, 
						x + w, 
						y + h
					}
					quitscreenStayArea = {
						x + buttonMargin + 0 * (buttonWidth + buttonMargin), 
						y + buttonMargin, 
						x + buttonMargin + 0 * (buttonWidth + buttonMargin) + buttonWidth, 
						y + buttonMargin + buttonHeight
					}
					quitscreenResignArea = {
						x + buttonMargin + 1 * (buttonWidth + buttonMargin), 
						y + buttonMargin, 
						x + buttonMargin + 1 * (buttonWidth + buttonMargin) + buttonWidth, 
						y + buttonMargin + buttonHeight
					}
					quitscreenQuitArea = {
						x + buttonMargin + 2 * (buttonWidth + buttonMargin), 
						y + buttonMargin, 
						x + buttonMargin + 2 * (buttonWidth + buttonMargin) + buttonWidth, 
						y + buttonMargin + buttonHeight
					}

					-- window
					UiElement(quitscreenArea[1], quitscreenArea[2], quitscreenArea[3], quitscreenArea[4], 1,1,1,1, 1,1,1,1, nil, {1, 1, 1, 0.6 + (0.34 * fadeProgress)}, {0.45, 0.45, 0.4, 0.025 + (0.025 * fadeProgress)})

					local color1, color2

					font:Begin()
					font:SetTextColor(0, 0, 0, 1)
					font:Print(text, quitscreenArea[1] + ((quitscreenArea[3] - quitscreenArea[1]) / 2), quitscreenArea[4]-textTopPadding, fontSize, "cn")
					font:End()

					font2:Begin()
					font2:SetTextColor(1, 1, 1, 1)
					font2:SetOutlineColor(0, 0, 0, 0.23)

					fontSize = fontSize * 0.92

					-- stay button
					if gameIsOver or not chobbyLoaded then
						if math_isInRect(mx, my, quitscreenStayArea[1], quitscreenStayArea[2], quitscreenStayArea[3], quitscreenStayArea[4]) then
							color1 = { 0, 0.4, 0, 0.4 + (0.5 * fadeProgress) }
							color2 = { 0.05, 0.6, 0.05, 0.4 + (0.5 * fadeProgress) }
						else
							color1 = { 0, 0.25, 0, 0.35 + (0.5 * fadeProgress) }
							color2 = { 0, 0.5, 0, 0.35 + (0.5 * fadeProgress) }
						end
						UiButton(quitscreenStayArea[1], quitscreenStayArea[2], quitscreenStayArea[3], quitscreenStayArea[4], 1,1,1,1, 1,1,1,1, nil, color1, color2, padding * 0.5)
						font2:Print(Spring.I18N('ui.topbar.quit.stay'), quitscreenStayArea[1] + ((quitscreenStayArea[3] - quitscreenStayArea[1]) / 2), quitscreenStayArea[2] + ((quitscreenStayArea[4] - quitscreenStayArea[2]) / 2) - (fontSize / 3), fontSize, "con")
					end

					-- resign button
					if not spec and not gameIsOver then
						if math_isInRect(mx, my, quitscreenResignArea[1], quitscreenResignArea[2], quitscreenResignArea[3], quitscreenResignArea[4]) then
							color1 = { 0.28, 0.28, 0.28, 0.4 + (0.5 * fadeProgress) }
							color2 = { 0.45, 0.45, 0.45, 0.4 + (0.5 * fadeProgress) }
						else
							color1 = { 0.18, 0.18, 0.18, 0.4 + (0.5 * fadeProgress) }
							color2 = { 0.33, 0.33, 0.33, 0.4 + (0.5 * fadeProgress) }
						end
						UiButton(quitscreenResignArea[1], quitscreenResignArea[2], quitscreenResignArea[3], quitscreenResignArea[4], 1,1,1,1, 1,1,1,1, nil, color1, color2, padding * 0.5)
						font2:Print(Spring.I18N('ui.topbar.quit.resign'), quitscreenResignArea[1] + ((quitscreenResignArea[3] - quitscreenResignArea[1]) / 2), quitscreenResignArea[2] + ((quitscreenResignArea[4] - quitscreenResignArea[2]) / 2) - (fontSize / 3), fontSize, "con")
					end

					-- quit button
					if gameIsOver or not chobbyLoaded then
						if math_isInRect(mx, my, quitscreenQuitArea[1], quitscreenQuitArea[2], quitscreenQuitArea[3], quitscreenQuitArea[4]) then
							color1 = { 0.4, 0, 0, 0.4 + (0.5 * fadeProgress) }
							color2 = { 0.6, 0.05, 0.05, 0.4 + (0.5 * fadeProgress) }
						else
							color1 = { 0.25, 0, 0, 0.35 + (0.5 * fadeProgress) }
							color2 = { 0.5, 0, 0, 0.35 + (0.5 * fadeProgress) }
						end
						UiButton(quitscreenQuitArea[1], quitscreenQuitArea[2], quitscreenQuitArea[3], quitscreenQuitArea[4], 1,1,1,1, 1,1,1,1, nil, color1, color2, padding * 0.5)
						font2:Print(Spring.I18N('ui.topbar.quit.quit'), quitscreenQuitArea[1] + ((quitscreenQuitArea[3] - quitscreenQuitArea[1]) / 2), quitscreenQuitArea[2] + ((quitscreenQuitArea[4] - quitscreenQuitArea[2]) / 2) - (fontSize / 3), fontSize, "con")
					end

					font2:End()
				end
			end)

			-- background
			if WG['guishader'] then
				WG['guishader'].setScreenBlur(true)
				WG['guishader'].insertRenderDlist(dlistQuit)
			end
		end
		if not WG['guishader'] then
			glCallList(dlistQuit)
		end
	end
	glColor(1, 1, 1, 1)
	glPopMatrix()
end

local function adjustSliders(x, y)
	if draggingShareIndicator ~= nil and not spec then
		local shareValue = (x - resbarDrawinfo[draggingShareIndicator]['barArea'][1]) / (resbarDrawinfo[draggingShareIndicator]['barArea'][3] - resbarDrawinfo[draggingShareIndicator]['barArea'][1])
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
		local convValue = math_floor((x - resbarDrawinfo['energy']['barArea'][1]) / (resbarDrawinfo['energy']['barArea'][3] - resbarDrawinfo['energy']['barArea'][1]) * 100)
		if convValue < 12 then
			convValue = 12
		end
		if convValue > 88 then
			convValue = 88
		end
		Spring.SendLuaRulesMsg(sformat(string.char(137) .. '%i', convValue))
		draggingConversionIndicatorValue = convValue
		updateResbar('energy')
	end
end

function widget:MouseMove(x, y)
	adjustSliders(x, y)
end

local function hideWindows()
	local closedWindow = false
	if WG['options'] ~= nil and WG['options'].isvisible() then
		WG['options'].toggle(false)
		closedWindow = true
	end
	if WG['scavengerinfo'] ~= nil and WG['scavengerinfo'].isvisible() then
		WG['scavengerinfo'].toggle(false)
		closedWindow = true
	end
	if WG['keybinds'] ~= nil and WG['keybinds'].isvisible() then
		WG['keybinds'].toggle(false)
		closedWindow = true
	end
	if WG['changelog'] ~= nil and WG['changelog'].isvisible() then
		WG['changelog'].toggle(false)
		closedWindow = true
	end
	if WG['gameinfo'] ~= nil and WG['gameinfo'].isvisible() then
		WG['gameinfo'].toggle(false)
		closedWindow = true
	end
	if WG['teamstats'] ~= nil and WG['teamstats'].isvisible() then
		WG['teamstats'].toggle(false)
		closedWindow = true
	end
	if WG['widgetselector'] ~= nil and WG['widgetselector'].isvisible() then
		WG['widgetselector'].toggle(false)
		closedWindow = true
	end
	if showQuitscreen then
		closedWindow = true
	end
	showQuitscreen = nil
	if WG['guishader'] then
		WG['guishader'].setScreenBlur(false)
	end

	if gameIsOver then -- Graphs window can only be open after game end
		-- Closing Graphs window if open, no way to tell if it was open or not
		Spring.SendCommands('endgraph 0')
		graphsWindowVisible = false
	end

	return closedWindow
end

local function applyButtonAction(button)

	if playSounds then
		Spring.PlaySoundFile(leftclick, 0.8, 'ui')
	end

	local isvisible = false
	if button == 'quit' or button == 'resign' then
		if not gameIsOver and chobbyLoaded and button == 'quit' then
			Spring.SendLuaMenuMsg("showLobby")
		else
			local oldShowQuitscreen
			if showQuitscreen ~= nil then
				oldShowQuitscreen = showQuitscreen
				isvisible = true
			end
			hideWindows()
			if oldShowQuitscreen ~= nil then
				if isvisible ~= true then
					showQuitscreen = oldShowQuitscreen
					if WG['guishader'] then
						WG['guishader'].setScreenBlur(true)
					end
				end
			else
				showQuitscreen = os.clock()
			end
		end
	elseif button == 'options' then
		if WG['options'] ~= nil then
			isvisible = WG['options'].isvisible()
		end
		hideWindows()
		if WG['options'] ~= nil and isvisible ~= true then
			WG['options'].toggle()
		end
	elseif button == 'save' then
		if isSinglePlayer and allowSavegame and WG['savegame'] ~= nil then
			--local gameframe = Spring.GetGameFrame()
			--local minutes = math.floor((gameframe / 30 / 60))
			--local seconds = math.floor((gameframe - ((minutes*60)*30)) / 30)
			--if seconds == 0 then
			--	seconds = '00'
			--elseif seconds < 10 then
			--	seconds = '0'..seconds
			--end
			local time = os.date("%Y%m%d_%H%M%S")
			Spring.SendCommands("savegame "..time)
		end
	elseif button == 'scavengers' then
		if WG['scavengerinfo'] ~= nil then
			isvisible = WG['scavengerinfo'].isvisible()
		end
		hideWindows()
		if WG['scavengerinfo'] ~= nil and isvisible ~= true then
			WG['scavengerinfo'].toggle()
		end
	elseif button == 'keybinds' then
		if WG['keybinds'] ~= nil then
			isvisible = WG['keybinds'].isvisible()
		end
		hideWindows()
		if WG['keybinds'] ~= nil and isvisible ~= true then
			WG['keybinds'].toggle()
		end
	elseif button == 'changelog' then
		if WG['changelog'] ~= nil then
			isvisible = WG['changelog'].isvisible()
		end
		hideWindows()
		if WG['changelog'] ~= nil and isvisible ~= true then
			WG['changelog'].toggle()
		end
	elseif button == 'stats' then
		if WG['teamstats'] ~= nil then
			isvisible = WG['teamstats'].isvisible()
		end
		hideWindows()
		if WG['teamstats'] ~= nil and isvisible ~= true then
			WG['teamstats'].toggle()
		end
	elseif button == 'graphs' then
		isvisible = graphsWindowVisible
		hideWindows()
		if gameIsOver and not isvisible then
			Spring.SendCommands('endgraph 2')
			graphsWindowVisible = true
		end
	end
end

function widget:GameOver()
	gameIsOver = true
	updateButtons()
end

function widget:MouseWheel(up, value)
	--up = true/false , value = -1/1
	if showQuitscreen ~= nil and quitscreenArea ~= nil then
		return true
	end
end

function widget:KeyPress(key)
	if key == 27 then
		-- ESC
		if not WG['options'] or (WG['options'].disallowEsc and not WG['options'].disallowEsc()) then
			local escDidSomething = hideWindows()
			if escapeKeyPressesQuit and not escDidSomething then
				applyButtonAction('quit')
			end
		end
	end
	if showQuitscreen ~= nil and quitscreenArea ~= nil then
		return true
	end
end

function widget:MousePress(x, y, button)
	if button == 1 then
		if showQuitscreen ~= nil and quitscreenArea ~= nil then

			if math_isInRect(x, y, quitscreenArea[1], quitscreenArea[2], quitscreenArea[3], quitscreenArea[4]) then
				if (gameIsOver or not chobbyLoaded or not spec) and math_isInRect(x, y, quitscreenStayArea[1], quitscreenStayArea[2], quitscreenStayArea[3], quitscreenStayArea[4]) then
					if playSounds then
						Spring.PlaySoundFile(leftclick, 0.75, 'ui')
					end
					showQuitscreen = nil
					if WG['guishader'] then
						WG['guishader'].setScreenBlur(false)
					end
				end
				if (gameIsOver or not chobbyLoaded) and math_isInRect(x, y, quitscreenQuitArea[1], quitscreenQuitArea[2], quitscreenQuitArea[3], quitscreenQuitArea[4]) then
					if playSounds then
						Spring.PlaySoundFile(leftclick, 0.75, 'ui')
					end
					if not chobbyLoaded then
						Spring.SendCommands("QuitForce") -- Exit the game completely
					else
						Spring.SendCommands("ReloadForce") -- Exit to the lobby
					end
					showQuitscreen = nil
					hideQuitWindow = os.clock()
				end
				if not spec and not gameIsOver and math_isInRect(x, y, quitscreenResignArea[1], quitscreenResignArea[2], quitscreenResignArea[3], quitscreenResignArea[4]) then
					if playSounds then
						Spring.PlaySoundFile(leftclick, 0.75, 'ui')
					end
					Spring.SendCommands("spectator")
					showQuitscreen = nil
					if WG['guishader'] then
						WG['guishader'].setScreenBlur(false)
					end
				end
			else
				showQuitscreen = nil
				if WG['guishader'] then
					WG['guishader'].setScreenBlur(false)
				end
			end
			return true
		end

		if not spec then
			if not isSingle then
				if math_isInRect(x, y, shareIndicatorArea['metal'][1], shareIndicatorArea['metal'][2], shareIndicatorArea['metal'][3], shareIndicatorArea['metal'][4]) then
					draggingShareIndicator = 'metal'
				end
				if math_isInRect(x, y, shareIndicatorArea['energy'][1], shareIndicatorArea['energy'][2], shareIndicatorArea['energy'][3], shareIndicatorArea['energy'][4]) then
					draggingShareIndicator = 'energy'
				end
			end
			if draggingShareIndicator == nil and math_isInRect(x, y, conversionIndicatorArea[1], conversionIndicatorArea[2], conversionIndicatorArea[3], conversionIndicatorArea[4]) then
				draggingConversionIndicator = true
			end
			if draggingShareIndicator or draggingConversionIndicator then
				if playSounds then
					Spring.PlaySoundFile(resourceclick, 0.7, 'ui')
				end
				return true
			end
		end

		if buttonsArea['buttons'] ~= nil then
			for button, pos in pairs(buttonsArea['buttons']) do
				if math_isInRect(x, y, pos[1], pos[2], pos[3], pos[4]) then
					applyButtonAction(button)
					return true
				end
			end
		end
	else
		if showQuitscreen ~= nil and quitscreenArea ~= nil then
			return true
		end
	end

	hoveringTopbar = hoveringElement(x, y) -- hover is otherwise only refreshed by the 30 Hz tick
	if hoveringTopbar then
		return true
	end
end

function widget:MouseRelease(x, y, button)
	if showQuitscreen ~= nil and quitscreenArea ~= nil then
		return true
	end
	if draggingShareIndicator ~= nil then
		adjustSliders(x, y)
		draggingShareIndicator = nil
	end
	if draggingConversionIndicator ~= nil then
		adjustSliders(x, y)
		draggingConversionIndicator = nil
	end

end

function widget:PlayerChanged()
	local prevSpec = spec
	spec = spGetSpectatingState()
	checkSelfStatus()
	numTeamsInAllyTeam = #Spring.GetTeamList(myAllyTeamID)
	InitAdditionalValues()
	if displayComCounter then
		countComs(true)
	end
	if spec then
		resbarHover = nil
	end
	if not prevSpec and prevSpec ~= spec then
		init()
	end
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
	if not isCommander[unitDefID] then
		return
	end
	--record com created
	if select(6, Spring.GetTeamInfo(unitTeam, false)) == myAllyTeamID then
		allyComs = allyComs + 1
	elseif spec then
		enemyComs = enemyComs + 1
	end
	comcountChanged = true
end

function widget:UnitTaken(unitID, unitDefID, unitTeam)
	UntrackUnit(unitID, unitDefID, unitTeam)
end

function widget:UnitGiven(unitID, unitDefID, unitTeam)
	TrackUnit(unitID, unitDefID, unitTeam)
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	TrackUnit(unitID, unitDefID, unitTeam)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)	
	UntrackUnit(unitID, unitDefID, unitTeam)
	if not isCommander[unitDefID] then
		return
	end
	--record com died
	if select(6, Spring.GetTeamInfo(unitTeam, false)) == myAllyTeamID then
		allyComs = allyComs - 1
	elseif spec then
		enemyComs = enemyComs - 1
	end
	comcountChanged = true
end

function widget:LanguageChanged()
	updateButtons()
end

function widget:Initialize()
	-- GL4 renderer first: if it is not available, say so and leave without touching anything else
	local gl4ok, gl4err = gl4.init()
	if not gl4ok then
		Spring.Echo("Top Bar with Buildpower 0.4.011 gl4: GL4 renderer unavailable (" .. tostring(gl4err) .. "). Removing this widget - please enable 'Top Bar with Buildpower 0.4.011 light' (F11 widget list) instead.")
		gl4.shutdown()
		gl4.initFailed = true -- Shutdown must not touch WG['topbar'] / options / tooltips we never set up
		widgetHandler:RemoveWidget(widget)
		return
	end
if widgetHandler:IsWidgetKnown("Top Bar") then
		--widgetHandler:DisableWidget("Top Bar")
	end
	if WG['options'] then
		for _, optionSpec in ipairs(OPTION_SPECS) do
			addOptionFromSpec(optionSpec)
		end
	end
	gameFrame = Spring.GetGameFrame()
	Spring.SendCommands("resbar 0")


	-- determine if we want to show comcounter
	local allteams = Spring.GetTeamList()
	local teamN = table.maxn(allteams) - 1               --remove gaia
	if teamN > 2 then
		displayComCounter = true
	end

	WG['topbar'] = {}
	WG['topbar'].showingQuit = function()
		return (showQuitscreen)
	end
	WG['topbar'].hideWindows = function()
		hideWindows()
	end
	WG['topbar'].setAutoHideButtons = function(value)
		config.autoHideButtons = value
		showButtons = not value
		updateButtons()
	end
	WG['topbar'].getAutoHideButtons = function()
		return config.autoHideButtons
	end
	WG['topbar'].getShowButtons = function()
		return showButtons
	end
	
	WG['topbar'].updateTopBarEnergy = function(value)
		draggingConversionIndicatorValue = value
		updateResbar('energy')
	end

	widget:ViewResize()

	InitAdditionalValues()
	for unitDefID, unitDef in pairs(UnitDefs) do -- fill unitCostData this is needed for exact calculations
		local energy = unitDef.energyCost
		unitCostData[unitDefID] = {
			buildTime = unitDef.buildTime, 
			energy = unitDef.energyCost, 
			metal = unitDef.metalCost, 
			EperBP = unitDef.energyCost/unitDef.buildTime, 
			MperBP = unitDef.metalCost/unitDef.buildTime
		}
		local unitName = UnitDefs[unitDefID].name
	end

	if gameFrame > 0 then
		widget:GameStart()
	end

	if WG['resource_spot_finder'] and WG['resource_spot_finder'].metalSpotsList and #WG['resource_spot_finder'].metalSpotsList > 0 and #WG['resource_spot_finder'].metalSpotsList <= 2 then	-- probably speedmetal kind of map
		isMetalmap = true
	end
end

function shutdown()
	if dlistButtons1 ~= nil then
		dlistWindGuishader = glDeleteList(dlistWindGuishader)
		dlistTidalGuishader = glDeleteList(dlistTidalGuishader)
		dlistWind1 = glDeleteList(dlistWind1)
		dlistWind2 = glDeleteList(dlistWind2)
		tidaldlist1 = glDeleteList(tidaldlist1)
		tidaldlist2 = glDeleteList(tidaldlist2)
		dlistComsGuishader = glDeleteList(dlistComsGuishader)
		dlistComs1 = glDeleteList(dlistComs1)
		dlistComs2 = glDeleteList(dlistComs2)
		dlistButtonsGuishader = glDeleteList(dlistButtonsGuishader)
		dlistButtons1 = glDeleteList(dlistButtons1)
		dlistButtons2 = glDeleteList(dlistButtons2)
		dlistQuit = glDeleteList(dlistQuit)

		for n, _ in pairs(dlistResbar['metal']) do
			dlistResbar['metal'][n] = glDeleteList(dlistResbar['metal'][n])
		end
		for n, _ in pairs(dlistResbar['energy']) do
			dlistResbar['energy'][n] = glDeleteList(dlistResbar['energy'][n])
		end
		if config.drawBPBar == true then
			for n, _ in pairs(dlistResbar['BP']) do
				dlistResbar['BP'][n] = glDeleteList(dlistResbar['BP'][n])
			end
		end
	end
	-- text caches and highlight lists exist independently of dlistButtons1
	TC.clear(TC.wind)
	for res, cache in pairs(TC.res) do
		TC.clear(cache)
	end
	if ui.dlistHover ~= nil then
		glDeleteList(ui.dlistHover)
		ui.dlistHover = nil
	end
	if ui.dlistChangelog ~= nil then
		glDeleteList(ui.dlistChangelog)
		ui.dlistChangelog = nil
	end
	if dlistQuit ~= nil then
		if WG['guishader'] and WG['guishader'].removeRenderDlist then
			WG['guishader'].removeRenderDlist(dlistQuit)
		end
		glDeleteList(dlistQuit)
		dlistQuit = nil
	end
	gl4.shutdown()
	if WG['guishader'] then
		WG['guishader'].RemoveDlist('topbar_energy')
		WG['guishader'].RemoveDlist('topbar_metal')
		WG['guishader'].RemoveDlist('topbar_wind')
		WG['guishader'].RemoveDlist('topbar_coms')
		WG['guishader'].RemoveDlist('topbar_buttons')
	end
	if WG['tooltip'] ~= nil then
		WG['tooltip'].RemoveTooltip('coms')
		WG['tooltip'].RemoveTooltip('wind')
		local res = 'energy'
		WG['tooltip'].RemoveTooltip(res .. '_share_slider')
		WG['tooltip'].RemoveTooltip(res .. '_share_slider2')
		WG['tooltip'].RemoveTooltip(res .. '_metalmaker_slider')
		WG['tooltip'].RemoveTooltip(res .. '_pull')
		WG['tooltip'].RemoveTooltip(res .. '_income')
		WG['tooltip'].RemoveTooltip(res .. '_storage')
		WG['tooltip'].RemoveTooltip(res .. '_current')
		res = 'metal'
		WG['tooltip'].RemoveTooltip(res .. '_share_slider')
		WG['tooltip'].RemoveTooltip(res .. '_share_slider2')
		WG['tooltip'].RemoveTooltip(res .. '_pull')
		WG['tooltip'].RemoveTooltip(res .. '_income')
		WG['tooltip'].RemoveTooltip(res .. '_storage')
		WG['tooltip'].RemoveTooltip(res .. '_current')
	end	
	if WG['options'] ~= nil then
		for _, option in ipairs(OPTION_SPECS) do
			WG['options'].removeOption("top_bar_bp_" .. option.configVariable)
		end
	end
end

function widget:Shutdown()
	if gl4.initFailed then
		gl4.shutdown()
		return
	end
	--Spring.SendCommands("resbar 1")
	if widgetHandler:IsWidgetKnown("Top Bar") then
		--widgetHandler:EnableWidget("Top Bar")
	end
	shutdown()
	WG['topbar'] = nil
end

function TrackUnit(unitID, unitDefID, unitTeam) --needed for exact calculations
	if (myTeamID == unitTeam) then
		local unitDef = UnitDefs[unitDefID]
		local _, _, _, _, build = Spring.GetUnitHealth(unitID) --is it finished?
		local isBuilt = build >= 1
		if isBuilt and unitDef then
			local name = unitDef.name
			local isNano = name:find("nano")
			if unitDef.buildSpeed and unitDef.buildSpeed > 0 and unitDef.canAssist or unitDef.isFactory then
				unitTracking.trackedNum = unitTracking.trackedNum + 1
				local unitType = "builder"
				if not unitDef.isFactory then
					if isNano then
						unitType = "nano"
					end
				else
					unitType = "factory"
				end
				if not trackedBuilders[unitID] then				-- We may have already tracked this unit when it started being built. No need to add its BP again.
					BP[4] = BP[4] + unitDef.buildSpeed -- BP[4] ^= totalAvailableBP
				end
				trackedBuilders[unitID] = {
					buildSpeed = unitDef.buildSpeed,
					isBuilt = isBuilt,
					unitDefID = unitDefID,
					unitTeamID = unitTeam,
					unitType = unitType
				}
			elseif unitDef.name == "armwin" or unitDef.name == "corwin" then -- wind generator
				trackedWinds[unitID] = 1
				numWindGenerators = numWindGenerators + 1
			end
		end
	end
end

function UntrackUnit(unitID, unitDefID, unitTeam) -- needed for exact calculations
	local unitDef = UnitDefs[unitDefID]
	if (myTeamID == unitTeam) and unitDef then
		if trackedBuilders[unitID] then
			if unitDef.buildSpeed and unitDef.buildSpeed > 0 and unitDef.canAssist or UnitDefs[unitDefID].isFactory then
				unitTracking.trackedNum = unitTracking.trackedNum - 1
				BP[4] = BP[4] - trackedBuilders[unitID].buildSpeed -- BP[4] ^= totalAvailableBP
			end
		end
		if trackedBuilders[unitID] then
			 trackedBuilders[unitID] = nil
		end
		if trackedWinds[unitID] then
			trackedWinds[unitID] = nil
			numWindGenerators = numWindGenerators - 1
		end
	end
end

function InitAdditionalValues()
	BP[4] = 0
	unitTracking.trackedNum = 0
	trackedBuilders = {}
	trackedWinds = {}
	numWindGenerators = 0

	for _, unitID in pairs(Spring.GetTeamUnits(myTeamID)) do  -- needed for exact calculations
		TrackUnit(unitID, Spring.GetUnitDefID(unitID), myTeamID)
	end
end
