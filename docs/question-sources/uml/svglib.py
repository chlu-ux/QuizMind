"""Tiny helpers for drawing UML diagrams as static SVG.

Only elements that the server accepts and flutter_svg can draw are produced: rect, ellipse, circle, line,
polyline, polygon, path, text, g. No markers, no CSS: arrow heads are drawn as polygons, so a diagram looks
the same in a browser <img>, in Flutter and in the admin page.
"""
import math

FONT = "PingFang SC, Microsoft YaHei, Noto Sans CJK SC, sans-serif"
INK = "#1f2937"
LINE = "#374151"
BOX = "#fffdf0"      # class / state fill
BOX2 = "#eef4ff"     # secondary fill
NOTE = "#6b7280"
ACCENT = "#b45309"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def tw(s, size):
    """Rough rendered width of a string: CJK and full-width glyphs are one em, Latin about 0.56 em."""
    return sum(size if ord(ch) > 0x2E80 else size * 0.58 for ch in s)


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.parts = []

    # ---- primitives -------------------------------------------------------------------------
    def add(self, s):
        self.parts.append(s)

    def rect(self, x, y, w, h, fill=BOX, stroke=LINE, sw=1.5, rx=0, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="{rx:g}" fill="{fill}" stroke="{stroke}" stroke-width="{sw:g}"{d}/>')

    def ellipse(self, cx, cy, rx, ry, fill=BOX, stroke=LINE, sw=1.5, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<ellipse cx="{cx:g}" cy="{cy:g}" rx="{rx:g}" ry="{ry:g}" fill="{fill}" stroke="{stroke}" stroke-width="{sw:g}"{d}/>')

    def circle(self, cx, cy, r, fill="none", stroke=LINE, sw=1.5):
        self.add(f'<circle cx="{cx:g}" cy="{cy:g}" r="{r:g}" fill="{fill}" stroke="{stroke}" stroke-width="{sw:g}"/>')

    def line(self, x1, y1, x2, y2, stroke=LINE, sw=1.5, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{stroke}" stroke-width="{sw:g}"{d}/>')

    def polyline(self, pts, stroke=LINE, sw=1.5, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        p = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        self.add(f'<polyline points="{p}" fill="none" stroke="{stroke}" stroke-width="{sw:g}"{d}/>')

    def polygon(self, pts, fill="#ffffff", stroke=LINE, sw=1.5):
        p = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        self.add(f'<polygon points="{p}" fill="{fill}" stroke="{stroke}" stroke-width="{sw:g}"/>')

    def path(self, d, fill="none", stroke=LINE, sw=1.5, dash=None):
        da = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="{d}" fill="{fill}" stroke="{stroke}" stroke-width="{sw:g}"{da}/>')

    def text(self, x, y, s, size=14, anchor="middle", bold=False, italic=False, fill=INK):
        """y is the baseline."""
        extra = (' font-weight="bold"' if bold else "") + (' font-style="italic"' if italic else "")
        self.add(f'<text x="{x:g}" y="{y:g}" font-size="{size:g}" text-anchor="{anchor}" fill="{fill}"{extra}>{esc(s)}</text>')

    def ctext(self, cx, cy, s, size=14, **kw):
        """Text centred on (cx, cy)."""
        self.text(cx, cy + size * 0.36, s, size=size, **kw)

    def underlined(self, cx, cy, s, size=14, bold=False):
        self.ctext(cx, cy, s, size=size, bold=bold)
        w = tw(s, size)
        self.line(cx - w / 2, cy + size * 0.62, cx + w / 2, cy + size * 0.62, sw=1)

    # ---- UML pieces ---------------------------------------------------------------------------
    def class_box(self, x, y, w, name, attrs=(), methods=(), stereo=None, italic=False, member_size=13, show_attrs=True):
        """A class: name / attributes / operations. Returns (x, y, w, h)."""
        lh = 20
        head = 30 + (16 if stereo else 0)
        a_h = max(len(attrs) * lh + 8, 16) if show_attrs else 0
        m_h = max(len(methods) * lh + 8, 16)
        h = head + a_h + m_h
        self.rect(x, y, w, h)
        cy = y + head / 2
        if stereo:
            self.ctext(x + w / 2, y + 14, f"«{stereo}»", size=12, fill=NOTE)
            cy = y + 30
        self.ctext(x + w / 2, cy, name, size=15, bold=not italic, italic=italic)
        yy = y + head
        if show_attrs:
            self.line(x, yy, x + w, yy)
            for i, a in enumerate(attrs):
                self.text(x + 8, yy + 18 + i * lh, a, size=member_size, anchor="start")
            yy += a_h
        self.line(x, yy, x + w, yy)
        for i, m in enumerate(methods):
            self.text(x + 8, yy + 18 + i * lh, m, size=member_size, anchor="start", italic=italic)
        return (x, y, w, h)

    def simple_box(self, x, y, w, h, name, fill=BOX, size=15, bold=True, rx=0):
        self.rect(x, y, w, h, fill=fill, rx=rx)
        self.ctext(x + w / 2, y + h / 2, name, size=size, bold=bold)
        return (x, y, w, h)


# ---- connectors with UML line ends ---------------------------------------------------------------
def _unit(p, q):
    dx, dy = q[0] - p[0], q[1] - p[1]
    n = math.hypot(dx, dy) or 1
    return dx / n, dy / n


def end_shape(c, kind, tip, frm):
    """Draw the line end `kind` at `tip`, for a line arriving from `frm`. Returns where the line itself should stop."""
    ux, uy = _unit(frm, tip)       # points towards the tip
    nx, ny = -uy, ux
    if kind is None:
        return tip
    if kind == "open":             # association navigability / dependency / return message
        L, W = 12, 6
        bx, by = tip[0] - ux * L, tip[1] - uy * L
        c.polyline([(bx + nx * W, by + ny * W), tip, (bx - nx * W, by - ny * W)])
        return tip
    if kind in ("filled", "tri"):  # synchronous message / hollow triangle (generalization, realization)
        L, W = 14, 7
        bx, by = tip[0] - ux * L, tip[1] - uy * L
        c.polygon([tip, (bx + nx * W, by + ny * W), (bx - nx * W, by - ny * W)], fill=LINE if kind == "filled" else "#ffffff")
        return (bx, by) if kind == "tri" else (bx + ux * 2, by + uy * 2)
    if kind in ("dia", "fdia"):    # aggregation (hollow) / composition (filled)
        L, W = 22, 7
        mx, my = tip[0] - ux * L / 2, tip[1] - uy * L / 2
        bx, by = tip[0] - ux * L, tip[1] - uy * L
        c.polygon([tip, (mx + nx * W, my + ny * W), (bx, by), (mx - nx * W, my - ny * W)], fill=LINE if kind == "fdia" else "#ffffff")
        return (bx, by)
    raise ValueError(kind)


def connect(c, pts, start=None, end=None, dash=None, sw=1.5):
    """Polyline through `pts` with a UML line end at each side."""
    pts = [tuple(p) for p in pts]
    first = end_shape(c, start, pts[0], pts[1]) if start else pts[0]
    last = end_shape(c, end, pts[-1], pts[-2]) if end else pts[-1]
    body = [first] + pts[1:-1] + [last]
    c.polyline(body, dash=dash, sw=sw)


def label(c, x, y, s, size=12, anchor="middle", fill=INK, italic=False):
    c.text(x, y, s, size=size, anchor=anchor, fill=fill, italic=italic)


def stick(c, cx, top, name, size=14):
    """A stick figure whose head starts at `top`; returns the point at its middle (for attaching lines)."""
    c.circle(cx, top + 9, 9, fill="#ffffff")
    c.line(cx, top + 18, cx, top + 44)
    c.line(cx - 16, top + 28, cx + 16, top + 28)
    c.line(cx, top + 44, cx - 14, top + 64)
    c.line(cx, top + 44, cx + 14, top + 64)
    c.ctext(cx, top + 80, name, size=size)
    return (cx, top + 32)


def save(c, path, title):
    body = "\n  ".join(c.parts)
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{c.w}" height="{c.h}" viewBox="0 0 {c.w} {c.h}" '
           f'font-family="{FONT}">\n  <title>{esc(title)}</title>\n  <rect width="{c.w}" height="{c.h}" fill="#ffffff"/>\n  {body}\n</svg>\n')
    with open(path, "w", encoding="utf-8") as f:
        f.write(svg)
