#!/usr/bin/env python3
"""Render a BAR top bar widget to a PNG without the game.

Usage:
  python3 -I tools/render_widget.py <widget.lua> [--out file.png] [--vsx 1920 --vsy 1080] [--ui-scale 1]
         [--legacy] [--frames 200] [--compare mockup.png] [--crop auto|full|x1,y1,x2,y2] [--scale N]
         [--ss 2] [--bg R,G,B|transparent] [--font-scale 0.95] [--no-coms] [--no-tidal]

Runs the widget lifecycle like run_widget.py (mock_env.lua) with the REAL stock FlowUI
(stock_reference/gui_flowui.lua) and a recording gl layer (mock_gl_record.lua), then draws the last
DrawScreen with a small software rasteriser: Gouraud-shaded triangles with GL blending, bilinear
textures from tools/assets, render-to-texture layers, scissor, and text via Pillow (Poppins-Regular /
Exo2-SemiBold). Needs `pip install lupa` and Pillow + numpy.
"""
import argparse
import math
import os
import re
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from lupa import lua51

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
ASSETS = os.path.join(TOOLS, "assets")
FONT_FILES = {
    "poppins": os.path.join(ASSETS, "fonts", "Poppins-Regular.otf"),
    "exo2": os.path.join(ASSETS, "fonts", "Exo2-SemiBold.otf"),
    "mono": os.path.join(ASSETS, "fonts", "Poppins-Regular.otf"),
}
# defaults for the bundled mockup (tools/assets/mockup_new_design.png): height of its top bar and the
# x of the metal element's left (top) edge, in mockup pixels
MOCKUP_BAR_H = 67
MOCKUP_METAL_X = 100

# ------------------------------------------------------------------------------------------- assets
_asset_index = None


def asset_index():
    global _asset_index
    if _asset_index is None:
        _asset_index = {}
        for root, _, files in os.walk(ASSETS):
            for f in files:
                p = os.path.join(root, f)
                _asset_index[os.path.relpath(p, ASSETS).replace(os.sep, "/").lower()] = p
    return _asset_index


def asset_for_texture(name):
    """':lr64,64:LuaUI/Images/metal.png' -> tools/assets/images/metal.png (None if unknown)."""
    n = re.sub(r"^:[^:]*:", "", str(name)).replace("\\", "/").lower()
    if n.startswith("icons/"):
        rel = "icons/" + n[len("icons/"):]
    elif n.startswith("luaui/images/"):
        rel = "images/" + n[len("luaui/images/"):]
    else:
        return None
    return asset_index().get(rel)


# ------------------------------------------------------------------------------------------- fonts
class Fonts:
    def __init__(self, scale):
        self.scale = scale  # Pillow pixel size per Spring font size (Spring: size = em size)
        self.cache = {}
        self.metric = {}
        for k, p in FONT_FILES.items():
            f = ImageFont.truetype(p, 100)
            asc, desc = f.getmetrics()
            self.metric[k] = (f, asc / 100.0, desc / 100.0)

    def get(self, key, px):
        px = max(1.0, round(px * 4) / 4)
        k = (key, px)
        if k not in self.cache:
            self.cache[k] = ImageFont.truetype(FONT_FILES.get(key, FONT_FILES["poppins"]), px)
        return self.cache[k]

    def width(self, key, text):
        f = self.metric.get(key, self.metric["poppins"])[0]
        return f.getlength(text) / 100.0 * self.scale

    def height(self, key, text):
        """(height above baseline, descender below baseline as a negative number), in size units"""
        f = self.metric.get(key, self.metric["poppins"])[0]
        if not text:
            return 0.0, 0.0
        b = f.getbbox(text, anchor="ls")
        return -b[1] / 100.0 * self.scale, -b[3] / 100.0 * self.scale

    def descender(self, key):
        return -self.metric.get(key, self.metric["poppins"])[2] * self.scale


def as_str(s):
    if isinstance(s, bytes):
        return s.decode("utf-8", "replace")
    return "" if s is None else str(s)


