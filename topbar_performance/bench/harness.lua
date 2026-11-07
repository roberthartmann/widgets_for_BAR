--------------------------------------------------------------------------------
-- Offline benchmark harness for gui_top_bar.lua (plain Lua 5.1, no engine)
--
--   lua5.1 harness.lua <path/to/gui_top_bar.lua> [seconds] [fps]
--
-- Mocks the Spring/BAR API, simulates fluctuating resources and drives
-- Update/GameFrame/DrawScreen like the engine does. It counts what costs CPU
-- inside the widget's own Lua code:
--   * gl.CreateList compiles (each compile runs the FlowUI geometry code in Lua)
--   * gl.Vertex calls issued by the widget's Lua code (proxy for Lua draw work)
--   * render-to-texture passes (FBO switches)
--   * Lua memory allocated (GC stopped, so the heap growth == allocated bytes)
-- It does NOT measure GPU time or real engine call overhead. Use it to compare
-- two versions of the widget on identical input, not as absolute numbers.
--------------------------------------------------------------------------------
local widgetPath = assert(arg[1], "usage: lua5.1 harness.lua <widget.lua> [seconds] [fps]")
local SECONDS = tonumber(arg[2]) or 120
local FPS = tonumber(arg[3]) or 60

local stats = {
	createList = 0, deleteList = 0, callList = 0, liveLists = 0,
	vertex = 0, vertexInLists = 0, r2t = 0, fontPrint = 0,
}
local compiling = 0

-- simulated clock (the widget uses os.clock for all its timers)
local realClock = os.clock
local simTime = 0
os.clock = function() return simTime end

-- deterministic pseudo random
local seed = 12345
local function rnd()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end

-- resource simulation: values fluctuate like in a real game (income spikes,
-- spending bursts), so the bar width changes most updates
local res = {
	metal = { cur = 600, storage = 1500 },
	energy = { cur = 3000, storage = 6000 },
}
local function stepResources(dt)
	local t = simTime
	res.metal.cur = math.max(0, 700 + 500 * math.sin(t * 0.21) + 60 * math.sin(t * 2.3) + 20 * (rnd() - 0.5))
	res.energy.cur = math.max(0, 3200 + 2400 * math.sin(t * 0.13) + 300 * math.sin(t * 3.1) + 120 * (rnd() - 0.5))
end

--------------------------------------------------------------------------------
-- generic permissive stub: any field is a no-op function / empty table
local function stubTable(name)
	return setmetatable({}, {
		__index = function(t, k)
			local f = function() end
			rawset(t, k, f)
			return f
		end,
	})
end

local function countVertex()
	stats.vertex = stats.vertex + 1
	if compiling > 0 then
		stats.vertexInLists = stats.vertexInLists + 1
	end
end

-- FlowUI draw functions: emulate their Lua vertex generation (rounded rect ~ 4 corners
-- x 4 segments + quads). Cost model is identical for both widget versions.
local function emitVerts(n)
	for _ = 1, n do
		countVertex()
	end
end
local FlowUIDraw = setmetatable({
	RectRound = function() emitVerts(40) end,
	RectRoundQuad = function() emitVerts(40) end,
	RectRoundOutline = function() emitVerts(60) end,
	TexturedRectRound = function() emitVerts(40) end,
	Element = function() emitVerts(200) end,
	SliderKnob = function() emitVerts(80) end,
}, { __index = function(t, k) local f = function() emitVerts(40) end rawset(t, k, f) return f end })

local font = setmetatable({
	GetTextWidth = function(self, text) return #tostring(text) * 0.5 end,
	Print = function() stats.fontPrint = stats.fontPrint + 1 emitVerts(24) end,
}, { __index = function(t, k) local f = function() end rawset(t, k, f) return f end })

local nextListID, nextTexID = 0, 0
gl = setmetatable({
	CreateList = function(fn, ...)
		stats.createList = stats.createList + 1
		stats.liveLists = stats.liveLists + 1
		compiling = compiling + 1
		fn(...)
		compiling = compiling - 1
		nextListID = nextListID + 1
		return nextListID
	end,
	DeleteList = function(id)
		if id then
			stats.deleteList = stats.deleteList + 1
			stats.liveLists = stats.liveLists - 1
		end
		return nil
	end,
	CallList = function() stats.callList = stats.callList + 1 end,
	Vertex = countVertex,
	BeginEnd = function(_, fn, ...) fn(...) end,
	GetViewSizes = function() return 1920, 1080 end,
	CreateTexture = function() nextTexID = nextTexID + 1 return nextTexID end,
	R2tHelper = {
		RenderToTexture = function(tex, fn, ...) stats.r2t = stats.r2t + 1 fn() end,
		BlendTexRect = function() end,
	},
}, { __index = function(t, k) local f = function() end rawset(t, k, f) return f end })

GL = setmetatable({}, { __index = function(_, k) return k end })

