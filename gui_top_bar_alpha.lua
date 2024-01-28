function widget:GetInfo()
	return {
		name = "Top Bar alpha 1", 
		desc = "Shows Resources, wind speed, commander counter, and various options.", 
		author = "Floris and Floris and Floris and Robert82", 
		date = "Feb, 2017", 
		license = "GNU GPL, v2 or later", 
		layer = -999999, 
		enabled = true, --enabled by default
		handler = true, --can use widgetHandler:x()
	}
end
local Debugmode = false
function Log(Message)
	if Debugmode==true then
		Spring.Echo(Message)
	end
end
local Debugmode1 = true
function Log1(Message)
	if Debugmode1 == true then
		Spring.Echo(Message)
	end
end
-- for bp bar only
local metalCostForCommander = 1250 
local includeFactories = true 
local proMode = true
local drawBPBar = true
local drawBPIndicators = true

-- needed for exact calculations
local initData = {0, 0, 0.1, 0, 0, 1, 1, 1, 1}

local totalUsedBPData = {} -- used to calculate the avarage used BP
local totalReservedBPData = {} -- used to calculate the avarage reserved BP

local unitsPerFrame = 100 --limit processed units per frame to improve performance
local trackedNum = 0
local nowChecking = 0
local trackPosBase = 0 -- will start the next checks from here
local cacheDataBase = {0, 0, 0.1, 0, 0, 1, 1, 1, 1} -- gives the data to the next calc frame
local trackedBuilders = {} -- stores units of the player and theit BP

local spSetUnitBuildSpeed = Spring.SetUnitBuildSpeed
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spGetUnitDefID = Spring.GetUnitDefID

local unitCostData = {} --data of all units regarding the building costs, M/BP and E/BP
local totalStallingM = 0
local totalStallingE = 0
local addStalling = true

local CMD_PRIORITY = 34571 --low prio builders

local BP = initData -- stores the date that is used for the res calc and BP bar

-- build power/ res calc entries end here

local allowSavegame = true--Spring.Utilities.ShowDevUI()

local ui_scale = 0.85 tonumber(Spring.GetConfigFloat("ui_scale", 1) or 1) -- xxx 

local fontfile = "fonts/" .. Spring.GetConfigString("bar_font", "Poppins-Regular.otf")
local fontfile2 = "fonts/" .. Spring.GetConfigString("bar_font2", "Exo2-SemiBold.otf")

local textWarnColor = "\255\255\215\215"

local vsx, vsy = Spring.GetViewGeometry()

local orgHeight = 46
local height = orgHeight * (1 + (ui_scale - 1) / 1.7)

local escapeKeyPressesQuit = false

local relXpos = 0.3 
if drawBPBar == true then
   relXpos = 0.3
end


local borderPadding = 5
local bladeSpeedMultiplier = 0.2

local wholeTeamWastingMetalCount = 0

local noiseBackgroundTexture = ":g:LuaUI/Images/rgbnoise.png"
local showButtons = true
local autoHideButtons = false

local playSounds = true
local leftclick = 'LuaUI/Sounds/tock.wav'
local resourceclick = 'LuaUI/Sounds/buildbar_click.wav'

local barGlowCenterTexture = ":l:LuaUI/Images/barglow-center.png"
local barGlowEdgeTexture = ":l:LuaUI/Images/barglow-edge.png"
local bladesTexture = ":n:LuaUI/Images/wind-blades.png"
local wavesTexture = ":n:LuaUI/Images/tidal-waves.png"
local comTexture = ":n:Icons/corcom.png"		-- will be changed later to unit icon depending on faction

local math_ceil = math.ceil
local math_floor = math.floor
local math_min = math.min
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

local spGetSpectatingState = Spring.GetSpectatingState
local spGetTeamResources = Spring.GetTeamResources
local spGetMyTeamID = Spring.GetMyTeamID
local spGetMouseState = Spring.GetMouseState
local spGetWind = Spring.GetWind

local isMetalmap = false

local widgetSpaceMargin, bgpadding, RectRound, TexturedRectRound, UiElement, UiButton, UiSliderKnob

local gaiaTeamID = Spring.GetGaiaTeamID()
local spec = spGetSpectatingState()
local myAllyTeamID = Spring.GetMyAllyTeamID()
local myTeamID = Spring.GetMyTeamID()
local myPlayerID = Spring.GetMyPlayerID()

comTexture = ':n:Icons/'..UnitDefs[Spring.GetTeamRulesParam(myTeamID, 'startUnit')].name..'.png'

local myAllyTeamList = Spring.GetTeamList(myAllyTeamID)
local numTeamsInAllyTeam = #myAllyTeamList

local function checkPriority(unitID) -- needed for exact calculations
    -- Check if the "priority" command is set to "High Priority" or "Low Priority"
    local cmdDescID = Spring.FindUnitCmdDesc(unitID, CMD_PRIORITY)
    if cmdDescID then
        local cmdDesc = Spring.GetUnitCmdDescs(unitID, cmdDescID, cmdDescID)[1]
        if cmdDesc then
            if cmdDesc.params[1] == "1" then
                return "high"  -- The unit is set to "High Priority"
            elseif cmdDesc.params[1] == "0" then
                return "low"  -- The unit is set to "Low Priority"
            end
        end
    end
    return nil  -- The unit does not have these settings
end


