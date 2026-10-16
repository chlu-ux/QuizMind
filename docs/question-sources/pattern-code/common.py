"""Shared types and the class-diagram drawer for the pattern code-completion bank (see ../software-designer.t6-pattern-code.outline.md)."""
import os
import sys
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "uml"))
import svglib  # noqa: E402

KINDS = {"类名": "填空·类名", "关键字": "填空·关键字", "方法": "填空·方法", "逻辑": "填空·逻辑"}
# concept questions: what the pattern is for, its roles, where to use it, pros and cons, and how it differs from similar ones
CONCEPT_KINDS = {"意图": "概念·意图", "角色": "概念·角色", "场景": "概念·场景", "优缺点": "概念·优缺点", "辨析": "概念·辨析"}


@dataclass
class Blank:
    """One blank of a code case. `ans` is what the code needs, `wrong` three plausible mistakes."""
    ans: str
    wrong: list
    kind: str            # key of KINDS
    why: str             # explanation shown after answering
    quote: str           # verbatim sentence of the lecture section
    diff: int = 2


@dataclass
class Code:
    """`src` holds the code shown to the learner with @@n@@ at each blank; `blanks` maps n to its Blank."""
    src: str
    blanks: dict
    scene: str           # one-line description of the scenario
    main: str = ""       # hidden driver (Java: body of main(); C++: body of main()) used only to compile and run


@dataclass
class Pattern:
    key: str
    sec: str             # T6.x
    name: str            # 工厂方法
    en: str
    diagram: dict
    java: Code
    cpp: Code
    diagram_cpp: dict = None     # when the C++ code needs a different class diagram (e.g. Prototype instead of Cloneable)


# ---------------------------------------------------------------------------------------------------------------
# class diagram
# ---------------------------------------------------------------------------------------------------------------
def box(name, attrs=(), methods=(), stereo=None, abstract=False):
    return dict(name=name, attrs=list(attrs), methods=list(methods), stereo=stereo, abstract=abstract)


def compact(sig):
    """`+send(msg: String, from: User): void` -> `+send(msg, from): void`: the diagram stays readable on a phone."""
    if "(" not in sig:
        return sig
    head, _, rest = sig.partition("(")
    params, _, tail = rest.partition(")")
    params = ", ".join(x.split(":")[0].strip() for x in params.split(",") if x.strip())
    return f"{head}({params}){tail}"


def draw_diagram(path, title, boxes, rows, edges, cw=170, gap_y=64, pad=16):
    """boxes: {id: box(...)}; rows: [[(id, col), ...], ...] with col a float column index;
    edges: [(from, to, kind, label)] where kind is gen | real | assoc | dep | agg | comp and `to` carries the arrow head
    (for agg / comp `from` is the whole)."""
    boxes = {k: dict(v, methods=[compact(m) for m in v["methods"]]) for k, v in boxes.items()}
    # measure
    size = {}
    for bid, b in boxes.items():
        texts = [b["name"] + (" " * 0)] + b["attrs"] + b["methods"]
        w = max(svglib.tw(t, 13) + 24 for t in texts)
        w = max(w, svglib.tw(b["name"], 15) + 36, 110)
        lh = 20
        head = 30 + (16 if b["stereo"] else 0)
        a_h = max(len(b["attrs"]) * lh + 8, 16) if b["attrs"] else 0
        m_h = max(len(b["methods"]) * lh + 8, 16)
        size[bid] = (round(w), head + a_h + m_h)
    row_h = [max(size[i][1] for i, _ in r) for r in rows]
    pos = {}
    y = pad
    row_y = []
    for r, rh in zip(rows, row_h):
        row_y.append(y)
        right = -1e9
        for bid, col in sorted(r, key=lambda t: t[1]):
            w, h = size[bid]
            x = max(pad + col * cw + (cw - w) / 2 + 10, right + 26)   # keep a gap between neighbours
            pos[bid] = (x, y, w, h)
            right = x + w
        y += rh + gap_y
    W = int(max(x + w for x, _, w, _ in pos.values()) + pad)
    H = int(y - gap_y + pad)
    c = svglib.Canvas(W, H)
    row_of = {bid: ri for ri, r in enumerate(rows) for bid, _ in r}

    for bid, b in boxes.items():
        x, y0, w, _ = pos[bid]
        c.class_box(x, y0, w, b["name"], b["attrs"], b["methods"], stereo=b["stereo"], italic=b["abstract"],
                    show_attrs=bool(b["attrs"]))

    # attachment points: spread the edges that meet the same side of a box
    sides = {}  # (bid, side) -> list of (other_x, idx)
    plan = []
    for i, (a, b, kind, lab) in enumerate(edges):
        ra, rb = row_of[a], row_of[b]
        ax = pos[a][0] + pos[a][2] / 2
        bx = pos[b][0] + pos[b][2] / 2
        if ra == rb:
            sa, sb = ("r", "l") if ax < bx else ("l", "r")
        elif ra < rb:
            sa, sb = "b", "t"
        else:
            sa, sb = "t", "b"
        sides.setdefault((a, sa), []).append((bx, i, "a"))
        sides.setdefault((b, sb), []).append((ax, i, "b"))
        plan.append([sa, sb])
    attach = {}
    for (bid, side), lst in sides.items():
        lst.sort()
        x, y0, w, h = pos[bid]
        n = len(lst)
        for k, (_, i, end) in enumerate(lst):
            f = (k + 1) / (n + 1)
            if side in ("t", "b"):
                attach[(i, end)] = (x + w * f, y0 + (h if side == "b" else 0))
            else:
                attach[(i, end)] = (x + (w if side == "r" else 0), y0 + 15 + 18 * k)
    # horizontal channel for the elbows between two rows
    channel = {}
    for i, (a, b, kind, lab) in enumerate(edges):
        ra, rb = sorted((row_of[a], row_of[b]))
        if ra != rb:
            channel.setdefault(ra, []).append(i)
    for i, (a, b, kind, lab) in enumerate(edges):
        p, q = attach[(i, "a")], attach[(i, "b")]
        ra, rb = row_of[a], row_of[b]
        if ra == rb:
            pts = [p, q] if abs(p[1] - q[1]) < 1 else [p, (p[0] + (q[0] - p[0]) / 2, p[1]), (p[0] + (q[0] - p[0]) / 2, q[1]), q]
        else:
            lo = min(ra, rb)
            ids = channel[lo]
            k = ids.index(i)
            top = row_y[lo] + row_h[lo]
            my = top + gap_y * (k + 1) / (len(ids) + 1)
            pts = [p, (p[0], my), (q[0], my), q] if abs(p[0] - q[0]) > 1 else [p, q]
        start = end = None
        dash = None
        if kind == "gen":
            end = "tri"
        elif kind == "real":
            end, dash = "tri", "6 4"
        elif kind == "assoc":
            end = "open"
        elif kind == "dep":
            end, dash = "open", "6 4"
        elif kind == "agg":
            start = "dia"
        elif kind == "comp":
            start = "fdia"
        else:
            raise ValueError(kind)
        # "to" carries the arrow head; for gen/real the child is `from`, so the head sits at `to` already
        svglib.connect(c, pts, start=start, end=end, dash=dash)
        if lab:
            mid = pts[len(pts) // 2 - 1] if len(pts) > 2 else pts[0]
            nxt = pts[len(pts) // 2] if len(pts) > 2 else pts[1]
            lx, ly = (mid[0] + nxt[0]) / 2, (mid[1] + nxt[1]) / 2
            svglib.label(c, lx + 10, ly - 4, lab, size=12, anchor="start")
    svglib.save(c, path, title)
