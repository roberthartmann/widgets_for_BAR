"""Syntax-check Lua files with a real Lua 5.1 compiler (lupa.lua51) and report
local-variable / upvalue limit risks. Usage: python3 -I luacheck51.py file.lua [...]"""
import sys, re
from lupa import lua51
rt = lua51.LuaRuntime()
load = rt.eval("function(src, name) local f, err = loadstring(src, name) if f then return true, '' end return false, err end")
status = 0
for path in sys.argv[1:]:
    src = open(path, encoding="utf-8", errors="replace").read()
    ok, err = load(src, "@" + path)
    if ok:
        # top-level 'local' count (rough): lines starting with 'local ' at column 0
        n = sum(1 for l in src.splitlines() if re.match(r"local\s", l))
        print(f"OK   {path}  (top-level local statements: {n}, lua5.1 limit is 200 active locals per function)")
    else:
        status = 1
        print(f"FAIL {path}\n     {err}")
sys.exit(status)