local supressOverflowNotifs = false
for _, teamID in ipairs(myAllyTeamList) do
	if select(4, Spring.GetTeamInfo(teamID, false)) then	-- is AI?
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
local avgWind = {[0] = {[1] = "0.8", [2] = "1.5", [3] = "2.2", [4] = "3.0", [5] = "3.7", [6] = "4.5", [7] = "5.2", [8] = "6.0", [9] = "6.7", [10] = "7.5", [11] = "8.2", [12] = "9.0", [13] = "9.7", [14] = "10.4", [15] = "11.2", [16] = "11.9", [17] = "12.7", [18] = "13.4", [19] = "14.2", [20] = "14.9", [21] = "15.7", [22] = "16.4", [23] = "17.2", [24] = "17.9", [25] = "18.6", [26] = "19.2", [27] = "19.6", [28] = "20.0", [29] = "20.4", [30] = "20.7", }, [1] = {[2] = "1.6", [3] = "2.3", [4] = "3.0", [5] = "3.8", [6] = "4.5", [7] = "5.2", [8] = "6.0", [9] = "6.7", [10] = "7.5", [11] = "8.2", [12] = "9.0", [13] = "9.7", [14] = "10.4", [15] = "11.2", [16] = "11.9", [17] = "12.7", [18] = "13.4", [19] = "14.2", [20] = "14.9", [21] = "15.7", [22] = "16.4", [23] = "17.2", [24] = "17.9", [25] = "18.6", [26] = "19.2", [27] = "19.6", [28] = "20.0", [29] = "20.4", [30] = "20.7", }, [2] = {[3] = "2.6", [4] = "3.2", [5] = "3.9", [6] = "4.6", [7] = "5.3", [8] = "6.0", [9] = "6.8", [10] = "7.5", [11] = "8.2", [12] = "9.0", [13] = "9.7", [14] = "10.5", [15] = "11.2", [16] = "12.0", [17] = "12.7", [18] = "13.4", [19] = "14.2", [20] = "14.9", [21] = "15.7", [22] = "16.4", [23] = "17.2", [24] = "17.9", [25] = "18.6", [26] = "19.2", [27] = "19.6", [28] = "20.0", [29] = "20.4", [30] = "20.7", }, [3] = {[4] = "3.6", [5] = "4.2", [6] = "4.8", [7] = "5.5", [8] = "6.2", [9] = "6.9", [10] = "7.6", [11] = "8.3", [12] = "9.0", [13] = "9.8", [14] = "10.5", [15] = "11.2", [16] = "12.0", [17] = "12.7", [18] = "13.5", [19] = "14.2", [20] = "15.0", [21] = "15.7", [22] = "16.4", [23] = "17.2", [24] = "17.9", [25] = "18.7", [26] = "19.2", [27] = "19.7", [28] = "20.0", [29] = "20.4", [30] = "20.7", }, [4] = {[5] = "4.6", [6] = "5.2", [7] = "5.8", [8] = "6.4", [9] = "7.1", [10] = "7.8", [11] = "8.5", [12] = "9.2", [13] = "9.9", [14] = "10.6", [15] = "11.3", [16] = "12.1", [17] = "12.8", [18] = "13.5", [19] = "14.3", [20] = "15.0", [21] = "15.7", [22] = "16.5", [23] = "17.2", [24] = "18.0", [25] = "18.7", [26] = "19.2", [27] = "19.7", [28] = "20.1", [29] = "20.4", [30] = "20.7", }, [5] = {[6] = "5.5", [7] = "6.1", [8] = "6.8", [9] = "7.4", [10] = "8.0", [11] = "8.7", [12] = "9.4", [13] = "10.1", [14] = "10.8", [15] = "11.5", [16] = "12.2", [17] = "12.9", [18] = "13.6", [19] = "14.4", [20] = "15.1", [21] = "15.8", [22] = "16.5", [23] = "17.3", [24] = "18.0", [25] = "18.8", [26] = "19.3", [27] = "19.7", [28] = "20.1", [29] = "20.4", [30] = "20.7", }, [6] = {[7] = "6.5", [8] = "7.1", [9] = "7.7", [10] = "8.4", [11] = "9.0", [12] = "9.7", [13] = "10.3", [14] = "11.0", [15] = "11.7", [16] = "12.4", [17] = "13.1", [18] = "13.8", [19] = "14.5", [20] = "15.2", [21] = "15.9", [22] = "16.7", [23] = "17.4", [24] = "18.1", [25] = "18.8", [26] = "19.4", [27] = "19.8", [28] = "20.2", [29] = "20.5", [30] = "20.8", }, [7] = {[8] = "7.5", [9] = "8.1", [10] = "8.7", [11] = "9.3", [12] = "10.0", [13] = "10.6", [14] = "11.3", [15] = "11.9", [16] = "12.6", [17] = "13.3", [18] = "14.0", [19] = "14.7", [20] = "15.4", [21] = "16.1", [22] = "16.8", [23] = "17.5", [24] = "18.2", [25] = "19.0", [26] = "19.5", [27] = "19.9", [28] = "20.3", [29] = "20.6", [30] = "20.9", }, [8] = {[9] = "8.5", [10] = "9.1", [11] = "9.7", [12] = "10.3", [13] = "11.0", [14] = "11.6", [15] = "12.2", [16] = "12.9", [17] = "13.6", [18] = "14.2", [19] = "14.9", [20] = "15.6", [21] = "16.3", [22] = "17.0", [23] = "17.7", [24] = "18.4", [25] = "19.1", [26] = "19.6", [27] = "20.0", [28] = "20.4", [29] = "20.7", [30] = "21.0", }, [9] = {[10] = "9.5", [11] = "10.1", [12] = "10.7", [13] = "11.3", [14] = "11.9", [15] = "12.6", [16] = "13.2", [17] = "13.8", [18] = "14.5", [19] = "15.2", [20] = "15.8", [21] = "16.5", [22] = "17.2", [23] = "17.9", [24] = "18.6", [25] = "19.3", [26] = "19.8", [27] = "20.2", [28] = "20.5", [29] = "20.8", [30] = "21.1", }, [10] = {[11] = "10.5", [12] = "11.1", [13] = "11.7", [14] = "12.3", [15] = "12.9", [16] = "13.5", [17] = "14.2", [18] = "14.8", [19] = "15.4", [20] = "16.1", [21] = "16.8", [22] = "17.4", [23] = "18.1", [24] = "18.8", [25] = "19.5", [26] = "20.0", [27] = "20.4", [28] = "20.7", [29] = "21.0", [30] = "21.2", }, [11] = {[12] = "11.5", [13] = "12.1", [14] = "12.7", [15] = "13.3", [16] = "13.9", [17] = "14.5", [18] = "15.1", [19] = "15.8", [20] = "16.4", [21] = "17.1", [22] = "17.7", [23] = "18.4", [24] = "19.1", [25] = "19.7", [26] = "20.2", [27] = "20.6", [28] = "20.9", [29] = "21.2", [30] = "21.4", }, [12] = {[13] = "12.5", [14] = "13.1", [15] = "13.6", [16] = "14.2", [17] = "14.9", [18] = "15.5", [19] = "16.1", [20] = "16.7", [21] = "17.4", [22] = "18.0", [23] = "18.7", [24] = "19.3", [25] = "20.0", [26] = "20.4", [27] = "20.8", [28] = "21.1", [29] = "21.4", [30] = "21.6", }, [13] = {[14] = "13.5", [15] = "14.1", [16] = "14.6", [17] = "15.2", [18] = "15.8", [19] = "16.5", [20] = "17.1", [21] = "17.7", [22] = "18.4", [23] = "19.0", [24] = "19.6", [25] = "20.3", [26] = "20.7", [27] = "21.1", [28] = "21.4", [29] = "21.6", [30] = "21.8", }, [14] = {[15] = "14.5", [16] = "15.0", [17] = "15.6", [18] = "16.2", [19] = "16.8", [20] = "17.4", [21] = "18.1", [22] = "18.7", [23] = "19.3", [24] = "20.0", [25] = "20.6", [26] = "21.0", [27] = "21.3", [28] = "21.6", [29] = "21.8", [30] = "22.0", }, [15] = {[16] = "15.5", [17] = "16.0", [18] = "16.6", [19] = "17.2", [20] = "17.8", [21] = "18.4", [22] = "19.0", [23] = "19.6", [24] = "20.3", [25] = "20.9", [26] = "21.3", [27] = "21.6", [28] = "21.9", [29] = "22.1", [30] = "22.3", }, [16] = {[17] = "16.5", [18] = "17.0", [19] = "17.6", [20] = "18.2", [21] = "18.8", [22] = "19.4", [23] = "20.0", [24] = "20.6", [25] = "21.3", [26] = "21.7", [27] = "21.9", [28] = "22.2", [29] = "22.4", [30] = "22.5", }, [17] = {[18] = "17.5", [19] = "18.0", [20] = "18.6", [21] = "19.2", [22] = "19.8", [23] = "20.4", [24] = "21.0", [25] = "21.6", [26] = "22.0", [27] = "22.3", [28] = "22.5", [29] = "22.7", [30] = "22.8", }, [18] = {[19] = "18.5", [20] = "19.0", [21] = "19.6", [22] = "20.2", [23] = "20.8", [24] = "21.4", [25] = "22.0", [26] = "22.4", [27] = "22.6", [28] = "22.8", [29] = "23.0", [30] = "23.1", }, [19] = {[20] = "19.5", [21] = "20.0", [22] = "20.6", [23] = "21.2", [24] = "21.8", [25] = "22.4", [26] = "22.7", [27] = "22.9", [28] = "23.1", [29] = "23.2", [30] = "23.4", }, [20] = {[21] = "20.4", [22] = "21.0", [23] = "21.6", [24] = "22.2", [25] = "22.8", [26] = "23.1", [27] = "23.3", [28] = "23.4", [29] = "23.6", [30] = "23.7", }, [21] = {[22] = "21.4", [23] = "22.0", [24] = "22.6", [25] = "23.2", [26] = "23.5", [27] = "23.6", [28] = "23.8", [29] = "23.9", [30] = "24.0", }, [22] = {[23] = "22.4", [24] = "23.0", [25] = "23.6", [26] = "23.8", [27] = "24.0", [28] = "24.1", [29] = "24.2", [30] = "24.2", }, [23] = {[24] = "23.4", [25] = "24.0", [26] = "24.2", [27] = "24.4", [28] = "24.4", [29] = "24.5", [30] = "24.5", }, [24] = {[25] = "24.4", [26] = "24.6", [27] = "24.7", [28] = "24.7", [29] = "24.8", [30] = "24.8", }, }
-- precomputed percentage of time wind is less than 6, from wind random monte carlo simulation, given minWind and maxWind
local riskWind = {[0] = {[1] = "100", [2] = "100", [3] = "100", [4] = "100", [5] = "100", [6] = "100", [7] = "56", [8] = "42", [9] = "33", [10] = "27", [11] = "22", [12] = "18.5", [13] = "15.8", [14] = "13.6", [15] = "11.8", [16] = "10.4", [17] = "9.2", [18] = "8.2", [19] = "7.4", [20] = "6.7", [21] = "6.0", [22] = "5.5", [23] = "5.0", [24] = "4.6", [25] = "4.3", [26] = "4.0", [27] = "3.7", [28] = "3.4", [29] = "3.2", [30] = "3.0", }, [1] = {[2] = "100", [3] = "100", [4] = "100", [5] = "100", [6] = "100", [7] = "56", [8] = "42", [9] = "33", [10] = "27", [11] = "22", [12] = "18.5", [13] = "15.7", [14] = "13.6", [15] = "11.8", [16] = "10.4", [17] = "9.2", [18] = "8.2", [19] = "7.4", [20] = "6.7", [21] = "6.0", [22] = "5.5", [23] = "5.0", [24] = "4.6", [25] = "4.3", [26] = "4.0", [27] = "3.7", [28] = "3.4", [29] = "3.2", [30] = "3.0", }, [2] = {[3] = "100", [4] = "100", [5] = "100", [6] = "100", [7] = "55", [8] = "42", [9] = "33", [10] = "27", [11] = "22", [12] = "18.4", [13] = "15.6", [14] = "13.5", [15] = "11.8", [16] = "10.4", [17] = "9.2", [18] = "8.2", [19] = "7.4", [20] = "6.6", [21] = "6.0", [22] = "5.5", [23] = "5.0", [24] = "4.6", [25] = "4.3", [26] = "3.9", [27] = "3.6", [28] = "3.4", [29] = "3.1", [30] = "2.9", }, [3] = {[4] = "100", [5] = "100", [6] = "100", [7] = "53", [8] = "40", [9] = "32", [10] = "25", [11] = "21", [12] = "17.8", [13] = "15.2", [14] = "13.2", [15] = "11.5", [16] = "10.2", [17] = "9.1", [18] = "8.1", [19] = "7.3", [20] = "6.6", [21] = "6.0", [22] = "5.4", [23] = "5.0", [24] = "4.6", [25] = "4.2", [26] = "3.9", [27] = "3.6", [28] = "3.4", [29] = "3.1", [30] = "2.9", }, [4] = {[5] = "100", [6] = "100", [7] = "49", [8] = "36", [9] = "29", [10] = "23", [11] = "19.4", [12] = "16.4", [13] = "14.0", [14] = "12.2", [15] = "10.8", [16] = "9.6", [17] = "8.6", [18] = "7.7", [19] = "7.0", [20] = "6.3", [21] = "5.8", [22] = "5.3", [23] = "4.8", [24] = "4.4", [25] = "4.1", [26] = "3.8", [27] = "3.5", [28] = "3.3", [29] = "3.0", [30] = "2.8", }, [5] = {[6] = "100", [7] = "41", [8] = "30", [9] = "24", [10] = "19.5", [11] = "16.2", [12] = "13.9", [13] = "11.9", [14] = "10.4", [15] = "9.3", [16] = "8.3", [17] = "7.5", [18] = "6.8", [19] = "6.2", [20] = "5.7", [21] = "5.2", [22] = "4.8", [23] = "4.4", [24] = "4.1", [25] = "3.8", [26] = "3.5", [27] = "3.2", [28] = "3.0", [29] = "2.8", [30] = "2.6", }, [6] = {[7] = "16.0", [8] = "12.4", [9] = "10.5", [10] = "9.0", [11] = "8.0", [12] = "7.3", [13] = "6.6", [14] = "6.0", [15] = "5.5", [16] = "5.1", [17] = "4.7", [18] = "4.4", [19] = "4.2", [20] = "3.9", [21] = "3.6", [22] = "3.4", [23] = "3.2", [24] = "3.0", [25] = "2.8", [26] = "2.7", [27] = "2.5", [28] = "2.4", [29] = "2.2", [30] = "2.1", }, }
-- pull average wind from precomputed table, if it exists
local avgWindValue = avgWind[minWind]
if avgWindValue ~= nil then
	avgWindValue = avgWindValue[maxWind]
end
if avgWindValue == nil then
	avgWindValue = "~" .. tostring(math.max(minWind, maxWind * .75)) --fallback approximation
end
-- pull wind risk from precomputed table, if it exists
local riskWindValue = riskWind[minWind]
if riskWindValue ~= nil then
	riskWindValue = riskWindValue[maxWind]
end
if riskWindValue == nil then
	if minWind+maxWind >= 0.5 then
		riskWindValue = "0"
	else
		riskWindValue = "100"
	end
end

local tidalSpeed = Game.tidal
local tidalWaveAnimationHeight = 10
local windRotation = 0

local lastFrame = -1
local topbarArea = {}
local resbarArea = { metal = {}, energy = {}, BP = {} }
local resbarDrawinfo = { metal = {}, energy = {}, BP = {} }
local shareIndicatorArea = { metal = {}, energy = {}, BP = {} } --get rid of BP
local dlistResbar = { metal = {}, energy = {}, BP = {} }
local windArea = {}
local tidalarea = {}
local comsArea = {}
local buttonsArea = {}
local dlistWindText = {}
local dlistResValuesBar = { metal = {}, energy = {}, BP = {} }
local dlistResValues = { metal = {}, energy = {}, BP = {} }
local currentResValue = { metal = 1000, energy = 1000, BP = 0 }
local currentStorageValue = { metal = -1, energy = -1, BP = 0.1 }


local r = { metal = { spGetTeamResources(myTeamID, 'metal') }, energy = { spGetTeamResources(myTeamID, 'energy'), }}


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

local numPlayers = Spring.Utilities.GetPlayerCount()
local isSinglePlayer = Spring.Utilities.Gametype.IsSinglePlayer()

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

	for n, _ in pairs(dlistWindText) do
		dlistWindText[n] = glDeleteList(dlistWindText[n])
	end
	for res, _ in pairs(dlistResValues) do
		for n, _ in pairs(dlistResValues[res]) do
			dlistResValues[res][n] = glDeleteList(dlistResValues[res][n])
		end
	end
	for res, _ in pairs(dlistResValuesBar) do
		for n, _ in pairs(dlistResValuesBar[res]) do
			dlistResValuesBar[res][n] = glDeleteList(dlistResValuesBar[res][n])
		end
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
		local textPadding = math_floor(fontsize * 0.8)
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
			RectRound(buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4], 5.5 * widgetScale, 0, 0, 1, 1)
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
		RectRound(area[1], area[2], area[3], area[4], 5.5 * widgetScale, 0, 0, 1, 1)
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

	local bladesSize = height * 0.53 * widgetScale

	-- add background blur
	if dlistWindGuishader ~= nil then
		if WG['guishader'] then
			WG['guishader'].RemoveDlist('topbar_wind')
		end
		glDeleteList(dlistWindGuishader)
	end
	dlistWindGuishader = glCreateList(function()
		RectRound(area[1], area[2], area[3], area[4], 5.5 * widgetScale, 0, 0, 1, 1)
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
			font2:Print("\255\200\200\200" .. Spring.I18N('ui.topbar.wind.nowind1'), windArea[1] + ((windArea[3] - windArea[1]) / 2), windArea[2] + ((windArea[4] - windArea[2]) / 1.5) - (fontsize / 5), fontsize * 1.06, 'oc') -- Wind speed text
			font2:Print("\255\200\200\200" .. Spring.I18N('ui.topbar.wind.nowind2'), windArea[1] + ((windArea[3] - windArea[1]) / 2), windArea[2] + ((windArea[4] - windArea[2]) / 2.8) - (fontsize / 5), fontsize * 1.06, 'oc') -- Wind speed text
			font2:End()
		end
	end)

	if WG['tooltip'] ~= nil then
		WG['tooltip'].AddTooltip('wind', area, Spring.I18N('ui.topbar.windspeedTooltip', { avgWindValue = avgWindValue, riskWindValue = riskWindValue, warnColor = textWarnColor }), nil, Spring.I18N('ui.topbar.windspeed'))
	end
end