# ------------------------------------------------------------------------------------------- textures
class Texture:
    """RGBA float32 levels (mip 0 first); file textures are straight alpha with row 0 = t 0,
    render targets are premultiplied with row 0 = top (t 1)."""

    def __init__(self, levels, wrap="repeat", tflip=False, const=None, nearest=False):
        self.levels, self.wrap, self.tflip, self.const, self.nearest = levels, wrap, tflip, const, nearest

    @staticmethod
    def from_file(name, path):
        """Spring texture name flags (':flags:path'): n = nearest, no mipmaps; l = linear, no mipmaps;
        g = greyscale; i = invert; c = clamp; rW,H = resize. Without n/l: linear with mipmaps."""
        m = re.match(r"^:([^:]*):", str(name))
        flags = m.group(1) if m else ""
        im = Image.open(path).convert("RGBA")
        rs = re.search(r"r(\d+),(\d+)", flags)
        if rs:
            im = im.resize((int(rs.group(1)), int(rs.group(2))), Image.BILINEAR)
        arr = np.asarray(im, dtype=np.float32) / 255.0
        if "g" in flags:
            lum = arr[:, :, 0] * 0.299 + arr[:, :, 1] * 0.587 + arr[:, :, 2] * 0.114
            arr = np.dstack([lum, lum, lum, arr[:, :, 3]])
        if "i" in flags:
            arr = np.dstack([1 - arr[:, :, :3], arr[:, :, 3:]])
        levels = [arr]
        if "n" not in flags and "l" not in flags:
            img = Image.fromarray((arr * 255 + 0.5).astype(np.uint8), "RGBA")
            w, h = img.size
            while w > 1 and h > 1 and len(levels) < 10:
                w, h = max(1, w // 2), max(1, h // 2)
                levels.append(np.asarray(img.resize((w, h), Image.BOX), dtype=np.float32) / 255.0)
        return Texture(levels, wrap="clamp" if "c" in flags else "repeat", nearest="n" in flags)

    def level_for(self, ratio):
        if ratio <= 1.0 or len(self.levels) == 1:
            return 0
        return min(len(self.levels) - 1, int(math.floor(math.log2(ratio))))

    def sample(self, u, v, level=0):
        if self.const is not None:
            return np.broadcast_to(np.array(self.const, np.float32), (u.shape[0], 4))
        arr = self.levels[level]
        H, W = arr.shape[:2]
        if self.tflip:
            v = 1.0 - v
        if self.nearest:
            xi = np.floor(u * W).astype(np.int64)
            yi = np.floor(v * H).astype(np.int64)
            if self.wrap == "repeat":
                xi, yi = xi % W, yi % H
            else:
                xi, yi = np.clip(xi, 0, W - 1), np.clip(yi, 0, H - 1)
            return arr[yi, xi]
        x = u * W - 0.5
        y = v * H - 0.5
        x0 = np.floor(x)
        y0 = np.floor(y)
        fx = (x - x0).astype(np.float32)[:, None]
        fy = (y - y0).astype(np.float32)[:, None]
        x0 = x0.astype(np.int64)
        y0 = y0.astype(np.int64)
        x1, y1 = x0 + 1, y0 + 1
        if self.wrap == "repeat":
            x0, x1, y0, y1 = x0 % W, x1 % W, y0 % H, y1 % H
        else:
            x0, x1 = np.clip(x0, 0, W - 1), np.clip(x1, 0, W - 1)
            y0, y1 = np.clip(y0, 0, H - 1), np.clip(y1, 0, H - 1)
        a = arr[y0, x0] * (1 - fx) + arr[y0, x1] * fx
        b = arr[y1, x0] * (1 - fx) + arr[y1, x1] * fx
        return a * (1 - fy) + b * fy


UNKNOWN_TEX = Texture(None, const=(0.5, 0.5, 0.5, 0.3))


# ------------------------------------------------------------------------------------------- canvas
def parse_rects(s):
    s = as_str(s)
    if not s:
        return None
    return [tuple(float(v) for v in r.split()) for r in s.split(";") if r.strip()]


class Canvas:
    """A render target: w x h target pixels (y up), rasterised at ss x ss samples per pixel,
    stored premultiplied, row 0 = top."""

    def __init__(self, w, h, ss, bg=None):
        self.w, self.h, self.ss = float(w), float(h), ss
        self.W, self.H = max(1, int(round(w * ss))), max(1, int(round(h * ss)))
        self.C = np.zeros((self.H, self.W, 3), np.float32)
        self.A = np.zeros((self.H, self.W), np.float32)
        if bg is not None:
            self.C[:] = np.array(bg[:3], np.float32) / 255.0
            self.A[:] = 1.0

    def rect_rows(self, x, y, w, h):
        """target rect (x, y, w, h) -> raster (c0, r0, c1, r1), clamped"""
        ss = self.ss
        c0 = int(round(x * ss))
        c1 = int(round((x + w) * ss))
        r0 = int(round((self.h - (y + h)) * ss))
        r1 = int(round((self.h - y) * ss))
        return max(0, c0), max(0, r0), min(self.W, c1), min(self.H, r1)

    def clear(self, rects):
        if not rects:
            self.C[:] = 0
            self.A[:] = 0
            return
        for r in rects:
            c0, r0, c1, r1 = self.rect_rows(*r)
            if c1 > c0 and r1 > r0:
                self.C[r0:r1, c0:c1] = 0
                self.A[r0:r1, c0:c1] = 0

    def as_texture(self):
        return Texture([np.dstack([self.C, self.A[:, :, None]])], wrap="clamp", tflip=True)

    def downsample(self):
        ss = self.ss
        H, W = self.H // ss * ss, self.W // ss * ss
        C = self.C[:H, :W].reshape(H // ss, ss, W // ss, ss, 3).mean(axis=(1, 3))
        A = self.A[:H, :W].reshape(H // ss, ss, W // ss, ss).mean(axis=(1, 3))
        return C, A


def factor(name, sa, sc, da, dc):
    if name == "ZERO":
        return 0.0
    if name == "ONE":
        return 1.0
    if name == "SRC_ALPHA":
        return sa[:, None]
    if name == "ONE_MINUS_SRC_ALPHA":
        return 1.0 - sa[:, None]
    if name == "DST_ALPHA":
        return da[:, None]
    if name == "ONE_MINUS_DST_ALPHA":
        return 1.0 - da[:, None]
    if name == "SRC_COLOR":
        return sc
    if name == "ONE_MINUS_SRC_COLOR":
        return 1.0 - sc
    if name == "DST_COLOR":
        return dc
    if name == "ONE_MINUS_DST_COLOR":
        return 1.0 - dc
    return 1.0


def blend_into(cv, r0, r1, c0, c1, mask, src, blend):
    """src: (n, 4) fragment colours for the True pixels of mask in cv[r0:r1, c0:c1]."""
    Cv = cv.C[r0:r1, c0:c1]
    Av = cv.A[r0:r1, c0:c1]
    dc = Cv[mask]
    da = Av[mask]
    sc = src[:, :3]
    sa = src[:, 3]
    if blend == "off":
        Cv[mask] = np.clip(sc, 0, 1)
        Av[mask] = np.clip(sa, 0, 1)
        return
    s, d = blend.split(",")
    out = sc * factor(s, sa, sc, da, dc) + dc * factor(d, sa, sc, da, dc)
    Cv[mask] = np.clip(out, 0, 1)
    if d == "ONE_MINUS_SRC_ALPHA":
        Av[mask] = np.clip(sa + da * (1 - sa), 0, 1)
    elif d == "ONE":
        pass  # additive: keeps the target's coverage (premultiplied with alpha 0 composites additively)
    else:
        fa = factor(s, sa, sa[:, None], da, da[:, None])
        fd = factor(d, sa, sa[:, None], da, da[:, None])
        fa = fa[:, 0] if isinstance(fa, np.ndarray) else fa
        fd = fd[:, 0] if isinstance(fd, np.ndarray) else fd
        Av[mask] = np.clip(sa * fa + da * fd, 0, 1)


# ------------------------------------------------------------------------------------------- renderer
class Renderer:
    def __init__(self, rt, ss, fonts, verbose=False):
        self.rt, self.ss, self.fonts, self.verbose = rt, ss, fonts, verbose
        self.rec = rt.globals().HARNESS.rec
        self.file_tex = {}
        self.layers = {}  # texture name -> [canvas, next op index]
        self.missing = set()
        self.ntri = 0

    # textures
    def texture(self, name, ver):
        name = as_str(name)
        if not name:
            return None
        if name.startswith("!"):
            return self.layer_texture(name, ver)
        if name not in self.file_tex:
            p = asset_for_texture(name)
            if p:
                try:
                    self.file_tex[name] = Texture.from_file(name, p)
                except Exception as e:
                    self.missing.add(f"{name} ({e})")
                    self.file_tex[name] = UNKNOWN_TEX
            else:
                self.missing.add(name)
                self.file_tex[name] = UNKNOWN_TEX
        return self.file_tex[name]

    def layer_texture(self, name, ver):
        t = self.rec.textures[name]
        if t is None:
            self.missing.add(name + " (deleted render texture)")
            return UNKNOWN_TEX
        st = self.layers.get(name)
        if st is None:
            st = [Canvas(t.w, t.h, self.ss), 0, -1]
            self.layers[name] = st
        cv, ops = st[0], t.ops
        n = len(ops)
        # ops are rasterised incrementally; a full clear may have dropped earlier ops from the list,
        # so find the first op not drawn yet by its sequence number
        i = 1
        while i <= n and ops[i].seq <= st[2]:
            i += 1
        while i <= n and ops[i].seq <= ver:
            self.draw_op(cv, ops[i])
            st[2] = ops[i].seq
            i += 1
        return cv.as_texture()

    # ops
    def draw_ops(self, cv, ops):
        for i in range(1, len(ops) + 1):
            self.draw_op(cv, ops[i])

    def draw_op(self, cv, op):
        kind = op.kind
        if kind == "clear":
            cv.clear(parse_rects(op.rects))
        elif kind == "tri":
            self.draw_tris(cv, op)
        elif kind == "text":
            self.draw_text(cv, op)

    def op_bounds(self, cv, op):
        """raster bounds (c0, r0, c1, r1) and an optional clip-union function"""
        c0, r0, c1, r1 = 0, 0, cv.W, cv.H
        sc = parse_rects(op.scissor)
        if sc:
            a = cv.rect_rows(*sc[0])
            c0, r0, c1, r1 = max(c0, a[0]), max(r0, a[1]), min(c1, a[2]), min(r1, a[3])
        clip = parse_rects(op.clip)
        clip_rows = [cv.rect_rows(*r) for r in clip] if clip else None
        return (c0, r0, c1, r1), clip_rows

    @staticmethod
    def clip_mask(clip_rows, r0, r1, c0, c1):
        m = np.zeros((r1 - r0, c1 - c0), bool)
        for (a0, b0, a1, b1) in clip_rows:
            x0, x1 = max(a0, c0), min(a1, c1)
            y0, y1 = max(b0, r0), min(b1, r1)
            if x1 > x0 and y1 > y0:
                m[y0 - r0:y1 - r0, x0 - c0:x1 - c0] = True
        return m

    def draw_tris(self, cv, op):
        data = np.array(as_str(op.data).split(","), dtype=np.float64).reshape(-1, 3, 8)
        (bc0, br0, bc1, br1), clip_rows = self.op_bounds(cv, op)
        if bc1 <= bc0 or br1 <= br0:
            return
        tex = self.texture(op.tex, op.texver)
        blend = as_str(op.blend)
        ss, h = cv.ss, cv.h
        for tri in data:
            xs = tri[:, 0] * ss
            ys = (h - tri[:, 1]) * ss
            area = (xs[1] - xs[0]) * (ys[2] - ys[0]) - (xs[2] - xs[0]) * (ys[1] - ys[0])
            if abs(area) < 1e-9:
                continue
            c0 = max(bc0, int(math.floor(xs.min())))
            c1 = min(bc1, int(math.ceil(xs.max())) + 1)
            r0 = max(br0, int(math.floor(ys.min())))
            r1 = min(br1, int(math.ceil(ys.max())) + 1)
            if c1 <= c0 or r1 <= r0:
                continue
            px = np.arange(c0, c1, dtype=np.float64) + 0.5
            py = np.arange(r0, r1, dtype=np.float64)[:, None] + 0.5
            l0 = ((xs[2] - xs[1]) * (py - ys[1]) - (ys[2] - ys[1]) * (px - xs[1])) / area
            l1 = ((xs[0] - xs[2]) * (py - ys[2]) - (ys[0] - ys[2]) * (px - xs[2])) / area
            l2 = 1.0 - l0 - l1
            eps = -1e-9
            mask = (l0 >= eps) & (l1 >= eps) & (l2 >= eps)
            if clip_rows is not None:
                mask &= self.clip_mask(clip_rows, r0, r1, c0, c1)
            if not mask.any():
                continue
            self.ntri += 1
            # barycentric weights: l0 -> vertex 0 etc. (edge v1v2 opposite v0)
            w0, w1, w2 = l0[mask], l1[mask], l2[mask]
            cols = tri[:, 2:6]
            if np.allclose(cols[0], cols[1]) and np.allclose(cols[0], cols[2]):
                frag = np.broadcast_to(cols[0].astype(np.float32), (w0.shape[0], 4)).copy()
            else:
                frag = (w0[:, None] * cols[0] + w1[:, None] * cols[1] + w2[:, None] * cols[2]).astype(np.float32)
            if tex is not None:
                uv = tri[:, 6:8]
                u = w0 * uv[0, 0] + w1 * uv[1, 0] + w2 * uv[2, 0]
                v = w0 * uv[0, 1] + w1 * uv[1, 1] + w2 * uv[2, 1]
                level = 0
                if tex.levels is not None and len(tex.levels) > 1:
                    H0, W0 = tex.levels[0].shape[:2]
                    uva = abs((uv[1, 0] - uv[0, 0]) * (uv[2, 1] - uv[0, 1]) - (uv[2, 0] - uv[0, 0]) * (uv[1, 1] - uv[0, 1]))
                    ratio = math.sqrt(uva * W0 * H0 / abs(area)) if uva > 0 else 1.0
                    level = tex.level_for(ratio)
                frag = frag * tex.sample(u, v, level)
            blend_into(cv, r0, r1, c0, c1, mask, frag, blend)

    def draw_text(self, cv, op):
        fonts, ss = self.fonts, cv.ss
        key = as_str(op.font)
        size = float(op.size)
        if size <= 0.5:
            return
        opts = as_str(op.opts)
        segs = []
        for s in as_str(op.segs).split(";"):
            if not s:
                continue
            parts = s.split(" ")
            r, g, b, a = (float(v) for v in parts[:4])
            txt = bytes.fromhex(parts[4]).decode("utf-8", "replace") if len(parts) > 4 and parts[4] else ""
            if txt:
                segs.append(((r, g, b, a), txt))
        if not segs:
            return
        plain = "".join(t for _, t in segs)
        x, y = float(op.x), float(op.y)
        width = fonts.width(key, plain) * size
        if "c" in opts:
            x -= width / 2
        elif "r" in opts:
            x -= width
        th, td = fonts.height(key, plain)
        fd = fonts.descender(key)
        if "d" in opts:
            base = y - size * fd
        elif "v" in opts:
            base = y - size * 0.5 * (th + td)
        elif "t" in opts:
            base = y - size * th
        elif "a" in opts:
            base = y - size * (1 + fd)
        elif "b" in opts:
            base = y - size * td
        else:  # 'x' or none: baseline
            base = y
        font = fonts.get(key, size * fonts.scale * ss)
        asc, desc = font.getmetrics()
        outline = "o" in opts or "O" in opts
        shadow = "s" in opts
        ow = float(op.outlineWidth or 0.25) * size * ss  # outline width in raster px
        pad = int(math.ceil(ow * 1.5)) + 3 if outline else 3
        if shadow:
            pad += int(size * ss * 0.1) + 2
        tw = int(math.ceil(font.getlength(plain))) + 2 * pad + 2
        th_px = asc + desc + 2 * pad
        prem = np.zeros((th_px, tw, 3), np.float32)
        alpha = np.zeros((th_px, tw), np.float32)
        glyphs = np.zeros((th_px, tw), np.float32)
        # sub-pixel placement of the baseline-left origin inside the raster
        X = x * ss
        Y = (cv.h - base) * ss
        ix, iy = int(math.floor(X)), int(math.floor(Y))
        fx, fy = X - ix, Y - iy
        xoff = pad + fx
        for (r, g, b, a), txt in segs:
            im = Image.new("L", (tw, th_px), 0)
            ImageDraw.Draw(im).text((xoff, pad + asc + fy), txt, font=font, fill=255, anchor="ls")
            m = np.asarray(im, dtype=np.float32) / 255.0
            glyphs = np.maximum(glyphs, m)
            ma = m * a
            prem = prem * (1 - ma[:, :, None]) + np.array([r, g, b], np.float32) * ma[:, :, None]
            alpha = alpha * (1 - ma) + ma
            xoff += font.getlength(txt)
        if outline or shadow:
            oc = [float(v) for v in as_str(op.outline).split()] if outline else [0, 0, 0, 1]
            if "O" in opts:
                oc = [1, 1, 1, oc[3]]
            gi = Image.fromarray((glyphs * 255).astype(np.uint8))
            if outline:
                o = np.asarray(gi.filter(ImageFilter.GaussianBlur(max(0.6, ow * 0.45))), np.float32) / 255.0
                o = np.clip(o * float(op.outlineStrength or 1.7) * 1.6, 0, 1) * oc[3]
            else:
                o = np.zeros_like(glyphs)
            if shadow:
                d = max(1, int(round(size * ss * 0.06)))
                sh = np.zeros_like(glyphs)
                sh[d:, d:] = glyphs[:-d, :-d] * 0.6
                o = np.maximum(o, sh)
            # text over outline
            prem = prem + np.array(oc[:3], np.float32) * (o * (1 - alpha))[:, :, None]
            alpha = alpha + o * (1 - alpha)
        # place: image (0,0) is at raster (ix - pad, iy - pad - asc)
        r0, c0 = iy - pad - asc, ix - pad
        r1, c1 = r0 + th_px, c0 + tw
        (bc0, br0, bc1, br1), clip_rows = self.op_bounds(cv, op)
        R0, R1, C0, C1 = max(r0, br0), min(r1, br1), max(c0, bc0), min(c1, bc1)
        if R1 <= R0 or C1 <= C0:
            return
        sub_a = alpha[R0 - r0:R1 - r0, C0 - c0:C1 - c0]
        mask = sub_a > 0.002
        if clip_rows is not None:
            mask &= self.clip_mask(clip_rows, R0, R1, C0, C1)
        if not mask.any():
            return
        sub_p = prem[R0 - r0:R1 - r0, C0 - c0:C1 - c0]
        frag = np.concatenate([sub_p[mask], sub_a[mask][:, None]], axis=1)
        blend_into(cv, R0, R1, C0, C1, mask, frag, "ONE,ONE_MINUS_SRC_ALPHA")


# ------------------------------------------------------------------------------------------- driver
DRIVER = r"""
function(w, frames, vsx, vsy)
  local results = {}
  local function step(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then results[#results + 1] = name .. ": " .. tostring(err) end
    return ok
  end
  local rec = HARNESS.rec
  local function draw()
    rec.resetState()
    if w.DrawScreen then w:DrawScreen() end
  end
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
  local enemyCom = U.addUnit(8, 1, 1)
  if not step("Initialize", function() w:Initialize() end) then return results end
  if w.SetConfigData then step("SetConfigData", function() w:SetConfigData(nil) end) end
  if w.ViewResize then step("ViewResize", function() w:ViewResize(vsx, vsy) end) end
  if w.UnitCreated then step("UnitCreated", function() w:UnitCreated(enemyCom, 8, 1) w:UnitCreated(com, 1, 0) end) end
  step("pregame", function()
    for i = 1, 20 do HARNESS.clock = HARNESS.clock + 0.05 w:Update(0.05) draw() end
  end)
  HARNESS.frame = 1
  if w.GameStart then step("GameStart", function() w:GameStart() end) end
  step("frames", function()
    for f = 1, frames do
      HARNESS.frame = f
      HARNESS.clock = HARNESS.clock + 1 / 30
      if w.GameFrame then w:GameFrame(f) end
      w:Update(1 / 30)
      draw()
    end
  end)
  -- final frame: record the screen
  step("final DrawScreen", function()
    HARNESS.frame = frames + 1
    HARNESS.clock = HARNESS.clock + 1 / 30
    if w.GameFrame then w:GameFrame(frames + 1) end
    w:Update(1 / 30)
    rec.screenOn = true
    rec.screen.ops = {}
    draw()
    rec.screenOn = false
    rec.resetState()
  end)
  return results
end
"""

SETUP = r"""
local vsx, vsy, uiScale, coms, tidal, wind = ...
HARNESS.clock = 100
os.clock = function() return HARNESS.clock end
Spring.GetViewGeometry = function() return vsx, vsy, 0, 0 end
Spring.GetWindowGeometry = Spring.GetViewGeometry
gl.GetViewSizes = function() return vsx, vsy end
local getF = Spring.GetConfigFloat
Spring.GetConfigFloat = function(k, d) if k == "ui_scale" then return uiScale end return getF(k, d) end
Spring.IsGUIHidden = function() return false end
HARNESS.wind = wind
HARNESS.mx, HARNESS.my = math.floor(vsx / 2), math.floor(vsy / 2)
if tidal then
  Spring.GetTidal = function() return 20 end
  Spring.GetGroundExtremes = function() return 0, 100, -50, 100 end
end
if coms then
  Spring.GetTeamList = function(ally) if ally == nil then return { 0, 1, 2, 3, 4 } end return { 0, 1 } end
end
VFS.FileExists = function(p) return PY_FILE_EXISTS(p) end
"""

LOAD_FLOWUI = r"""
local src, name, legacy = ...
local f, e = loadstring(src, name)
if not f then error(e) end
local env = setmetatable({ widget = {} }, { __index = _G })
setfenv(f, env)
f()
HARNESS.elements = {}
local element = WG.FlowUI.Draw.Element
WG.FlowUI.Draw.Element = function(px, py, sx, sy, ...)
  HARNESS.elements[#HARNESS.elements + 1] = { px, py, sx, sy }
  return element(px, py, sx, sy, ...)
end
if legacy then
  -- spring-2026 FlowUI: no skewed drawers, Element without the skew argument
  local D = WG.FlowUI.Draw
  D.RectRoundQuad, D.TexturedRectRoundQuad, D.RectRoundOutlineQuad = nil, nil, nil
  local el = D.Element
  D.Element = function(px, py, sx, sy, tl, tr, br, bl, ptl, ptr, pbr, pbl, opacity, color1, color2, bgpadding, opaque)
    return el(px, py, sx, sy, tl, tr, br, bl, ptl, ptr, pbr, pbl, opacity, color1, color2, bgpadding, opaque)
  end
end
"""


def py_file_exists(p):
    p = as_str(p)
    low = p.replace("\\", "/").lower()
    if low.startswith("icons/") or low.startswith("luaui/images/"):
        return asset_for_texture(p) is not None
    return True


def lua_text(path):
    return open(path, encoding="utf-8", errors="replace").read()


def run_widget(args, fonts):
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.HARNESS_LEGACY = args.legacy
    g.PY_TEXT_WIDTH = lambda k, t: fonts.width(as_str(k), as_str(t))
    g.PY_TEXT_HEIGHT = lambda k, t: fonts.height(as_str(k), as_str(t))
    g.PY_FILE_EXISTS = py_file_exists
    rt.execute(lua_text(os.path.join(TOOLS, "mock_env.lua")))
    g.HARNESS.barRoot = os.path.join(REPO, "stock_reference")
    rt.execute(SETUP, args.vsx, args.vsy, args.ui_scale, not args.no_coms, not args.no_tidal, args.wind)
    rt.execute(lua_text(os.path.join(TOOLS, "mock_gl_record.lua")))
    flowui = os.path.join(REPO, "stock_reference", "gui_flowui.lua")
    rt.execute(LOAD_FLOWUI, lua_text(flowui), "@" + flowui, args.legacy)
    src = lua_text(args.widget)
    chunk = rt.eval("function(src, name) local f, e = loadstring(src, name) if not f then error(e) end return f end")(
        src, "@" + args.widget)
    try:
        chunk()
    except Exception as e:  # e.g. the stock widget with --legacy: no BAR table
        print(f"widget failed to load: {e}", file=sys.stderr)
        sys.exit(1)
    w = g.widget
    errors = rt.eval(DRIVER)(w, args.frames, args.vsx, args.vsy)
    errs = [as_str(errors[i]) for i in range(1, len(errors) + 1)]
    return rt, errs


def topbar_box(rt, vsx, vsy):
    """(x1, y1, x2, y2) in image coordinates of the drawn top bar elements, and the metal element's left x"""
    els = rt.globals().HARNESS.elements
    boxes = []
    for i in range(1, len(els) + 1):
        e = els[i]
        boxes.append((float(e[1]), float(e[2]), float(e[3]), float(e[4])))
    if not boxes:
        return None, None
    top = [b for b in boxes if b[3] >= vsy - 1] or boxes
    metal = min(top, key=lambda b: b[0])  # the leftmost element at the top edge: metal
    x1 = min(b[0] for b in boxes)
    x2 = max(b[2] for b in boxes)
    y_low = min(b[1] for b in boxes)
    y_high = max(b[3] for b in boxes)
    return (x1, vsy - y_high, x2, vsy - y_low, vsy - metal[1]), metal[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("widget")
    ap.add_argument("--out", default=None)
    ap.add_argument("--vsx", type=int, default=1920)
    ap.add_argument("--vsy", type=int, default=1080)
    ap.add_argument("--ui-scale", type=float, default=1.0)
    ap.add_argument("--legacy", action="store_true", help="simulate a spring-2026 game build (no BAR table, no skew drawers)")
    ap.add_argument("--frames", type=int, default=200)
    ap.add_argument("--compare", default=None, help="mockup PNG to show above the render (plus a 50%% blend)")
    ap.add_argument("--mockup-bar-height", type=float, default=MOCKUP_BAR_H)
    ap.add_argument("--mockup-metal-x", type=float, default=MOCKUP_METAL_X)
    ap.add_argument("--crop", default="auto", help="auto | full | x1,y1,x2,y2 (image pixels)")
    ap.add_argument("--scale", type=float, default=1.0, help="upsample the output for viewing")
    ap.add_argument("--ss", type=int, default=2, help="supersampling (antialiasing) factor")
    ap.add_argument("--bg", default="60,80,70", help="background R,G,B or 'transparent'")
    ap.add_argument("--font-scale", type=float, default=0.95,
                    help="Pillow pixel size per Spring font size (0.95: calibrated on a real game screenshot)")
    ap.add_argument("--wind", type=float, default=15.2)
    ap.add_argument("--no-coms", action="store_true", help="do not fake >2 teams (stock hides the commander counter then)")
    ap.add_argument("--no-tidal", action="store_true", help="do not fake a water map (hides the tidal element)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    t0 = time.time()
    fonts = Fonts(args.font_scale)
    rt, errs = run_widget(args, fonts)
    for e in errs:
        print("LUA ERROR " + e, file=sys.stderr)
    if any(e.startswith("final DrawScreen") or e.startswith("Initialize") for e in errs):
        sys.exit(1)
    t1 = time.time()

    bg = None if args.bg == "transparent" else tuple(int(v) for v in args.bg.split(","))
    screen = Canvas(args.vsx, args.vsy, args.ss, bg)
    R = Renderer(rt, args.ss, fonts, args.verbose)
    rec = rt.globals().HARNESS.rec
    R.draw_ops(screen, rec.screen.ops)
    C, A = screen.downsample()
    if bg is None:
        rgb = np.where(A[:, :, None] > 0, C / np.maximum(A[:, :, None], 1e-6), 0)
        img = Image.fromarray(np.dstack([np.clip(rgb * 255 + 0.5, 0, 255), np.clip(A * 255 + 0.5, 0, 255)]).astype(np.uint8), "RGBA")
    else:
        img = Image.fromarray(np.clip(C * 255 + 0.5, 0, 255).astype(np.uint8), "RGB")
    t2 = time.time()

    box, metal_left = topbar_box(rt, args.vsx, args.vsy)
    if args.crop == "auto":
        # everything drawn: pixels that differ from the background (or are not transparent)
        if bg is None:
            drawn = A > 0.02
        else:
            drawn = np.abs(C - np.array(bg, np.float32) / 255.0).sum(axis=2) > 0.03
        ys, xs = np.nonzero(drawn)
        if len(xs):
            x1, x2, y1, y2 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
            bottom = y2 + 10
            if box:
                x1, x2 = min(x1, box[0]), max(x2, box[2])
                bottom = max(bottom, box[4] + 40)
            crop = (max(0, int(x1) - 10), max(0, int(y1) - 10), min(args.vsx, int(math.ceil(x2)) + 10),
                    min(args.vsy, int(math.ceil(bottom))))
        else:
            crop = (0, 0, args.vsx, args.vsy)
    elif args.crop != "full":
        crop = tuple(int(v) for v in args.crop.split(","))
    else:
        crop = (0, 0, args.vsx, args.vsy)
    out_img = img.crop(crop)

    if args.compare:
        bar_h = (box[4] - box[1]) if box else out_img.height
        mock = Image.open(args.compare).convert("RGB")
        f = bar_h / args.mockup_bar_height
        mock = mock.resize((max(1, int(round(mock.width * f))), max(1, int(round(mock.height * f)))), Image.LANCZOS)
        render = out_img.convert("RGB")
        # align the mockup's metal element left edge with the render's
        dx = int(round((metal_left - crop[0]) - args.mockup_metal_x * f)) if metal_left is not None else 0
        Wd = render.width
        row_h = max(render.height, mock.height)
        mrow = Image.new("RGB", (Wd, row_h), (0, 0, 0))
        mrow.paste(mock, (dx, 0))
        rrow = Image.new("RGB", (Wd, row_h), (0, 0, 0))
        rrow.paste(render, (0, 0))
        blend = Image.blend(mrow, rrow, 0.5)
        sep = 4
        comp = Image.new("RGB", (Wd, row_h * 3 + sep * 2), (255, 0, 255))
        comp.paste(mrow, (0, 0))
        comp.paste(rrow, (0, row_h + sep))
        comp.paste(blend, (0, 2 * (row_h + sep)))
        out_img = comp

    if args.scale != 1:
        out_img = out_img.resize((int(out_img.width * args.scale), int(out_img.height * args.scale)), Image.LANCZOS)
    out = args.out or os.path.splitext(os.path.basename(args.widget))[0] + ".png"
    out_img.save(out)
    if R.missing:
        print("textures not in tools/assets (drawn as grey 0.3 alpha): " + ", ".join(sorted(R.missing)))
    print(f"wrote {out} ({out_img.width}x{out_img.height}); lua {t1 - t0:.1f}s, raster {t2 - t1:.1f}s, "
          f"{len(rec.screen.ops)} screen ops, {R.ntri} triangles; crop {crop}")
    if errs:
        sys.exit(2)


if __name__ == "__main__":
    main()
