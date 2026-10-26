-- Recording gl layer for tools/render_widget.py. Loaded AFTER mock_env.lua; replaces the no-op gl
-- functions with ones that track GL state (matrix stack, colour, texture, blending, scissor) and
-- record what gets drawn as primitives in target pixel space, for a Python rasteriser to draw.
--
-- Targets: the screen (pixel coordinates, y up, as in DrawScreen) and every texture made with
-- gl.CreateTexture (drawn into with gl.R2tHelper.RenderToTexture / gl.RenderToTexture: matrices
-- start at identity there, so coordinates are NDC and get mapped to the texture's pixels, which is
-- what the widgets' glTranslate(-1,-1) glScale(2/w,2/h) glTranslate(-x1,-y1) prologue expects).
-- Display lists record the gl calls made while compiling (the function runs once, at
-- CreateList time, like GL_COMPILE) and replay them with the state current at CallList time.
-- Screen output is only kept while REC.screenOn is true (the final DrawScreen); texture contents
-- are always recorded (with clears applied and fully cleared draws pruned) so the final frame
-- shows what the textures hold at that moment.
local REC = { seq = 0, nextList = 1, nextTex = 1, lists = {}, textures = {}, screenOn = false, stats = { prims = 0 } }
HARNESS.rec = REC
local vsx0, vsy0 = Spring.GetViewGeometry()
REC.screen = { name = "screen", w = vsx0, h = vsy0, ops = {} }

local floor, max, min, cos, sin, rad = math.floor, math.max, math.min, math.cos, math.sin, math.rad
local concat, format, byte, sub = table.concat, string.format, string.byte, string.sub

-- state ---------------------------------------------------------------------------------------
local S = {}
local function identity() return { 1, 0, 0, 0, 1, 0 } end -- x' = a x + b y + c ; y' = d x + e y + f
local function resetState()
	S.color = { 1, 1, 1, 1 }
	S.tc = { 0, 0 }
	S.tex = false
	S.blendOn, S.bsrc, S.bdst = true, "SRC_ALPHA", "ONE_MINUS_SRC_ALPHA"
	S.scissor = nil
	S.clip = nil
	S.mode = "MODELVIEW"
	S.mv, S.mvStack = identity(), {}
	S.tm, S.tmStack = identity(), {}
	S.pm, S.pmStack = identity(), {}
	S.base = identity()
	S.target = REC.screenOn and REC.screen or nil
	S.lineWidth = 1
	S.prim = nil
end
resetState()
REC.resetState = resetState

local function mulT(m, tx, ty)
	m[3] = m[1] * tx + m[2] * ty + m[3]
	m[6] = m[4] * tx + m[5] * ty + m[6]
end
local function curMatrix()
	if S.mode == "TEXTURE" then return S.tm, S.tmStack end
	if S.mode == "PROJECTION" then return S.pm, S.pmStack end
	return S.mv, S.mvStack
end
-- full transform of a point: base(projection(modelview(p)))
local function xform(x, y)
	local m, p, b = S.mv, S.pm, S.base
	local x1, y1 = m[1] * x + m[2] * y + m[3], m[4] * x + m[5] * y + m[6]
	local x2, y2 = p[1] * x1 + p[2] * y1 + p[3], p[4] * x1 + p[5] * y1 + p[6]
	return b[1] * x2 + b[2] * y2 + b[3], b[4] * x2 + b[5] * y2 + b[6]
end
local function xscale() -- uniform scale factor of the full transform (for text sizes)
	local m, p, b = S.mv, S.pm, S.base
	local function det(t) return t[1] * t[5] - t[2] * t[4] end
	return math.sqrt(math.abs(det(m) * det(p) * det(b)))
end

-- op emission ---------------------------------------------------------------------------------
local function blendKey()
	if not S.blendOn then return "off" end
	return S.bsrc .. "," .. S.bdst
end
local function clipKey()
	if not S.clip then return "" end
	local t = {}
	for i, r in ipairs(S.clip) do t[i] = format("%.3f %.3f %.3f %.3f", r[1], r[2], r[3], r[4]) end
	return concat(t, ";")
end
local function scissorKey()
	local s = S.scissor
	if not s then return "" end
	return format("%.3f %.3f %.3f %.3f", s[1], s[2], s[3], s[4])
end
local function texKey()
	local t = S.tex
	if not t then return "", -1 end
	t = tostring(t)
	if REC.textures[t] then return t, REC.seq end
	return t, -1
end

local function pushOp(op, bb)
	local tgt = S.target
	if not tgt then return end
	op.blend, op.scissor, op.clip = blendKey(), scissorKey(), clipKey()
	op.bb = bb
	if tgt ~= REC.screen then
		REC.seq = REC.seq + 1
		op.seq = REC.seq
	end
	tgt.ops[#tgt.ops + 1] = op
	REC.stats.prims = REC.stats.prims + 1
end

-- triangulation per GL mode, indices into the 0-based vertex list
local function triangulate(mode, n)
	local t = {}
	local function tri(a, b, c) t[#t + 1] = a; t[#t + 1] = b; t[#t + 1] = c end
	if mode == "TRIANGLES" then
		for i = 0, n - 3, 3 do tri(i, i + 1, i + 2) end
	elseif mode == "TRIANGLE_STRIP" then
		for i = 0, n - 3 do if i % 2 == 0 then tri(i, i + 1, i + 2) else tri(i + 1, i, i + 2) end end
	elseif mode == "TRIANGLE_FAN" or mode == "POLYGON" then
		for i = 1, n - 2 do tri(0, i, i + 1) end
	elseif mode == "QUADS" then
		for i = 0, n - 4, 4 do tri(i, i + 1, i + 2); tri(i, i + 2, i + 3) end
	elseif mode == "QUAD_STRIP" then
		for i = 0, n - 4, 2 do tri(i, i + 1, i + 3); tri(i, i + 3, i + 2) end
	end
	return t
end

-- verts: flat list x,y,r,g,b,a,u,v (already transformed)
local function emitTriangles(verts, idx)
	if not S.target or #idx == 0 then return end
	local buf, k = {}, 0
	local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, #idx do
		local o = idx[i] * 8
		for j = 1, 8 do k = k + 1; buf[k] = verts[o + j] end
		local x, y = verts[o + 1], verts[o + 2]
		if x < x1 then x1 = x end
		if x > x2 then x2 = x end
		if y < y1 then y1 = y end
		if y > y2 then y2 = y end
	end
	local tk, tv = texKey()
	pushOp({ kind = "tri", data = concat(buf, ","), tex = tk, texver = tv }, { x1, y1, x2, y2 })
end

local function emitLines(mode, verts, n)
	-- each segment becomes a quad lineWidth wide
	local segs = {}
	if mode == "LINES" then
		for i = 0, n - 2, 2 do segs[#segs + 1] = { i, i + 1 } end
	else
		for i = 0, n - 2 do segs[#segs + 1] = { i, i + 1 } end
		if mode == "LINE_LOOP" and n > 2 then segs[#segs + 1] = { n - 1, 0 } end
	end
	local hw = S.lineWidth * 0.5
	local out, idx = {}, {}
	for _, sg in ipairs(segs) do
		local a, b = sg[1] * 8, sg[2] * 8
		local dx, dy = verts[b + 1] - verts[a + 1], verts[b + 2] - verts[a + 2]
		local len = math.sqrt(dx * dx + dy * dy)
		if len > 0 then
			local nx, ny = -dy / len * hw, dx / len * hw
			local base = #out / 8
			for _, v in ipairs({ { a, 1 }, { b, 1 }, { b, -1 }, { a, -1 } }) do
				local o = v[1]
				out[#out + 1] = verts[o + 1] + nx * v[2]
				out[#out + 1] = verts[o + 2] + ny * v[2]
				for j = 3, 8 do out[#out + 1] = verts[o + j] end
			end
			for _, i in ipairs({ 0, 1, 2, 0, 2, 3 }) do idx[#idx + 1] = base + i end
		end
	end
	emitTriangles(out, idx)
end

-- the actual (non-recording) implementations --------------------------------------------------
local impl = {}

function impl.Color(r, g, b, a)
	if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
	S.color = { r or 1, g or 1, b or 1, a or 1 }
end
function impl.TexCoord(s, t)
	if type(s) == "table" then s, t = s[1], s[2] end
	local m = S.tm
	s, t = s or 0, t or 0
	S.tc = { m[1] * s + m[2] * t + m[3], m[4] * s + m[5] * t + m[6] }
end
function impl.Vertex(x, y)
	if type(x) == "table" then x, y = x[1], x[2] end
	local p = S.prim
	if not p then return end
	local X, Y = xform(x, y)
	local c, t, v = S.color, S.tc, p.verts
	local n = #v
	v[n + 1], v[n + 2], v[n + 3], v[n + 4], v[n + 5], v[n + 6], v[n + 7], v[n + 8] = X, Y, c[1], c[2], c[3], c[4], t[1], t[2]
	p.n = p.n + 1
end
function impl.Begin(mode)
	S.prim = { mode = tostring(mode), verts = {}, n = 0 }
end
function impl.End()
	local p = S.prim
	S.prim = nil
	if not p or not S.target then return end
	if p.mode == "LINES" or p.mode == "LINE_STRIP" or p.mode == "LINE_LOOP" then
		emitLines(p.mode, p.verts, p.n)
	else
		emitTriangles(p.verts, triangulate(p.mode, p.n))
	end
end
function impl.LineWidth(w) S.lineWidth = w or 1 end
function impl.Texture(a, b)
	local t = b
	if b == nil then t = a end
	if t == nil or t == false then S.tex = false else S.tex = t end
end
local blendModes = {
	alpha = { "SRC_ALPHA", "ONE_MINUS_SRC_ALPHA" }, reset = { "SRC_ALPHA", "ONE_MINUS_SRC_ALPHA" },
	add = { "ONE", "ONE" }, alpha_add = { "SRC_ALPHA", "ONE" }, color = { "SRC_COLOR", "ONE_MINUS_SRC_COLOR" },
	modulate = { "DST_COLOR", "ZERO" },
}
function impl.Blending(a, b)
	if b ~= nil then
		S.blendOn, S.bsrc, S.bdst = true, tostring(a), tostring(b)
	elseif a == false or a == "disable" then
		S.blendOn = false
	elseif a == true then
		S.blendOn = true
	elseif type(a) == "string" and blendModes[a] then
		S.blendOn, S.bsrc, S.bdst = true, blendModes[a][1], blendModes[a][2]
	end
end
impl.BlendFunc = function(a, b) impl.Blending(a, b) end
impl.BlendFuncSeparate = function(a, b) impl.Blending(a, b) end
function impl.Scissor(x, y, w, h)
	if x == false or x == nil then S.scissor = nil
	elseif x == true then -- keep
	else -- window coordinates of the current target, the matrix does not apply
		S.scissor = { x, y, w, h }
	end
end
function impl.MatrixMode(m) S.mode = tostring(m) end
function impl.PushMatrix()
	local m, st = curMatrix()
	st[#st + 1] = { m[1], m[2], m[3], m[4], m[5], m[6] }
end
function impl.PopMatrix()
	local m, st = curMatrix()
	local top = st[#st]
	if top then
		st[#st] = nil
		for i = 1, 6 do m[i] = top[i] end
	end
end
function impl.LoadIdentity()
	local m = curMatrix()
	m[1], m[2], m[3], m[4], m[5], m[6] = 1, 0, 0, 0, 1, 0
end
function impl.Translate(x, y)
	mulT(curMatrix(), x or 0, y or 0)
end
function impl.Scale(sx, sy)
	local m = curMatrix()
	sx, sy = sx or 1, sy or 1
	m[1], m[4] = m[1] * sx, m[4] * sx
	m[2], m[5] = m[2] * sy, m[5] * sy
end
function impl.Rotate(angle, x, y, z)
	if (z or 0) == 0 then return end -- only rotations about the screen normal matter in 2D
	local a = rad(angle) * (z > 0 and 1 or -1)
	local c, s = cos(a), sin(a)
	local m = curMatrix()
	local a1, b1, d1, e1 = m[1], m[2], m[4], m[5]
	m[1], m[2] = a1 * c + b1 * s, -a1 * s + b1 * c
	m[4], m[5] = d1 * c + e1 * s, -d1 * s + e1 * c
end
function impl.Text(op) -- recorded font:Print
	if not S.target then return end
	local X, Y = xform(op.x, op.y)
	local sc = xscale()
	local o = {}
	for k, v in pairs(op) do o[k] = v end
	o.kind, o.x, o.y, o.size = "text", X, Y, op.size * sc
	local w = (op.width or 1) * o.size
	pushOp(o, { X - w - 2, Y - o.size * 1.5, X + w + 2, Y + o.size * 1.5 })
end
local callList
function impl.CallList(id)
	callList(id)
end

-- recording dispatch: inside gl.CreateList calls are appended to the list being compiled ------
local compiling = nil -- the command array being compiled
local function call(name, ...)
	if compiling then
		compiling[#compiling + 1] = { name, select("#", ...), ... }
		return
	end
	return impl[name](...)
end
callList = function(id)
	local l = REC.lists[id]
	if not l then return end
	for i = 1, #l do
		local c = l[i]
		impl[c[1]](unpack(c, 3, 2 + c[2]))
	end
end
REC.call = call

-- public gl API -----------------------------------------------------------------------------------
for _, name in ipairs({ "Color", "TexCoord", "Vertex", "LineWidth", "Texture", "Blending", "BlendFunc",
	"BlendFuncSeparate", "Scissor", "MatrixMode", "PushMatrix", "PopMatrix", "LoadIdentity", "Translate",
	"Scale", "Rotate", "CallList" }) do
	gl[name] = function(...) return call(name, ...) end
end
gl.Texture = function(...) call("Texture", ...) return true end
gl.Normal = function() end

function gl.BeginEnd(mode, fn, ...)
	call("Begin", mode)
	fn(...)
	call("End")
end
function gl.Shape(mode, list)
	call("Begin", mode)
	for _, v in ipairs(list) do
		if v.c then call("Color", v.c[1], v.c[2], v.c[3], v.c[4]) end
		if v.t then call("TexCoord", v.t[1], v.t[2]) end
		call("Vertex", v.v[1], v.v[2])
	end
	call("End")
end
function gl.Rect(x1, y1, x2, y2)
	local tex = S.tex
	call("Texture", false)
	call("Begin", "QUADS")
	call("Vertex", x1, y1); call("Vertex", x2, y1); call("Vertex", x2, y2); call("Vertex", x1, y2)
	call("End")
	call("Texture", tex)
end
-- Spring: (x1,y1,x2,y2[,flipS,flipT]) maps (x1,y1) to (s0,t1) with s0,t0 = 0,0 and s1,t1 = 1,1
-- unless flipped; (x1,y1,x2,y2,s0,t0,s1,t1) maps (x1,y1) to (s0,t0)
function gl.TexRect(x1, y1, x2, y2, a, b, c, d)
	local s0, t0, s1, t1
	if type(a) == "number" then
		s0, t0, s1, t1 = a, b, c, d
	else
		local fs, ft = a == true, b == true
		local S0, S1 = fs and 1 or 0, fs and 0 or 1
		local T0, T1 = ft and 1 or 0, ft and 0 or 1
		s0, t0, s1, t1 = S0, T1, S1, T0
	end
	call("Begin", "QUADS")
	call("TexCoord", s0, t0); call("Vertex", x1, y1)
	call("TexCoord", s1, t0); call("Vertex", x2, y1)
	call("TexCoord", s1, t1); call("Vertex", x2, y2)
	call("TexCoord", s0, t1); call("Vertex", x1, y2)
	call("End")
end
function gl.PushPopMatrix(fn, ...)
	call("PushMatrix")
	if type(fn) == "function" then fn(...) end
	call("PopMatrix")
end

function gl.CreateList(fn, ...)
	local id = REC.nextList
	REC.nextList = id + 1
	local outer = compiling
	local l = {}
	compiling = l
	local ok, err = pcall(fn, ...)
	compiling = outer
	if not ok then error(err, 0) end
	REC.lists[id] = l
	return id
end
function gl.DeleteList(id)
	if id then REC.lists[id] = nil end
	return nil
end

-- textures -----------------------------------------------------------------------------------------
function gl.CreateTexture(w, h, opts)
	local name = "!" .. REC.nextTex
	REC.nextTex = REC.nextTex + 1
	REC.textures[name] = { name = name, w = w, h = h, ops = {} }
	return name
end
function gl.DeleteTexture(name)
	if name then REC.textures[tostring(name)] = nil end
	return true
end
gl.TextureInfo = function(name)
	local t = REC.textures[tostring(name)]
	if t then return { xsize = t.w, ysize = t.h } end
	return { xsize = 64, ysize = 64 }
end

local function normRects(sc)
	if not sc then return nil end
	if type(sc[1]) == "number" then return { { sc[1], sc[2], sc[3], sc[4] } } end
	local out = {}
	for _, r in ipairs(sc) do out[#out + 1] = { r[1], r[2], r[3], r[4] } end
	if #out == 0 then return nil end
	return out
end

-- clear (part of) a texture; drop recorded draws that the clear fully covers
local function clearTexture(t, rects)
	if REC.screenOn then
		-- final frame: screen ops refer to texture versions by sequence number, so keep everything
		local rs = {}
		for i, r in ipairs(rects or {}) do rs[i] = format("%.3f %.3f %.3f %.3f", r[1], r[2], r[3], r[4]) end
		REC.seq = REC.seq + 1
		t.ops[#t.ops + 1] = { kind = "clear", rects = concat(rs, ";"), seq = REC.seq }
		return
	end
	if not rects then
		t.ops = {}
		REC.seq = REC.seq + 1
		t.ops[1] = { kind = "clear", rects = "", seq = REC.seq }
		return
	end
	local keep = {}
	for _, op in ipairs(t.ops) do
		local bb, covered = op.bb, false
		if bb then
			for _, r in ipairs(rects) do
				if bb[1] >= r[1] and bb[3] <= r[1] + r[3] and bb[2] >= r[2] and bb[4] <= r[2] + r[4] then
					covered = true
					break
				end
			end
		end
		if not covered then keep[#keep + 1] = op end
	end
	t.ops = keep
	local rs = {}
	for i, r in ipairs(rects) do rs[i] = format("%.3f %.3f %.3f %.3f", r[1], r[2], r[3], r[4]) end
	REC.seq = REC.seq + 1
	keep[#keep + 1] = { kind = "clear", rects = concat(rs, ";"), seq = REC.seq,
		bb = nil }
end

local function renderToTexture(tex, fn, clear, scissors, ...)
	local t = REC.textures[tostring(tex)]
	if not t then
		if type(fn) == "function" then fn(...) end
		return
	end
	if compiling then error("RenderToTexture inside gl.CreateList is not supported by the renderer") end
	local saved = {}
	for k, v in pairs(S) do saved[k] = v end
	S.target = t
	S.base = { t.w / 2, 0, t.w / 2, 0, t.h / 2, t.h / 2 }
	S.mv, S.mvStack, S.pm, S.pmStack, S.mode = identity(), {}, identity(), {}, "MODELVIEW"
	S.scissor = nil
	local rects = normRects(scissors)
	if clear then clearTexture(t, rects) end
	-- like the game's helper the scissor rectangles limit only the clear: drawing outside them lands in the texture
	-- too (and stays there until a clear covers it). HARNESS.r2tClip = true restores the old clipped drawing.
	S.clip = HARNESS.r2tClip and rects or nil
	S.blendOn, S.bsrc, S.bdst = true, "SRC_ALPHA", "ONE_MINUS_SRC_ALPHA"
	local ok, err = pcall(fn, ...)
	for k in pairs(S) do S[k] = nil end
	for k, v in pairs(saved) do S[k] = v end
	if not ok then error(err, 0) end
end
gl.RenderToTexture = function(tex, fn, ...) return renderToTexture(tex, fn, false, nil, ...) end
gl.R2tHelper = {
	RenderToTexture = function(tex, fn, clear, scissors) return renderToTexture(tex, fn, clear, scissors) end,
	BlendTexRect = function(tex, x1, y1, x2, y2)
		call("Blending", "ONE", "ONE_MINUS_SRC_ALPHA")
		call("Color", 1, 1, 1, 1)
		call("Texture", tex)
		-- render-to-texture content is stored bottom row first: t = 0 at y1
		gl.TexRect(x1, y1, x2, y2, false, true)
		call("Texture", false)
		call("Blending", "SRC_ALPHA", "ONE_MINUS_SRC_ALPHA")
	end,
	RenderInRect = function(tex, x1, y1, x2, y2, fn, clear)
		return renderToTexture(tex, function()
			gl.Translate(-1, -1, 0)
			gl.Scale(2 / (x2 - x1), 2 / (y2 - y1), 0)
			gl.Translate(-x1, -y1, 0)
			fn()
		end, clear)
	end,
}

-- fonts ----------------------------------------------------------------------------------------------
-- Text colour codes: "\255RGB" sets the colour (alpha from the text colour), "\b" resets it.
local function parseColored(text, base)
	text = tostring(text)
	local segs, cur, buf = {}, { base[1], base[2], base[3], base[4] }, {}
	local function flush()
		if #buf > 0 then
			local s = concat(buf)
			segs[#segs + 1] = { cur[1], cur[2], cur[3], cur[4], (s:gsub(".", function(ch) return format("%02x", byte(ch)) end)) }
			buf = {}
		end
	end
	local i, n = 1, #text
	while i <= n do
		local b = byte(text, i)
		if b == 255 and i + 3 <= n then
			flush()
			cur = { byte(text, i + 1) / 255, byte(text, i + 2) / 255, byte(text, i + 3) / 255, base[4] }
			i = i + 4
		elseif b == 254 and i + 4 <= n then
			flush()
			cur = { byte(text, i + 1) / 255, byte(text, i + 2) / 255, byte(text, i + 3) / 255, byte(text, i + 4) / 255 }
			i = i + 5
		elseif b == 8 then
			flush()
			cur = { base[1], base[2], base[3], base[4] }
			i = i + 1
		else
			buf[#buf + 1] = sub(text, i, i)
			i = i + 1
		end
	end
	flush()
	return segs
end
local function plainText(text)
	local segs = parseColored(text, { 1, 1, 1, 1 })
	local t = {}
	-- the segments hold the text hex encoded (for the Python side): decode it, widths are of the plain text
	for i, s in ipairs(segs) do t[i] = s[5]:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end) end
	return concat(t)
end
REC.widthCache = {}
local function textWidth(fontKey, text)
	local plain = plainText(text)
	local key = fontKey .. "|" .. plain
	local w = REC.widthCache[key]
	if not w then
		w = PY_TEXT_WIDTH(fontKey, plain)
		REC.widthCache[key] = w
	end
	return w
end
REC.textWidth = textWidth

local Font = {}
Font.__index = Font
function Font:Begin() end
function Font:End() end
function Font:SubmitBuffered() end
function Font:SetTextColor(r, g, b, a)
	if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
	self.textColor = { r or 1, g or 1, b or 1, a or 1 }
end
function Font:SetOutlineColor(r, g, b, a)
	if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
	self.outlineColor = { r or 0, g or 0, b or 0, a or 1 }
end
function Font:SetAutoOutlineColor() end
function Font:GetTextWidth(text) return textWidth(self.fontKey, text) end
function Font:GetTextHeight(text)
	local h, d = PY_TEXT_HEIGHT(self.fontKey, plainText(text))
	return h, d, 1
end
function Font:WrapText(text) return text end
function Font:Print(text, x, y, size, opts)
	if text == nil then return end
	text = tostring(text)
	local segs = parseColored(text, self.textColor)
	local s = {}
	for i, g in ipairs(segs) do s[i] = format("%.4f %.4f %.4f %.4f %s", g[1], g[2], g[3], g[4], g[5]) end
	local oc = self.outlineColor
	call("Text", {
		font = self.fontKey, segs = concat(s, ";"), x = x or 0, y = y or 0, size = size or self.size,
		opts = opts or "", width = textWidth(self.fontKey, text),
		outline = format("%.4f %.4f %.4f %.4f", oc[1], oc[2], oc[3], oc[4]),
		outlineWidth = self.outlineWidth / self.size, outlineStrength = self.outlineStrength,
	})
end
Font.PrintWorld = Font.Print

local function fontKeyFor(file)
	file = tostring(file or ""):lower()
	if file:find("exo2") then return "exo2" end
	if file:find("sourcecode") or file:find("mono") then return "mono" end
	return "poppins"
end
local function newFont(file, size, outlineWidth, outlineStrength)
	return setmetatable({
		fontKey = fontKeyFor(file), file = file, size = size or 34, outlineWidth = outlineWidth or (size or 34) * 0.3,
		outlineStrength = outlineStrength or 1.7, textColor = { 1, 1, 1, 1 }, outlineColor = { 0, 0, 0, 1 },
	}, Font)
end
gl.LoadFont = function(file, size, outlineWidth, outlineStrength) return newFont(file, size, outlineWidth, outlineStrength) end
gl.DeleteFont = function() end
gl.GetTextWidth = function(text) return textWidth("poppins", text) end
-- WG.fonts like the BAR font handler: 1 = bar_font (Poppins-Regular), 2 = bar_font2 (Exo2-SemiBold),
-- 3 = monospaced; returns the font and its pixel size
do
	local fontCache = {}
	local function getFont(file, size, outlineSize, outlineStrength)
		local name
		if not file or file == 1 then name = "fonts/" .. Spring.GetConfigString("bar_font", "Poppins-Regular.otf")
		elseif file == 2 then name = "fonts/" .. Spring.GetConfigString("bar_font2", "Exo2-SemiBold.otf")
		elseif file == 3 then name = "fonts/monospaced/SourceCodePro-Medium.otf"
		else name = file end
		local vsx, vsy = Spring.GetViewGeometry()
		local fontScale = (vsy / 1080) * Spring.GetConfigFloat("ui_scale", 1)
		local outlineMult = math.clamp(1 / (vsy / 1400), 1, 1.5)
		local px = math.floor(34 * (size or 1) + 0.5) * fontScale
		local outlinePx = math.floor(34 * (outlineSize or 0.22 * outlineMult * 0.9) + 0.5) * fontScale
		local key = name .. "_" .. px .. "_" .. outlinePx
		if not fontCache[key] then fontCache[key] = newFont(name, px, outlinePx, outlineStrength or 1.7) end
		return fontCache[key], px
	end
	WG.fonts = { getFont = getFont }
end