-- return true if tidal speed is * relevant * , enough water in the world (>= 10%)
local function checkTidalRelevant()
	local _, _, mapMinHeight, mapMaxHeight = Spring.GetGroundExtremes()
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
		RectRound(area[1], area[2], area[3], area[4], 5.5 * widgetScale, 0, 0, 1, 1)
	end)

	if tidaldlist1 ~= nil then
		glDeleteList(tidaldlist1)
	end
	if tidaldlist2 ~= nil then
		glDeleteList(tidaldlist2)
	end
	local wavesSize = height * 0.53 * widgetScale
	tidalWaveAnimationHeight = height * 0.1 * widgetScale
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
	if dlistResbar[res][4] ~= nil then
		glDeleteList(dlistResbar[res][4])
	end
	dlistResbar[res][4] = glCreateList(function()
		RectRound(resbarArea[res][1] + bgpadding, resbarArea[res][2] + bgpadding, resbarArea[res][3] - bgpadding, resbarArea[res][4], bgpadding * 1.25, 0, 0, 1, 1)
		RectRound(resbarArea[res][1], resbarArea[res][2], resbarArea[res][3], resbarArea[res][4], 5.5 * widgetScale, 0, 0, 1, 1)
	end)
	if dlistResbar[res][5] ~= nil then
		glDeleteList(dlistResbar[res][5])
	end
	dlistResbar[res][5] = glCreateList(function()
		RectRound(resbarArea[res][1], resbarArea[res][2], resbarArea[res][3], resbarArea[res][4], 5.5 * widgetScale, 0, 0, 1, 1)
	end)

	-- storage changed!
	if currentStorageValue[res] ~= r[res][2] then
		-- flush old dlist caches
		for n, _ in pairs(dlistResValues[res]) do
			if n ~= currentResValue[res] then
				glDeleteList(dlistResValues[res][n])
				dlistResValues[res][n] = nil
			end
		end

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
			elseif res == 'BP' and drawBPBar == true then
				font2:SetTextColor(0.45, 0.6, 0.45, 1)
			end
			-- -- Text: Storage
			if res ~= 'BP' then
				font2:Print(short(r[res][2]), resbarDrawinfo[res].textStorage[2], resbarDrawinfo[res].textStorage[3], resbarDrawinfo[res].textStorage[4], resbarDrawinfo[res].textStorage[5])
			end
			if res == 'BP' and proMode == true and drawBPBar == true then
				font2:Print("\255\100\100\100" .. short(r[res][4]), resbarDrawinfo[res].textStorage[2], resbarDrawinfo[res].textStorage[3], resbarDrawinfo[res].textStorage[4], resbarDrawinfo[res].textStorage[5]) 
			end
			font2:End()
		end)
	end

	if dlistResbar[res][3] ~= nil then
		glDeleteList(dlistResbar[res][3])
	end

	addStalling = false -- needed for exact calculations
	for unitID, currentUnitBP in pairs(trackedBuilders) do
		local prio = checkPriority(unitID)
		if checkPriority(unitID) == "low" then
			addStalling = true
		end 
	end

	if addStalling == true and res == 'metal' then
		r[res][3] = r[res][3] + totalStallingM
	end

	if addStalling == true and res == 'energy' then
		r[res][3] = r[res][3] + totalStallingE
	end -- until here
	if res ~= 'BP' or drawBPBar == true then
		dlistResbar[res][3] = glCreateList(function() 
			font2:Begin()
			-- Text: pull
			if res ~= 'BP' then
			font2:Print("\255\240\125\125" .. "-" .. short(r[res][3]), resbarDrawinfo[res].textPull[2], resbarDrawinfo[res].textPull[3], resbarDrawinfo[res].textPull[4], resbarDrawinfo[res].textPull[5])
			elseif res == 'BP' then
				font2:Print("\255\0\255\0"  .. short(r[res][5]), resbarDrawinfo[res].textPull[2], resbarDrawinfo[res].textPull[3], resbarDrawinfo[res].textPull[4], resbarDrawinfo[res].textPull[5])
			end
			-- Text: expense
			local textcolor = "\255\240\180\145"
			if r[res][3] == r[res][5] then
				textcolor = "\255\200\140\130"
			end
			if res ~= 'BP' then
				font2:Print(textcolor .. "-" .. short(r[res][5]), resbarDrawinfo[res].textExpense[2], resbarDrawinfo[res].textExpense[3], resbarDrawinfo[res].textExpense[4], resbarDrawinfo[res].textExpense[5])
			elseif res == 'BP' then
				font2:Print("\255\50\155\0" .. short(r[res][3]), resbarDrawinfo[res].textExpense[2], resbarDrawinfo[res].textExpense[3], resbarDrawinfo[res].textExpense[4], resbarDrawinfo[res].textExpense[5])
			end
			-- Text: income
			if res ~= 'BP' then
				font2:Print("\255\120\235\120" .. "+" .. short(r[res][4]), resbarDrawinfo[res].textIncome[2], resbarDrawinfo[res].textIncome[3], resbarDrawinfo[res].textIncome[4], resbarDrawinfo[res].textIncome[5])
			elseif res == 'BP' then
				--font2:Print("\001\100\100\100" .. short(r[res][2]), resbarDrawinfo[res].textIncome[2], resbarDrawinfo[res].textIncome[3], resbarDrawinfo[res].textIncome[4], resbarDrawinfo[res].textIncome[5]) --don't show metal cost
			end	
			font2:End()

			if gameFrame > 1 then --xxx not spec and 
				-- display overflow notification
				if (res == 'metal' and (allyteamOverflowingMetal or overflowingMetal)) or (res == 'energy' and (allyteamOverflowingEnergy or overflowingEnergy)) or (res == 'BP' and (playerStallingMetal or playerStallingEnergy) and drawBPBar == true)then
					if showOverflowTooltip[res] == nil then
						showOverflowTooltip[res] = os.clock() + 0.1
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
								elseif r[res][6] > 0.75 then	-- supress if you are deliberately overflowing by adjusting the share slider down
									--WG['notifications'].addEvent('YouAreOverflowingEnergy')	-- this annoys the fuck out of em and makes them build energystoages too much
								end
							end
						end

						local fontSize = (orgHeight * (1 + (ui_scale - 1) / 1.33) / 4) * widgetScale
						local textWidth = font2:GetTextWidth(text) * fontSize
						-- background
						local color1, color2, color3, color4, color5, color6
						if res == 'metal' then
							if allyteamOverflowingMetal then
								color1 = { 0.35, 0.1, 0.1, 1 }
								color2 = { 0.25, 0.05, 0.05, 1 }
							else
								color1 = { 0.35, 0.35, 0.35, 1 }
								color2 = { 0.25, 0.25, 0.25, 1 }
							end
							RectRound(resbarArea[res][3] - textWidth, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3] , resbarArea[res][2], 3.7 * widgetScale, 0, 0, 1, 1, color1, color2)
						elseif res == 'energy' then
							if allyteamOverflowingEnergy then
								color1 = { 0.35, 0.1, 0.1, 1 }
								color2 = { 0.25, 0.05, 0.05, 1 }
							else
								color1 = { 0.35, 0.25, 0, 1 }
								color2 = { 0.25, 0.16, 0, 1 }
							end
							RectRound(resbarArea[res][3] - textWidth, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3] , resbarArea[res][2], 3.7 * widgetScale, 0, 0, 1, 1, color1, color2)
						end
						if res == 'metal' then
							if allyteamOverflowingMetal then
								color1 = { 1, 0.3, 0.3, 0.25 }
								color2 = { 1, 0.3, 0.3, 0.44 }
							else
								color1 = { 1, 1, 1, 0.25 }
								color2 = { 1, 1, 1, 0.44 }
							end
							RectRound(resbarArea[res][3] - textWidth, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3], resbarArea[res][2], 3.7 * widgetScale, 0, 0, 1, 1, color1, color2)
						elseif res == 'energy' then
							if allyteamOverflowingEnergy then
								color1 = { 1, 0.3, 0.3, 0.25 }
								color2 = { 1, 0.3, 0.3, 0.44 }
							else
								color1 = { 1, 0.88, 0, 0.25 }
								color2 = { 1, 0.88, 0, 0.44 }
							end
							RectRound(resbarArea[res][3] - textWidth, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3], resbarArea[res][2], 3.7 * widgetScale, 0, 0, 1, 1, color1, color2)
						end
						font2:Begin()
						font2:SetTextColor(1, 0.88, 0.88, 1)
						font2:SetOutlineColor(0.2, 0, 0, 0.6)
						if res ~= 'BP' then
						font2:Print(text, resbarArea[res][3], resbarArea[res][2] - 9.3 * widgetScale, fontSize, 'or')
						end

						if res == 'BP' and playerStallingMetal then
							text ='   need Metal   '
							local textWidth = font2:GetTextWidth(text) * fontSize
							color1 = { 0.35, 0.1, 0.1, 1 }
							color2 = { 0.25, 0.05, 0.05, 1 }
							RectRound(resbarArea[res][3] - textWidth, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3], resbarArea[res][2], 3.7 * widgetScale, 0, 0, 1, 1, color1, color2)
							color1 = { 0.35, 0.1, 0.1, 1 }
							color2 = { 0.25, 0.05, 0.05, 1 }
							RectRound(resbarArea[res][3] - textWidth, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3], resbarArea[res][2], 3.7 * widgetScale, 0, 0, 1, 1, color1, color2)
							font2:Print(text, resbarArea[res][3], resbarArea[res][2] - 9.3 * widgetScale , fontSize, 'or') 
						end
						
						if res == 'BP' and playerStallingEnergy then
							text ='   need Energy   '
							local textWidth = font2:GetTextWidth(text) * fontSize
							color3 = { 0.35, 0.1, 0.1, 1 }
							color4 = { 0.25, 0.05, 0.05, 1 }
							RectRound(resbarArea[res][3] - 2 * textWidth, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3] - 1 * textWidth, resbarArea[res][2] , 3.7 * widgetScale, 0, 0, 1, 1, color3, color4)
							color3 = { 0.35, 0.1, 0.1, 1 }
							color4 = { 0.25, 0.05, 0.05, 1 }
							RectRound(resbarArea[res][3] - 2 * textWidth, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3] - 1 * textWidth, resbarArea[res][2], 3.7 * widgetScale, 0, 0, 1, 1, color3, color4)
							font2:Print(text, resbarArea[res][3] - 1 * textWidth, resbarArea[res][2] - 9.3 * widgetScale , fontSize, 'or') 
						end
						
						local indicatorPosM = BP[10]
						local indicatorPosE = BP[11]
						if indicatorPosM == nil or indicatorPosE == nil then
							indicatorPosM = 0
							indicatorPosE = 0
						end
						if res == 'BP' and indicatorPosM < 0.4 or indicatorPosE < 0.4 then
							text ='   too much BP   '
							local textWidth1 = font2:GetTextWidth(text) * fontSize
							color5 = { 0.20, 0.20, 0.20, 1 }
							color6 = { 0.12, 0.12, 0.12, 1 }
							RectRound(resbarArea[res][3] - 3.5 * textWidth1, resbarArea[res][2] - 15.5 * widgetScale, resbarArea[res][3] - 2.5 * textWidth1, resbarArea[res][2], 3.7 * widgetScale, 0, 0, 1, 1, color5, color6)
							font2:Print(text, resbarArea[res][3] - 2.5 * textWidth1, resbarArea[res][2] - 9.3 * widgetScale , fontSize, 'or') 
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

