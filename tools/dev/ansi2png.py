#!/usr/bin/env python3
"""Render a terminal capture (tmux capture-pane -e -p) as a PNG in a terminal window frame.

Usage: ansi2png.py output.png COLS ROWS "window title" capture.txt

Colors and SGR handling come from ansi2html.py (same folder). Needs Pillow and the DejaVu fonts
(Debian: fonts-dejavu-core). Glyphs missing from DejaVu Sans Mono fall back to DejaVu Sans, then Noto.
Renders at 2x so the image stays sharp when GitHub scales it down.
"""
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ansi2html import BG_DEFAULT, FG_DEFAULT, SEQ, State  # noqa: E402

SCALE = 2
FONT_SIZE = 15 * SCALE
PAD = 14 * SCALE
BAR = 30 * SCALE
RADIUS = 10 * SCALE
FRAME = "#0b0d11"
TITLE_FG = "#8b909a"
DOTS = ["#ff5f57", "#febc2e", "#28c840"]

FONT_DIRS = ["/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/truetype/noto", "/usr/share/fonts/opentype/noto"]


def find_font(names):
    for d in FONT_DIRS:
        for n in names:
            p = os.path.join(d, n)
            if os.path.exists(p):
                return p
    return None


REGULAR = find_font(["DejaVuSansMono.ttf"])
BOLD = find_font(["DejaVuSansMono-Bold.ttf"]) or REGULAR
FALLBACKS = [p for p in (find_font(["DejaVuSans.ttf"]), find_font(["NotoSansSymbols2-Regular.ttf"]),
                         find_font(["NotoSansMono-Regular.ttf"])) if p]
if not REGULAR:
    sys.exit("DejaVu Sans Mono not found (Debian: apt-get install fonts-dejavu-core)")
assert REGULAR and BOLD

FONTS = {}


def font(path):
    if path not in FONTS:
        FONTS[path] = ImageFont.truetype(path, FONT_SIZE)
    return FONTS[path]


def has_glyph(path, ch):
    # PIL draws .notdef for missing glyphs; compare against a character that surely is missing.
    f = font(path)
    return f.getmask(ch).getbbox() != f.getmask("\U0010FFFD").getbbox() or ch == " "


GLYPH_CACHE = {}


def font_for(ch, bold):
    key = (ch, bold)
    if key not in GLYPH_CACHE:
        base = BOLD if bold else REGULAR
        choice = base
        if not has_glyph(base, ch):
            choice = next((p for p in FALLBACKS if has_glyph(p, ch)), base)
        GLYPH_CACHE[key] = choice
    return GLYPH_CACHE[key]


def rgb(hexcol):
    hexcol = hexcol.lstrip("#")
    return tuple(int(hexcol[i:i + 2], 16) for i in (0, 2, 4))


def blend(fg, bg, a):
    f, b = rgb(fg), rgb(bg)
    return "#%02x%02x%02x" % tuple(int(f[i] * a + b[i] * (1 - a)) for i in range(3))


def parse(text, cols, rows):
    """Return rows of cells (char, fg, bg, bold) with BCE fill like ansi2html.convert."""
    st = State()
    grid = []
    for line in text.rstrip("\n").split("\n")[:rows]:
        cells, pos = [], 0

        def put(chunk):
            for ch in chunk:
                fg, bg = st.fg or FG_DEFAULT, st.bg or BG_DEFAULT
                if st.rev:
                    fg, bg = (st.bg or BG_DEFAULT), (st.fg or FG_DEFAULT)
                if st.dim:
                    fg = blend(fg, bg, 0.6)
                cells.append((ch, fg, bg, st.bold))

        for m in SEQ.finditer(line):
            put(line[pos:m.start()])
            pos = m.end()
            if m.group(2) == "m":
                st.apply(m.group(1))
        put(line[pos:])
        if cells and (st.bg or st.rev) and len(cells) < cols:
            bg = cells[-1][2]
            cells += [(" ", FG_DEFAULT, bg, False)] * (cols - len(cells))
        grid.append(cells[:cols])
    while len(grid) < rows:
        grid.append([])
    return grid


def render(grid, cols, rows, title, out):
    f = font(REGULAR)
    asc, desc = f.getmetrics()
    cw = round(f.getlength("M"))
    ch_h = asc + desc
    w = cols * cw + 2 * PAD
    h = rows * ch_h + 2 * PAD + BAR
    img = Image.new("RGB", (w, h), FRAME)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, w - 1, h - 1], RADIUS, fill=BG_DEFAULT)
    d.rounded_rectangle([0, 0, w - 1, BAR + RADIUS], RADIUS, fill="#1d2027")
    d.rectangle([0, BAR, w - 1, BAR + RADIUS], fill=BG_DEFAULT)
    for i, col in enumerate(DOTS):
        cx, cy, r = PAD + i * 20 * SCALE + 6 * SCALE, BAR // 2, 6 * SCALE
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
    tf = ImageFont.truetype(FALLBACKS[0] if FALLBACKS else REGULAR, 13 * SCALE)
    tw = d.textlength(title, font=tf)
    d.text(((w - tw) / 2, BAR / 2), title, fill=TITLE_FG, font=tf, anchor="lm")
    y0 = BAR + PAD
    for r, cells in enumerate(grid):
        y = y0 + r * ch_h
        for c, (ch, fg, bg, bold) in enumerate(cells):
            x = PAD + c * cw
            if bg != BG_DEFAULT:
                d.rectangle([x, y, x + cw - 1, y + ch_h - 1], fill=bg)
            if ch != " ":
                d.text((x, y), ch, fill=fg, font=font(font_for(ch, bold)))
    img.save(out, optimize=True)


def main():
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    out, cols, rows, title, src = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
    with open(src, encoding="utf-8", errors="replace") as fh:
        text = re.sub(r"\x1b\][^\x07]*\x07", "", fh.read())  # OSC (window title) entfernen
    render(parse(text, cols, rows), cols, rows, title, out)


if __name__ == "__main__":
    main()
