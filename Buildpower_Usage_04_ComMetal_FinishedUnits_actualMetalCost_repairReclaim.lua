function widget:GetInfo()
    return {
        name    = "Buildpower Usage with multi color bar 04",
        desc    = "Shows how much of build power is used.",
        author  = "Robert82 and hihoman23",
        date    = "2023",
        license = "GNU GPL, v2 or later",
        layer   = 0,
        enabled = true --  loaded by default?
    }
end

local metalCostForCommander = 1250 --NEW  Set your own price for your commander

local myTeamID = Spring.GetMyTeamID()



local glCreateList = gl.CreateList
local glCallList = gl.CallList
local glGetViewSizes = gl.GetViewSizes
local glDeleteList = gl.DeleteList

local vsx, vsy = Spring.GetViewGeometry()
local widgetScale = (0.80 + (vsx * vsy / 6000000))

local fontfile2 = "fonts/" .. Spring.GetConfigString("bar_font2", "Exo2-SemiBold.otf")
local font2

local RectRound, UiElement
local dlistGuishader, dlistCU
local area ={}

local floor = math.floor
local round = math.round

local gameStarted = false

local builderUnits = {}
local totalBuildPower

local activeBuildPowerData = {}
local activeBuildPower
local avgActiveBuildPower 
local activeBuildPowerPercentage

local usedBuildPowerData ={}
local usedBuildPower
local avgUsedBuildPower
local usedBuildPowerPercentage

local totalMetalCostOfBuilders
local metalCostUnusedBuilders
local metalCostOfUsedBuildPower --NEW
local foundActivity --NEW

local Debugmode=false
function Log(Message)  --Logs almost everything
	if Debugmode==true then
		Spring.Echo(Message)
	end
end

local Debugmode1=true
function Log1(Message) --Logs new stuff
	if Debugmode1==true then
		Spring.Echo(Message)
	end
end


local function updateUI()
    Log("Updating UI...")
    -- place the widget in the free space next to the top bar
    local freeArea = WG['topbar'].GetFreeArea()
    widgetScale = freeArea[5]
    area[1] = freeArea[1]
    area[2] = freeArea[2]
    area[3] = freeArea[1] + floor(150 * widgetScale) -- how long shall it be? 40 is about as long as it's hight
    if area[3] > freeArea[3] then
        area[3] = freeArea[3]
    end
    area[4] = freeArea[4]
    -- make sure this widget is pushed by the converter_usage widget
    if WG['converter_usage'] then
        local converter_usage_area = WG['converter_usage'].GetPosition()
        local converter_usage_width = converter_usage_area[3] - converter_usage_area[1]
        area[1] = area[1] + converter_usage_width
        area[3] = area[3] + converter_usage_width
    end

	if dlistGuishader ~= nil then
		if WG['guishader'] then
			WG['guishader'].RemoveDlist('build_power_bar')
		end
		glDeleteList(dlistGuishader)
	end

	dlistGuishader = glCreateList(function()
		RectRound(area[1], area[2], area[3], area[4], 5.5 * widgetScale, 0, 0, 1, 1)
	end)

    local fontSize = (area[4] - area[2]) * 0.4
    local color = "\255\255\255\255"


    if dlistCU ~= nil then
        glDeleteList(dlistCU)
    end


	dlistCU = glCreateList(function()
		UiElement(area[1], area[2], area[3], area[4], 0, 0, 1, 1)

		if WG['guishader'] then
			WG['guishader'].InsertDlist(dlistGuishader, 'build_power_bar')
		end
        -- color of the text
        if usedBuildPowerPercentage < 20 then
            color = "\255\255\20\000" --Red  
        elseif usedBuildPowerPercentage < 40 then
            color = "\255\255\100\000" --Orange
        elseif usedBuildPowerPercentage < 50 then
            color = "\255\255\255\000" --Yellow
        elseif usedBuildPowerPercentage < 70 then
            color = "\255\215\230\100" --Yelleen?
        else
            color = "\255\000\255\000" --Green
        end

        local _, _, _, income, _, _, _, _ = Spring.GetTeamResources(myTeamID, "metal") 
        metalCostUnusedBuilders = totalMetalCostOfBuilders - metalCostOfUsedBuildPower  --NEW
        if D then colorM = "\255\255\20\000" --Red 
        elseif income*80 < metalCostUnusedBuilders then colorM = "\255\255\100\000" --Orange 
        elseif income*40 < metalCostUnusedBuilders then colorM = "\255\255\255\000" --Yellow 
        elseif income*20 < metalCostUnusedBuilders then colorM = "\255\215\230\100" --Yelleen? 
        else colorM = "\255\000\255\000" end --Green 

        -- draw a bar
        local barWidth = (area[3] - area[1]- 10 * widgetScale)   
        local barHeight = 20 * widgetScale  
        local barX = area[1] + 5 * widgetScale
        local barY = area[2] + 5 * widgetScale

        -- Background of the bar
        gl.Color(0.7, 0.1, 0.1, 1)  -- Grau
        gl.Rect(barX, barY, barX + barWidth, barY + barHeight)

        -- Filling of the bar with active BP
        local fillActiveWidth = barWidth * (activeBuildPowerPercentage / 100)  -- % of filling
        gl.Color(0.5, 0.5, 0, 1)  -- Grün
        gl.Rect(barX, barY, barX + fillActiveWidth, barY + barHeight)

        -- Filling of the bar with used BP
        local fillUsedWidth = barWidth * (usedBuildPowerPercentage / 100)  -- % of filling
        gl.Color(0, 1, 0, 1)  -- gelb
        gl.Rect(barX, barY, barX + fillUsedWidth, barY + barHeight)

        -- text: useful BP %
        local roundedUsedBuildPowerPercentage = math.floor(usedBuildPowerPercentage)
        font2:Begin()
            fontSize = fontSize * 0.75
  
            font2:Print(color .. roundedUsedBuildPowerPercentage .. "%", area[1] + (fontSize * 0.42), area[2] + 3.2 * ((area[4] - area[2]) / 4) - (fontSize / 5), fontSize, 'ol')

            -- Adding the code to display metalCostUnusedBuilders
            font2:Print(colorM .. "Metal: " .. metalCostUnusedBuilders, area[3] - (fontSize * 0.42), area[2] + 3.2 * ((area[4] - area[2]) / 4) - (fontSize / 5), fontSize, 'or')


        font2:End()
	end)
