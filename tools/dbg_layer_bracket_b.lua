local widget = widget ---@type Widget

-- Layer bracket, part B. Together with dbg_layer_bracket_a.lua it measures how long ALL widgets on one layer
-- (default -95000: Top Bar and Top Bar Buttons, or our variants of them) spend per callin, without the per-callin
-- hooks and the 2 s smoothing of the widget profiler. The widget handler runs callins in layer order, so A (layer-1)
-- and B (layer+1) enclose the layer. Whichever of the two runs first records the start, the other computes the
-- difference with the microsecond timer. Enable both. Commands: /bracketreport  /bracketreset
-- A report is also echoed every REPORT_SECONDS. "alloc" is Lua allocation inside the bracket.
local BRACKET_LAYER = -95000
local REPORT_SECONDS = 10

function widget:GetInfo()
	return {
		name = "Layer bracket B (" .. BRACKET_LAYER .. ")",
		desc = "Measures the time of all widgets on layer " .. BRACKET_LAYER .. " per callin, together with part A",
		author = "Robert82",
		date = "Nov, 2025",
		license = "GNU GPL, v2 or later",
		layer = BRACKET_LAYER + 1,
		enabled = false,
		handler = true,
	}
end

local function LayerBracketShared(widget, side, bracketLayer, reportSeconds)
	local spEcho = Spring.Echo
	local getTimer = Spring.GetTimerMicros or Spring.GetTimer
	local diffTimers = Spring.DiffTimers
	local micros = Spring.GetTimerMicros ~= nil
	local function elapsedUs(t1, t2)
		if micros then
			return diffTimers(t2, t1, true, true) * 1000 -- ms -> us
		end
		return diffTimers(t2, t1, true) * 1000
	end
	local getDrawFrame = Spring.GetDrawFrame
	local gcCount = collectgarbage
	local CALLINS = { "DrawScreen", "Update", "GameFrame" }
	local RING = 1200

	local function newStat()
		return { n = 0, sum = 0, max = 0, alloc = 0, ring = {}, ringPos = 0 }
	end
	local function state()
		WG.layerBracket = WG.layerBracket or {}
		local s = WG.layerBracket[bracketLayer]
		if not s then
			s = { pending = {}, stats = {}, lastReport = os.clock(), startClock = os.clock(), present = {} }
			for _, c in ipairs(CALLINS) do s.stats[c] = newStat() end
			WG.layerBracket[bracketLayer] = s
		end
		return s
	end

	local function record(c, frameID)
		local s = state()
		local p = s.pending[c]
		local now = getTimer()
		local mem = gcCount("count")
		if p and p.frame == frameID then
			-- second of the pair: close the measurement
			local st = s.stats[c]
			local us = elapsedUs(p.t, now)
			st.n = st.n + 1
			st.sum = st.sum + us
			if us > st.max then st.max = us end
			local d = mem - p.mem
			if d > 0 then st.alloc = st.alloc + d end
			st.ringPos = st.ringPos % RING + 1
			st.ring[st.ringPos] = us
			s.pending[c] = nil
		else
			s.pending[c] = { t = now, mem = mem, frame = frameID, side = side }
		end
	end

	local function percentile(ring, q)
		local tmp = {}
		for i = 1, #ring do tmp[i] = ring[i] end
		if #tmp == 0 then return 0 end
		table.sort(tmp)
		return tmp[math.max(1, math.min(#tmp, math.floor(#tmp * q + 0.5)))]
	end

	local function report(reset)
		local s = state()
		local secs = os.clock() - s.startClock
		spEcho(string.format("[layer %d bracket] %.0f s window; per call: avg / median / p95 / max in us, alloc in kB/s (widgets on that layer: Top Bar + Top Bar Buttons or their variants)", bracketLayer, secs))
		for _, c in ipairs(CALLINS) do
			local st = s.stats[c]
			if st.n > 0 then
				spEcho(string.format("  %-10s n=%6d  avg %7.1f  med %7.1f  p95 %7.1f  max %8.1f  alloc %6.1f kB/s  => %.1f us per draw frame equivalent",
					c, st.n, st.sum / st.n, percentile(st.ring, 0.5), percentile(st.ring, 0.95), st.max, st.alloc / secs, st.sum / secs / math.max(1, (s.stats.DrawScreen.n / secs))))
			end
		end
		if reset then
			for _, c in ipairs(CALLINS) do s.stats[c] = newStat() end
			s.startClock = os.clock()
		end
	end

	local api = {}
	function api.Initialize()
		local s = state()
		s.present[side] = true
		if s.present.A and s.present.B then
			spEcho("[layer " .. bracketLayer .. " bracket] both halves active; /bracketreport prints, /bracketreset restarts the window")
		end
	end
	function api.Shutdown()
		local s = state()
		s.present[side] = nil
	end
	function api.DrawScreen()
		record("DrawScreen", getDrawFrame())
		local s = state()
		if side == "B" and os.clock() - s.lastReport > reportSeconds then
			s.lastReport = os.clock()
			if s.present.A and s.present.B then report(false) end
		end
	end
	function api.Update()
		record("Update", getDrawFrame())
	end
	function api.GameFrame(n)
		record("GameFrame", n)
	end
	function api.TextCommand(cmd)
		if cmd == "bracketreport" then report(false) return true end
		if cmd == "bracketreset" then report(true) return true end
		return false
	end
	return api
end

local shared = LayerBracketShared(widget, "B", BRACKET_LAYER, REPORT_SECONDS)
widget.Initialize = shared.Initialize
widget.Shutdown = shared.Shutdown
widget.Update = shared.Update
widget.DrawScreen = shared.DrawScreen
widget.GameFrame = shared.GameFrame
widget.TextCommand = shared.TextCommand
