local widget = widget ---@type Widget

--------------------------------------------------------------------------------
-- Top Bar Bench: misst die Callins anderer Widgets genauer als der F11-Profiler.
--
-- Der F11-Profiler zeigt nur einen gleitenden Mittelwert in 0,1-%-Schritten.
-- Ob 0.8 % oder 0.9 % angezeigt wird, liegt im Rauschen. Dieses Widget misst
-- jeden einzelnen Aufruf in Mikrosekunden und gibt alle WINDOW Sekunden aus:
--
--   median  = Grundkosten eines normalen Frames (das, was JEDEN Frame anfaellt)
--   mean    = Durchschnitt inkl. Ausreisser
--   p95/max = Spitzen (z.B. Frames, in denen Display-Listen gebaut werden)
--   ms/s    = Gesamtzeit pro Sekunde (mit der FPS vergleichbar)
--
-- Liegt mean deutlich ueber median, kommen die Kosten aus seltenen teuren Frames
-- (Listen-Kompilierung, Render-to-Texture). Ist median hoch, sind es die festen
-- Kosten pro Frame.
--
-- BENUTZUNG
--   1. Datei nach LuaUI/Widgets/ kopieren, im Spiel per F11 aktivieren.
--   2. IMMER NUR EINE Top-Bar-Variante gleichzeitig aktiv lassen!
--   3. Am besten ein Replay nehmen und jeweils an derselben Stelle
--      (z.B. Minute 10, Kamera fest) mindestens 2 Fenster abwarten.
--   4. Ergebnis steht im Chat und in infolog.txt ("[TopBarBench]").
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name = "Top Bar Bench",
		desc = "Debug: misst DrawScreen/Update der Top Bar Varianten in Mikrosekunden (median/mean/p95)",
		author = "Robert82",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = false,
		handler = true,
	}
end

-- Welche Widgets gemessen werden (Name aus GetInfo)
local TARGETS = { "Top Bar", "Top Bar perf" }
local CALLINS = { "DrawScreen", "Update", "GameFrame" }
local WINDOW = 30 -- Sekunden pro Auswertung
local MAX_SAMPLES = 20000 -- reicht fuer 30 s bei >600 fps

local spGetTimer = Spring.GetTimer
local spDiffTimers = Spring.DiffTimers

local data = {} -- data[name][callin] = { n = 0, sum = 0, samples = {} }
local wrapped = {} -- wrapped[widgetTable] = true
local windowStart = spGetTimer()
local frames = 0
local nextScan = 0

local function getName(w)
	if w.whInfo and w.whInfo.name then
		return w.whInfo.name
	end
	if w.GetInfo then
		local ok, info = pcall(w.GetInfo, w)
		if ok and info then
			return info.name
		end
	end
end

local function wrap(w, name)
	data[name] = data[name] or {}
	for _, callin in ipairs(CALLINS) do
		local orig = w[callin]
		if type(orig) == "function" then
			local d = data[name][callin] or { n = 0, sum = 0, samples = {} }
			data[name][callin] = d
			local samples = d.samples
			w[callin] = function(self, ...)
				local t = spGetTimer()
				local a, b, c, e = orig(self, ...)
				local us = spDiffTimers(spGetTimer(), t) * 1000000
				local n = d.n + 1
				if n <= MAX_SAMPLES then
					d.n = n
					samples[n] = us
				end
				d.sum = d.sum + us
				return a, b, c, e
			end
		end
	end
	wrapped[w] = true
end

local function scan()
	for _, w in ipairs(widgetHandler.widgets or {}) do
		if not wrapped[w] then
			local name = getName(w)
			for i = 1, #TARGETS do
				if name == TARGETS[i] then
					wrap(w, name)
					Spring.Echo("[TopBarBench] messe jetzt: " .. name)
				end
			end
		end
	end
end

local function report(elapsed)
	local activeTargets = 0
	for _ in pairs(data) do
		activeTargets = activeTargets + 1
	end
	Spring.Echo(string.format("[TopBarBench] ---- %.1f s, %.0f fps ----", elapsed, frames / elapsed))
	if activeTargets > 1 then
		Spring.Echo("[TopBarBench] WARNUNG: mehrere Top-Bar-Varianten aktiv. Sie teilen WG.topbar, GUI-Shader-Key und Tooltips -> Messung ungueltig!")
	end
	for name, callins in pairs(data) do
		for _, callin in ipairs(CALLINS) do
			local d = callins[callin]
			if d and d.n > 0 then
				local s = d.samples
				for i = d.n + 1, #s do
					s[i] = nil
				end
				table.sort(s)
				local n = d.n
				Spring.Echo(string.format(
					"[TopBarBench] %-14s %-10s calls %6d  median %7.1f us  mean %7.1f us  p95 %7.1f us  max %8.1f us  => %6.3f ms/s",
					name, callin, n, s[math.max(1, math.floor(n * 0.5))], d.sum / n,
					s[math.max(1, math.floor(n * 0.95))], s[n], d.sum / 1000 / elapsed))
				d.n = 0
				d.sum = 0
			end
		end
	end
end

function widget:Update(dt)
	frames = frames + 1
	local now = os.clock()
	if now > nextScan then
		nextScan = now + 1
		scan() -- erfasst auch Widgets, die erst spaeter (wieder) aktiviert werden
	end
	local elapsed = spDiffTimers(spGetTimer(), windowStart)
	if elapsed >= WINDOW then
		report(elapsed)
		windowStart = spGetTimer()
		frames = 0
	end
end

function widget:Initialize()
	scan()
end