end



function widget:DrawScreen()
    Log("DrawScreen()")
    if dlistCU and dlistGuishader then
        glCallList(dlistCU)
    end
    if area[1] then
        local x, y = Spring.GetMouseState()
        if math.isInRect(x, y, area[1], area[2], area[3], area[4]) then
            Spring.SetMouseCursor('cursornormal')
        end
    end
end



function widget:Shutdown()
    Log("Shutdown()")
    if dlistGuishader ~= nil then
        if WG['guishader'] then
            WG['guishader'].RemoveDlist('build_power_bar')
        end
        glDeleteList(dlistGuishader)
    end
    if dlistCU ~= nil then
        glDeleteList(dlistCU)
    end
    WG['converter_usage'] = nil
end



function widget:ViewResize()
    Log("ViewResize()")
    vsx, vsy = glGetViewSizes()

    RectRound = WG.FlowUI.Draw.RectRound
    UiElement = WG.FlowUI.Draw.Element

    font2 = WG['fonts'].getFont(fontfile2)
end



function widget:GameFrame(n)
    if n % 6 == 0 then
        Log("GameFrame(n)")
        gameStarted = true

        totalBuildPower = 0
        activeBuildPower = 0
        usedBuildPower = 0
        totalMetalCostOfBuilders = 0 
        metalCostOfUsedBuildPower = 0 --NEW

        for unitID, buildSpeed in pairs(builderUnits) do
            Log("unitID " ..tostring(unitID))
            totalBuildPower = totalBuildPower + buildSpeed
            Log("totalBuildPower " ..tostring(totalBuildPower))
            local unitDefID = Spring.GetUnitDefID(unitID)
            Log("unitDefID " ..tostring(unitDefID))
            local metalCost = UnitDefs[unitDefID].metalCost
            Log("metalCost " ..tostring(metalCost))
            local unitName = UnitDefs[unitDefID].name               --NEW
            if unitName == "armcom" or unitName == "corcom" then    --NEW
                 Log("Commmander found" ..tostring(metalCostForCommander) )
                metalCost = metalCostForCommander                   --NEW
            end
            totalMetalCostOfBuilders = totalMetalCostOfBuilders + metalCost
            Log("totalMetalCostOfBuilders " ..tostring(totalMetalCostOfBuilders))
            foundActivity, _, _, _ = findFirstCommand(unitID, CMD.REPAIR, CMD.RECLAIM, CMD.CAPTURE) --NEW
            Log("foundActivity " ..tostring(foundActivity))
            -- local foundBuildingWish = findBuildCommand(unitID)
            if foundActivity == true or Spring.GetUnitIsBuilding(unitID)  then -- foundBuildingWish == true
                activeBuildPower = activeBuildPower + buildSpeed
                Log("activeBuildPower " ..tostring(activeBuildPower))
                useBuildPower = (Spring.GetUnitCurrentBuildPower(unitID) or 0) * buildSpeed
                if useBuildPower and useBuildPower > 0 then
                    usedBuildPower = usedBuildPower + useBuildPower
                    metalCostOfUsedBuildPower = metalCostOfUsedBuildPower+ metalCost*useBuildPower/activeBuildPower --NEW
                    Log("usedBuildPower " ..tostring(usedBuildPower))
                end
            end
        end

        activeBuildPowerPercentage = 0
        if totalBuildPower > 0 then
            activeBuildPowerPercentage = (activeBuildPower / totalBuildPower) * 100
            Log("activeBuildPowerPercentage " ..tostring(activeBuildPowerPercentage))
        end

        table.insert(activeBuildPowerData, activeBuildPowerPercentage)
        if #activeBuildPowerData > 30 then
            table.remove(activeBuildPowerData, 1)
        end

        avgActiveBuildPower = 0

        for _, power in ipairs(activeBuildPowerData) do
            avgActiveBuildPower = avgActiveBuildPower + power
        end
        avgActiveBuildPower = math.floor(avgActiveBuildPower / #activeBuildPowerData)
        Spring.Echo(avgActiveBuildPower)



        usedBuildPowerPercentage = 0
        if totalBuildPower > 0 then
            usedBuildPowerPercentage = (usedBuildPower / totalBuildPower) * 100
        end

        table.insert(usedBuildPowerData, usedBuildPowerPercentage)
        if #usedBuildPowerData > 30 then
            table.remove(usedBuildPowerData, 1)
        end

        avgUsedBuildPower = 0
        for _, power in ipairs(usedBuildPowerData) do
            avgUsedBuildPower = avgUsedBuildPower + power
        end
        avgUsedBuildPower = math.floor(avgUsedBuildPower / #usedBuildPowerData)
        Spring.Echo(avgUsedBuildPower)
    end
end


function findFirstCommand(unitID, ...) --NEW FUNCTION checks for one of the commands in the brackets
    local commands = Spring.GetUnitCommands(unitID, -1)
    local CMDtargetID = nil
    local cmdList = {...} -- Tabel of commands
    
    Log("Total commands for unit " .. tostring(unitID) .. ": " .. #commands)
    
    for i = 1, #commands do
        for _, CMD in ipairs(cmdList) do
            Log("Checking command " .. i .. " with id " .. tostring(commands[i].id))
            if commands[i].id == CMD then
                Log("Match found at iteration " .. tostring(i))
                local x, y, z = unpack(commands[i].params)
                Log("before x " .. tostring(x) .. " y " .. tostring(y) .. " z " .. tostring(z) .. " ")
                
                if x and not y then  -- checks if the target is a unit or a position
                    CMDtargetID = x
                    x, y, z = Spring.GetUnitPosition(x)
                    Log(" CMDtargetID after" .. tostring(CMDtargetID) .." ")
                end
                
                if not x then
                    Log("Spring.GetUnitPosition returned nil values.")
                    return false, nil, nil, nil
                end
                
                Log("After GetUnitPosition: x " .. tostring(x) .. " y " .. tostring(y) .. " z " .. tostring(z) .. " ")
                local firstTime = i
                return true, firstTime, {x, y, z}, CMDtargetID
            end
        end
    end
    return false, nil, nil, nil
end

function findBuildCommand(unitID)
    local commands = Spring.GetUnitCommands(unitID, -1)
    for i = 1, #commands do
       --Log("Checking command " .. i .. " with id " .. tostring(commands[i].id))
        if commands[i].id > 0 then
           return true
        end
    end
    return false
end

local sec = 0
function widget:Update(dt)
    Log("Update(dt)")
    if not gameStarted then return end

        sec = sec + dt
        if sec <= 0.6 then 
            return 
        end
        Log("Update rate not reached, exiting Update")
            sec = 0

        if gameStarted ==true then  -- allways on for now. can be editet to if #builderUnits>0
            Log("Updating UI...")
            updateUI()
            return
        end

        if dlistGuishader ~= nil then
            if WG['guishader'] then
                WG['guishader'].RemoveDlist('build_power_bar')
            end
            dlistGuishader = glDeleteList(dlistGuishader)
        end

    if dlistCU ~= nil then
            dlistCU = glDeleteList(dlistCU)
    end
end


function InitUnit(unitID, unitDefID, unitTeam)
    Log("InitUnit(unitID, unitDefID, unitTeam)")
    local unitDef = UnitDefs[unitDefID]
    if (myTeamID == unitTeam) then
        if unitDef and unitDef.buildSpeed and unitDef.buildSpeed > 0 then
            builderUnits[unitID] = unitDef.buildSpeed
        end
    end
end


function widget:UnitFinished(unitID, unitDefID, unitTeam)
    InitUnit(unitID, unitDefID, unitTeam)
end

function widget:UnitGiven(unitID, unitDefID, unitTeam)
    InitUnit(unitID, unitDefID, unitTeam)
end

function widget:UnitTaken(unitID, unitDefID, unitTeam)
    if builderUnits[unitID] then
        builderUnits[unitID] = nil
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
    if builderUnits[unitID] then
        builderUnits[unitID] = nil
    end
end


function widget:Initialize()
    Log("Initialize()")
    widget:ViewResize()
    if Spring.GetSpectatingState() then
        widgetHandler:RemoveWidget(self)
    end
--    WG['build_power_bar'] = {}
--	WG['build_power_bar'].GetPosition = function()
--		return area
    for _, unitID in pairs(Spring.GetTeamUnits(myTeamID)) do
        InitUnit(unitID, Spring.GetUnitDefID(unitID), myTeamID)
    end
end