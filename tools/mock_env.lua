-- Headless mock of the BAR/Spring widget environment, enough to run the top bar
-- widget's lifecycle and catch runtime errors. Numbers are plausible, not exact.
HARNESS = { frame = 0, log = {}, units = {}, nextUnitID = 1 }
local function noop() end
local function logf(...) HARNESS.log[#HARNESS.log + 1] = table.concat({...}, " ") end

math.round = math.round or function(n, d) local m = 10 ^ (d or 0) return math.floor(n * m + 0.5) / m end
math.isInRect = math.isInRect or function(x, y, x1, y1, x2, y2) return x >= x1 and y >= y1 and x <= x2 and y <= y2 end
math.clamp = math.clamp or function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
table.copy = table.copy or function(t) local n = {} for k, v in pairs(t) do n[k] = v end return n end
table.maxn = table.maxn or function(t) local m = 0 for k in pairs(t) do if type(k) == "number" and k > m then m = k end end return m end
string.lines = string.lines or function(s) local t = {} for l in s:gmatch("[^\n]+") do t[#t+1] = l end return t end
unpack = unpack or table.unpack

-- unit defs ---------------------------------------------------------------
UnitDefs = {}
UnitDefNames = {}
local function def(id, name, t)
  t.id = id; t.name = name; t.customParams = t.customParams or {}
  t.translatedHumanName = name; t.humanName = name
  t.buildSpeed = t.buildSpeed or 0
  t.metalCost = t.metalCost or 100; t.energyCost = t.energyCost or 1000; t.buildTime = t.buildTime or 1000
  t.canAssist = t.canAssist or false; t.isFactory = t.isFactory or false; t.isBuilder = (t.buildSpeed or 0) > 0
  t.canMove = t.canMove == nil and true or t.canMove
  t.height = 20; t.power = 100
  UnitDefs[id] = t; UnitDefNames[name] = t
end
def(1, "armcom", { buildSpeed = 300, canAssist = true, customParams = { iscommander = 1 }, metalCost = 2700, energyCost = 26000, buildTime = 75000 })
def(2, "armck", { buildSpeed = 90, canAssist = true, metalCost = 130, energyCost = 1600, buildTime = 3500 })
def(3, "armnanotc", { buildSpeed = 200, canAssist = true, canMove = false, metalCost = 220, energyCost = 3800, buildTime = 7000 })
def(4, "armlab", { buildSpeed = 100, isFactory = true, canMove = false, metalCost = 620, energyCost = 1300, buildTime = 6500 })
def(5, "armwin", { canMove = false, metalCost = 40, energyCost = 175, buildTime = 1500, windGenerator = 25 })
def(6, "armstump", { metalCost = 150, energyCost = 1500, buildTime = 2500 })
def(7, "armsolar", { canMove = false, metalCost = 155, energyCost = 0, buildTime = 2600 })
def(8, "corcom", { buildSpeed = 300, canAssist = true, customParams = { iscommander = 1 }, metalCost = 2700, energyCost = 26000, buildTime = 75000 })

-- game globals -----------------------------------------------------------
Game = { windMin = 1, windMax = 25, gameSpeed = 30, spawnWarpInFrame = 90, waterDamage = 0, mapSizeX = 8192, mapSizeZ = 8192, gameName = "BAR", version = "test" }
GL = setmetatable({}, { __index = function(t, k) return k end })
CMD = { FIGHT = 16, PATROL = 15, GUARD = 25, REPAIR = 40, RECLAIM = 90, MOVE = 10, STOP = 0, ATTACK = 20 }
BAR = { I18N = function(key, args) return key end, Lava = { isLavaMap = false } }
VFS = { FileExists = function() return true end, Include = function(p) return dofile(HARNESS.barRoot .. "/" .. p) end, RAW_FIRST = 1, ZIP_FIRST = 2 }
function require(mod)
  if mod == "common/wind_functions" then return dofile(HARNESS.barRoot .. "/common/wind_functions.lua") end
  error("require of unmocked module " .. tostring(mod))
end
I18N = BAR.I18N
Script = { LuaUI = {}, GetName = function() return "LuaUI" end }

-- Spring --------------------------------------------------------------------
Spring = {}
Spring.Echo = function(...) logf("[echo]", tostring((...))) end
Spring.Log = noop
Spring.I18N = BAR.I18N
Spring.GetConfigFloat = function(k, d) return d or 1 end
Spring.GetConfigInt = function(k, d) return d or 1 end
Spring.GetConfigString = function(k, d) return d or "" end
Spring.SetConfigInt = noop; Spring.SetConfigFloat = noop; Spring.SetConfigString = noop
Spring.GetViewGeometry = function() return 1920, 1080, 0, 0 end
Spring.GetWindowGeometry = Spring.GetViewGeometry
Spring.GetGameFrame = function() return HARNESS.frame end
Spring.GetGameSeconds = function() return HARNESS.frame / 30 end
Spring.GetGameSpeed = function() return 1, 1, false end
Spring.GetGaiaTeamID = function() return 2 end
Spring.GetLocalTeamID = function() return 0 end
Spring.GetMyTeamID = Spring.GetLocalTeamID
Spring.GetLocalAllyTeamID = function() return 0 end
Spring.GetMyAllyTeamID = Spring.GetLocalAllyTeamID
Spring.GetMyPlayerID = function() return 0 end
Spring.GetLocalPlayerID = Spring.GetMyPlayerID
Spring.GetSpectatingState = function() return HARNESS.spec or false, false end
Spring.GetTeamList = function(ally) if ally == nil then return { 0, 1, 2 } end return { 0, 1 } end
Spring.GetAllyTeamList = function() return { 0, 1 } end
Spring.GetTeamInfo = function(teamID) local ally = (teamID == 0 or teamID == 1) and 0 or 1
  return teamID, 0, false, false, "side", ally, {} end
Spring.GetTeamLuaAI = function() return "" end
Spring.GetPlayerInfo = function() return "player", true, false, 0, 0, 0, 0, "", 1 end
Spring.GetPlayerList = function() return { 0, 1 } end
Spring.GetTeamColor = function() return 1, 0, 0, 1 end
HARNESS.res = {
  metal = { 812, 1000, 13, 15, 13, 0.99, 0, 0, 0 },
  energy = { 0, 2500, 214, 158, 214, 0.9, 0, 0, 0 },
}
Spring.GetTeamResources = function(teamID, res) local r = HARNESS.res[res] return unpack(r) end
Spring.GetTeamResourceStats = function() return 0, 0, 0, 0, 0 end
HARNESS.rules = { mmLevel = 0.8, mmUse = 10, mmCapacity = 20, mmAvgEffi = 1 / 70, startUnit = 1, suspendbuilderpriority = 0 }
Spring.GetTeamRulesParam = function(teamID, k) return HARNESS.rules[k] end
Spring.GetGameRulesParam = function() return nil end
Spring.GetUnitRulesParam = function() return nil end
Spring.GetModOptions = function() return { debugcommands = "", map_waterislava = false } end
Spring.GetMouseState = function() return HARNESS.mx or 900, HARNESS.my or 1060, false, false, false, false end
Spring.GetWind = function() return 0, 0, 0, HARNESS.wind or 12.3 end
Spring.GetTidal = function() return 15 end
Spring.GetGroundExtremes = function() return 0, 100, 0, 100 end
Spring.GetTeamUnitDefCount = function() return 1 end
Spring.GetTeamUnitCount = function() return #HARNESS.units end
Spring.SendCommands = noop; Spring.SendLuaRulesMsg = noop; Spring.SendLuaUIMsg = noop; Spring.SendLuaMenuMsg = noop
Spring.SetMouseCursor = noop; Spring.PlaySoundFile = noop; Spring.SetShareLevel = noop
Spring.GetMenuName = function() return "" end
Spring.SetUnitDefIcon = noop
Spring.Utilities = {
  ShowDevUI = function() return false end,
  GetPlayerCount = function() return 2 end,
  Gametype = { IsSinglePlayer = function() return false end, IsPvE = function() return false end },
}
-- units
function HARNESS.addUnit(unitDefID, team, built, building)
  local id = HARNESS.nextUnitID; HARNESS.nextUnitID = id + 1
  HARNESS.units[id] = { defID = unitDefID, team = team or 0, built = built == nil and 1 or built, building = building, cmds = {} }
  return id
end
Spring.ValidUnitID = function(id) return HARNESS.units[id] ~= nil end
Spring.GetUnitDefID = function(id) local u = HARNESS.units[id] return u and u.defID end
Spring.GetUnitTeam = function(id) local u = HARNESS.units[id] return u and u.team end
Spring.GetTeamUnits = function(team) local t = {} for id, u in pairs(HARNESS.units) do if u.team == team then t[#t+1] = id end end return t end
Spring.GetAllUnits = function() local t = {} for id in pairs(HARNESS.units) do t[#t+1] = id end return t end
Spring.GetUnitHealth = function(id) local u = HARNESS.units[id] if not u then return nil end return 100, 100, 0, 1, u.built end
Spring.GetUnitIsBuilding = function(id) local u = HARNESS.units[id] return u and u.building end
Spring.GetUnitIsBeingBuilt = function(id) local u = HARNESS.units[id] return u and u.built < 1 end
Spring.GetUnitCommands = function(id, n) local u = HARNESS.units[id] if not u then return nil end if n == 0 then return #u.cmds end return u.cmds end
Spring.GetUnitCommandCount = function(id) local u = HARNESS.units[id] return u and #u.cmds or 0 end
Spring.GetFactoryCommands = Spring.GetUnitCommands
Spring.GetCommandQueue = Spring.GetUnitCommands
Spring.GetUnitResources = function(id) local u = HARNESS.units[id] if not u then return nil end
  if u.building then return 0, 5, 0, 60 end
  if UnitDefs[u.defID].windGenerator then return 0, 0, HARNESS.wind or 12.3, 0 end
  return 0, 0, 0, 0 end
Spring.GetUnitPosition = function() return 100, 0, 100 end
Spring.GetUnitCurrentBuildPower = function() return 1 end
Spring.GetUnitExperience = function() return 0 end
Spring.GetUnitIsStunned = function() return false, false, false end
Spring.GetUnitBuildFacing = function() return 0 end
Spring.GetUnitIsDead = function(id) return HARNESS.units[id] == nil end

-- gl ---------------------------------------------------------------------------
gl = setmetatable({}, { __index = function(t, k) return noop end })
HARNESS.nextList = 1
gl.CreateList = function(fn, ...) if type(fn) == "function" then fn(...) end local id = HARNESS.nextList HARNESS.nextList = id + 1 return id end
gl.CallList = function(id) assert(type(id) == "number", "CallList with non-number") end
gl.DeleteList = noop
gl.CreateTexture = function() local id = HARNESS.nextList HARNESS.nextList = id + 1 return "tex" .. id end
gl.DeleteTexture = noop
gl.GetViewSizes = function() return 1920, 1080 end
gl.GetTextWidth = function(s) return #tostring(s) * 0.5 end
gl.GetTextHeight = function() return 1, 0, 1 end
gl.R2tHelper = {
  RenderToTexture = function(tex, fn, ...) if type(fn) == "function" then fn() end end,
  BlendTexRect = noop,
}
-- fonts
local Font = {}
Font.__index = Font
function Font:Begin() end function Font:End() end function Font:Print() end
function Font:SetTextColor() end function Font:SetOutlineColor() end function Font:SetAutoOutlineColor() end
function Font:GetTextWidth(s) return #tostring(s) * 0.5 end
function Font:GetTextHeight() return 1, 0, 1 end
function Font:WrapText(s) return s end
gl.LoadFont = function() return setmetatable({ size = 20 }, Font) end
gl.DeleteFont = noop

-- WG -----------------------------------------------------------------------------
WG = {}
WG.fonts = { getFont = function() return setmetatable({ size = 20 }, Font) end }
WG.FlowUI = {
  elementCorner = 6, elementMargin = 5, elementPadding = 4, buttonPadding = 3,
  Draw = setmetatable({}, { __index = function(t, k) return noop end }),
}
WG.guishader = { InsertDlist = noop, RemoveDlist = noop, DeleteDlist = noop, InsertRect = noop, RemoveRect = noop }
WG.tooltip = { AddTooltip = noop, RemoveTooltip = noop }
WG.notifications = { queueNotification = noop, addEvent = noop }
HARNESS.options = {}
WG.options = { addOption = function(o) HARNESS.options[#HARNESS.options + 1] = o end, removeOption = noop, getOptionValue = function() return nil end }
WG.resource_spot_finder = { metalSpotsList = {} }

widgetHandler = {
  orderList = { ["GUI Shader"] = 1 },
  RaiseWidget = noop, LowerWidget = noop, RemoveWidget = noop, DisableWidget = noop, EnableWidget = noop,
  RegisterGlobal = noop, DeregisterGlobal = noop, ConfigLayoutHandler = noop,
  widgets = {},
  IsWidgetKnown = function() return false end,
  knownWidgets = {},
}
widget = setmetatable({}, { __index = function(t, k) return nil end })
