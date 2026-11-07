--------------------------------------------------------------------------------
-- TOP BAR SECTION PROFILER  (Debug-Hilfe, NICHT fuer Release)
--
-- Zweck: Der F11/Widget-Profiler zeigt nur "DrawScreen 2.2 %". Dieses Snippet
-- zeigt, WELCHER Teil von DrawScreen die Zeit kostet und wie viele
-- Display-Listen pro Sekunde erzeugt/geloescht werden (das ist der teure Teil).
--
-- EINBAU:
--   1) Diesen ganzen Block GANZ OBEN in die Widget-Datei kopieren, direkt nach
--      "local widget = widget ---@type Widget" (also VOR "local glCreateList =
--      gl.CreateList" usw.). Er ueberschattet "gl" nur in dieser Datei, andere
--      Widgets sind nicht betroffen.
--   2) In DrawScreen/Update Abschnitte markieren, z.B.:
--          PROF_begin('drawResBars')  drawResBars()  PROF_end('drawResBars')
--      und in drawResbarValues:
--          PROF_begin('effect_'..res) ... PROF_end('effect_'..res)
--   3) Ganz am Ende von widget:DrawScreen() einmal  PROF_frame()  aufrufen.
--   4) Alle 5 s erscheint eine Auswertung im Chat/infolog.
--
-- Zum Abschalten: PROF_ENABLED = false
--------------------------------------------------------------------------------
local PROF_ENABLED = true
local PROF_REPORT_INTERVAL = 5 -- Sekunden (Echtzeit, NICHT os.clock)

local spGetTimer = Spring.GetTimer
local spDiffTimers = Spring.DiffTimers

local prof = {
	sections = {},   -- name -> { total = s, calls = n, max = s, start = timer }
	counters = {},   -- name -> n (seit letztem Report)
	liveLists = 0,   -- erzeugt - geloescht (seit Widget-Start) -> Leck-Detektor
	frames = 0,
	lastReport = spGetTimer(),
}

local function PROF_count(name, n)
	if not PROF_ENABLED then return end
	prof.counters[name] = (prof.counters[name] or 0) + (n or 1)
end

function PROF_begin(name)
	if not PROF_ENABLED then return end
	local s = prof.sections[name]
	if not s then
		s = { total = 0, calls = 0, max = 0 }
		prof.sections[name] = s
	end
	s.start = spGetTimer()
end

function PROF_end(name)
	if not PROF_ENABLED then return end
	local s = prof.sections[name]
	if not s or not s.start then return end
	local dt = spDiffTimers(spGetTimer(), s.start)
	s.start = nil
	s.total = s.total + dt
	s.calls = s.calls + 1
	if dt > s.max then s.max = dt end
end

function PROF_frame()
	if not PROF_ENABLED then return end
	prof.frames = prof.frames + 1
	local elapsed = spDiffTimers(spGetTimer(), prof.lastReport)
	if elapsed < PROF_REPORT_INTERVAL then return end

	local f = math.max(1, prof.frames)
	Spring.Echo(string.format("[TopBarProf] %.1f s, %d frames (%.0f fps)", elapsed, prof.frames, prof.frames / elapsed))

	local names = {}
	for name in pairs(prof.sections) do names[#names + 1] = name end
	table.sort(names, function(a, b) return prof.sections[a].total > prof.sections[b].total end)
	for _, name in ipairs(names) do
		local s = prof.sections[name]
		Spring.Echo(string.format("[TopBarProf]   %-22s %7.4f ms/frame  %6.1f calls/s  max %6.3f ms",
			name, s.total * 1000 / f, s.calls / elapsed, s.max * 1000))
		s.total, s.calls, s.max = 0, 0, 0
	end

	local cnames = {}
	for name in pairs(prof.counters) do cnames[#cnames + 1] = name end
	table.sort(cnames)
	for _, name in ipairs(cnames) do
		Spring.Echo(string.format("[TopBarProf]   #%-21s %8.1f /s  (%6.2f /frame)",
			name, prof.counters[name] / elapsed, prof.counters[name] / f))
		prof.counters[name] = 0
	end
	Spring.Echo(string.format("[TopBarProf]   live display lists: %d  (steigt dieser Wert stetig -> Leck)", prof.liveLists))

	prof.frames = 0
	prof.lastReport = spGetTimer()
end

-- "gl" nur fuer diese Datei ueberschatten, um Display-List-Operationen zu zaehlen
-- und die Kompilierzeit (CreateList inkl. Lua-Geometrie-Erzeugung) zu messen.
if PROF_ENABLED then
	local realGL = gl
	local realCreate, realDelete, realCall = realGL.CreateList, realGL.DeleteList, realGL.CallList
	gl = setmetatable({
		CreateList = function(fn, ...)
			local t = spGetTimer()
			local id = realCreate(fn, ...)
			local dt = spDiffTimers(spGetTimer(), t)
			PROF_count('CreateList')
			local s = prof.sections['<CreateList compile>']
			if not s then
				s = { total = 0, calls = 0, max = 0 }
				prof.sections['<CreateList compile>'] = s
			end
			s.total = s.total + dt
			s.calls = s.calls + 1
			if dt > s.max then s.max = dt end
			if id then prof.liveLists = prof.liveLists + 1 end
			return id
		end,
		DeleteList = function(id, ...)
			if id then
				PROF_count('DeleteList')
				prof.liveLists = prof.liveLists - 1
			end
			return realDelete(id, ...)
		end,
		CallList = function(id, ...)
			PROF_count('CallList')
			return realCall(id, ...)
		end,
	}, { __index = realGL })
end
--------------------------------------------------------------------------------