local function updateResbar(res)  --decides where and what is drawn
	local area = resbarArea[res]

	if dlistResbar[res][1] ~= nil then
		glDeleteList(dlistResbar[res][1])
		glDeleteList(dlistResbar[res][2])
	end
	local barHeight = math_floor((height * widgetScale / 7) + 0.5)
	local barHeightPadding = math_floor(((height / 4.4) * widgetScale) + 0.5) --((height/2) * widgetScale) - (barHeight/2)
	--local barLeftPadding = 2 * widgetScale
	local barLeftOffset = -10
	local barLeftPadding = math_floor(47 * widgetScale) --xxx 53*
	if res == 'BP' and drawBPBar == true then
		barLeftPadding = math_floor(10 * widgetScale)
		barLeftOffset = barLeftOffset + 37
	end
	local barRightPadding = math_floor(14.5 * widgetScale)
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
	elseif res == 'BP'  and drawBPBar == true then
		resbarDrawinfo[res].barColor = { 0, 1, 0, 1 }
	end
	resbarDrawinfo[res].barArea = barArea
	resbarDrawinfo[res].barTexRect = { barArea[1], barArea[2], barArea[1] + ((r[res][1] / r[res][2]) * barWidth), barArea[4] }
	resbarDrawinfo[res].barGlowMiddleTexRect = { resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[2] - glowSize, resbarDrawinfo[res].barTexRect[3], resbarDrawinfo[res].barTexRect[4] + glowSize }
	resbarDrawinfo[res].barGlowLeftTexRect = { resbarDrawinfo[res].barTexRect[1] - (glowSize * 2.5), resbarDrawinfo[res].barTexRect[2] - glowSize, resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[4] + glowSize }
	resbarDrawinfo[res].barGlowRightTexRect = { resbarDrawinfo[res].barTexRect[3] + (glowSize * 2.5), resbarDrawinfo[res].barTexRect[2] - glowSize, resbarDrawinfo[res].barTexRect[3], resbarDrawinfo[res].barTexRect[4] + glowSize }
	if res ~= 'BP' then -- for bp bar only
		resbarDrawinfo[res].textStorage = { "\255\150\150\100" .. short(r[res][2]), barArea[3], barArea[2] + barHeight * 2.1, (height / 3.2) * widgetScale, 'ord' }
		resbarDrawinfo[res].textPull = { "\255\210\100\100" .. short(r[res][3]), barArea[1] + (barLeftOffset * widgetScale), barArea[2] + barHeight * 2.15, (height / 3) * widgetScale, 'ord' }
		resbarDrawinfo[res].textExpense = { "\255\210\100\100" .. short(r[res][5]), barArea[1] + ((barLeftOffset + 20) * widgetScale), barArea[2] + barHeight * 2.15, (height / 3) * widgetScale, 'old' }	
		resbarDrawinfo[res].textIncome = { "\255\100\210\100" .. short(r[res][4]), barArea[1] + (barLeftOffset * widgetScale), barArea[2] - (barHeight * 0.55), (height / 3) * widgetScale, 'ord' }
		resbarDrawinfo[res].textCurrent = { short(r[res][1]), barArea[1] + barWidth / 2, barArea[2] + barHeight * 1.8, (height / 2.5) * widgetScale, 'ocd' }
	end
	if res == 'BP' and drawBPBar == true then -- for bp bar only does the color really matter here? isn't it set in font2:Print("\255\240\125\125" .. "-" .. short(r[res][3]), resbarDrawinfo[res].textPull[2]
		resbarDrawinfo[res].textStorage = { "\100\125\125\100" .. short(r[res][4]), barArea[3], barArea[2] + barHeight * 2.1, (height / 3.2) * widgetScale, 'ord' } --totalBP
		resbarDrawinfo[res].textPull = { "\100\255\0\100" .. short(r[res][3]), barArea[1] + (barLeftOffset * widgetScale), barArea[2] + barHeight * 2.15, (height / 3) * widgetScale, 'ord' } --used
		resbarDrawinfo[res].textExpense = { "\100\150\0\100" .. short(r[res][5]), barArea[1] + ((barLeftOffset + 20) * widgetScale), barArea[2] + barHeight * 2.15, (height / 3) * widgetScale, 'old' }	--reserved
		resbarDrawinfo[res].textIncome = { "\100\100\100\100" .. short(r[res][2]), barArea[1] + (barLeftOffset * widgetScale), barArea[2] - (barHeight * 0.55), (height / 3) * widgetScale, 'ord' } --metalCost
		resbarDrawinfo[res].textCurrent = { short(r[res][1]), barArea[1] + barWidth / 2, barArea[2] + barHeight * 1.8, (height / 2.5) * widgetScale, 'ocd' }	
	end

	-- add background blur
	if dlistResbar[res][0] ~= nil then
		if WG['guishader'] then
			WG['guishader'].RemoveDlist('topbar_' .. res)
		end
		glDeleteList(dlistResbar[res][0])
	end
	dlistResbar[res][0] = glCreateList(function()
		RectRound(area[1], area[2], area[3], area[4], 5.5 * widgetScale, 0, 0, 1, 1)

	end)




	dlistResbar[res][1] = glCreateList(function()
		UiElement(area[1], area[2], area[3], area[4], 0, 0, 1, 1)

		if WG['guishader'] then
			WG['guishader'].InsertDlist(dlistResbar[res][0], 'topbar_' .. res)
		end

		-- Icon
		glColor(1, 1, 1, 1)
		local iconPadding = math_floor((area[4] - area[2]) / 9) --xxx /7
		local iconSize = math_floor(area[4] - area[2] - iconPadding - iconPadding)
		local bgpaddingHalf = math_floor((bgpadding * 0.5) + 0.5)
		local texSize = math_floor(iconSize * 2)
		if res == 'metal' then
			glTexture(":lr" ..texSize ..", " ..texSize ..":LuaUI/Images/metal.png")
		elseif res == 'energy' then

			glTexture(":lr" ..texSize ..", " ..texSize ..":LuaUI/Images/energy.png") 
		elseif drawBPBar == true then
			glColor(0.8, 1, 0.8, 1)
			glTexture(":lr" ..texSize ..", " ..texSize ..":LuaUI/Widgets/topbar/BP.png") --for bp bar only
		end
		glTexRect(area[1] + bgpaddingHalf + iconPadding, area[2] + bgpaddingHalf + iconPadding, area[1] + bgpaddingHalf + iconPadding + iconSize, area[4] + bgpaddingHalf - iconPadding)
		glTexture(false)

		-- Bar background
		local addedSize = math_floor(((barArea[4] - barArea[2]) * 0.15) + 0.5)
		--RectRound(barArea[1] - edgeWidth, barArea[2] - edgeWidth, barArea[3] + edgeWidth, barArea[4] + edgeWidth, barHeight * 0.33, 1, 1, 1, 1, { 1, 1, 1, 0.03 }, { 1, 1, 1, 0.03 })
		local borderSize = 1
		local fullBarColorLow = { 0, 0, 0, 0.12 } -- bottom (lowlight)
		local fullBarColorHigh = { 0, 0, 0, 0.15 } -- top (highlight)
		if res == 'BP' then
			-- red background, since unused BP is a problem
			fullBarColorLow = { 1, 0, 0, 0.22 } -- bottom (lowlight)
			fullBarColorHigh = { 1, 0, 0, 0.25 } -- top (highlight)
		end
		RectRound(barArea[1] - edgeWidth + borderSize, barArea[2] - edgeWidth + borderSize, barArea[3] + edgeWidth - borderSize, barArea[4] + edgeWidth - borderSize, barHeight * 0.2, 1, 1, 1, 1, fullBarColorLow, fullBarColorHigh)

		gl.Texture(noiseBackgroundTexture)
		gl.Color(1, 1, 1, 0.16)
		TexturedRectRound(barArea[1] - edgeWidth, barArea[2] - edgeWidth, barArea[3] + edgeWidth, barArea[4] + edgeWidth, barHeight * 0.33, 1, 1, 1, 1, barWidth * 0.33, 0)
		gl.Texture(false)

		glBlending(GL_SRC_ALPHA, GL_ONE)
		RectRound(barArea[1] - addedSize - edgeWidth, barArea[2] - addedSize - edgeWidth, barArea[3] + addedSize + edgeWidth, barArea[4] + addedSize + edgeWidth, barHeight * 0.33, 1, 1, 1, 1, { 0, 0, 0, 0.1 }, { 0, 0, 0, 0.1 })
		RectRound(barArea[1] - addedSize, barArea[2] - addedSize, barArea[3] + addedSize, barArea[4] + addedSize, barHeight * 0.33, 1, 1, 1, 1, { 0.15, 0.15, 0.15, 0.2 }, { 0.8, 0.8, 0.8, 0.16 })
		-- gloss
		RectRound(barArea[1] - addedSize, barArea[2] + addedSize, barArea[3] + addedSize, barArea[4] + addedSize, barHeight * 0.33, 1, 1, 0, 0, { 1, 1, 1, 0 }, { 1, 1, 1, 0.07 })
		RectRound(barArea[1] - addedSize, barArea[2] - addedSize, barArea[3] + addedSize, barArea[2] + addedSize + addedSize + addedSize, barHeight * 0.2, 0, 0, 1, 1, { 1, 1, 1, 0.1 }, { 1, 1, 1, 0.0 })
		glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
	end)

	dlistResbar[res][2] = glCreateList(function()
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
			local cornerSize
			if not showQuitscreen and resbarHover ~= nil and resbarHover == res then
				cornerSize = 2 * widgetScale
			else
				cornerSize = 1.33 * widgetScale
			end
			UiSliderKnob(math_floor(conversionIndicatorArea[1]+((conversionIndicatorArea[3]-conversionIndicatorArea[1])/2)), math_floor(conversionIndicatorArea[2]+((conversionIndicatorArea[4]-conversionIndicatorArea[2])/2)), math_floor((conversionIndicatorArea[3]-conversionIndicatorArea[1])/2), { 0.95, 0.95, 0.7, 1 })
		end
		--show usefulBPFactor
		local ignore = false
		if ignore ~= true then
			for i = 1, 1 do
				if drawBPIndicators == true and BP[10] ~= nil and BP[11] ~= nil then 
				
					-- If we aren't using any BP, we don't have a good estimate as to how much BP our eco can support.
					if res == 'BP' and BP[5] > 0.01 then
						local texWidth = 1.0 * shareSliderWidth
						local texHeight = math_floor( shareSliderWidth / 2 ) - 1
						local indicatorPosM = BP[10]
						local indicatorPosE = BP[11]
						local indicatorAreaMultiplyerM = 1
						local indicatorAreaMultiplyerE = 1
						if playerStallingMetal == true then
							indicatorAreaMultiplyerM = 1.5
						end
						if playerStallingEnergy == true then
							indicatorAreaMultiplyerE = 1.5
						end

						local indicatorH = barHeight -- how tall are the metal-supported-BP and energy-supported-BP indicators?
						local barIntrusion = barHeight / 3 -- how much of the BP bar can be obscured (vertically) by one of these indicators?
						local indicatorW = indicatorH * 1.5
						local cornerSize = indicatorH / 2
						local metalIndicatorHalfWidth = indicatorW * indicatorAreaMultiplyerM / 2
						local energyIndicatorHalfWidth = indicatorW * indicatorAreaMultiplyerE / 2

						-- Indicator for buildpower that current METAL income can support. This is shown along the BOTTOM edge of the BP bar.
						RectRound(
							barArea[1] + (indicatorPosM * barWidth) - metalIndicatorHalfWidth, -- left
							barArea[2] + (barIntrusion - indicatorH), -- bottom
							barArea[1] + (indicatorPosM * barWidth) + metalIndicatorHalfWidth, -- right
							barArea[2] + barIntrusion, -- top
							cornerSize,
							1, 1, 0, 0, -- round TopLeft, TopRight, but not BottomRight, BottomLeft (so it looks like it's pointing upward)
							{ 0.6, 0.6, 0.6, 1 }, -- lowlight color (RGBA)
							{ 1,   1,   1,   1 }) -- highlight color (RGBA)

						-- Indicator for buildpower that current ENERGY income can support. This is shown along the TOP edge of the BP bar.
						RectRound(
							barArea[1] + (indicatorPosE * barWidth) - energyIndicatorHalfWidth, -- left
							barArea[4] - barIntrusion, -- bottom
							barArea[1] + (indicatorPosE * barWidth) + energyIndicatorHalfWidth, -- right
							barArea[4] - barIntrusion + indicatorH, -- top
							cornerSize,
							0, 0, 1, 1, -- don't round TopLeft, TopRight but round BottomRight, BottomLeft (so it looks like it's pointing downward)
							{0.8, 0.8, 0.4, 1}, -- lowlight color (RGBA)
							{1,   1,   0.6, 1}) -- highlight color (RGBA)

						Log("sliders end" ..i)
					end
				end
			end
		end
		-- Share slider
		if not isSingle then
			if res ~= 'BP' then
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
				local cornerSize
				if not showQuitscreen and resbarHover ~= nil and resbarHover == res then
					cornerSize = 2 * widgetScale
				else
					cornerSize = 1.33 * widgetScale
				end
				UiSliderKnob(math_floor(shareIndicatorArea[res][1]+((shareIndicatorArea[res][3]-shareIndicatorArea[res][1])/2)), math_floor(shareIndicatorArea[res][2]+((shareIndicatorArea[res][4]-shareIndicatorArea[res][2])/2)), math_floor((shareIndicatorArea[res][3]-shareIndicatorArea[res][1])/2), { 0.85, 0, 0, 1 })
			end
		end
	end)
	local resourceTranslations = {
		metal = Spring.I18N('ui.topbar.resources.metal'), 
		energy = Spring.I18N('ui.topbar.resources.energy')
	}

	local resourceName = resourceTranslations[res]

	-- add tooltips
	if WG['tooltip'] ~= nil and conversionIndicatorArea then  -- tool tips 
		if res == 'energy' then -- tool tips for share sliders
			WG['tooltip'].AddTooltip(res .. '_share_slider', { resbarDrawinfo[res].barArea[1], shareIndicatorArea[res][2], conversionIndicatorArea[1], shareIndicatorArea[res][4] }, Spring.I18N('ui.topbar.resources.shareEnergyTooltip'), nil, Spring.I18N('ui.topbar.resources.shareEnergyTooltipTitle'))
			WG['tooltip'].AddTooltip(res .. '_share_slider2', { conversionIndicatorArea[3], shareIndicatorArea[res][2], resbarDrawinfo[res].barArea[3], shareIndicatorArea[res][4] }, Spring.I18N('ui.topbar.resources.shareEnergyTooltip'), nil, Spring.I18N('ui.topbar.resources.shareEnergyTooltipTitle'))
			WG['tooltip'].AddTooltip(res .. '_metalmaker_slider', conversionIndicatorArea, Spring.I18N('ui.topbar.resources.conversionTooltip'), nil, Spring.I18N('ui.topbar.resources.conversionTooltipTitle'))
		else
			WG['tooltip'].AddTooltip(res .. '_share_slider', { resbarDrawinfo[res].barArea[1], shareIndicatorArea[res][2], resbarDrawinfo[res].barArea[3], shareIndicatorArea[res][4] }, Spring.I18N('ui.topbar.resources.shareMetalTooltip'), nil, Spring.I18N('ui.topbar.resources.shareMetalTooltipTitle'))
		end
		if res == 'BP' and drawBPBar == true then -- for bp bar only
			if not (res == 'BP' and proMode == false) then -- too much info for some users while early testing
				WG['tooltip'].AddTooltip(res .. '_expense', { resbarDrawinfo[res].textExpense[2] - (4 * widgetScale), resbarDrawinfo[res].textExpense[3], resbarDrawinfo[res].textExpense[2] + (30 * widgetScale), resbarDrawinfo[res].textExpense[3] + resbarDrawinfo[res].textExpense[4] },
					tostring(totallyUsedBP) .." BP is actually used")
				WG['tooltip'].AddTooltip(res .. '_storage', { resbarDrawinfo[res].textStorage[2] - (resbarDrawinfo[res].textStorage[4] * 2.75), resbarDrawinfo[res].textStorage[3], resbarDrawinfo[res].textStorage[2], resbarDrawinfo[res].textStorage[3] + resbarDrawinfo[res].textStorage[4] },
					"You have a total of " ..tostring(BP[4]) .." build power.")
				WG['tooltip'].AddTooltip(res .. '_pull', { resbarDrawinfo[res].textPull[2] - (resbarDrawinfo[res].textPull[4] * 2.5), resbarDrawinfo[res].textPull[3], resbarDrawinfo[res].textPull[2] + (resbarDrawinfo[res].textPull[4] * 0.5), resbarDrawinfo[res].textPull[3] + resbarDrawinfo[res].textPull[4] },
					tostring(avgTotalReservedBP ) .." BP is reserved for current and comming projects")
			end

			-- TODO: ensure these are consistent with text/highlight colors elsewhere in BAR.
			local textColor = '\255\215\215\215'
			local highlightColor = '\255\255\255\255'
			local avgTotalReservedBP = math.round(BP[3])
			local totalAvailableBP = BP[4]
			local avgTotalUsedBP = math.round(BP[5])
			WG['tooltip'].AddTooltip(res .. '_income', { resbarDrawinfo[res].textIncome[2] - (resbarDrawinfo[res].textIncome[4] * 2.5), resbarDrawinfo[res].textIncome[3], resbarDrawinfo[res].textIncome[2] + (resbarDrawinfo[res].textIncome[4] * 0.5), resbarDrawinfo[res].textIncome[3] + resbarDrawinfo[res].textIncome[4] },
				textColor .. "You have a total of " .. highlightColor .. totalAvailableBP .. textColor .. " build power (BP).\n" ..
				"You are using " .. highlightColor .. avgTotalUsedBP .. textColor .. " BP, " ..
				"with " .. highlightColor .. avgTotalReservedBP .. textColor .. " reserved.\n(Reserved: in-use, walking to a structure, or stalled.)", nil, "Build Power")
			WG['tooltip'].AddTooltip(res .. '_Current', { resbarDrawinfo[res].textCurrent[2] - (resbarDrawinfo[res].textCurrent[4] * 2.75), resbarDrawinfo[res].textCurrent[3], resbarDrawinfo[res].textCurrent[2], resbarDrawinfo[res].textCurrent[3] + resbarDrawinfo[res].textCurrent[4] },
				"your idling BP is costing you " ..tostring(currentResValue[res]) .."s of metal income. Consider less BP if this number is above 20")
		elseif res ~= 'BP' or drawBPBar == true then
			WG['tooltip'].AddTooltip(res .. '_pull', { resbarDrawinfo[res].textPull[2] - (resbarDrawinfo[res].textPull[4] * 2.5), resbarDrawinfo[res].textPull[3], resbarDrawinfo[res].textPull[2] + (resbarDrawinfo[res].textPull[4] * 0.5), resbarDrawinfo[res].textPull[3] + resbarDrawinfo[res].textPull[4] }, Spring.I18N('ui.topbar.resources.pullTooltip', { resource = resourceName }))  
			WG['tooltip'].AddTooltip(res .. '_income', { resbarDrawinfo[res].textIncome[2] - (resbarDrawinfo[res].textIncome[4] * 2.5), resbarDrawinfo[res].textIncome[3], resbarDrawinfo[res].textIncome[2] + (resbarDrawinfo[res].textIncome[4] * 0.5), resbarDrawinfo[res].textIncome[3] + resbarDrawinfo[res].textIncome[4] }, Spring.I18N('ui.topbar.resources.incomeTooltip', { resource = resourceName })) 
			WG['tooltip'].AddTooltip(res .. '_expense', { resbarDrawinfo[res].textExpense[2] - (4 * widgetScale), resbarDrawinfo[res].textExpense[3], resbarDrawinfo[res].textExpense[2] + (30 * widgetScale), resbarDrawinfo[res].textExpense[3] + resbarDrawinfo[res].textExpense[4] }, Spring.I18N('ui.topbar.resources.expenseTooltip', { resource = resourceName })) 
			WG['tooltip'].AddTooltip(res .. '_storage', { resbarDrawinfo[res].textStorage[2] - (resbarDrawinfo[res].textStorage[4] * 2.75), resbarDrawinfo[res].textStorage[3], resbarDrawinfo[res].textStorage[2], resbarDrawinfo[res].textStorage[3] + resbarDrawinfo[res].textStorage[4] }, Spring.I18N('ui.topbar.resources.storageTooltip', { resource = resourceName })) 
		end
	end
