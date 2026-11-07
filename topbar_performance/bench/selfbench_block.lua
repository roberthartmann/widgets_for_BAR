
--------------------------------------------------------------------------------
-- SELF-BENCH (angehaengt von bench/make_bench_variants.sh, nicht fuer Release)
--
-- Misst die eigenen Callins dieses Widgets von innen. Die Wrapper werden beim
-- Laden gesetzt, also BEVOR barwidgets.lua seinen pcall-/Memory-Guard-Wrapper
-- darumlegt. Gemessen wird nur der Code des Widgets, ohne den Sandbox-Aufschlag,
-- den jedes User-Widget pro Aufruf zahlt (und das offizielle Mod-Widget nicht).
--
-- Ausgabe alle 30 s in Chat + infolog, Praefix "[TopBarSelfBench]".
--------------------------------------------------------------------------------
do
	local bench = {
		window = 30,
		callins = { "DrawScreen", "Update", "GameFrame" },
		data = {},
		frames = 0,
	}
	local spGetTimerMicros = Spring.GetTimerMicros
	local spGetTimer = Spring.GetTimer
	local spDiffTimers = Spring.DiffTimers
	local function nowMicros()
		if spGetTimerMicros then
			return spGetTimerMicros()
		end
		return spGetTimer()
	end
	local function elapsedUs(t)
		if spGetTimerMicros then
			return spDiffTimers(spGetTimerMicros(), t, true, true) * 1000
		end
		return spDiffTimers(spGetTimer(), t) * 1000000
	end
	bench.windowStart = spGetTimer()
	local benchName = widget:GetInfo().name

	local function report(elapsed)
		Spring.Echo(string.format("[TopBarSelfBench] %s ---- %.1f s, %.0f fps ----", benchName, elapsed, bench.frames / elapsed))
		for _, callin in ipairs(bench.callins) do
			local d = bench.data[callin]
			if d and d.n > 0 then
				local s, n = d.samples, d.n
				for i = n + 1, #s do
					s[i] = nil
				end
				table.sort(s)
				local median = s[math.max(1, math.floor(n * 0.5))]
				local spikes, spikeSum = 0, 0
				for i = 1, n do
					if s[i] > median * 3 + 20 then
						spikes = spikes + 1
						spikeSum = spikeSum + s[i]
					end
				end
				Spring.Echo(string.format(
					"[TopBarSelfBench] %-10s calls %6d | median %6.1f us | mean %6.1f us | p95 %6.1f us | max %7.1f us | spikes %4d (%5.1f%% of time) | %6.3f ms/s",
					callin, n, median, d.sum / n, s[math.max(1, math.floor(n * 0.95))], s[n],
					spikes, d.sum > 0 and spikeSum / d.sum * 100 or 0, d.sum / 1000 / elapsed))
				d.n, d.sum = 0, 0
			end
		end
	end

	for _, callin in ipairs(bench.callins) do
		local orig = widget[callin]
		if type(orig) == "function" then
			local d = { n = 0, sum = 0, samples = {} }
			bench.data[callin] = d
			local samples = d.samples
			widget[callin] = function(self, ...)
				local t = nowMicros()
				local r1, r2, r3 = orig(self, ...)
				local us = elapsedUs(t)
				local n = d.n + 1
				if n <= 40000 then
					d.n = n
					samples[n] = us
				end
				d.sum = d.sum + us
				if callin == "Update" then
					bench.frames = bench.frames + 1
					local elapsed = spDiffTimers(spGetTimer(), bench.windowStart)
					if elapsed >= bench.window then
						report(elapsed)
						bench.windowStart = spGetTimer()
						bench.frames = 0
					end
				end
				return r1, r2, r3
			end
		end
	end
end
