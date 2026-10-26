"""Run a BAR top bar widget headlessly through its lifecycle under Lua 5.1.
Usage: python3 -I tools/run_widget.py <widget.lua> [bar_root=stock_reference] [--legacy]
--legacy simulates a spring-2026 game build (no BAR table, no require, no skew drawers).
Needs `pip install lupa`. bar_root must contain common/wind_functions.lua."""
import sys
from lupa import lua51
rt = lua51.LuaRuntime(unpack_returned_tuples=True)
legacy = "--legacy" in sys.argv
args = [a for a in sys.argv[1:] if a != "--legacy"]
path = args[0]
bar_root = args[1] if len(args) > 1 else "stock_reference"
tools = __file__.rsplit("/", 1)[0]
rt.globals()["HARNESS_LEGACY"] = legacy
rt.execute(open(f"{tools}/mock_env.lua").read())
rt.globals()["HARNESS"]["barRoot"] = bar_root
src = open(path, encoding="utf-8", errors="replace").read()
chunk = rt.eval("function(src, name) local f, e = loadstring(src, name) if not f then error(e) end return f end")(src, "@" + path)
chunk()
w = rt.globals()["widget"]
driver = rt.eval("""
function(w)
  local results = {}
  local function step(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    results[#results + 1] = { name, ok, err }
    return ok
  end
  local info = w:GetInfo()
  results[#results + 1] = { "GetInfo", true, info.name .. " layer=" .. tostring(info.layer) }
  -- units owned by the player before init: commander, builder, nano, factory, wind, tank
  local U = HARNESS
  local com = U.addUnit(1, 0, 1)
  local con = U.addUnit(2, 0, 1)
  local nano = U.addUnit(3, 0, 1)
  local lab = U.addUnit(4, 0, 1)
  local wind1 = U.addUnit(5, 0, 1); local wind2 = U.addUnit(5, 0, 1)
  local tank = U.addUnit(6, 0, 1)
  local solarFrame = U.addUnit(7, 0, 0.3)
  U.units[con].building = solarFrame; U.units[con].cmds = { { id = -7 } }
  U.units[nano].cmds = { { id = CMD.FIGHT } }
  U.units[lab].cmds = { { id = -6 }, { id = -6 } }
  local guardCon = U.addUnit(2, 0, 1); U.units[guardCon].cmds = { { id = CMD.GUARD, params = { com } } } -- guards the idle commander: idle itself
  local enemyCom = U.addUnit(8, 1, 1)

  step("Initialize", function() w:Initialize() end)
  if w.SetConfigData then step("SetConfigData(nil)", function() w:SetConfigData(nil) end) end
  if w.ViewResize then step("ViewResize", function() w:ViewResize(1920, 1080) end) end
  if w.UnitCreated then step("UnitCreated", function() w:UnitCreated(enemyCom, 8, 1) w:UnitCreated(com, 1, 0) end) end
  step("pregame Update/Draw", function()
    for i = 1, 20 do w:Update(0.05) if w.DrawScreen then w:DrawScreen() end end
  end)
  HARNESS.frame = 1
  if w.GameStart then step("GameStart", function() w:GameStart() end) end
  step("frames 1..400", function()
    for f = 1, 400 do
      HARNESS.frame = f
      if w.GameFrame then w:GameFrame(f) end
      if f % 2 == 0 then w:Update(1/30) end
      if w.DrawScreen then w:DrawScreen() end
      if f == 60 and w.UnitFinished then
        -- solar finishes, con becomes idle, new builder appears, nano gets a build job
        U.units[solarFrame].built = 1; U.units[con].building = nil; U.units[con].cmds = {}
        w:UnitFinished(solarFrame, 7, 0)
        local con2 = U.addUnit(2, 0, 1); w:UnitFinished(con2, 2, 0)
        local frame2 = U.addUnit(6, 0, 0.1); U.units[nano].building = frame2; U.units[nano].cmds = { { id = CMD.FIGHT }, { id = CMD.REPAIR } }
      end
      if f == 120 and w.UnitDestroyed then
        w:UnitDestroyed(wind2, 5, 0, nil, nil, nil, nil); U.units[wind2] = nil
      end
      if f == 150 and w.UnitTaken and w.UnitGiven then
        w:UnitTaken(nano, 3, 0, 1); U.units[nano].team = 1
        w:UnitGiven(lab, 4, 0, 1)
      end
      if f == 200 then HARNESS.res.metal[1] = 0; HARNESS.res.metal[3] = 60; HARNESS.res.energy[1] = 2500; HARNESS.res.energy[9] = 300 end
      if f == 300 then HARNESS.mx, HARNESS.my = 700, 1065 end -- hover the bar
      if f == 30 and WG.buildpower then
        local d = WG.buildpower.GetData()
        HARNESS.bpStart = string.format("frame 30: total=%s reserved=%s used=%s", tostring(d.total), tostring(d.reserved), tostring(d.used))
      end
    end
  end)
  if WG.buildpower then
    -- buildpower fork only: the published data after the 400 frames
    step("buildpower data", function()
      local d = WG.buildpower.GetData()
      assert(type(d) == "table", "GetData did not return a table")
      assert(type(d.total) == "number" and d.total > 0, "total is not > 0: " .. tostring(d.total))
      assert(HARNESS.bpStart == "frame 30: total=780 reserved=190 used=83.870967741935", "unexpected frame 30 data: " .. tostring(HARNESS.bpStart))
      assert(type(d.reserved) == "number", "reserved is not a number")
      assert(type(d.used) == "number", "used is not a number")
      local function f(v) return type(v) == "number" and string.format("%.3f", v) or tostring(v) end
      HARNESS.bpReport = (HARNESS.bpStart or "frame 30: n/a") .. "\\n     frame 400: total=" .. f(d.total) .. " reserved=" .. f(d.reserved)
        .. " used=" .. f(d.used) .. " usedRatio=" .. f(d.usedRatio) .. " mSupportRatio=" .. f(d.mSupportRatio)
        .. " eSupportRatio=" .. f(d.eSupportRatio) .. "\\n     flags: stallingMetal=" .. tostring(d.stallingMetal)
        .. " stallingEnergy=" .. tostring(d.stallingEnergy) .. " idleAlert=" .. tostring(d.idleAlert)
        .. " surplusBP=" .. tostring(d.surplusBP) .. "; options registered=" .. #HARNESS.options
        .. " (addOptions calls: " .. tostring(HARNESS.optionCalls) .. ")"
    end)
    if HARNESS.bpReport then results[#results + 1] = { "buildpower values", true, HARNESS.bpReport } end
    step("buildpower options toggle", function()
      for _, o in ipairs(HARNESS.options) do
        if o.onchange and type(o.value) == "boolean" then
          o.onchange(o, not o.value) w:Update(0.3) if w.DrawScreen then w:DrawScreen() end
          o.onchange(o, o.value) w:Update(0.3) if w.DrawScreen then w:DrawScreen() end
        end
      end
    end)
  end
  step("MouseMove/Press/Release", function()
    if w.MouseMove then w:MouseMove(700, 1065, 0, 0, 1) end
    if w.MousePress then w:MousePress(700, 1065, 1) end
    if w.MouseRelease then w:MouseRelease(700, 1065, 1) end
  end)
  step("spectator switch", function()
    HARNESS.spec = true
    if w.PlayerChanged then w:PlayerChanged(0) end
    for f = 401, 430 do HARNESS.frame = f if w.GameFrame then w:GameFrame(f) end w:Update(1/30) if w.DrawScreen then w:DrawScreen() end end
  end)
  if w.GetConfigData then step("GetConfigData", function() local d = w:GetConfigData() assert(type(d) == "table") end) end
  if w.GameOver then step("GameOver", function() w:GameOver() end) end
  if w.LanguageChanged then step("LanguageChanged", function() w:LanguageChanged() end) end
  step("Shutdown", function() w:Shutdown() end)
  return results
end
""")
results = driver(w)
fail = 0
for i in range(1, len(results) + 1):
    name, ok, err = results[i][1], results[i][2], results[i][3]
    print(("PASS " if ok else "FAIL ") + str(name) + ("" if ok and name not in ("GetInfo", "buildpower values") else "\n     " + str(err)))
    if not ok:
        fail += 1
log = rt.globals()["HARNESS"]["log"]
n = len(log)
if n:
    print(f"--- {n} echo lines, first 10:")
    for i in range(1, min(n, 10) + 1):
        print("   ", log[i])
sys.exit(1 if fail else 0)