end


local function drawResbarValues(res, updateText) --drawing the bar itself and value of stored res
	Log("drawResbarValues")
	if res ~= 'BP' or drawBPBar == true then
		local cappedCurRes = r[res][1]    -- limit so when production dies the value wont be much larger than what you can store
    
		if r[res][1] > r[res][2] * 1.07 then
			cappedCurRes = r[res][2] * 1.07
		end

		local barHeight = resbarDrawinfo[res].barArea[4] - resbarDrawinfo[res].barArea[2]
		local barWidth = resbarDrawinfo[res].barArea[3] - resbarDrawinfo[res].barArea[1]
		local valueWidth 
		local additionalWidth = 0  
		if res == 'BP' and drawBPBar == true then -- for bp bar only
			valueWidth = math_floor(((r[res][5] / r[res][4]) * barWidth))
			if valueWidth > barWidth then
				valueWidth = barWidth
			end
			additionalWidth = math_floor(((r[res][3] / r[res][4]) * barWidth)) - valueWidth
			if additionalWidth < math_ceil(barHeight * 0.2) or math_ceil(barHeight * 0.2) > barWidth then
				additionalWidth = 0
			end
		else 
			valueWidth = math_floor(((cappedCurRes / r[res][2]) * barWidth)) -- this is needed even if no bp bar
		end
		if valueWidth < math_ceil(barHeight * 0.2) or r[res][2] == 0 then
			valueWidth = math_ceil(barHeight * 0.2)
		end
		local uniqueKey = valueWidth * 10000 + additionalWidth -- for bp bar only
		if not dlistResValuesBar[res][uniqueKey] then
			dlistResValuesBar[res][uniqueKey] = glCreateList(function()
				local glowSize = (resbarDrawinfo[res].barArea[4] - resbarDrawinfo[res].barArea[2]) * 7
				local color1, color2, glowAlpha
				if res == 'metal' then
					color1 = { 0.51, 0.51, 0.5, 1 }
					color2 = { 0.95, 0.95, 0.95, 1 }
					glowAlpha = 0.025 + (0.05 * math_min(1, cappedCurRes / r[res][2] * 40))
				elseif res == 'energy' then
					color1 = { 0.5, 0.45, 0, 1 }
					color2 = { 0.8, 0.75, 0, 1 }
					glowAlpha = 0.035 + (0.07 * math_min(1, cappedCurRes / r[res][2] * 40))
				elseif drawBPBar == true then -- for bp bar only
					color1 = { 0.2, 0.65, 0, 1 }
					color2 = { 0.5, 0.75, 0, 1 }
					glowAlpha = 0.035 + (0.06 * math_min(1, cappedCurRes / r[res][2] * 40))
				end
				RectRound(resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[2], resbarDrawinfo[res].barTexRect[1] + valueWidth, resbarDrawinfo[res].barTexRect[4], barHeight * 0.2, 1, 1, 1, 1, color1, color2)

				local borderSize = 1
				RectRound(resbarDrawinfo[res].barTexRect[1]+borderSize, resbarDrawinfo[res].barTexRect[2]+borderSize, resbarDrawinfo[res].barTexRect[1] + valueWidth-borderSize, resbarDrawinfo[res].barTexRect[4]-borderSize, barHeight * 0.2, 1, 1, 1, 1, { 0, 0, 0, 0.1 }, { 0, 0, 0, 0.17 })

				-- Bar value glow
				glBlending(GL_SRC_ALPHA, GL_ONE)
				glColor(resbarDrawinfo[res].barColor[1], resbarDrawinfo[res].barColor[2], resbarDrawinfo[res].barColor[3], glowAlpha)
				glTexture(barGlowCenterTexture)
				DrawRect(resbarDrawinfo[res].barGlowMiddleTexRect[1], resbarDrawinfo[res].barGlowMiddleTexRect[2], resbarDrawinfo[res].barGlowMiddleTexRect[1] + valueWidth, resbarDrawinfo[res].barGlowMiddleTexRect[4], 0.008)
				glTexture(barGlowEdgeTexture)
				DrawRect(resbarDrawinfo[res].barGlowLeftTexRect[1], resbarDrawinfo[res].barGlowLeftTexRect[2], resbarDrawinfo[res].barGlowLeftTexRect[3], resbarDrawinfo[res].barGlowLeftTexRect[4], 0.008)
				DrawRect((resbarDrawinfo[res].barGlowMiddleTexRect[1] + valueWidth) + (glowSize * 3), resbarDrawinfo[res].barGlowRightTexRect[2], resbarDrawinfo[res].barGlowMiddleTexRect[1] + valueWidth, resbarDrawinfo[res].barGlowRightTexRect[4], 0.008)
				glTexture(false)

				if res == 'BP' and drawBPBar == true then -- for bp bar only
					local color1Secondary = { 0.1, 0.55, 0, 0.5 } 
					local color2Secondary = { 0.3, 0.65, 0, 0.5 }
					RectRound(resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[2], resbarDrawinfo[res].barTexRect[1] + valueWidth + additionalWidth, resbarDrawinfo[res].barTexRect[4], barHeight * 0.2, 1, 1, 1, 1, color1Secondary, color2Secondary)
				end

				if res == 'metal' then
					-- noise
					gl.Texture(noiseBackgroundTexture)
					gl.Color(1, 1, 1, 0.37)
					TexturedRectRound(resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[2], resbarDrawinfo[res].barTexRect[1] + valueWidth, resbarDrawinfo[res].barTexRect[4], barHeight * 0.2, 1, 1, 1, 1, barWidth * 0.33, 0)
					gl.Texture(false)
				end

				glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
			end)

		end
		glCallList(dlistResValuesBar[res][uniqueKey]) --uniqueKey for bp bar only

		if res == 'energy' or (res == 'BP' and drawBPBar == true) then --  or... is for bp bar only
			-- energy flow effect
			gl.Color(1, 1, 1, 0.33)
			glBlending(GL_SRC_ALPHA, GL_ONE)
			glTexture("LuaUI/Images/paralyzed.png")
			TexturedRectRound(resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[2], resbarDrawinfo[res].barTexRect[1] + valueWidth, resbarDrawinfo[res].barTexRect[4], barHeight * 0.2, 0, 0, 1, 1, barWidth/0.5, -os.clock()/80)
			TexturedRectRound(resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[2], resbarDrawinfo[res].barTexRect[1] + valueWidth, resbarDrawinfo[res].barTexRect[4], barHeight * 0.2, 0, 0, 1, 1, barWidth/0.33, os.clock()/70)
			TexturedRectRound(resbarDrawinfo[res].barTexRect[1], resbarDrawinfo[res].barTexRect[2], resbarDrawinfo[res].barTexRect[1] + valueWidth, resbarDrawinfo[res].barTexRect[4], barHeight * 0.2, 0, 0, 1, 1, barWidth/0.45, -os.clock()/55)
			glTexture(false)

			-- colorize a bit more (with added size)
			local addedSize = math_floor(((resbarDrawinfo[res].barArea[4] - resbarDrawinfo[res].barArea[2]) * 0.15) + 0.5)
			gl.Color(1, 1, 0, 0.14)
			RectRound(resbarDrawinfo[res].barTexRect[1]-addedSize, resbarDrawinfo[res].barTexRect[2]-addedSize, resbarDrawinfo[res].barTexRect[1] + valueWidth + addedSize, resbarDrawinfo[res].barTexRect[4] + addedSize, barHeight * 0.33)
			glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
		end
		if updateText then
			currentResValue[res] = short(cappedCurRes)
			if not dlistResValues[res][currentResValue[res]] then
				if res == 'BP' and drawBPBar == true then
					local _, _, _, incomeMetal, _ = spGetTeamResources(myTeamID, 'metal')
					if incomeMetal and incomeMetal ~= 0 then
						currentResValue[res] = math_floor((r[res][2] - r[res][1]) / incomeMetal)
					else
						currentResValue[res] = 0
					end
				end
				dlistResValues[res][currentResValue[res]] = glCreateList(function()
					-- Text: current
					font2:Begin()
					if res == 'metal' then
						font2:SetTextColor(0.95, 0.95, 0.95, 1)
					elseif  res == 'energy' then
						font2:SetTextColor(1, 1, 0.74, 1)
					elseif drawBPBar == true then  -- for bp bar only
						local color 
						if currentResValue[res] > 120 then color = { 0.82, 0.39, 0.39, 1.0 } --Red 
						elseif currentResValue[res] > 80 then color = { 1.0, 0.39, 0.39, 1.0 } --Orange 
						elseif currentResValue[res] > 40 then color = { 1.0, 1.0, 0.39, 1.0 } --Yellow 
						elseif currentResValue[res] > 20 then color = { 0.84, 0.90, 0.39, 1.0 } --Bright Yellow
						else color = {0.0, 1.0, 0.39, 1.0} end --Green 
						font2:SetTextColor(color[1], color[2], color[3], color[4])
					end
					-- Text: current
					if res == 'BP' and drawBPBar == true then -- for bp bar only
						font2:SetOutlineColor(0, 0, 0, 1)
						--font2:Print(currentResValue[res] .."s", resbarDrawinfo[res].textCurrent[2], resbarDrawinfo[res].textCurrent[3], resbarDrawinfo[res].textCurrent[4], resbarDrawinfo[res].textCurrent[5])
						font2:End()
					else
						font2:SetOutlineColor(0, 0, 0, 1)
						font2:Print(currentResValue[res], resbarDrawinfo[res].textCurrent[2], resbarDrawinfo[res].textCurrent[3], resbarDrawinfo[res].textCurrent[4], resbarDrawinfo[res].textCurrent[5])
						font2:End()
					end
				end)
			end
		end
		if res ~= 'BP' or drawBPBar == true then
			if dlistResValues[res][currentResValue[res]] then
				glCallList(dlistResValues[res][currentResValue[res]])
			end
		end
	end
	Log("drawResbarValues  end")
