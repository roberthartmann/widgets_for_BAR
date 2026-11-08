local widget = widget ---@type Widget

-- A/B frame-time bench. Enables the listed widgets one at a time (plus "none" = all of them off), measures
-- the real frame time while each one runs, and reports medians per candidate. This is the number that
-- matters to the player: total frame time including GL driver and engine overhead, which Lua profilers miss.
-- Use with uncapped frame rate (/vsync 0, max fps 0 in settings), a static camera and a paused game or a
-- replay at the same moment, otherwise the noise swamps the differences.
-- Commands: /abbench start   /abbench stop   /abbench report
local CANDIDATES = {
	"Top Bar",
	"Top Bar with Buildpower 0.5.001 gl4",
	"Top Bar with Buildpower 0.5.002 gl4 lean",
	"Top Bar with Buildpower 0.5.003 gl4 onedraw",
	"Top Bar with Buildpower 0.5.004 gl4 glyphs",
	"Top Bar with Buildpower 0.5.005 gl4 tuned",
}
local INCLUDE_NONE = true    -- also measure with every candidate disabled (baseline)
local WINDOW_SECONDS = 8     -- measured time per candidate per round
local SETTLE_SECONDS = 2     -- skipped after each switch (widget init, caches, texture builds)
local ROUNDS = 4             -- full passes over all candidates; order rotates each round

function widget:GetInfo()
	return {
		name = "Widget A/B frame-time bench",
		desc = "Alternates between widgets and compares real frame times (/abbench start)",
		author = "Robert82",
		date = "Nov, 2025",
		license = "GNU GPL, v2 or later",
		layer = 1000000,
		enabled = false,
		handler = true,
	}
end

local spEcho = Spring.Echo
local getTimer = Spring.GetTimerMicros or Spring.GetTimer
local diffTimers = Spring.DiffTimers
local micros = Spring.GetTimerMicros ~= nil
local function elapsedUs(t1, t2)
	if micros then return diffTimers(t2, t1, true, true) * 1000 end
	return diffTimers(t2, t1, true) * 1000
end

local run = nil -- { list, round, idx, phase, phaseStart, lastT, samples, results }
local function setWidget(name, on)
	Spring.SendCommands("luaui " .. (on and "enablewidget " or "disablewidget ") .. name)
end
local function candidateList()
	local list = {}
	for i = 1, #CANDIDATES do list[i] = CANDIDATES[i] end
	if INCLUDE_NONE then list[#list + 1] = "none" end
	return list
end
local function activate(name)
	for _, c in ipairs(CANDIDATES) do
		if c ~= name then setWidget(c, false) end
	end
	if name ~= "none" then setWidget(name, true) end
end
local function median(t)
	if #t == 0 then return 0 end
	local tmp = {}
	for i = 1, #t do tmp[i] = t[i] end
	table.sort(tmp)
	local m = math.floor(#tmp / 2)
	if #tmp % 2 == 1 then return tmp[m + 1] end
	return (tmp[m] + tmp[m + 1]) / 2
end
local function percentile(t, q)
	if #t == 0 then return 0 end
	local tmp = {}
	for i = 1, #t do tmp[i] = t[i] end
	table.sort(tmp)
	return tmp[math.max(1, math.min(#tmp, math.floor(#tmp * q + 0.5)))]
end

local function startRun()
	run = { list = candidateList(), round = 1, idx = 1, phase = "settle", results = {}, samples = {}, allocKB = 0 }
	for _, c in ipairs(run.list) do run.results[c] = { medians = {}, p90s = {}, allocs = {} } end
	run.phaseStart = os.clock()
	run.lastT = nil
	activate(run.list[1])
	spEcho(string.format("[abbench] started: %d candidates, %d rounds, %ds settle + %ds measure each", #run.list, ROUNDS, SETTLE_SECONDS, WINDOW_SECONDS))
end

local function finishWindow()
	local name = run.list[run.idx]
	local r = run.results[name]
	local secs = os.clock() - run.phaseStart
	r.medians[#r.medians + 1] = median(run.samples)
	r.p90s[#r.p90s + 1] = percentile(run.samples, 0.9)
	r.allocs[#r.allocs + 1] = run.allocKB / math.max(0.001, secs)
	spEcho(string.format("[abbench] round %d  %-45s median %7.1f us/frame  p90 %7.1f  alloc %6.1f kB/s  (%d frames)", run.round, name, r.medians[#r.medians], r.p90s[#r.p90s], r.allocs[#r.allocs], #run.samples))
end

local function report()
	if not run then spEcho("[abbench] nothing measured yet") return end
	local base = run.results["none"]
	local baseMed = base and #base.medians > 0 and median(base.medians) or nil
	spEcho("[abbench] result: median of per-round medians; delta = cost of the widget vs. all candidates off")
	for _, name in ipairs(run.list) do
		local r = run.results[name]
		if #r.medians > 0 then
			local m = median(r.medians)
			local spread = percentile(r.medians, 1.0) - percentile(r.medians, 0.0)
			local line = string.format("  %-45s %8.1f us/frame (round spread %6.1f)  p90 %8.1f  alloc %6.1f kB/s", name, m, spread, median(r.p90s), median(r.allocs))
			if baseMed and name ~= "none" then
				line = line .. string.format("  delta %+7.1f us = %+5.2f%% of the frame", m - baseMed, (m - baseMed) / baseMed * 100)
			end
			spEcho(line)
		end
	end
end

local function nextCandidate()
	run.idx = run.idx + 1
	if run.idx > #run.list then
		run.idx = 1
		run.round = run.round + 1
		-- rotate the order so drift (heating, game state) spreads over all candidates
		table.insert(run.list, table.remove(run.list, 1))
		if run.round > ROUNDS then
			report()
			activate(CANDIDATES[1])
			spEcho("[abbench] done; re-enabled '" .. CANDIDATES[1] .. "'")
			run = nil
			return
		end
	end
	run.phase = "settle"
	run.phaseStart = os.clock()
	run.lastT = nil
	activate(run.list[run.idx])
end

function widget:Update()
	if not run then return end
	local now = getTimer()
	local clock = os.clock()
	if run.phase == "settle" then
		if clock - run.phaseStart >= SETTLE_SECONDS then
			run.phase = "measure"
			run.phaseStart = clock
			run.samples = {}
			run.allocKB = 0
			run.lastMem = collectgarbage("count")
		end
		run.lastT = now
		return
	end
	if run.lastT then
		run.samples[#run.samples + 1] = elapsedUs(run.lastT, now)
		local mem = collectgarbage("count")
		if mem > run.lastMem then run.allocKB = run.allocKB + (mem - run.lastMem) end
		run.lastMem = mem
	end
	run.lastT = now
	if clock - run.phaseStart >= WINDOW_SECONDS then
		finishWindow()
		nextCandidate()
	end
end

function widget:TextCommand(cmd)
	if cmd == "abbench start" then startRun() return true end
	if cmd == "abbench stop" then if run then report() end run = nil return true end
	if cmd == "abbench report" then report() return true end
	return false
end

function widget:Initialize()
	spEcho("[abbench] loaded; edit CANDIDATES at the top of the file, then /abbench start")
end