local frame = 0
Spring = setmetatable({
	GetGameFrame = function() return frame end,
	GetTeamRulesParam = function(_, key) if key == "mmLevel" then return 0.75 end return nil end,
	GetTeamList = function(ally) if ally then return { 0, 1 } end return { 0, 1, 2, 3 } end,
	GetLocalAllyTeamID = function() return 0 end,
	GetLocalTeamID = function() return 0 end,
	GetGaiaTeamID = function() return 3 end,
	GetSpectatingState = function() return false end,
	GetTeamResources = function(team, kind)
		local r = res[kind]
		-- current, storage, pull, income, expense, share, sent, received
		return r.cur, r.storage, 25 + 5 * math.sin(simTime), 30 + 3 * math.sin(simTime * 0.7), 20, 0.9, 0, 0
	end,
	GetMouseState = function() return 10, 10 end,
	GetWind = function() return 0, 0, 0, 9 + 3 * math.sin(simTime) end,
	GetGameSpeed = function() return 1, 1, false end,
	GetViewGeometry = function() return 1920, 1080 end,
	GetConfigFloat = function(_, d) return d end,
	GetConfigInt = function(_, d) return d end,
	GetTidal = function() return 15 end,
	GetGroundExtremes = function() return 0, 300, -50 end,
	GetModOptions = function() return { debugcommands = "", map_waterlevel = 0 } end,
	GetTeamInfo = function() return 0, 0, false, false, "", 0 end,
	GetTeamUnitDefCount = function() return 1 end,
	-- timers follow the simulated clock, so self-bench windows elapse in sim time
	GetTimer = function() return simTime end,
	GetTimerMicros = function() return realClock() end, -- real CPU time: self-bench measures actual Lua cost
	DiffTimers = function(a, b, ms) local d = a - b return ms and d * 1000 or d end,
	Echo = print,
	Utilities = stubTable("Utilities"),
}, { __index = function(t, k) local f = function() end rawset(t, k, f) return f end })

Game = { windMin = 0, windMax = 20, spawnWarpInFrame = 90 }
UnitDefs = {}
BAR = { I18N = function(k) return k end, Lava = { isLavaMap = false } }
math.isInRect = function(x, y, x1, y1, x2, y2) return x >= x1 and x <= x2 and y >= y1 and y <= y2 end
table.maxn = table.maxn or function(t) return #t end
function require(name)
	if name:find("wind_functions") then
		return { isNoWind = function() return false end, getWindRisk = function() return 10 end, averageWindLookup = {} }
	end
	return stubTable(name)
end

WG = {
	FlowUI = { elementMargin = 3, elementPadding = 4, Draw = FlowUIDraw },
	fonts = { getFont = function() return font end },
	tooltip = stubTable("tooltip"),
	notifications = stubTable("notifications"),
}

VFS = setmetatable({ FileExists = function() return false end }, { __index = function(t, k) local f = function() end rawset(t, k, f) return f end })
widgetHandler = stubTable("widgetHandler")
widget = {}

--------------------------------------------------------------------------------
local chunk = assert(loadfile(widgetPath))
chunk()

widget:Initialize()
frame = 100
widget:GameStart()

-- warm-up: the first seconds build the static UI, not interesting
local dt = 1 / FPS
local function run(seconds)
	local frames = math.floor(seconds * FPS)
	local gameFrameAcc = 0
	for _ = 1, frames do
		simTime = simTime + dt
		stepResources(dt)
		gameFrameAcc = gameFrameAcc + dt
		while gameFrameAcc >= 1 / 30 do
			gameFrameAcc = gameFrameAcc - 1 / 30
			frame = frame + 1
			widget:GameFrame(frame)
		end
		widget:Update(dt)
		widget:DrawScreen()
	end
	return frames
end

run(5)
for k in pairs(stats) do
	if k ~= "liveLists" then stats[k] = 0 end
end
local liveAtStart = stats.liveLists

collectgarbage("collect")
collectgarbage("stop")
local mem0 = collectgarbage("count")
local frames = run(SECONDS)
local allocKB = collectgarbage("count") - mem0
collectgarbage("restart")

local function per(v) return v / SECONDS end
print(string.format("widget: %s", widgetPath))
print(string.format("simulated %d s at %d fps (%d frames)", SECONDS, FPS, frames))
print(string.format("  CreateList compiles     %8.2f /s", per(stats.createList)))
print(string.format("  DeleteList              %8.2f /s", per(stats.deleteList)))
print(string.format("  live display lists      %8d (start %d)", stats.liveLists, liveAtStart))
print(string.format("  Lua vertices total      %8.0f /s", per(stats.vertex)))
print(string.format("    ...inside CreateList  %8.0f /s", per(stats.vertexInLists)))
print(string.format("  render-to-texture       %8.2f /s", per(stats.r2t)))
print(string.format("  font Print              %8.2f /s", per(stats.fontPrint)))
print(string.format("  CallList                %8.2f /frame", stats.callList / frames))
print(string.format("  Lua allocations         %8.2f kB/s", allocKB / SECONDS))
