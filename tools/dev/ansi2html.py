#!/usr/bin/env python3
"""ANSI-Bildschirmabzüge (tmux capture-pane -e -p) als eine eigenständige HTML-Datei.

Nutzung: ansi2html.py ausgabe.html "Titel|Beschreibung|spalten" datei [ "Titel|…|spalten" datei … ]

Versteht SGR: 0, 1, 2, 3, 4, 7, 22, 23, 24, 27, 30–37, 39, 40–47, 49, 90–97, 100–107,
38;5;n, 48;5;n, 38;2;r;g;b, 48;2;r;g;b. Wie im Terminal (BCE) wird eine Zeile, die mit
gesetzter Hintergrundfarbe endet, bis zur Spaltenzahl mit dieser Farbe aufgefüllt.
Nur Standardbibliothek, keine externen Ressourcen im Ergebnis.
"""
import html
import re
import sys

BG_DEFAULT = "#14161b"
FG_DEFAULT = "#d4d7dd"
BASE16 = ["#1c1f24", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#c8ccd4",
          "#5c6370", "#ff7b86", "#b5e890", "#ffd88a", "#7cc4ff", "#de8cff", "#6fd6e3", "#ffffff"]


def xterm256(n):
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (steps[n // 36], steps[(n // 6) % 6], steps[n % 6])
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


class State:
    def __init__(self):
        self.reset()

    def reset(self):
        self.fg = None
        self.bg = None
        self.bold = self.dim = self.italic = self.under = self.rev = False

    def key(self):
        return (self.fg, self.bg, self.bold, self.dim, self.italic, self.under, self.rev)

    def style(self):
        fg, bg = self.fg or FG_DEFAULT, self.bg
        if self.rev:
            fg, bg = (self.bg or BG_DEFAULT), (self.fg or FG_DEFAULT)
        css = ["color:" + fg]
        if bg:
            css.append("background:" + bg)
        if self.bold:
            css.append("font-weight:bold")
        if self.dim:
            css.append("opacity:.6")
        if self.italic:
            css.append("font-style:italic")
        if self.under:
            css.append("text-decoration:underline")
        return ";".join(css)

    def apply(self, params):
        p = [int(x) if x else 0 for x in params.split(";")] if params else [0]
        i = 0
        while i < len(p):
            c = p[i]
            if c == 0:
                self.reset()
            elif c == 1:
                self.bold = True
            elif c == 2:
                self.dim = True
            elif c == 3:
                self.italic = True
            elif c == 4:
                self.under = True
            elif c == 7:
                self.rev = True
            elif c == 22:
                self.bold = self.dim = False
            elif c == 23:
                self.italic = False
            elif c == 24:
                self.under = False
            elif c == 27:
                self.rev = False
            elif 30 <= c <= 37:
                self.fg = BASE16[c - 30]
            elif 90 <= c <= 97:
                self.fg = BASE16[c - 90 + 8]
            elif c == 39:
                self.fg = None
            elif 40 <= c <= 47:
                self.bg = BASE16[c - 40]
            elif 100 <= c <= 107:
                self.bg = BASE16[c - 100 + 8]
            elif c == 49:
                self.bg = None
            elif c in (38, 48) and i + 1 < len(p):
                if p[i + 1] == 5 and i + 2 < len(p):
                    col = xterm256(p[i + 2])
                    i += 2
                elif p[i + 1] == 2 and i + 4 < len(p):
                    col = "#%02x%02x%02x" % tuple(p[i + 2:i + 5])
                    i += 4
                else:
                    col = None
                if c == 38:
                    self.fg = col
                else:
                    self.bg = col
                i += 1
            i += 1


SEQ = re.compile(r"\x1b\[([0-9;]*)([A-Za-z])")


def convert(text, cols):
    st = State()
    out = []
    for line in text.rstrip("\n").split("\n"):
        spans, buf, cur, width, pos = [], [], None, 0, 0

        def flush():
            if buf:
                spans.append('<span style="%s">%s</span>' % (cur_style[0], html.escape("".join(buf))))
                buf.clear()

        cur_style = [st.style()]
        cur = st.key()
        for m in SEQ.finditer(line):
            chunk = line[pos:m.start()]
            if chunk:
                buf.append(chunk)
                width += len(chunk)
            pos = m.end()
            if m.group(2) == "m":
                st.apply(m.group(1))
                if st.key() != cur:
                    flush()
                    cur, cur_style[0] = st.key(), st.style()
        chunk = line[pos:]
        if chunk:
            buf.append(chunk)
            width += len(chunk)
        # tmux capture-pane -e setzt Attribute am Zeilenende nicht zurück und lässt leere
        # Zeilen ohne Sequenzen. Eine leere Zeile ist deshalb immer Standard-Hintergrund,
        # sonst erbt sie den Auswahlbalken der Zeile davor.
        if width > 0 and (st.bg or st.rev) and width < cols:
            buf.append(" " * (cols - width))
        flush()
        out.append("".join(spans))
    return "\n".join(out)


PAGE = """<!DOCTYPE html>
<html lang="de"><head><meta charset="utf-8"><title>sshlobby Vorschau</title>
<style>
body{background:#0d0f13;color:#c9ccd3;font:15px/1.5 system-ui,sans-serif;margin:0;padding:24px 32px}
h1{font-size:22px;margin:0 0 4px}
p.lead{margin:0 0 24px;color:#8b909a}
section{margin:0 0 36px}
h2{font-size:16px;margin:0 0 2px}
p.d{margin:0 0 8px;color:#8b909a;font-size:13px}
pre.term{background:%s;color:%s;font:13px/1.25 "JetBrains Mono","DejaVu Sans Mono",Menlo,Consolas,monospace;
padding:10px 12px;border-radius:8px;box-shadow:0 4px 24px #0008;display:inline-block;margin:0;overflow-x:auto}
nav a{color:#7cc4ff;margin-right:14px;font-size:13px;text-decoration:none}
</style></head><body>
<h1>sshlobby 2.0: Vorschau der Oberfläche</h1>
<p class="lead">Mit den Test-Stubs gerendert (tmux, capture-pane mit Farben). Erzeugt von tools/dev/screenshots.sh.</p>
<nav>%s</nav><br>
%s
</body></html>
"""


def main():
    if len(sys.argv) < 4 or len(sys.argv) % 2:
        sys.exit(__doc__)
    out, rest = sys.argv[1], sys.argv[2:]
    nav, secs = [], []
    for k in range(0, len(rest), 2):
        title, desc, cols = (rest[k].split("|") + ["", "100"])[:3]
        with open(rest[k + 1], encoding="utf-8", errors="replace") as f:
            body = convert(f.read(), int(cols or 100))
        anchor = "v%d" % (k // 2 + 1)
        nav.append('<a href="#%s">%s</a>' % (anchor, html.escape(title)))
        secs.append('<section id="%s"><h2>%s</h2><p class="d">%s</p><pre class="term">%s</pre></section>'
                    % (anchor, html.escape(title), html.escape(desc), body))
    with open(out, "w", encoding="utf-8") as f:
        f.write(PAGE % (BG_DEFAULT, FG_DEFAULT, "\n".join(nav), "\n".join(secs)))


if __name__ == "__main__":
    main()