end

function init()
	r = { metal = { spGetTeamResources(myTeamID, 'metal') }, energy = { spGetTeamResources(myTeamID, 'energy') } }
	if drawBPBar == true then
		r['BP'] = initData
	end

	topbarArea = { math_floor(xPos + (borderPadding * widgetScale)), math_floor(vsy - (height * widgetScale)), vsx, vsy }

	local filledWidth = 0
	local totalWidth = topbarArea[3] - topbarArea[1]

	-- metal

	local width = math_floor(totalWidth / 4.4)
	if drawBPBar == true then 
		width = math_floor(totalWidth / 6) --xxx  5.5
	end
	resbarArea['metal'] = { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
	filledWidth = filledWidth + width + widgetSpaceMargin
	updateResbar('metal')

	--energy
	resbarArea['energy'] = { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
	filledWidth = filledWidth + width + widgetSpaceMargin
	updateResbar('energy')
	if drawBPBar == true then
		resbarArea['BP'] = { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[1] + filledWidth + width, topbarArea[4] }
		filledWidth = filledWidth + width + widgetSpaceMargin
		updateResbar('BP')
	end

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
	width = math_floor(totalWidth / 4)
	buttonsArea = { topbarArea[3] - width, topbarArea[2], topbarArea[3], topbarArea[4] }
	updateButtons()

	if WG['topbar'] then
		WG['topbar'].GetPosition = function()
			return { topbarArea[1], topbarArea[2], topbarArea[3], topbarArea[4], widgetScale}
		end
		WG['topbar'].GetFreeArea = function()
			return { topbarArea[1] + filledWidth, topbarArea[2], topbarArea[3] - width - widgetSpaceMargin, topbarArea[4], widgetScale}
		end
	end

	updateResbarText('metal')
	updateResbarText('energy')
	if drawBPBar == true then
		updateResbarText('BP')
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
		for unitDefID, _ in pairs(isCommander) do
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

function widget:GameFrame(n)
	Log("n " ..n)
	spec = spGetSpectatingState()

	windRotation = windRotation + (currentWind * bladeSpeedMultiplier)
	gameFrame = n
	
		-- calculations for the exact metal and energy draw value

	local ignore = false
	if ignore ~= true then
		for i = 1, 1 do
			Log(i .."cache")
			if gameFrame % 2 == 0 then --refresh rate for BP and stalling calculations
				gameStarted = true

				local cacheTotalStallingM = 0
				local cacheTotalStallingE = 0

				--local totalAvailableBP = 0
				local cacheTotalReservedBP = 0
				local cacheTotallyUsedBP = 0
				local cacheMetalCostOfUsedBuildPower = 0
				--local nowChecking = 0 -- counter for trackedUnits per frame
				--Log("." )
				--Log("." )
				--Log("trackedNum" ..trackedNum)
				for unitID, currentUnitBP in pairs(trackedBuilders) do --calculation of exact pull
					if (nowChecking >= trackPosBase) then -- begin at trackedPos with calcs
						if (nowChecking >= trackPosBase + unitsPerFrame) or nowChecking > trackedNum then -- end at trackPosBase + unitsPerFrame with calcs
							break
						end
						if not Spring.ValidUnitID(unitID) or Spring.GetUnitIsDead(unitID) then
							InitAllUnits()
						else
							--Log("nowChecking" ..nowChecking)
							--totalAvailableBP = totalAvailableBP + currentUnitBP
							local unitDefID = spGetUnitDefID(unitID)
							local foundActivity, _ = findBPCommand(unitID, unitDefID, {CMD.REPAIR, CMD.RECLAIM, CMD.CAPTURE, CMD.GUARD})
							local _, currrentlyUsedM, _, currrentlyUsedE = Spring.GetUnitResources(unitID)
							if foundActivity == true or currrentlyUsedM > 0 or currrentlyUsedE > 0 then
								cacheTotalReservedBP = cacheTotalReservedBP + currentUnitBP
								local builtUnitID = spGetUnitIsBuilding(unitID)
								if builtUnitID then
									addStalling = false
									local prio = checkPriority(unitID)
									if checkPriority(unitID) == "low" then
										addStalling = true
									end 
									local builtUnitDefID = spGetUnitDefID(builtUnitID)
									currentlyUsedBP = (Spring.GetUnitCurrentBuildPower(unitID) or 0) * currentUnitBP
									currentlyUsedBP = currrentlyUsedM / unitCostData[builtUnitDefID].MperBP
									if addStalling == true then
										local currrentlyWantedM = unitCostData[builtUnitDefID].MperBP * currentUnitBP
										local currrentlyWantedE = unitCostData[builtUnitDefID].EperBP * currentUnitBP
										cacheTotalStallingM = cacheTotalStallingM + currrentlyWantedM - currrentlyUsedM
										cacheTotalStallingE = cacheTotalStallingE + currrentlyWantedE - currrentlyUsedE
									end
									if drawBPBar == true then
										if currentlyUsedBP and currentlyUsedBP > 0 then 				
											cacheTotallyUsedBP = cacheTotallyUsedBP + currentlyUsedBP
											cacheMetalCostOfUsedBuildPower = cacheMetalCostOfUsedBuildPower + unitCostData[unitDefID].metal * currentlyUsedBP / currentUnitBP 
										end -- until here
									end
								end
							end
						end
					end
					nowChecking = nowChecking + 1
					--Log("nowChecking new one" ..nowChecking)
				end
				cacheDataBase[1] = cacheDataBase[1] + cacheMetalCostOfUsedBuildPower
				cacheDataBase[3] = cacheDataBase[3] + cacheTotalReservedBP
				cacheDataBase[5] = cacheDataBase[5] + cacheTotallyUsedBP
				cacheDataBase[6] = cacheDataBase[6] + cacheTotalStallingM
				cacheDataBase[7] = cacheDataBase[7] + cacheTotalStallingE
				trackPosBase = trackPosBase + unitsPerFrame
				--Log("trackPosBase-----------------" ..trackPosBase)
			end
		end
	end
	local ignore = false
	if ignore ~= true then
		for i = 1, 1 do
			if gameFrame % 2 == 0 and drawBPIndicators == true then
				Log(i)
				local totalMetalCostOfBuilders = BP[2]
				local avgTotalReservedBP = BP[3]
				local totalAvailableBP = BP[4]
				local avgTotalUsedBP = BP[5]
				local usefulBPFactorM = BP[8]
				local usefulBPFactorE = BP[9]
				
				if BP[2] == nil then
					totalMetalCostOfBuilders = 1
				end

				if BP[3] == nil then
					avgTotalReservedBP = 1
				end
				if BP[4] == nil then
					totalAvailableBP = 1
				end

				if BP[5] == nil then
					avgTotalUsedBP = 1
				end

				if BP[8] == nil then
					usefulBPFactorM = 1
				end
				if BP[9] == nil then
					usefulBPFactorE = 1
				end
				local indicatorPosM = usefulBPFactorM * avgTotalReservedBP / totalAvailableBP
				local indicatorPosE = usefulBPFactorE * avgTotalReservedBP / totalAvailableBP
				if indicatorPosM == nil or indicatorPosM > 1 then --be save that the usefulBPFactorM isn't nil or over 100%
					indicatorPosM = 1
				end
				if indicatorPosE == nil or indicatorPosE > 1 then --be save that the usefulBPFactorE isn't nil or over 100%
					indicatorPosE = 1
				end
				BP[10] = indicatorPosM
				BP[11] = indicatorPosE
			end
		end
	end
	--Log("% 2 done")
	--if gameFrame % 15 == 0 then
		if trackPosBase >= trackedNum then
			--Log("show stuff-----------------")
			local totalReservedBP = cacheDataBase[3]
			local totallyUsedBP = cacheDataBase[5]
			trackPosBase = 0
			if drawBPBar == true then --this section will smooth the values so that factories that finish units won't have too much of an impact
				table.insert(totalReservedBPData, totalReservedBP)
				if #totalReservedBPData > 30 then --so a grand total of x refresh cicles is considdered (search for "if gameFrame % = " to find the time steps )
					table.remove(totalReservedBPData, 1)
				end

				local avgTotalReservedBP = 0
				
				for _, power in ipairs(totalReservedBPData) do
					avgTotalReservedBP = avgTotalReservedBP + power
				end

				avgTotalReservedBP = math.floor(avgTotalReservedBP / #totalReservedBPData)

				table.insert(totalUsedBPData, totallyUsedBP)
				if #totalUsedBPData > 30 then --so a grand total of x refresh cicles is considdered (search for "if gameFrame % = " to find the time steps )
					table.remove(totalUsedBPData, 1)
				end

				local avgTotalUsedBP = 0
				for _, power in ipairs(totalUsedBPData) do
					avgTotalUsedBP = avgTotalUsedBP + power
				end

				avgTotalUsedBP = math.floor(avgTotalUsedBP / #totalUsedBPData)
				BP[1] = cacheDataBase[1]
				BP[3] = avgTotalReservedBP
				updateResbar('BP')
				BP[5] = avgTotalUsedBP
				cacheDataBase[1] = 0
				cacheDataBase[3] = 0
				cacheDataBase[5] = 0
				
			end
			BP[6] = cacheDataBase[6]
			BP[7] = cacheDataBase[7]
			cacheDataBase[6] = 0
			cacheDataBase[7] = 0
			nowChecking = 0
		end
	--end -- calculations end here
	Log("GameFrame(n)")
end

local function updateAllyTeamOverflowing()
	Log("updateAllyTeamOverflowing()")
	allyteamOverflowingMetal = false
	allyteamOverflowingEnergy = false
	overflowingMetal = false
	overflowingEnergy = false
	playerStallingMetal = false
	playerStallingEnergy = false
	local totalMetal = 0
	local totalMetalStorage = 0
	local totalEnergy = 0
	local totalEnergyStorage = 0
	local metalPercentile, energyPercentile 
	local teams = Spring.GetTeamList(myAllyTeamID)
	for i, teamID in pairs(teams) do
		local metal, metalStorage, metalPull, metalIncome, _, metalShare, metalSent = spGetTeamResources(teamID, "metal")
		totalMetal = totalMetal + metal
		totalMetalStorage = totalMetalStorage + metalStorage
		local energy, energyStorage, energyPull, energyIncome, _, energyShare, energySent = spGetTeamResources(teamID, "energy")
		totalEnergy = totalEnergy + energy
		totalEnergyStorage = totalEnergyStorage + energyStorage
		if teamID == myTeamID then
			metalPercentile = metalSent / totalMetalStorage
			energyPercentile = energySent / totalEnergyStorage
			if metalPercentile > 0.0001 then
				overflowingMetal = metalPercentile * (1 / 0.025)
				if overflowingMetal > 1 then
					overflowingMetal = 1
				end
			end
			if energyPercentile > 0.0001 then
				overflowingEnergy = energyPercentile * (1 / 0.025)
				if overflowingEnergy > 1 then
					overflowingEnergy = 1
				end
			end


			-- needed for exact calculations
			local realMetalPull = metalPull
			local realEnergyPull = energyPull
			if BP[6] then
				totalStallingM = BP[6]
				totalStallingE = BP[7]
			end	
			addStalling = false 
			for unitID, currentUnitBP in pairs(trackedBuilders) do
				if addStalling == true then 
					break
				end
				local prio = checkPriority(unitID)
				if checkPriority(unitID) == "low" then
					addStalling = true
				end 
			end
			if totalStallingM and totalStallingE then
				if addStalling == true then
					realMetalPull = metalPull + totalStallingM
					realEnergyPull = energyPull + totalStallingE
				end 
			end -- until here
			if res ~= 'BP' or drawBPBar == true then
				local usefulBPFactorM = metalIncome / realMetalPull
				local usefulBPFactorE = energyIncome / realEnergyPull
				BP[8] = usefulBPFactorM
                BP[9] = usefulBPFactorE
				if usefulBPFactorM < 0.8 and metal < 2 * metalPull then
					playerStallingMetal = 1
				end

				if usefulBPFactorE < 0.8 and energy < 2 * energyPull then
					playerStallingEnergy = 1
				end
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
	Log("end")
end

local sec = 0
local sec2 = 0
local secComCount = 0
local blinkDirection = true
local blinkProgress = 0

function widget:Update(dt)
	local prevMyTeamID = myTeamID
	if spec and spGetMyTeamID() ~= prevMyTeamID then
		-- check if the team that we are spectating changed
		checkSelfStatus()
		init()
	end

	local mx, my = spGetMouseState()
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
	if sec > 0.1 then
		Log("sec > 0.1")
		if BP[1] == nil or BP[2] == 0 then -- for bp bar only (change player while specing/ player death)
			BP = initData
		end 
		sec = 0
		r = { metal = { spGetTeamResources(myTeamID, 'metal') }, energy = { spGetTeamResources(myTeamID, 'energy') }, BP = BP }
		if not spec and not showQuitscreen then
			if drawBPBar == true then
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
			if drawBPBar == true then
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
		Log("sec > 0.1 end")
	end
	
	sec2 = sec2 + dt
	if sec2 >= 1 then
		Log("sec2 >= 1")
		sec2 = 0
		updateResbarText('metal')
		updateResbarText('energy')
		if drawBPBar == true then
			updateResbarText('BP') 
		end
		updateAllyTeamOverflowing()
		Log("sec2 >= 1 end")
	end

	-- wind
	if gameFrame ~= lastFrame then
		Log("wind")
		currentWind = sformat('%.1f', select(4, spGetWind()))
	end

	-- coms
	if displayComCounter then
		secComCount = secComCount + dt
		if secComCount > 0.5 then
			Log("secComCount > 0.5")
			secComCount = 0
			countComs()
		end
	end
end

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

function widget:drawTidal()
	if displayTidalSpeed and tidaldlist1 then
		glPushMatrix()
		glCallList(tidaldlist1)
		glTranslate(tidalarea[1] + ((tidalarea[3] - tidalarea[1]) / 2), math.sin(now/math.pi) * tidalWaveAnimationHeight + tidalarea[2] + (bgpadding/2) + ((tidalarea[4] - tidalarea[2]) / 2), 0)
		glCallList(tidaldlist2)
		glPopMatrix()
	end
end

local function drawResBars() --hadles the blinking
	Log("drawResBars()")
	glPushMatrix()

	local updateText = os.clock() - updateTextClock > 0.1
	if updateText then
		updateTextClock = os.clock()
	end

	local res = 'metal'
	if dlistResbar[res][1] and dlistResbar[res][2] and dlistResbar[res][3] then
		glCallList(dlistResbar[res][1])

		if not spec and gameFrame > 90 then
			if allyteamOverflowingMetal then
				glColor(1, 0, 0, 0.13 * allyteamOverflowingMetal * blinkProgress)
			elseif overflowingMetal then
				glColor(1, 1, 1, 0.05 * overflowingMetal * (0.6 + (blinkProgress * 0.4)))
			end
			if allyteamOverflowingMetal or overflowingMetal then
				glCallList(dlistResbar[res][4])
			end
		end
		-- low energy background
		if r[res][1] < 1000 then
			local process = (r[res][1] / r[res][2]) * 13
			if process < 1 then
				process = 1 - process
				glColor(0.9, 0.4, 1, 0.08 * process)
				glCallList(dlistResbar[res][5])
			end
		end
		drawResbarValues(res, updateText)
		glCallList(dlistResbar[res][6])
		glCallList(dlistResbar[res][3])
		glCallList(dlistResbar[res][2])
	end

	res = 'energy'
	if dlistResbar[res][1] and dlistResbar[res][2] and dlistResbar[res][3] then
		glCallList(dlistResbar[res][1])

		if not spec and gameFrame > 90 then
			if allyteamOverflowingEnergy then
				glColor(1, 0, 0, 0.13 * allyteamOverflowingEnergy * blinkProgress)
			elseif overflowingEnergy then
				glColor(1, 1, 0, 0.05 * overflowingEnergy * (0.6 + (blinkProgress * 0.4)))
			end
			if allyteamOverflowingEnergy or overflowingEnergy then
				glCallList(dlistResbar[res][4])
			end
			-- low energy background
			if r[res][1] < 2000 then
				local process = (r[res][1] / r[res][2]) * 13
				if process < 1 then
					process = 1 - process
					glColor(0.9, 0.55, 1, 0.08 * process)
					glCallList(dlistResbar[res][5])
				end
			end
		end
		drawResbarValues(res, updateText)
		glCallList(dlistResbar[res][6])
		glCallList(dlistResbar[res][3])
		glCallList(dlistResbar[res][2])
	end
	if drawBPBar == true then
		res = 'BP' -- for bp bar only
		if dlistResbar[res][1] and dlistResbar[res][2] and dlistResbar[res][3] then
			glCallList(dlistResbar[res][1])

			if not spec and gameFrame > 90 then
				if playerStallingMetal then
					glColor(0.0, -0.4, -0.4, 0.5 * playerStallingMetal * blinkProgress)
				elseif playerStallingEnergy then
					glColor(0.2, -0.2, -1, 0.5 * playerStallingEnergy * blinkProgress)
				end
				if playerStallingMetal or playerStallingEnergy then
					glCallList(dlistResbar[res][4])
				end
				-- low energy background
				--if r[res][1] < 2000 then
				--	local process = (r[res][1] / r[res][2]) * 13
				--	if process < 1 then
				--		process = 1 - process
				--		glColor(0.9, 0.55, 1, 0.08 * process)
				--		glCallList(dlistResbar[res][5])
				--	end
				--end
			end
			drawResbarValues(res, updateText)
			glCallList(dlistResbar[res][6])
			glCallList(dlistResbar[res][3])
			glCallList(dlistResbar[res][2])
		end
	end
	glPopMatrix()
	Log("drawResBars() end")
end

function widget:DrawScreen()
	drawResBars()

	local now = os.clock()
	local mx, my, mb = spGetMouseState()
	hoveringTopbar = hoveringElement(mx, my)
	if hoveringTopbar then
		Spring.SetMouseCursor('cursornormal')
	end

	if dlistWind1 then
		glPushMatrix()
		glCallList(dlistWind1)
		glRotate(windRotation, 0, 0, 1)
		glCallList(dlistWind2)
		glPopMatrix()
		-- current wind
		if gameFrame > 0 then
			if minWind+maxWind >= 0.5 then
				local fontSize = (height / 2.66) * widgetScale
				if not dlistWindText[currentWind] then
					dlistWindText[currentWind] = glCreateList(function()
						font2:Begin()
						font2:Print("\255\255\255\255" .. currentWind, windArea[1] + ((windArea[3] - windArea[1]) / 2), windArea[2] + ((windArea[4] - windArea[2]) / 2.05) - (fontSize / 5), fontSize, 'oc') -- Wind speed text
						font2:End()
					end)
				end
				glCallList(dlistWindText[currentWind])
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

	if autoHideButtons then
		if buttonsArea[1] and math_isInRect(mx, my, buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4]) then
			if not showButtons then
				showButtons = true
				dlistButtonsGuishader = glCreateList(function()
					RectRound(buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4], 5.5 * widgetScale, 0, 0, 1, 1)
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

	if showButtons and dlistButtons1 then
		glCallList(dlistButtons1)

		-- changelog changes highlight
		if WG['changelog'] and WG['changelog'].haschanges() then
			local button = 'changelog'
			local paddingsize = 1
			RectRound(buttonsArea['buttons'][button][1]+paddingsize, buttonsArea['buttons'][button][2]+paddingsize, buttonsArea['buttons'][button][3]-paddingsize, buttonsArea['buttons'][button][4]-paddingsize, 3.5 * widgetScale, 0, 0, 0, button == firstButton and 1 or 0, { 1, 1, 1, 0.1 * blinkProgress })
		end

		-- hovered?
		if not showQuitscreen and buttonsArea['buttons'] ~= nil and math_isInRect(mx, my, buttonsArea[1], buttonsArea[2], buttonsArea[3], buttonsArea[4]) then
			for button, pos in pairs(buttonsArea['buttons']) do
				if math_isInRect(mx, my, pos[1], pos[2], pos[3], pos[4]) then
					local paddingsize = 1
					RectRound(buttonsArea['buttons'][button][1]+paddingsize, buttonsArea['buttons'][button][2]+paddingsize, buttonsArea['buttons'][button][3]-paddingsize, buttonsArea['buttons'][button][4]-paddingsize, 3.5 * widgetScale, 0, 0, 0, button == firstButton and 1 or 0, { 0, 0, 0, 0.06 })
					glBlending(GL_SRC_ALPHA, GL_ONE)
					RectRound(buttonsArea['buttons'][button][1], buttonsArea['buttons'][button][2], buttonsArea['buttons'][button][3], buttonsArea['buttons'][button][4], 3.5 * widgetScale, 0, 0, 0, button == firstButton and 1 or 0, { 1, 1, 1, mb and 0.13 or 0.03 }, { 0.44, 0.44, 0.44, mb and 0.4 or 0.2 })
					local mult = 1
					RectRound(buttonsArea['buttons'][button][1], buttonsArea['buttons'][button][4] - ((buttonsArea['buttons'][button][4] - buttonsArea['buttons'][button][2]) * 0.4), buttonsArea['buttons'][button][3], buttonsArea['buttons'][button][4], 3.3 * widgetScale, 0, 0, 0, 0, { 1, 1, 1, 0 }, { 1, 1, 1, 0.18 * mult })
					RectRound(buttonsArea['buttons'][button][1], buttonsArea['buttons'][button][2], buttonsArea['buttons'][button][3], buttonsArea['buttons'][button][2] + ((buttonsArea['buttons'][button][4] - buttonsArea['buttons'][button][2]) * 0.25), 3.3 * widgetScale, 0, 0, 0, button == firstButton and 1 or 0, { 1, 1, 1, 0.045 * mult }, { 1, 1, 1, 0 })
					glBlending(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
					break
				end
			end
		end
		glCallList(dlistButtons2)
	end

	if dlistQuit ~= nil then
		if WG['guishader'] then
			WG['guishader'].removeRenderDlist(dlistQuit)
		end
		glDeleteList(dlistQuit)
		dlistQuit = nil
	end
	if showQuitscreen ~= nil then
		local fadeoutBonus = 0
		local fadeTime = 0.2
		local fadeProgress = (now - showQuitscreen) / fadeTime
		if fadeProgress > 1 then
			fadeProgress = 1
		end

		Spring.SetMouseCursor('cursornormal')

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
				UiElement(quitscreenArea[1], quitscreenArea[2], quitscreenArea[3], quitscreenArea[4], 1, 1, 1, 1, 1, 1, 1, 1, nil, {1, 1, 1, 0.6 + (0.34 * fadeProgress)}, {0.45, 0.45, 0.4, 0.025 + (0.025 * fadeProgress)})

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
					UiButton(quitscreenStayArea[1], quitscreenStayArea[2], quitscreenStayArea[3], quitscreenStayArea[4], 1, 1, 1, 1, 1, 1, 1, 1, nil, color1, color2, padding * 0.5)
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
					UiButton(quitscreenResignArea[1], quitscreenResignArea[2], quitscreenResignArea[3], quitscreenResignArea[4], 1, 1, 1, 1, 1, 1, 1, 1, nil, color1, color2, padding * 0.5)
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
					UiButton(quitscreenQuitArea[1], quitscreenQuitArea[2], quitscreenQuitArea[3], quitscreenQuitArea[4], 1, 1, 1, 1, 1, 1, 1, 1, nil, color1, color2, padding * 0.5)
					font2:Print(Spring.I18N('ui.topbar.quit.quit'), quitscreenQuitArea[1] + ((quitscreenQuitArea[3] - quitscreenQuitArea[1]) / 2), quitscreenQuitArea[2] + ((quitscreenQuitArea[4] - quitscreenQuitArea[2]) / 2) - (fontSize / 3), fontSize, "con")
				end

				font2:End()
			end
		end)

		-- background
		if WG['guishader'] then
			WG['guishader'].setScreenBlur(true)
			WG['guishader'].insertRenderDlist(dlistQuit)
		else
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
			--local seconds = math.floor((gameframe - ((minutes * 60) * 30)) / 30)
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
	--up = true/false, value = -1/1
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
	InitAllUnits()
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
	UntrackBuilder(unitID)
end

function widget:UnitGiven(unitID, unitDefID, unitTeam)
    TrackBuilder(unitID, unitDefID, unitTeam)
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    TrackBuilder(unitID, unitDefID, unitTeam)
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
	UntrackBuilder(unitID)	
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
	gameFrame = Spring.GetGameFrame()
	Spring.SendCommands("resbar 0")
	InitAllUnits()
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
		-- Spezielle Behandlung für Kommandeur-Einheiten
		if unitName == "armcom" or unitName == "corcom" then
			unitCostData[unitDefID].metal = metalCostForCommander
		end
    end
	-- determine if we want to show comcounter
	local allteams = Spring.GetTeamList()
	local teamN = table.maxn(allteams) - 1               --remove gaia
	if teamN > 2 then
		displayComCounter = true
	end

	WG['topbar'] = {}
	WG['topbar'].showingQuit = function()
		return (showQuitscreen ~= nil)
	end
	WG['topbar'].hideWindows = function()
		hideWindows()
	end
	WG['topbar'].setAutoHideButtons = function(value)
		autoHideButtons = value
		showButtons = not value
		updateButtons()
	end
	WG['topbar'].getAutoHideButtons = function()
		return autoHideButtons
	end
	WG['topbar'].getShowButtons = function()
		return showButtons
	end

	widget:ViewResize()

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

		for n, _ in pairs(dlistWindText) do
			dlistWindText[n] = glDeleteList(dlistWindText[n])
		end
		for n, _ in pairs(dlistResbar['metal']) do
			dlistResbar['metal'][n] = glDeleteList(dlistResbar['metal'][n])
		end
		for n, _ in pairs(dlistResbar['energy']) do
			dlistResbar['energy'][n] = glDeleteList(dlistResbar['energy'][n])
		end
		if drawBPBar == true then
			for n, _ in pairs(dlistResbar['BP']) do
				dlistResbar['BP'][n] = glDeleteList(dlistResbar['BP'][n])
			end
		end
		for res, _ in pairs(dlistResValues) do
			for n, _ in pairs(dlistResValues[res]) do
				dlistResValues[res][n] = glDeleteList(dlistResValues[res][n])
			end
		end
		for res, _ in pairs(dlistResValuesBar) do
			for n, _ in pairs(dlistResValuesBar[res]) do
				dlistResValuesBar[res][n] = glDeleteList(dlistResValuesBar[res][n])
			end
		end
	end
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
end

function widget:Shutdown()
	Spring.SendCommands("resbar 1")
	shutdown()
	WG['topbar'] = nil
end

function widget:GetConfigData()
	return {
		autoHideButtons = autoHideButtons
	}
end

function widget:SetConfigData(data)
	if data.autoHideButtons ~= nil then
		autoHideButtons = data.autoHideButtons
	end
end


function findBPCommand(unitID, unitDefID, cmdList) -- for bp bar only most likely
	--Log("findBPCommand")
    local commands = Spring.GetUnitCommands(unitID, -1)
	local unitDef = UnitDefs[unitDefID]
	if unitDef.isFactory == true then
		--Log("unitDef.isFactory == true")
		if #Spring.GetFactoryCommands(unitID, -1) > 0 then

			local firstTime = i
			return true, firstTime
		end
	end
    for i = 1, #commands do
        for _, relevantCMD in ipairs(cmdList) do
            if commands[i].id == relevantCMD or commands[i].id < 0 then
				--Log("commands[i].id == relevantCMD or commands[i].id < 0")
                local firstTime = i
                return true, firstTime
            end
        end
    end
    return false, nil
end

function TrackBuilder(unitID, unitDefID, unitTeam) -- needed for exact calculations
	local unitDef = UnitDefs[unitDefID]
	if (myTeamID == unitTeam) then
		if unitDef and unitDef.buildSpeed and unitDef.buildSpeed > 0 and unitDef.canAssist then
			local isFactory = false -- is factory is needed for bp bar only (switch metal cost on/off)
			if unitDef.isFactory == true then
				isFactory = true
			end
			if isFactory == false or (isFactory == true and includeFactories == true) then
				trackedNum = trackedNum + 1
				local unitDefID = Spring.GetUnitDefID(unitID) --handling metal cost
				if not UnitDefs[unitDefID].metalCost then
					UnitDefs[unitDefID].metalCost = 100 -- Standard value if somthing went wrong
				end
				local currentUnitMetalCost = UnitDefs[unitDefID].metalCost
				local unitName = UnitDefs[unitDefID].name -- Cost of Comms
				if unitName == "armcom" or unitName == "corcom" then
					currentUnitMetalCost = metalCostForCommander
				end
				BP[2] = BP[2] + currentUnitMetalCost --BP[2] ^= totalMetalCostOfBuilders
				trackedBuilders[unitID] = unitDef.buildSpeed
				BP[4] = BP[4] + trackedBuilders[unitID] -- BP[4] ^= totalAvailableBP
			end
		end
	end
end

function UntrackBuilder(unitID, unitDefID, unitTeam) -- needed for exact calculations
	local unitDef = UnitDefs[unitDefID]
	if (myTeamID == unitTeam) then
		if unitDef and unitDef.buildSpeed and unitDef.buildSpeed > 0 and unitDef.canAssist then
			local isFactory = false -- is factory is needed for bp bar only (switch metal cost on/off)
			if unitDef.isFactory == true then
				isFactory = true
			end
			if isFactory == false or (isFactory == true and includeFactories == true) then
				trackedNum = trackedNum - 1
				local unitDefID = Spring.GetUnitDefID(unitID) --handling metal cost
				if not UnitDefs[unitDefID].metalCost then
					UnitDefs[unitDefID].metalCost = 100 -- Standard value if somthing went wrong
				end
				local currentUnitMetalCost = UnitDefs[unitDefID].metalCost
				local unitName = UnitDefs[unitDefID].name -- Cost of Comms
				if unitName == "armcom" or unitName == "corcom" then
					currentUnitMetalCost = metalCostForCommander
				end
				BP[2] = BP[2] - currentUnitMetalCost --BP[2] ^= totalMetalCostOfBuilders
				trackedBuilders[unitID] = unitDef.buildSpeed
				BP[4] = BP[4] - trackedBuilders[unitID] -- BP[4] ^= totalAvailableBP
			end
		end
	end
end
--function removeBuildUnitFromBP(unitID)
--	if Spring.ValidUnitID(unitID) and not Spring.GetUnitIsDead(unitID) then
--		local unitDefID = Spring.GetUnitDefID(unitID)
--		-- Sicherstellen, dass ein Metallkostenwert vorhanden ist
--		if not UnitDefs[unitDefID].metalCost then
--			UnitDefs[unitDefID].metalCost = 100 -- Standardwert, falls nicht vorhanden
--		end
--		local currentUnitMetalCost = UnitDefs[unitDefID].metalCost
--		local unitName = UnitDefs[unitDefID].name
--		-- Spezielle Behandlung für Kommandeur-Einheiten
--		if unitName == "armcom" or unitName == "corcom" then
--			currentUnitMetalCost = metalCostForCommander
--		end
--		BP[2] = BP[2] - currentUnitMetalCost
--		BP[4] = BP[4] - currentUnitBP	
--	end
--end

function InitAllUnits()
	BP[2] = 0
	BP[4] = 0
	trackedNum = 0
	trackedBuilders = nil
    trackedBuilders = {}
	for _, unitID in pairs(Spring.GetTeamUnits(myTeamID)) do  -- needed for exact calculations
		TrackBuilder(unitID, Spring.GetUnitDefID(unitID), myTeamID)
	end
end

--function calcTotalMAndBPOfBuilders()
--	Log("calcTotalMAndBPOfBuilders")
--	local totalMetalCostOfBuilders = 0
--	local totalAvailableBP = 0
--	for unitID, currentUnitBP in pairs(trackedBuilders) do
--		-- Prüfen, ob die Einheit gültig und nicht tot ist
--		if Spring.ValidUnitID(unitID) and not Spring.GetUnitIsDead(unitID) then
--			local unitDefID = Spring.GetUnitDefID(unitID)
--			-- Sicherstellen, dass ein Metallkostenwert vorhanden ist
--			if not UnitDefs[unitDefID].metalCost then
--				UnitDefs[unitDefID].metalCost = 100 -- Standardwert, falls nicht vorhanden
--			end
--			local currentUnitMetalCost = UnitDefs[unitDefID].metalCost
--			local unitName = UnitDefs[unitDefID].name
--			-- Spezielle Behandlung für Kommandeur-Einheiten
--			if unitName == "armcom" or unitName == "corcom" then
--				currentUnitMetalCost = metalCostForCommander
--			end
--			totalMetalCostOfBuilders = totalMetalCostOfBuilders + currentUnitMetalCost
--			totalAvailableBP = totalAvailableBP + currentUnitBP
--		end
--	end
--	BP[2] = totalMetalCostOfBuilders
--	BP[4] = totalAvailableBP
--end

--function addBuildUnitToBP(unitID)
--	if Spring.ValidUnitID(unitID) and not Spring.GetUnitIsDead(unitID) then
--		local unitDefID = Spring.GetUnitDefID(unitID)
--		-- Sicherstellen, dass ein Metallkostenwert vorhanden ist
--		if not UnitDefs[unitDefID].metalCost then
--			UnitDefs[unitDefID].metalCost = 100 -- Standardwert, falls nicht vorhanden
--		end
--		local currentUnitMetalCost = UnitDefs[unitDefID].metalCost
--		local unitName = UnitDefs[unitDefID].name
--		-- Spezielle Behandlung für Kommandeur-Einheiten
--		if unitName == "armcom" or unitName == "corcom" then
--			currentUnitMetalCost = metalCostForCommander
--		end
--		BP[2] = BP[2] + currentUnitMetalCost
--		BP[4] = BP[4] + currentUnitBP	
--	end
--end
