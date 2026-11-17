"""framedesign.py (FrameDesign)

Editorial research diagrams as self-contained SVG: flowcharts and analysis
pipelines, causal DAGs, CONSORT trial flow, cohort selection (STROBE-style)
flow, study timelines, and multi-panel figures that combine FrameDesign
diagrams with InkSight charts.

Companion to InkSight: same palette, same serif type, same data-ink rules.
FrameDesign draws structure (boxes, arrows, stages, time); InkSight draws
quantities (bars, lines, scatter, distributions). See SKILL.md.

Security and privacy notes
- Standard library only. No network calls, no subprocess, no eval/exec,
  no pickle. Specs are plain JSON or Python dicts.
- Output SVG has no scripts, no remote fonts, no external links and no
  software or date metadata.
- SVG files read by compose_panels() and check_svg() are screened: DOCTYPE
  and ENTITY declarations, scripts, event handlers, foreignObject and remote
  references are refused.
- write_svg() refuses to overwrite unless asked and rejects '..' paths.
"""
from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

__version__ = "1.1.0"

# ---------------------------------------------------------------------------
# Shared design tokens (identical to InkSight: R/inksight.R, python/inksight.py)
# ---------------------------------------------------------------------------
INK = "#262626"          # data ink, text, primary strokes
MUTED = "#A6A6A6"        # secondary strokes and fills only (fails text contrast)
TEXT_MUTED = "#595959"   # secondary text (7:1 on white)
ACCENT = "#1F5FAD"       # the single accent, colour-deficiency safe
FILL_MUTED = "#F2F2F2"   # light tint for spans and emphasis areas
PAPER = "#FFFFFF"
FONT = "'Times New Roman', Times, 'Liberation Serif', serif"  # local fonts only
FONT_CSS = "Times New Roman, Times, Liberation Serif, serif"   # same, without quotes

SIZE_LABEL = 10.0        # node text, pt
SIZE_SMALL = 8.5         # edge labels, notes, reasons, pt
SIZE_TITLE = 11.0
SIZE_PANEL = 12.0        # panel letters A, B, C
STROKE = 0.75            # structural lines, pt
STROKE_FOCAL = 1.25      # focal nodes and highlighted paths
COLUMN_PT = 468.0        # 6.5 in, the InkSight default width
MAX_ACCENTS = 2          # accent is editorial: one or two focal elements

# Glyph advance widths (1/1000 em) for ASCII 32..126, Times-compatible
# metrics. Used to size boxes so text never overflows.
_W = {
    "regular": [250, 333, 408, 500, 500, 833, 778, 180, 333, 333, 500, 564, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444, 921, 722, 667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722, 556, 722, 667, 556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500, 333, 444, 500, 444, 500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500, 500, 500, 333, 389, 278, 500, 500, 722, 500, 500, 444, 480, 200, 480, 541],
    "bold": [250, 333, 555, 500, 500, 1000, 833, 278, 333, 333, 500, 570, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 570, 570, 570, 500, 930, 722, 667, 722, 722, 667, 611, 778, 778, 389, 500, 778, 667, 944, 722, 778, 611, 778, 722, 556, 667, 722, 722, 1000, 722, 722, 667, 333, 278, 333, 581, 500, 333, 500, 556, 444, 556, 444, 333, 500, 556, 278, 333, 556, 278, 833, 556, 500, 556, 556, 444, 389, 333, 556, 500, 722, 500, 500, 444, 394, 220, 394, 520],
    "italic": [250, 333, 420, 500, 500, 833, 778, 214, 333, 333, 500, 675, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 675, 675, 675, 500, 920, 611, 611, 667, 722, 611, 611, 722, 722, 333, 444, 667, 556, 833, 667, 722, 611, 722, 611, 500, 556, 722, 611, 833, 611, 556, 556, 389, 278, 389, 422, 500, 333, 500, 500, 444, 500, 444, 278, 500, 500, 278, 278, 444, 278, 722, 500, 500, 500, 500, 389, 389, 278, 500, 444, 667, 444, 444, 389, 400, 275, 400, 541],
}
_WX = {"\u00a0": 250, "•": 350, "·": 333, "–": 500, "×": 564, "≥": 549,
       "≤": 549, "±": 549, "µ": 576, "α": 524, "β": 509,
       "γ": 442, "Δ": 643, "→": 1000}


class SpecError(ValueError):
    """The diagram spec is malformed or its numbers do not add up."""


# ---------------------------------------------------------------------------
# Text measurement and wrapping
# ---------------------------------------------------------------------------
def text_width(s: str, size: float = SIZE_LABEL, style: str = "regular") -> float:
    table = _W.get(style, _W["regular"])
    total = 0
    for ch in s:
        o = ord(ch)
        if 32 <= o <= 126:
            total += table[o - 32]
        else:
            total += _WX.get(ch, 600)  # conservative for unknown glyphs
    return total * size / 1000.0


def wrap(text: str, max_w: float, size: float = SIZE_LABEL, style: str = "regular") -> list[str]:
    """Greedy word wrap; explicit newlines are kept. Over-long words stay whole."""
    lines: list[str] = []
    for para in str(text).split("\n"):
        words = para.split(" ")
        cur = ""
        for w in words:
            trial = w if not cur else cur + " " + w
            if cur and text_width(trial, size, style) > max_w:
                lines.append(cur)
                cur = w
            else:
                cur = trial
        lines.append(cur)
    return lines


def _esc(s) -> str:
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def _f(v: float) -> str:
    return f"{v:.2f}".rstrip("0").rstrip(".")


def _n(v) -> str:
    """Format a count with thousands separators: 12345 -> 12,345."""
    return f"{int(v):,}"


def _cnt(v) -> str:
    """'(n = 12,345)' joined by no-break spaces so it never splits across lines."""
    return f"(n\u00a0=\u00a0{_n(v)})"


# ---------------------------------------------------------------------------
# SVG builder
# ---------------------------------------------------------------------------
class _Canvas:
    def __init__(self):
        self.items: list[str] = []
        self.boxes: list[tuple] = []   # (kind, id, x, y, w, h) for the checker
        self.accent_uses = 0

    def add(self, s: str):
        self.items.append(s)

    def text_block(self, lines, cx, top, size=SIZE_LABEL, style="regular",
                   colour=INK, anchor="middle", lh=1.22, tag=None, maxw=None):
        weight = ' font-weight="bold"' if style == "bold" else ""
        italic = ' font-style="italic"' if style == "italic" else ""
        out = []
        for i, ln in enumerate(lines):
            y = top + size * 0.80 + i * size * lh  # baseline from cap height
            w = text_width(ln, size, style)
            meta = ""
            if maxw is not None:
                meta = f' data-fd-w="{_f(w)}" data-fd-maxw="{_f(maxw)}"'
            out.append(f'<text x="{_f(cx)}" y="{_f(y)}" font-size="{_f(size)}"'
                       f'{weight}{italic} fill="{colour}" text-anchor="{anchor}"{meta}>'
                       f'{_esc(ln)}</text>')
        self.add("".join(out))
        return len(lines) * size * lh

    def svg(self, width, height, title=None, desc=None) -> str:
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{_f(width)}pt" '
                f'height="{_f(height)}pt" viewBox="0 0 {_f(width)} {_f(height)}" '
                f'font-family="{FONT}" data-framedesign="{__version__}" role="img">')
        meta = ""
        if title:
            meta += f"<title>{_esc(title)}</title>"
        if desc:
            meta += f"<desc>{_esc(desc)}</desc>"
        defs = (
            "<defs>"
            f'<marker id="fd-arrow" viewBox="0 0 8 8" refX="7.4" refY="4" markerWidth="6" '
            f'markerHeight="6" markerUnits="userSpaceOnUse" orient="auto">'
            f'<path d="M0,0.6 L7.6,4 L0,7.4 Z" fill="{INK}"/></marker>'
            f'<marker id="fd-arrow-accent" viewBox="0 0 8 8" refX="7.4" refY="4" markerWidth="6.5" '
            f'markerHeight="6.5" markerUnits="userSpaceOnUse" orient="auto">'
            f'<path d="M0,0.6 L7.6,4 L0,7.4 Z" fill="{ACCENT}"/></marker>'
            f'<marker id="fd-arrow-muted" viewBox="0 0 8 8" refX="7.4" refY="4" markerWidth="6" '
            f'markerHeight="6" markerUnits="userSpaceOnUse" orient="auto">'
            f'<path d="M0,0.6 L7.6,4 L0,7.4 Z" fill="{MUTED}"/></marker>'
            "</defs>")
        bg = f'<rect width="100%" height="100%" fill="{PAPER}"/>'
        return head + meta + defs + bg + "".join(self.items) + "</svg>"


def _box_meta(kind, ident, x, y, w, h):
    return (f' data-fd="{kind}" data-fd-id="{_esc(ident)}" '
            f'data-fd-box="{_f(x)},{_f(y)},{_f(w)},{_f(h)}"')


def _poly(points, colour=INK, width=STROKE, dashed=False, arrow=True, marker=None, ident=""):
    d = "M" + " L".join(f"{_f(x)},{_f(y)}" for x, y in points)
    dash = ' stroke-dasharray="3,2.5"' if dashed else ""
    if arrow:
        m = marker or ("fd-arrow-accent" if colour == ACCENT else
                       "fd-arrow-muted" if colour == MUTED else "fd-arrow")
        mk = f' marker-end="url(#{m})"'
    else:
        mk = ""
    pts = " ".join(f"{_f(x)},{_f(y)}" for x, y in points)
    return (f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{_f(width)}" '
            f'stroke-linejoin="round"{dash}{mk} data-fd="edge" data-fd-id="{_esc(ident)}" '
            f'data-fd-points="{pts}"/>')


def _curve(points, colour=INK, width=STROKE, dashed=False, ident=""):
    """Smooth path through points (Catmull-Rom as cubic Beziers), arrow at the end."""
    if len(points) == 2:
        return _poly(points, colour, width, dashed, ident=ident)
    P = [points[0]] + points + [points[-1]]
    d = f"M{_f(P[1][0])},{_f(P[1][1])}"
    samples = [P[1]]
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f" C{_f(c1[0])},{_f(c1[1])} {_f(c2[0])},{_f(c2[1])} {_f(p2[0])},{_f(p2[1])}"
        for t in (0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0):
            u = 1 - t
            samples.append((u**3 * p1[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t**3 * p2[0],
                            u**3 * p1[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t**3 * p2[1]))
    dash = ' stroke-dasharray="3,2.5"' if dashed else ""
    m = "fd-arrow-accent" if colour == ACCENT else "fd-arrow-muted" if colour == MUTED else "fd-arrow"
    pts = " ".join(f"{_f(x)},{_f(y)}" for x, y in samples)
    return (f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{_f(width)}"{dash} '
            f'marker-end="url(#{m})" data-fd="edge" data-fd-id="{_esc(ident)}" data-fd-points="{pts}"/>')


def _clip_to_box(cx, cy, hw, hh, tx, ty, gap=2.0):
    """Point where the ray from a box centre toward (tx, ty) leaves the box (plus a gap)."""
    dx, dy = tx - cx, ty - cy
    if dx == 0 and dy == 0:
        return cx, cy
    t = min((hw + gap) / abs(dx) if dx else float("inf"), (hh + gap) / abs(dy) if dy else float("inf"))
    return cx + dx * t, cy + dy * t


def _shorten(points, by):
    """Pull the last point back so the arrowhead tip lands on the boundary."""
    (x1, y1), (x2, y2) = points[-2], points[-1]
    L = math.hypot(x2 - x1, y2 - y1)
    if L <= by:
        return points
    return points[:-1] + [(x2 - (x2 - x1) * by / L, y2 - (y2 - y1) * by / L)]


# ---------------------------------------------------------------------------
# Node shapes
# ---------------------------------------------------------------------------
_KINDS = {"process", "decision", "terminal", "data", "note", "plain"}


def _node_size(label, kind, max_w, size=SIZE_LABEL, style="regular"):
    pad_x, pad_y = (14, 7) if kind == "decision" else (9, 6)
    if kind in ("note", "plain"):
        pad_x, pad_y = 2, 2
    lines = wrap(label, max_w, size, style)
    tw = max(text_width(l, size, style) for l in lines)
    th = len(lines) * size * 1.22 - size * 0.22
    extra = 10 if kind == "data" else 0
    return lines, tw + 2 * pad_x + extra, th + 2 * pad_y, tw


def _draw_node(cv, n, x, y, w, h, lines, tw):
    kind = n.get("kind", "process")
    focal = bool(n.get("focal"))
    muted = bool(n.get("muted"))
    stroke = ACCENT if focal else (MUTED if muted else INK)
    sw = STROKE_FOCAL if focal else STROKE
    if focal:
        cv.accent_uses += 1
    style = "bold" if n.get("bold") else ("italic" if kind == "note" else "regular")
    tcol = TEXT_MUTED if (kind == "note" or muted) else (ACCENT if focal and n.get("accent_text") else INK)
    meta = _box_meta("node", n["id"], x, y, w, h)
    dash = ' stroke-dasharray="3,2.5"' if n.get("dashed") else ""
    common = f'fill="{PAPER}" stroke="{stroke}" stroke-width="{_f(sw)}"{dash}'
    if kind == "process":
        cv.add(f'<rect x="{_f(x)}" y="{_f(y)}" width="{_f(w)}" height="{_f(h)}" rx="2" {common}{meta}/>')
    elif kind == "terminal":
        cv.add(f'<rect x="{_f(x)}" y="{_f(y)}" width="{_f(w)}" height="{_f(h)}" rx="{_f(h/2)}" {common}{meta}/>')
    elif kind == "decision":
        k = min(10.0, h / 2)
        pts = [(x + k, y), (x + w - k, y), (x + w, y + h / 2), (x + w - k, y + h), (x + k, y + h), (x, y + h / 2)]
        cv.add(f'<polygon points="{" ".join(f"{_f(a)},{_f(b)}" for a, b in pts)}" {common}{meta}/>')
    elif kind == "data":
        k = 5.0
        pts = [(x + k, y), (x + w, y), (x + w - k, y + h), (x, y + h)]
        cv.add(f'<polygon points="{" ".join(f"{_f(a)},{_f(b)}" for a, b in pts)}" {common}{meta}/>')
    else:  # note / plain: no border, white knockout so lines pass cleanly
        cv.add(f'<rect x="{_f(x)}" y="{_f(y)}" width="{_f(w)}" height="{_f(h)}" fill="{PAPER}" stroke="none"{meta}/>')
    size = n.get("size", SIZE_SMALL if kind == "note" else SIZE_LABEL)
    th = len(lines) * size * 1.22 - size * 0.22
    cv.text_block(lines, x + w / 2, y + (h - th) / 2 - size * 0.02, size=size, style=style,
                  colour=tcol, maxw=w - 2)


# ---------------------------------------------------------------------------
# Layered layout (flowcharts, pipelines, DAGs)
# ---------------------------------------------------------------------------
def _isotonic(values, weights):
    """Pool-adjacent-violators: least-squares nondecreasing fit."""
    blocks = []  # [sum_wv, sum_w, count]
    for v, w in zip(values, weights):
        blocks.append([v * w, w, 1])
        while len(blocks) > 1 and blocks[-2][0] / blocks[-2][1] > blocks[-1][0] / blocks[-1][1]:
            b = blocks.pop()
            blocks[-1][0] += b[0]; blocks[-1][1] += b[1]; blocks[-1][2] += b[2]
    out = []
    for s, w, c in blocks:
        out.extend([s / w] * c)
    return out


def _crossings(order_a, order_b, edges_ab):
    pa = {v: i for i, v in enumerate(order_a)}
    pb = {v: i for i, v in enumerate(order_b)}
    es = [(pa[u], pb[v]) for u, v in edges_ab if u in pa and v in pb]
    c = 0
    for i in range(len(es)):
        for j in range(i + 1, len(es)):
            if (es[i][0] - es[j][0]) * (es[i][1] - es[j][1]) < 0:
                c += 1
    return c


def _layout_layers(spec, max_w=None, rank_gap=None, node_gap=18.0):
    direction = spec.get("direction", "TB").upper()
    if direction not in ("TB", "LR"):
        raise SpecError("direction must be 'TB' or 'LR'")
    nodes = spec.get("nodes") or []
    edges = spec.get("edges") or []
    if not nodes:
        raise SpecError("spec has no nodes")
    ids = [n.get("id") for n in nodes]
    if any(i is None or str(i) == "" for i in ids):
        raise SpecError("every node needs an 'id'")
    if len(set(ids)) != len(ids):
        dup = sorted({i for i in ids if ids.count(i) > 1})
        raise SpecError(f"duplicate node ids: {dup}")
    byid = {n["id"]: n for n in nodes}
    for n in nodes:
        n.setdefault("label", str(n["id"]))
        if n.get("kind", "process") not in _KINDS:
            raise SpecError(f"node {n['id']}: kind must be one of {sorted(_KINDS)}")
    E = []
    for e in edges:
        u, v = e.get("from"), e.get("to")
        if u not in byid or v not in byid:
            raise SpecError(f"edge {u} -> {v} references an unknown node")
        if u == v:
            raise SpecError(f"self-loop on {u}: describe repetition in the label instead")
        E.append(dict(e))

    # 1. Break cycles with a DFS in input order; back edges are drawn separately.
    succ = {i: [] for i in ids}
    for k, e in enumerate(E):
        succ[e["from"]].append((e["to"], k))
    state = {i: 0 for i in ids}
    back = set()

    def dfs(u):
        state[u] = 1
        for v, k in succ[u]:
            if state[v] == 1:
                back.add(k)
            elif state[v] == 0:
                dfs(v)
        state[u] = 2

    sys.setrecursionlimit(max(1000, 4 * len(ids) + 100))
    for i in ids:
        if state[i] == 0:
            dfs(i)
    fwd = [k for k in range(len(E)) if k not in back]

    # 2. Longest-path ranking, with optional same-rank pins.
    indeg = {i: 0 for i in ids}
    for k in fwd:
        indeg[E[k]["to"]] += 1
    queue = [i for i in ids if indeg[i] == 0]
    topo = []
    while queue:
        u = queue.pop(0)
        topo.append(u)
        for k in fwd:
            if E[k]["from"] == u:
                indeg[E[k]["to"]] -= 1
                if indeg[E[k]["to"]] == 0:
                    queue.append(E[k]["to"])
    rank = {i: 0 for i in ids}
    for u in topo:
        for k in fwd:
            if E[k]["from"] == u:
                v = E[k]["to"]
                rank[v] = max(rank[v], rank[u] + 1)
    for n in nodes:
        if "rank" in n:
            rank[n["id"]] = max(rank[n["id"]], int(n["rank"]))
    for u in topo:  # re-propagate after pins
        for k in fwd:
            if E[k]["from"] == u:
                v = E[k]["to"]
                rank[v] = max(rank[v], rank[u] + 1)

    # 3. Sizes.
    if max_w is None:
        max_w = 120.0 if direction == "TB" else 92.0
    info = {}
    for n in nodes:
        style = "bold" if n.get("bold") else ("italic" if n.get("kind") == "note" else "regular")
        size = n.get("size", SIZE_SMALL if n.get("kind") == "note" else SIZE_LABEL)
        lines, w, h, tw = _node_size(n["label"], n.get("kind", "process"),
                                     n.get("max_width", max_w), size, style)
        info[n["id"]] = dict(lines=lines, w=w, h=h, tw=tw)

    def osz(v):  # size along the order axis
        if v.startswith("\u0000d"):
            return 0.0
        return info[v]["w"] if direction == "TB" else info[v]["h"]

    def rsz(v):  # size along the rank axis
        if v.startswith("\u0000d"):
            return 0.0
        return info[v]["h"] if direction == "TB" else info[v]["w"]

    # 4. Dummy nodes for long edges.
    nlayers = max(rank.values()) + 1
    layers = [[] for _ in range(nlayers)]
    for i in ids:
        layers[rank[i]].append(i)
    chains = {}
    links = []  # (a, b) between adjacent layers
    dcount = 0
    for k in fwd:
        u, v = E[k]["from"], E[k]["to"]
        chain = [u]
        for r in range(rank[u] + 1, rank[v]):
            d = f"\u0000d{dcount}"
            dcount += 1
            rank[d] = r
            layers[r].append(d)
            chain.append(d)
        chain.append(v)
        chains[k] = chain
        for a, b in zip(chain, chain[1:]):
            links.append((a, b))

    # 5. Ordering: barycentre sweeps, keep the arrangement with fewest crossings.
    def total_cross(lys):
        return sum(_crossings(lys[r], lys[r + 1], [(a, b) for a, b in links if rank[a] == r])
                   for r in range(len(lys) - 1))

    pred = {}
    sucs = {}
    for a, b in links:
        sucs.setdefault(a, []).append(b)
        pred.setdefault(b, []).append(a)
    best = [list(l) for l in layers]
    best_c = total_cross(best)
    cur = [list(l) for l in layers]
    for it in range(12):
        rng = range(1, nlayers) if it % 2 == 0 else range(nlayers - 2, -1, -1)
        for r in rng:
            ref = cur[r - 1] if it % 2 == 0 else cur[r + 1]
            pos = {v: i for i, v in enumerate(ref)}
            nb = pred if it % 2 == 0 else sucs

            def key(v, i0):
                ps = [pos[p] for p in nb.get(v, []) if p in pos]
                return (sum(ps) / len(ps)) if ps else i0
            cur[r] = [v for _, v in sorted(((key(v, i), v) for i, v in enumerate(cur[r])),
                                           key=lambda t: t[0])]
        c = total_cross(cur)
        if c < best_c:
            best, best_c = [list(l) for l in cur], c
    layers = best

    # keep groups contiguous inside each layer
    def grp(v):
        return None if v.startswith("\u0000d") else byid[v].get("group")
    for r in range(nlayers):
        seen = []
        for v in layers[r]:
            g = grp(v)
            if g is not None and g not in seen:
                seen.append(g)
        if seen:
            first = {}
            for i, v in enumerate(layers[r]):
                g = grp(v)
                if g is not None and g not in first:
                    first[g] = i
            layers[r] = sorted(layers[r], key=lambda v: (first.get(grp(v), layers[r].index(v)),
                                                         layers[r].index(v)))

    # 6. Order-axis coordinates: centre on neighbours, then isotonic fit.
    gap_d = 8.0
    pos = {}
    for r in range(nlayers):
        p = 0.0
        for i, v in enumerate(layers[r]):
            if i:
                prev = layers[r][i - 1]
                g = node_gap if not (prev.startswith("\u0000d") or v.startswith("\u0000d")) else gap_d
                if grp(prev) != grp(v) and grp(prev) is not None and grp(v) is not None:
                    g += 14.0
                p += osz(prev) / 2 + g + osz(v) / 2
            pos[v] = p
    width_of = lambda r: (pos[layers[r][-1]] + osz(layers[r][-1]) / 2) - (pos[layers[r][0]] - osz(layers[r][0]) / 2)
    widest = max(width_of(r) for r in range(nlayers))
    for r in range(nlayers):  # centre each layer
        off = (widest - width_of(r)) / 2 - (pos[layers[r][0]] - osz(layers[r][0]) / 2)
        for v in layers[r]:
            pos[v] += off

    def place(r, nbmap):
        L = layers[r]
        if not L:
            return
        offs = [0.0]
        for i in range(1, len(L)):
            g = node_gap if not (L[i - 1].startswith("\u0000d") or L[i].startswith("\u0000d")) else gap_d
            if grp(L[i - 1]) != grp(L[i]) and grp(L[i - 1]) is not None and grp(L[i]) is not None:
                g += 14.0
            offs.append(offs[-1] + osz(L[i - 1]) / 2 + g + osz(L[i]) / 2)
        desired, wts = [], []
        for i, v in enumerate(L):
            ns = [pos[u] for u in nbmap.get(v, [])]
            desired.append((sum(ns) / len(ns) if ns else pos[v]) - offs[i])
            wts.append(len(ns) + (0.4 if not ns else 0.0) + (2.0 if v.startswith("\u0000d") else 0.0))
        fit = _isotonic(desired, wts)
        for i, v in enumerate(L):
            pos[v] = fit[i] + offs[i]

    for _ in range(6):
        for r in range(1, nlayers):
            place(r, pred)
        for r in range(nlayers - 2, -1, -1):
            place(r, sucs)
    minp = min(pos[v] - osz(v) / 2 for r in range(nlayers) for v in layers[r])
    for v in pos:
        pos[v] -= minp

    # 7. Rank-axis coordinates.
    has_labels = any(e.get("label") for e in E)
    if rank_gap is None:
        rank_gap = (40.0 if has_labels else 30.0) if direction == "TB" else (40.0 if has_labels else 30.0)
    tracks_needed = []
    for r in range(nlayers - 1):
        srcs = {a for a, b in links if rank[a] == r and abs(pos[a] - pos[b]) > 0.5}
        tracks_needed.append(len(srcs))
    rstart, rext = [], []
    acc = 0.0
    for r in range(nlayers):
        ext = max([rsz(v) for v in layers[r]] + [0.0])
        rstart.append(acc)
        rext.append(ext)
        if r < nlayers - 1:
            acc += ext + rank_gap + max(0, tracks_needed[r] - 2) * 5.0
    return dict(direction=direction, nodes=nodes, byid=byid, E=E, back=back, fwd=fwd,
                chains=chains, rank=rank, layers=layers, pos=pos, info=info, rstart=rstart,
                rext=rext, osz=osz, rsz=rsz, rank_gap=rank_gap, grp=grp)


def _render_layered(spec, cv, origin=(0.0, 0.0), dag_roles=False):
    L = _layout_layers(spec, max_w=spec.get("max_width"), rank_gap=spec.get("rank_gap"),
                       node_gap=spec.get("node_gap", 18.0))
    tb = L["direction"] == "TB"
    ox, oy = origin
    rank, pos, info, rstart, rext = L["rank"], L["pos"], L["info"], L["rstart"], L["rext"]

    def xy(o, r):  # abstract (order, rank) -> canvas (x, y)
        return (ox + o, oy + r) if tb else (ox + r, oy + o)

    # node boxes (centred on the layer band along the rank axis)
    boxes = {}
    for v, n in L["byid"].items():
        r = rank[v]
        o = pos[v]
        rs = rstart[r] + (rext[r] - L["rsz"](v)) / 2
        if tb:
            x, y = ox + o - info[v]["w"] / 2, oy + rs
        else:
            x, y = ox + rs, oy + o - info[v]["h"] / 2
        boxes[v] = (x, y, info[v]["w"], info[v]["h"])

    # groups drawn first, behind everything
    groups = {}
    for v, n in L["byid"].items():
        if n.get("group") is not None:
            groups.setdefault(n["group"], []).append(v)
    # TB: label at the frame's bottom-left (edges enter at the top);
    # LR: label at the top-left (edges enter at the left).
    for g, members in groups.items():
        x0 = min(boxes[m][0] for m in members) - 8
        y0 = min(boxes[m][1] for m in members) - (8 if tb else 17)
        x1 = max(boxes[m][0] + boxes[m][2] for m in members) + 8
        y1 = max(boxes[m][1] + boxes[m][3] for m in members) + (17 if tb else 8)
        cv.add(f'<rect x="{_f(x0)}" y="{_f(y0)}" width="{_f(x1-x0)}" height="{_f(y1-y0)}" rx="3" '
               f'fill="none" stroke="{MUTED}" stroke-width="0.6" stroke-dasharray="2,2"'
               f'{_box_meta("group", g, x0, y0, x1-x0, y1-y0)}/>')
        lw = text_width(str(g), SIZE_SMALL, "italic")
        ly = (y1 - 4 - SIZE_SMALL) if tb else (y0 + 3.5)
        cv.add(f'<rect x="{_f(x0+4)}" y="{_f(ly-0.5)}" width="{_f(lw+2)}" height="{_f(SIZE_SMALL+1)}" '
               f'fill="none"{_box_meta("label", "group:" + str(g), x0 + 5, ly, lw, SIZE_SMALL)}/>')
        cv.text_block([str(g)], x0 + 5, ly, size=SIZE_SMALL, style="italic",
                      colour=TEXT_MUTED, anchor="start")

    # edges
    E = L["E"]
    # tracks: horizontal runs in each gap, one per source node
    track_of = {}
    for r in range(len(L["layers"]) - 1):
        srcs = []
        for k in L["fwd"]:
            ch = L["chains"][k]
            for a, b in zip(ch, ch[1:]):
                if rank[a] == r and abs(pos[a] - pos[b]) > 0.5 and a not in srcs:
                    srcs.append(a)
        srcs.sort(key=lambda a: pos[a])
        for i, a in enumerate(srcs):
            track_of[(r, a)] = (i, len(srcs))

    label_jobs = []
    curved = dag_roles or spec.get("edge_style") == "curved"
    for k in L["fwd"]:
        e = E[k]
        ch = L["chains"][k]
        hi = bool(e.get("focal")) or (dag_roles and e.get("_causal"))
        colour = ACCENT if hi else (MUTED if e.get("muted") else INK)
        if curved:
            cen = [(pos[v], rstart[rank[v]] + rext[rank[v]] / 2) for v in ch]
            a, b = ch[0], ch[-1]
            plain_a = L["byid"][a].get("kind") in ("plain", "note")
            plain_b = L["byid"][b].get("kind") in ("plain", "note")
            s = _clip_to_box(cen[0][0], cen[0][1], L["osz"](a) / 2, L["rsz"](a) / 2,
                             cen[1][0], cen[1][1], gap=3.0 if plain_a else 0.5)
            t = _clip_to_box(cen[-1][0], cen[-1][1], L["osz"](b) / 2, L["rsz"](b) / 2,
                             cen[-2][0], cen[-2][1], gap=3.0 if plain_b else 0.6)
            abs_pts = [s] + cen[1:-1] + [t]
            canvas_pts = [xy(o, r) for o, r in abs_pts]
            cv.add(_curve(canvas_pts, colour=colour, width=STROKE_FOCAL if hi else STROKE,
                          dashed=bool(e.get("dashed")), ident=f'{e["from"]}->{e["to"]}'))
            if e.get("label"):
                (o1, r1), (o2, r2) = abs_pts[-2], abs_pts[-1]
                side = -1 if pos[ch[-1]] < pos[ch[0]] - 0.5 else 1
                label_jobs.append((e["label"], (o1 + o2) / 2, (r1 + r2) / 2, f'{e["from"]}->{e["to"]}', side))
            continue
        if hi:
            cv.accent_uses += 0  # counted once per diagram below
        pts = []
        for i, (a, b) in enumerate(zip(ch, ch[1:])):
            ra = rank[a]
            a_end = rstart[ra] + (rext[ra] + L["rsz"](a)) / 2 if not a.startswith("\u0000d") else rstart[ra] + rext[ra]
            b_beg = rstart[rank[b]] + (rext[rank[b]] - L["rsz"](b)) / 2 if not b.startswith("\u0000d") else rstart[rank[b]]
            if a.startswith("\u0000d"):
                a_end = rstart[ra] + rext[ra]
            gap0 = rstart[ra] + rext[ra]
            gap1 = rstart[rank[b]]
            if i == 0:
                pts.append((pos[a], a_end))
            else:
                pts.append((pos[a], rstart[ra]))  # pass straight through dummy band
                pts.append((pos[a], gap0))
            if abs(pos[a] - pos[b]) > 0.5:
                t, T = track_of.get((ra, a), (0, 1))
                rm = gap0 + (gap1 - gap0) * (t + 1) / (T + 1)
                pts.append((pos[a], rm))
                pts.append((pos[b], rm))
            pts.append((pos[b], b_beg))
        # collapse duplicate points
        clean = [pts[0]]
        for p in pts[1:]:
            if abs(p[0] - clean[-1][0]) > 0.01 or abs(p[1] - clean[-1][1]) > 0.01:
                clean.append(p)
        canvas_pts = [xy(o, r) for o, r in clean]
        canvas_pts = _shorten(canvas_pts, 0.6)
        cv.add(_poly(canvas_pts, colour=colour,
                     width=STROKE_FOCAL if hi else STROKE,
                     dashed=bool(e.get("dashed")), ident=f'{e["from"]}->{e["to"]}'))
        if e.get("label"):
            (o1, r1), (o2, r2) = clean[-2], clean[-1]
            side = -1 if pos[ch[-1]] < pos[ch[0]] - 0.5 else 1
            label_jobs.append((e["label"], (o1 + o2) / 2, (r1 + r2) / 2, f'{e["from"]}->{e["to"]}', side))

    # back edges: routed around the right (TB) or bottom (LR) side
    extent_o = max(pos[v] + L["osz"](v) / 2 for v in pos)
    for j, k in enumerate(sorted(L["back"])):
        e = E[k]
        u, v = e["from"], e["to"]
        lane = extent_o + 14 + 9 * j
        ru = rstart[rank[u]] + rext[rank[u]] / 2
        rv = rstart[rank[v]] + rext[rank[v]] / 2
        ou = pos[u] + L["osz"](u) / 2
        ovv = pos[v] + L["osz"](v) / 2
        pts = [(ou, ru), (lane, ru), (lane, rv), (ovv, rv)]
        canvas_pts = _shorten([xy(o, r) for o, r in pts], 0.6)
        cv.add(_poly(canvas_pts, colour=MUTED if not e.get("focal") else ACCENT,
                     dashed=e.get("dashed", True), ident=f"{u}->{v}"))
        if e.get("label"):
            label_jobs.append((e["label"], lane, (ru + rv) / 2, f"{u}->{v}", 1))

    # nodes on top of edges
    for v, n in L["byid"].items():
        x, y, w, h = boxes[v]
        _draw_node(cv, n, x, y, w, h, info[v]["lines"], info[v]["tw"])
        cv.boxes.append(("node", v, x, y, w, h))

    # edge labels with white knockout
    for text, o, r, ident, side in label_jobs:
        tw = text_width(text, SIZE_SMALL, "italic")
        th = SIZE_SMALL * 1.05
        # the label sits on the side of the line facing away from the branch point
        if tb:
            x, y = (ox + o + 4 if side > 0 else ox + o - 4 - tw), oy + r - th / 2
        else:
            x, y = ox + r - tw / 2, (oy + o + 3 if side > 0 else oy + o - 3 - th)
        cv.add(f'<rect x="{_f(x-1.5)}" y="{_f(y-0.5)}" width="{_f(tw+3)}" height="{_f(th+1)}" '
               f'fill="{PAPER}"{_box_meta("label", ident, x, y, tw, th)}/>')
        cv.text_block([text], x, y, size=SIZE_SMALL, style="italic", colour=TEXT_MUTED, anchor="start")
        cv.boxes.append(("label", ident, x, y, tw, th))

    if any(E[k].get("focal") for k in range(len(E))) or (dag_roles and any(E[k].get("_causal") for k in range(len(E)))):
        cv.accent_uses += 1
    max_x = max(b[0] + b[2] for b in boxes.values())
    max_y = max(b[1] + b[3] for b in boxes.values())
    for g, members in groups.items():
        max_x = max(max_x, max(boxes[m][0] + boxes[m][2] for m in members) + 8)
        max_y = max(max_y, max(boxes[m][1] + boxes[m][3] for m in members) + (17 if tb else 8))
    if L["back"]:
        lane_max = extent_o + 14 + 9 * (len(L["back"]) - 1) + 4
        if tb:
            max_x = max(max_x, ox + lane_max)
        else:
            max_y = max(max_y, oy + lane_max)
    for text, o, r, ident, side in label_jobs:
        tw = text_width(text, SIZE_SMALL, "italic")
        if tb:
            max_x = max(max_x, ox + o + 4 + tw + 2)
        else:
            max_y = max(max_y, oy + o + 3 + SIZE_SMALL * 1.1)
    return max_x, max_y


# ---------------------------------------------------------------------------
# Public renderers
# ---------------------------------------------------------------------------
M = 12.0  # outer margin, pt


def _finish(cv, spec, w, h, warnings):
    title = spec.get("title")
    svg = cv.svg(w, h, title=spec.get("alt") or title, desc=spec.get("desc"))
    if cv.accent_uses > MAX_ACCENTS:
        warnings.append(f"Accent used on {cv.accent_uses} elements: keep it to {MAX_ACCENTS} focal elements so it still signals.")
    return svg, warnings


def _title_block(cv, spec, y):
    if spec.get("title"):
        lines = wrap(spec["title"], spec.get("_width_hint", COLUMN_PT) - 2 * M, SIZE_TITLE)
        cv.add(f'<g data-fd="title">')
        hgt = cv.text_block(lines, M, y, size=SIZE_TITLE, anchor="start")
        cv.add("</g>")
        return y + hgt + 8
    return y


def render_flow(spec: dict) -> tuple[str, list[str]]:
    """Flowcharts, analysis pipelines, decision trees, hierarchies."""
    warnings: list[str] = []
    cv = _Canvas()
    top = _title_block(cv, spec, M)
    if len(spec.get("nodes", [])) > 12:
        warnings.append(f"{len(spec['nodes'])} nodes: above about 9 to 12 a diagram usually reads better as two.")
    grouped = any(n.get("group") is not None for n in spec["nodes"])
    lr = spec.get("direction", "TB").upper() == "LR"
    gx, gy = (8.0, 18.0 if lr else 9.0) if grouped else (0.0, 0.0)   # room for group frames and labels
    mx, my = _render_layered(spec, cv, origin=(M + gx, top + gy))
    w, h = mx + M, my + M
    if w > COLUMN_PT * 1.15:
        warnings.append(f"Figure is {w:.0f} pt wide (column is {COLUMN_PT:.0f} pt): use direction 'TB', "
                        "shorter labels, or keep it for slides only.")
    return _finish(cv, spec, w, h, warnings)


_ROLES = {"exposure", "outcome", "confounder", "mediator", "collider", "instrument",
          "precision", "unmeasured", "other"}


def dag_checks(spec: dict) -> list[str]:
    """Causal-structure checks: acyclicity and adjustment-set warnings."""
    nodes = spec.get("nodes") or []
    byid = {n["id"]: n for n in nodes}
    succ = {i: [] for i in byid}
    for e in spec.get("edges") or []:
        if e["from"] not in byid or e["to"] not in byid:
            raise SpecError(f"edge {e['from']} -> {e['to']} references an unknown node")
        succ[e["from"]].append(e["to"])
    # acyclic?
    state = {i: 0 for i in byid}

    def dfs(u, stack):
        state[u] = 1
        for v in succ[u]:
            if state[v] == 1:
                raise SpecError("causal DAG has a cycle: " + " -> ".join(stack + [u, v]))
            if state[v] == 0:
                dfs(v, stack + [u])
        state[u] = 2
    for i in byid:
        if state[i] == 0:
            dfs(i, [])

    def descendants(s):
        out, todo = set(), [s]
        while todo:
            u = todo.pop()
            for v in succ[u]:
                if v not in out:
                    out.add(v); todo.append(v)
        return out
    parents = {i: [] for i in byid}
    for u in byid:
        for v in succ[u]:
            parents[v].append(u)
    expo = [i for i, n in byid.items() if n.get("role") == "exposure"]
    outc = [i for i, n in byid.items() if n.get("role") == "outcome"]
    notes = []
    if len(expo) != 1 or len(outc) != 1:
        raise SpecError("a causal DAG needs exactly one node with role 'exposure' and one with role 'outcome'")
    x, y = expo[0], outc[0]
    dx = descendants(x)
    if y not in dx:
        notes.append(f"No directed path from {x} to {y}: the diagram assumes no causal effect. Check that this is intended.")
    for i, n in byid.items():
        if n.get("role") not in (None,) and n.get("role") not in _ROLES:
            raise SpecError(f"node {i}: role must be one of {sorted(_ROLES)}")
        if n.get("adjusted") and i in dx:
            notes.append(f"{i} is adjusted for but is a descendant of the exposure {x} (mediator or collider path): this can block the effect or induce bias.")
        if n.get("adjusted") and len(parents[i]) >= 2 and i not in dx and \
                not (i in _ancestors(x, parents) or i in _ancestors(y, parents)):
            notes.append(f"{i} is adjusted for and is a collider that is not an ancestor of {x} or {y}: conditioning on it can open a non-causal path (M-bias).")
        if n.get("adjusted") and n.get("role") == "instrument":
            notes.append(f"{i} is an instrument: adjusting for it can amplify bias and reduces precision.")
        if n.get("role") == "unmeasured" and n.get("adjusted"):
            raise SpecError(f"{i} is marked unmeasured, so it cannot be adjusted for")
    # Formal check of the drawn adjustment set (backdoor criterion)
    adj = [i for i, n in byid.items() if n.get("adjusted")]
    sets = adjustment_sets(spec)
    fmt = lambda s: "{" + ", ".join(s) + "}" if s else "{} (no adjustment needed)"
    if sets is not None:
        if not sets:
            notes.append(f"No set of measured variables closes every backdoor path from {x} to {y}: "
                         "the effect is not identified by adjustment (unmeasured confounding).")
        elif not backdoor_ok(spec, adj):
            notes.append(f"The adjusted set {fmt(adj)} does not satisfy the backdoor criterion. "
                         "Minimal sufficient sets: " + "; ".join(fmt(s) for s in sets[:4]) + ".")
    return notes


def _ancestors(s, parents):
    out, todo = set(), [s]
    while todo:
        u = todo.pop()
        for p in parents[u]:
            if p not in out:
                out.add(p); todo.append(p)
    return out


# --- Formal adjustment-set analysis (backdoor criterion) --------------------
def _d_separated(nodes, parents, xs, ys, zs):
    """True if xs and ys are d-separated given zs (moralised ancestral graph)."""
    keep = set(xs) | set(ys) | set(zs)
    todo = list(keep)
    while todo:
        u = todo.pop()
        for p in parents[u]:
            if p not in keep:
                keep.add(p); todo.append(p)
    adj = {v: set() for v in keep}
    for v in keep:
        ps = [p for p in parents[v] if p in keep]
        for p in ps:
            adj[v].add(p); adj[p].add(v)
        for i in range(len(ps)):          # marry parents of a common child
            for j in range(i + 1, len(ps)):
                adj[ps[i]].add(ps[j]); adj[ps[j]].add(ps[i])
    seen, todo = set(xs), list(xs)
    while todo:
        u = todo.pop()
        for v in adj[u]:
            if v in zs or v in seen:
                continue
            if v in ys:
                return False
            seen.add(v); todo.append(v)
    return True


def _dag_graph(spec):
    nodes = [n["id"] for n in spec["nodes"]]
    parents = {i: [] for i in nodes}
    children = {i: [] for i in nodes}
    for e in spec["edges"]:
        parents[e["to"]].append(e["from"]); children[e["from"]].append(e["to"])
    return nodes, parents, children


def backdoor_ok(spec: dict, adjusted) -> bool:
    """Backdoor criterion: no adjusted variable descends from the exposure, and the
    set blocks every backdoor path (d-separation after removing the exposure's
    outgoing edges)."""
    nodes, parents, children = _dag_graph(spec)
    x = next(n["id"] for n in spec["nodes"] if n.get("role") == "exposure")
    y = next(n["id"] for n in spec["nodes"] if n.get("role") == "outcome")
    desc, todo = set(), [x]
    while todo:
        u = todo.pop()
        for v in children[u]:
            if v not in desc:
                desc.add(v); todo.append(v)
    z = set(adjusted)
    if z & desc or x in z or y in z:
        return False
    cut = {v: [p for p in parents[v] if p != x] for v in nodes}   # drop X -> *
    return _d_separated(nodes, cut, {x}, {y}, z)


def adjustment_sets(spec: dict, limit: int = 18) -> list[list[str]] | None:
    """All minimal sufficient adjustment sets of measured variables (backdoor
    criterion), smallest first. None when the graph is too large to enumerate."""
    from itertools import combinations
    nodes, parents, children = _dag_graph(spec)
    x = next(n["id"] for n in spec["nodes"] if n.get("role") == "exposure")
    y = next(n["id"] for n in spec["nodes"] if n.get("role") == "outcome")
    desc, todo = set(), [x]
    while todo:
        u = todo.pop()
        for v in children[u]:
            if v not in desc:
                desc.add(v); todo.append(v)
    cand = [n["id"] for n in spec["nodes"] if n["id"] not in (x, y) and n["id"] not in desc
            and n.get("role") != "unmeasured"]
    if len(cand) > limit:
        return None
    found: list[set] = []
    for k in range(len(cand) + 1):
        for combo in combinations(cand, k):
            s = set(combo)
            if any(f <= s for f in found):
                continue
            if backdoor_ok(spec, s):
                found.append(s)
    order = {c: i for i, c in enumerate(cand)}
    return [sorted(f, key=order.get) for f in found]


def to_dagitty(spec: dict) -> str:
    """The DAG as a dagitty model string (paste into dagitty.net or dagitty::dagitty())."""
    def name(i):
        s = re.sub(r"[^A-Za-z0-9_.]", "_", str(i))
        return s if re.match(r"[A-Za-z_]", s) else "v_" + s
    lines = ["dag {"]
    for n in spec["nodes"]:
        tags = []
        if n.get("role") == "exposure":
            tags.append("exposure")
        if n.get("role") == "outcome":
            tags.append("outcome")
        if n.get("role") == "unmeasured":
            tags.append("latent")
        if n.get("adjusted"):
            tags.append("adjusted")
        lines.append(f"  {name(n['id'])}" + (f" [{','.join(tags)}]" if tags else ""))
    for e in spec["edges"]:
        lines.append(f"  {name(e['from'])} -> {name(e['to'])}")
    lines.append("}")
    return "\n".join(lines)


def render_dag(spec: dict) -> tuple[str, list[str]]:
    """Causal directed acyclic graph with exposure, outcome and adjustment set."""
    spec = json.loads(json.dumps(spec))  # private copy
    notes = dag_checks(spec)
    spec.setdefault("direction", "LR")
    for n in spec["nodes"]:
        role = n.get("role", "other")
        n.setdefault("kind", "process" if n.get("adjusted") else "plain")
        if role in ("exposure", "outcome"):
            n["bold"] = True
        if role == "outcome":
            n["focal"] = True
            if n["kind"] == "plain":
                n["kind"] = "process"
        if role == "unmeasured":
            n["muted"] = True
            n["label"] = n.get("label", n["id"])
            n["italic"] = True
    expo = next(n["id"] for n in spec["nodes"] if n.get("role") == "exposure")
    outc = next(n["id"] for n in spec["nodes"] if n.get("role") == "outcome")
    for e in spec["edges"]:
        src = next(n for n in spec["nodes"] if n["id"] == e["from"])
        if src.get("role") == "unmeasured":
            e["dashed"] = True
            e["muted"] = True
    # highlight the direct causal path exposure -> outcome if drawn
    for e in spec["edges"]:
        if e["from"] == expo and e["to"] == outc:
            e["_causal"] = True
    cv = _Canvas()
    spec.setdefault("rank_gap", 44.0)
    spec.setdefault("node_gap", 22.0)
    top = _title_block(cv, spec, M)
    mx, my = _render_layered(spec, cv, origin=(M, top), dag_roles=True)
    adj = [n.get("label", n["id"]) for n in spec["nodes"] if n.get("adjusted")]
    key = "Boxed: adjusted for" + (f" ({', '.join(adj)})" if adj else " (none)") + \
          ". Dashed: unmeasured. Blue: outcome and the effect of interest."
    lines = wrap(key, max(mx - M, 220), SIZE_SMALL)
    cv.text_block(lines, M, my + 10, size=SIZE_SMALL, colour=TEXT_MUTED, anchor="start")
    h = my + 10 + len(lines) * SIZE_SMALL * 1.22 + M
    w = max(mx, M + max(text_width(l, SIZE_SMALL) for l in lines)) + M
    return _finish(cv, spec, w, h, notes)


# ---------------------------------------------------------------------------
# Participant flow: CONSORT (trials) and cohort selection (observational)
# ---------------------------------------------------------------------------
def _count(v, where):
    """A non-negative whole number; accepts 33.0 (how R passes numbers)."""
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0 or v != int(v):
        raise SpecError(f"{where}: count must be a non-negative whole number, got {v!r}")
    return int(v)


def _sum_reasons(items, where):
    tot = 0
    for it in items or []:
        if not (isinstance(it, (list, tuple)) and len(it) == 2):
            raise SpecError(f"{where}: reasons must be [label, n] pairs")
        n = _count(it[1], f"{where} '{it[0]}'")
        tot += n
    return tot


def _sub(text, wrap_w, level=1):
    """Detail lines. Level 1: '· text' with tab-marked continuations.
    Level 2: double-tab lines, indented one step further."""
    if level == 2:
        return ["\t\t" + s for s in wrap(text, wrap_w - 24, SIZE_SMALL)]
    parts = wrap(text, wrap_w - 10, SIZE_SMALL)
    return [("\t" if i else "· ") + s for i, s in enumerate(parts)]


def _reason_lines(head, items, wrap_w):
    lines = wrap(head, wrap_w, SIZE_LABEL)
    for lab, n in items or []:
        lines += _sub(f"{lab} {_cnt(n)}", wrap_w)
    return lines


def _is_small(ln):
    return ln.startswith("· ") or ln.startswith("\t")


def _indent(ln):
    """(x offset, text) for a box line with indentation markers."""
    bullet = text_width("· ", SIZE_SMALL)
    if ln.startswith("\t\t"):
        return 2 + bullet + 8, ln[2:]
    if ln.startswith("\t"):
        return 2 + bullet, ln[1:]
    if ln.startswith("· "):
        return 2, ln
    return 0, ln


def _flow_box(cv, ident, x, y, w, lines, focal=False, align="start", min_h=0.0):
    """Box whose plain lines are statements (10 pt) and indented lines are details (8.5 pt)."""
    pad = 6.0
    heights = [(SIZE_SMALL if _is_small(ln) else SIZE_LABEL) * 1.22 for ln in lines]
    h = max(sum(heights) - SIZE_LABEL * 0.22 + 2 * pad, min_h)
    stroke = ACCENT if focal else INK
    if focal:
        cv.accent_uses += 1
    cv.add(f'<rect x="{_f(x)}" y="{_f(y)}" width="{_f(w)}" height="{_f(h)}" rx="2" fill="{PAPER}" '
           f'stroke="{stroke}" stroke-width="{_f(STROKE_FOCAL if focal else STROKE)}"'
           f'{_box_meta("node", ident, x, y, w, h)}/>')
    cy = y + pad
    for ln, lh in zip(lines, heights):
        small = _is_small(ln)
        size = SIZE_SMALL if small else SIZE_LABEL
        dx, txt = _indent(ln)
        tx = x + pad + dx if align == "start" else x + w / 2
        cv.text_block([txt], tx, cy, size=size, colour=TEXT_MUTED if small else INK,
                      anchor=align, maxw=w - 2 * pad - dx)
        cy += lh
    cv.boxes.append(("node", ident, x, y, w, h))
    return h


def _box_height(lines):
    hs = [(SIZE_SMALL if _is_small(l) else SIZE_LABEL) * 1.22 for l in lines]
    return sum(hs) - SIZE_LABEL * 0.22 + 12.0


def _stage_label(cv, text, y, x_rule0, x_rule1):
    """Stage name (Enrollment, Allocation, ...) in the left margin, level with the box top."""
    cv.text_block([text], x_rule0, y + 2, size=SIZE_SMALL, style="italic",
                  colour=TEXT_MUTED, anchor="start")


def consort_checks(spec: dict) -> list[str]:
    """Arithmetic checks for a CONSORT 2010 flow. Raises SpecError on contradictions."""
    for key in ("assessed", "randomized", "arms"):
        if key not in spec:
            raise SpecError(f"CONSORT spec needs '{key}'")
    a, r = spec["assessed"], spec["randomized"]
    ex = spec.get("excluded", {})
    ex_total = ex.get("total", a - r)
    rs = _sum_reasons(ex.get("reasons"), "excluded")
    if a - ex_total != r:
        raise SpecError(f"assessed ({a}) minus excluded ({ex_total}) = {a-ex_total}, but randomized = {r}")
    if ex.get("reasons") and rs != ex_total:
        raise SpecError(f"exclusion reasons sum to {rs}, but excluded total is {ex_total}")
    alloc = sum(arm["allocated"] for arm in spec["arms"])
    if alloc != r:
        raise SpecError(f"arms are allocated {alloc} in total, but randomized = {r}")
    notes = []
    small = []
    for arm in spec["arms"]:
        nm, al = arm.get("name", "?"), arm["allocated"]
        if "received" in arm:
            nr = _sum_reasons(arm.get("not_received"), f"{nm} not_received")
            if arm["received"] + nr != al:
                raise SpecError(f"{nm}: received ({arm['received']}) + did not receive ({nr}) != allocated ({al})")
        lost = _sum_reasons(arm.get("lost"), f"{nm} lost")
        disc = _sum_reasons(arm.get("discontinued"), f"{nm} discontinued")
        if lost + disc > al:
            raise SpecError(f"{nm}: lost ({lost}) + discontinued ({disc}) exceed allocated ({al})")
        exa = _sum_reasons(arm.get("excluded_analysis"), f"{nm} excluded_analysis")
        if "analysed" not in arm:
            raise SpecError(f"{nm}: 'analysed' count is required")
        if arm["analysed"] + exa != al:
            raise SpecError(f"{nm}: analysed ({arm['analysed']}) + excluded from analysis ({exa}) != allocated ({al})")
        if arm["analysed"] < al - lost - disc - exa and not arm.get("imputed"):
            notes.append(f"{nm}: analysed is below allocated minus losses; state how missing outcomes were handled.")
        for k in ("allocated", "received", "analysed"):
            if k in arm and 0 < arm[k] < 11:
                small.append(f"{nm} {k} = {arm[k]}")
    if small and spec.get("clinical", True):
        notes.append("Counts below 11 (" + "; ".join(small) + "): check your data use agreement on small-cell suppression before sharing.")
    return notes


def render_consort(spec: dict) -> tuple[str, list[str]]:
    notes = consort_checks(spec)
    cv = _Canvas()
    arms = spec["arms"]
    k = len(arms)
    col_w = spec.get("box_width", 140.0 if k <= 2 else 118.0)
    gutter = 16.0
    left = M + 52.0  # room for stage labels
    total_w = k * col_w + (k - 1) * gutter
    side_w = spec.get("side_width", 150.0)
    width = max(left + total_w + M, left + total_w / 2 + col_w / 2 + 24 + side_w + M)
    if width > COLUMN_PT + 1:
        notes = notes + [f"Figure is {width:.0f} pt wide, wider than a {COLUMN_PT:.0f} pt column: shorten labels or set box_width."]
    cx = left + total_w / 2
    y = _title_block(cv, dict(spec, _width_hint=width), M)
    ex = spec.get("excluded", {})
    ex_total = ex.get("total", spec["assessed"] - spec["randomized"])

    # enrollment
    _stage_label(cv, "Enrollment", y + 4, M, M + 50)
    l1 = wrap(f"Assessed for eligibility {_cnt(spec['assessed'])}", col_w - 12, SIZE_LABEL)
    h1 = _box_height(l1)
    b1x = cx - col_w / 2
    _flow_box(cv, "assessed", b1x, y, col_w, l1, align="middle")
    y_ex = y + h1 + 14
    lex = _reason_lines(f"Excluded {_cnt(ex_total)}", ex.get("reasons"), side_w - 12)
    hex_ = _box_height(lex)
    sx = cx + col_w / 2 + 24
    y_r = y_ex + hex_ + 14
    lr = wrap(f"Randomized {_cnt(spec['randomized'])}", col_w - 12, SIZE_LABEL)
    hr = _box_height(lr)
    _flow_box(cv, "excluded", sx, y_ex, side_w, lex)
    cv.add(_poly([(cx, y + h1), (cx, y_r)], arrow=True, ident="assessed->randomized"))
    cv.add(_poly([(cx, y_ex + hex_ / 2), (sx - 0.6, y_ex + hex_ / 2)], ident="assessed->excluded"))
    _flow_box(cv, "randomized", b1x, y_r, col_w, lr, align="middle")
    y = y_r + hr

    # arms: rows of equal height across arms
    def colx(i):
        return left + i * (col_w + gutter)

    alloc_rows = []
    for arm in arms:
        ln = wrap(f"Allocated to {arm.get('name', 'arm')} {_cnt(arm['allocated'])}", col_w - 12)
        if "received" in arm:
            ln += _sub(f"Received allocated intervention {_cnt(arm['received'])}", col_w - 12)
            nr = arm.get("not_received") or []
            ln += _sub(f"Did not receive allocated intervention {_cnt(sum(n for _, n in nr))}", col_w - 12)
            for lab, n in nr:
                ln += _sub(f"{lab} {_cnt(n)}", col_w - 12, level=2)
        alloc_rows.append(ln)
    fu_rows = []
    for arm in arms:
        lost = arm.get("lost") or []
        disc = arm.get("discontinued") or []
        ln = _reason_lines(f"Lost to follow-up {_cnt(sum(n for _, n in lost))}", lost, col_w - 12)
        ln += _reason_lines(f"Discontinued intervention {_cnt(sum(n for _, n in disc))}", disc, col_w - 12)
        fu_rows.append(ln)
    an_rows = []
    for arm in arms:
        exa = arm.get("excluded_analysis") or []
        ln = wrap(f"Analysed {_cnt(arm['analysed'])}", col_w - 12)
        ln += _reason_lines(f"Excluded from analysis {_cnt(sum(n for _, n in exa))}", exa, col_w - 12)
        an_rows.append(ln)
    rows = [("Allocation", alloc_rows), ("Follow-up", fu_rows), ("Analysis", an_rows)]

    y += 26  # gap for the allocation bus
    bus_y = y - 13
    cv.add(_poly([(cx, y - 26), (cx, bus_y)], arrow=False, ident="randomized->bus"))
    if k > 1:
        cv.add(_poly([(colx(0) + col_w / 2, bus_y), (colx(k - 1) + col_w / 2, bus_y)], arrow=False, ident="bus"))
    focal_arm = spec.get("focal_arm")
    prev_y = bus_y
    for ri, (stage, rws) in enumerate(rows):
        rh = max(_box_height(l) for l in rws)   # equal heights across arms
        _stage_label(cv, stage, y + 4, M, M + 50)
        for i, ln in enumerate(rws):
            bx = colx(i)
            cv.add(_poly([(bx + col_w / 2, prev_y), (bx + col_w / 2, y - 0.6)], ident=f"{stage}-{i}-in"))
            _flow_box(cv, f"{stage}-{i}", bx, y, col_w, ln, min_h=rh,
                      focal=(focal_arm is not None and focal_arm == arms[i].get("name") and ri == 2))
        prev_y = y + rh
        y += rh + 22
    svg_h = y - 22 + M
    return _finish(cv, spec, width, svg_h, notes)


def cohort_checks(spec: dict) -> list[str]:
    """Arithmetic checks for a cohort selection (STROBE-style) flow."""
    if "start" not in spec or "steps" not in spec:
        raise SpecError("cohort spec needs 'start' {label, n} and 'steps' [...]")
    n = spec["start"]["n"]
    notes, small = [], []
    for i, st in enumerate(spec["steps"]):
        exc = st.get("excluded", 0)
        rs = _sum_reasons(st.get("reasons"), f"step {i+1}")
        if st.get("reasons") and rs != exc:
            raise SpecError(f"step {i+1} ('{st.get('label','')}'): reasons sum to {rs}, but excluded = {exc}")
        if exc > n:
            raise SpecError(f"step {i+1}: excludes {exc} from only {n}")
        n_next = n - exc
        if "n" in st and st["n"] != n_next:
            raise SpecError(f"step {i+1} ('{st.get('label','')}'): {n} - {exc} = {n_next}, but n = {st['n']}")
        n = n_next
        if 0 < n < 11:
            small.append(f"after step {i+1}: {n}")
    groups = spec.get("groups") or []
    if groups:
        gs = sum(g["n"] for g in groups)
        if gs != n:
            raise SpecError(f"groups sum to {gs}, but the final cohort is {n}")
        small += [f"{g['label']}: {g['n']}" for g in groups if 0 < g["n"] < 11]
    if small and spec.get("clinical", True):
        notes.append("Counts below 11 (" + "; ".join(small) + "): check small-cell suppression rules before sharing.")
    return notes


def render_cohort(spec: dict) -> tuple[str, list[str]]:
    notes = cohort_checks(spec)
    cv = _Canvas()
    col_w = spec.get("box_width", 160.0)
    side_w = spec.get("side_width", 170.0)
    groups = spec.get("groups") or []
    g_w = spec.get("group_width", 120.0)
    g_gap = 14.0
    gw_total = len(groups) * g_w + max(0, len(groups) - 1) * g_gap
    cx = M + max(col_w, gw_total) / 2
    width = max(cx + col_w / 2 + 24 + side_w + M, M + gw_total + M)
    y = _title_block(cv, dict(spec, _width_hint=width), M)
    n = spec["start"]["n"]
    l0 = wrap(f"{spec['start'].get('label', 'Source population')} {_cnt(n)}", col_w - 12)
    h = _flow_box(cv, "start", cx - col_w / 2, y, col_w, l0, align="middle")
    y_prev_bottom = y + h
    y += h
    for i, st in enumerate(spec["steps"]):
        exc = st.get("excluded", 0)
        n -= exc
        lex = _reason_lines(f"Excluded {_cnt(exc)}" if not st.get("exclusion_label") else
                            f"{st['exclusion_label']} {_cnt(exc)}", st.get("reasons"), side_w - 12)
        hex_ = _box_height(lex)
        yex = y + 14
        sx = cx + col_w / 2 + 24
        _flow_box(cv, f"excl{i+1}", sx, yex, side_w, lex)
        cv.add(_poly([(cx, yex + hex_ / 2), (sx - 0.6, yex + hex_ / 2)], ident=f"excl{i+1}"))
        y_box = yex + hex_ + 14
        lbl = st.get("label", "Remaining")
        ln = wrap(f"{lbl} {_cnt(n)}", col_w - 12)
        last = (i == len(spec["steps"]) - 1)
        cv.add(_poly([(cx, y_prev_bottom), (cx, y_box - 0.6)], ident=f"step{i+1}"))
        h = _flow_box(cv, f"step{i+1}", cx - col_w / 2, y_box, col_w, ln, align="middle",
                      focal=last and spec.get("focal_final", True) and not groups)
        y_prev_bottom = y_box + h
        y = y_box + h
    if groups:
        y += 26
        bus = y - 13
        gx0 = cx - gw_total / 2
        cv.add(_poly([(cx, y_prev_bottom), (cx, bus)], arrow=False, ident="bus-stem"))
        if len(groups) > 1:
            cv.add(_poly([(gx0 + g_w / 2, bus), (gx0 + gw_total - g_w / 2, bus)], arrow=False, ident="bus"))
        hmax = 0
        for j, g in enumerate(groups):
            gx = gx0 + j * (g_w + g_gap)
            cv.add(_poly([(gx + g_w / 2, bus), (gx + g_w / 2, y - 0.6)], ident=f"group{j}"))
            ln = wrap(f"{g['label']} {_cnt(g['n'])}", g_w - 12)
            hmax = max(hmax, _flow_box(cv, f"group{j}", gx, y, g_w, ln, align="middle",
                                       focal=bool(g.get("focal"))))
        y += hmax
    return _finish(cv, spec, width, y + M, notes)


# ---------------------------------------------------------------------------
# PRISMA 2020 flow (systematic reviews)
# ---------------------------------------------------------------------------
def _pairs(x):
    """[label, n] pairs; a single bare pair (as R sends it) is wrapped."""
    if not x:
        return []
    if isinstance(x, list) and len(x) == 2 and isinstance(x[0], str) and not isinstance(x[1], (list, dict)):
        return [x]
    return x


def prisma_checks(spec: dict) -> dict:
    """Arithmetic checks for a PRISMA 2020 flow. Returns the derived counts."""
    if spec.get("other_methods"):
        om = spec["other_methods"]
        om["identified"] = _pairs(om.get("identified"))
        om["excluded"] = _pairs(om.get("excluded"))
    if isinstance(spec.get("screen_excluded"), list):
        spec["screen_excluded"] = _pairs(spec["screen_excluded"])
    ident = spec.get("identification") or {}
    dbs = ident.get("databases") or []
    regs = ident.get("registers") or []
    if not dbs and not regs:
        raise SpecError("PRISMA spec needs identification.databases and/or identification.registers")
    n_id = _sum_reasons(dbs, "databases") + _sum_reasons(regs, "registers")
    if "identified" in spec and _count(spec["identified"], "identified") != n_id:
        raise SpecError(f"identified = {spec['identified']}, but databases and registers sum to {n_id}")
    rem = spec.get("removed") or {}
    rem_items = [("Duplicate records removed", rem.get("duplicates", 0)),
                 ("Records marked as ineligible by automation tools", rem.get("automation", 0)),
                 ("Records removed for other reasons", rem.get("other", 0))]
    n_rem = sum(_count(v, k) for k, v in rem_items)
    d = {"identified": n_id, "removed": n_rem, "removed_items": rem_items}
    def step(name, value, where):
        if name in spec and _count(spec[name], name) != value:
            raise SpecError(f"{name} = {spec[name]}, but {where} = {value}")
        if value < 0:
            raise SpecError(f"{name} would be negative ({value}): check {where}")
        d[name] = value
    step("screened", n_id - n_rem, f"identified ({n_id}) minus removed before screening ({n_rem})")
    sx = spec.get("screen_excluded", 0)
    sx_n = _sum_reasons(sx, "screen_excluded") if isinstance(sx, list) else _count(sx, "screen_excluded")
    d["screen_excluded"] = sx_n
    step("sought", d["screened"] - sx_n, f"screened ({d['screened']}) minus excluded at screening ({sx_n})")
    nr = _count(spec.get("not_retrieved", 0), "not_retrieved")
    step("assessed", d["sought"] - nr, f"sought ({d['sought']}) minus not retrieved ({nr})")
    d["not_retrieved"] = nr
    fx = spec.get("full_text_excluded") or []
    d["full_text_excluded"] = _sum_reasons(fx, "full_text_excluded")
    new_reports = d["assessed"] - d["full_text_excluded"]
    if new_reports < 0:
        raise SpecError(f"reports excluded at full text ({d['full_text_excluded']}) exceed reports assessed ({d['assessed']})")
    oth = spec.get("other_methods")
    if oth:
        o_id = _sum_reasons(oth.get("identified"), "other_methods.identified")
        o_sought = _count(oth.get("sought", o_id), "other_methods.sought")
        if o_sought > o_id:
            raise SpecError(f"other methods: sought ({o_sought}) exceeds identified ({o_id})")
        o_nr = _count(oth.get("not_retrieved", 0), "other_methods.not_retrieved")
        o_as = o_sought - o_nr
        if "assessed" in oth and _count(oth["assessed"], "other_methods.assessed") != o_as:
            raise SpecError(f"other methods: assessed = {oth['assessed']}, but sought ({o_sought}) minus not retrieved ({o_nr}) = {o_as}")
        if o_as < 0:
            raise SpecError("other methods: not retrieved exceeds sought")
        o_ex = _sum_reasons(oth.get("excluded"), "other_methods.excluded")
        if o_ex > o_as:
            raise SpecError(f"other methods: excluded ({o_ex}) exceeds assessed ({o_as})")
        d.update(o_identified=o_id, o_sought=o_sought, o_not_retrieved=o_nr, o_assessed=o_as, o_excluded=o_ex)
        new_reports += o_as - o_ex
    inc = spec.get("included") or {}
    if "studies" not in inc:
        raise SpecError("PRISMA spec needs included.studies")
    st = _count(inc["studies"], "included.studies")
    rp = _count(inc.get("reports", new_reports), "included.reports")
    if rp != new_reports:
        raise SpecError(f"included reports = {rp}, but assessed minus excluded = {new_reports}"
                        + (" (both search columns)" if oth else ""))
    if st > rp:
        raise SpecError(f"included studies ({st}) cannot exceed reports of included studies ({rp})")
    d.update(studies=st, reports=rp)
    prev = spec.get("previous")
    if prev:
        ps, pr = _count(prev.get("studies", 0), "previous.studies"), _count(prev.get("reports", 0), "previous.reports")
        d.update(prev_studies=ps, prev_reports=pr, total_studies=ps + st, total_reports=pr + rp)
        tot = spec.get("total") or {}
        if "studies" in tot and _count(tot["studies"], "total.studies") != ps + st:
            raise SpecError(f"total studies = {tot['studies']}, but previous ({ps}) + new ({st}) = {ps + st}")
        if "reports" in tot and _count(tot["reports"], "total.reports") != pr + rp:
            raise SpecError(f"total reports = {tot['reports']}, but previous ({pr}) + new ({rp}) = {pr + rp}")
    return d


def render_prisma(spec: dict) -> tuple[str, list[str]]:
    """PRISMA 2020 flow: databases and registers, optional other methods and
    previous-version columns, with every count checked."""
    d = prisma_checks(spec)
    notes = []
    cv = _Canvas()
    oth = spec.get("other_methods")
    prev = spec.get("previous")
    bw = spec.get("box_width", 96.0 if oth else (112.0 if prev else 140.0))
    sw = spec.get("side_width", 92.0 if oth else (118.0 if prev else 150.0))
    g = 14.0
    left = M + 18.0   # rotated stage labels, as in the PRISMA 2020 template
    lanes = []
    if prev:
        lanes.append(("prev", bw))
    lanes.append(("main", bw + g + sw))
    if oth:
        lanes.append(("other", bw + g + sw))
    xs, x = {}, left
    for name, w in lanes:
        xs[name] = x
        x += w + 18.0
    width = x - 18.0 + M
    title_y = _title_block(cv, dict(spec, _width_hint=width), M)
    y = title_y
    hdr = {"prev": "Previous studies", "main": "Identification of new studies via databases and registers",
           "other": "Identification of new studies via other methods"}
    if prev or oth:
        hh = 0
        for name, w in lanes:
            ln = wrap(hdr[name], w - 4, SIZE_SMALL, "italic")
            cv.text_block(ln, xs[name], y, size=SIZE_SMALL, style="italic", colour=TEXT_MUTED, anchor="start")
            hh = max(hh, len(ln) * SIZE_SMALL * 1.22)
        y += hh + 8

    W = lambda t, w: wrap(t, w - 12)
    S = lambda t, w: _sub(t, w - 12)
    mx = xs["main"]
    # row contents ------------------------------------------------------------
    r0 = {"main": W("Records identified from:", bw)
          + [l for lab, n in (spec["identification"].get("databases") or []) for l in S(f"{lab} {_cnt(n)}", bw)]
          + [l for lab, n in (spec["identification"].get("registers") or []) for l in S(f"{lab} {_cnt(n)}", bw)],
          "main_side": W("Records removed before screening:", sw)
          + [l for lab, n in d["removed_items"] for l in S(f"{lab} {_cnt(n)}", sw)]}
    if oth:
        r0["other"] = W("Records identified from:", bw) + [l for lab, n in oth["identified"] for l in S(f"{lab} {_cnt(n)}", bw)]
    if prev:
        r0["prev"] = W(f"Studies included in previous version of review {_cnt(d['prev_studies'])}", bw) + \
            W(f"Reports of studies included in previous version of review {_cnt(d['prev_reports'])}", bw)
    sx = spec.get("screen_excluded", 0)
    r1 = {"main": W(f"Records screened {_cnt(d['screened'])}", bw),
          "main_side": W(f"Records excluded {_cnt(d['screen_excluded'])}", sw)
          + ([l for lab, n in sx for l in S(f"{lab} {_cnt(n)}", sw)] if isinstance(sx, list) else [])}
    r2 = {"main": W(f"Reports sought for retrieval {_cnt(d['sought'])}", bw),
          "main_side": W(f"Reports not retrieved {_cnt(d['not_retrieved'])}", sw)}
    r3 = {"main": W(f"Reports assessed for eligibility {_cnt(d['assessed'])}", bw),
          "main_side": W("Reports excluded:", sw) + [l for lab, n in (spec.get("full_text_excluded") or [])
                                                     for l in S(f"{lab} {_cnt(n)}", sw)]}
    if oth:
        r2["other"] = W(f"Reports sought for retrieval {_cnt(d['o_sought'])}", bw)
        r2["other_side"] = W(f"Reports not retrieved {_cnt(d['o_not_retrieved'])}", sw)
        r3["other"] = W(f"Reports assessed for eligibility {_cnt(d['o_assessed'])}", bw)
        r3["other_side"] = W("Reports excluded:", sw) + [l for lab, n in (oth.get("excluded") or [])
                                                        for l in S(f"{lab} {_cnt(n)}", sw)]
    rows = [r0, r1, r2, r3]
    pos = {}   # (row, slot) -> (x, y, w, h)
    stage_y = {}
    for ri, row in enumerate(rows):
        rh = max(_box_height(v) for v in row.values())
        if ri in (0, 1):
            stage_y[ri] = y
        for slot, lines in row.items():
            lane = slot.replace("_side", "")
            bx = xs[lane] + (bw + g if slot.endswith("_side") else 0)
            w = sw if slot.endswith("_side") else bw
            h = _box_height(lines)            # every box keeps its natural height
            _flow_box(cv, f"{slot}-{ri}", bx, y, w, lines)
            pos[(ri, slot)] = (bx, y, w, h)
        y += rh + 20
        if ri == 0:
            stage_end0 = y - 20
        if ri == 3:
            stage_end1 = y - 20
    stage_y[2] = y
    if prev:
        inc_lines = W(f"New studies included in review {_cnt(d['studies'])}", bw) + \
            W(f"Reports of new included studies {_cnt(d['reports'])}", bw)
    else:
        inc_lines = W(f"Studies included in review {_cnt(d['studies'])}", bw) + \
            W(f"Reports of included studies {_cnt(d['reports'])}", bw)
    ih = _box_height(inc_lines)
    _flow_box(cv, "included", mx, y, bw, inc_lines, focal=not prev and spec.get("focal_included", True))
    pos[("inc", "main")] = (mx, y, bw, ih)
    y_inc = y
    y += ih
    if prev:
        y += 20
        tot = W(f"Total studies included in review {_cnt(d['total_studies'])}", bw) + \
            W(f"Reports of total included studies {_cnt(d['total_reports'])}", bw)
        th = _box_height(tot)
        _flow_box(cv, "total", mx, y, bw, tot, focal=spec.get("focal_included", True))
        pos[("tot", "main")] = (mx, y, bw, th)
        y += th
    # arrows ------------------------------------------------------------------
    def down(a, b, ident):
        ax, ay, aw, ah = a
        bx_, by, bw_, bh = b
        cv.add(_poly([(ax + aw / 2, ay + ah), (bx_ + bw_ / 2, by - 0.6)], ident=ident))

    def side(a, b, ident):
        ax, ay, aw, ah = a
        bx_, by, bw_, bh = b
        yy = by + min(bh, ah) / 2
        cv.add(_poly([(ax + aw, yy), (bx_ - 0.6, yy)], ident=ident))

    for ri in range(4):
        side(pos[(ri, "main")], pos[(ri, "main_side")], f"main{ri}->side")
    for ri in range(3):
        down(pos[(ri, "main")], pos[(ri + 1, "main")], f"main{ri}->main{ri+1}")
    down(pos[(3, "main")], pos[("inc", "main")], "main3->included")
    if oth:
        down(pos[(0, "other")], pos[(2, "other")], "other0->other2")
        for ri in (2, 3):
            side(pos[(ri, "other")], pos[(ri, "other_side")], f"other{ri}->side")
        down(pos[(2, "other")], pos[(3, "other")], "other2->other3")
        ox, oy, ow, oh = pos[(3, "other")]
        ix, iy, iw, ih2 = pos[("inc", "main")]
        cx_ = ox + ow / 2
        cv.add(_poly([(cx_, oy + oh), (cx_, iy + ih2 / 2), (ix + iw + 0.6, iy + ih2 / 2)], ident="other3->included"))
    if prev:
        px, py, pw, ph = pos[(0, "prev")]
        tx, ty, tw, th = pos[("tot", "main")]
        cv.add(_poly([(px + pw / 2, py + ph), (px + pw / 2, ty + th / 2), (tx - 0.6, ty + th / 2)], ident="prev->total"))
        down(pos[("inc", "main")], pos[("tot", "main")], "included->total")
    # rotated stage labels with a thin rule spanning each stage
    for (y0, y1, text) in ((stage_y[0], stage_end0, "Identification"),
                           (stage_y[1], stage_end1, "Screening"),
                           (stage_y[2], y, "Included")):
        cx_, cy_ = M + 5, (y0 + y1) / 2
        cv.add(f'<line x1="{_f(M + 12)}" y1="{_f(y0)}" x2="{_f(M + 12)}" y2="{_f(y1)}" stroke="{MUTED}" stroke-width="0.6"/>')
        cv.add(f'<text x="{_f(cx_)}" y="{_f(cy_)}" font-size="{_f(SIZE_SMALL)}" font-style="italic" fill="{TEXT_MUTED}" '
               f'text-anchor="middle" transform="rotate(-90 {_f(cx_)} {_f(cy_)})">{text}</text>')
    if width > COLUMN_PT + 1:
        notes.append(f"Figure is {width:.0f} pt wide, wider than a {COLUMN_PT:.0f} pt column: set box_width and side_width smaller, or use it as a full-page figure.")
    return _finish(cv, spec, width, y + M, notes)


# ---------------------------------------------------------------------------
# Study timeline / Gantt
# ---------------------------------------------------------------------------
def _to_num(v, unit, end=False):
    """Numbers pass through. 'YYYY-MM' is the start of that month, or its end
    when end=True (so a span ending '2026-12' covers all of December)."""
    if isinstance(v, (int, float)):
        return float(v)
    m = re.fullmatch(r"(\d{4})-(\d{2})(?:-(\d{2}))?", str(v))
    if not m:
        raise SpecError(f"timeline value {v!r}: use a number or 'YYYY-MM'")
    y, mo = int(m.group(1)), int(m.group(2))
    if not 1 <= mo <= 12:
        raise SpecError(f"timeline value {v!r}: month must be 01 to 12")
    if m.group(3) is None:
        return y * 12 + (mo - 1) + (1.0 if end else 0.0)
    return y * 12 + (mo - 1) + (int(m.group(3)) - 1) / 30.5


def _nice_ticks(a, b, target=7):
    span = b - a
    raw = span / target
    mag = 10 ** math.floor(math.log10(raw)) if raw > 0 else 1
    step = min((s * mag for s in (1, 2, 3, 6, 12, 5, 10) if s * mag >= raw), default=mag * 10)
    t = math.ceil(a / step) * step
    out = []
    while t <= b + 1e-9:
        out.append(t)
        t += step
    return out


def render_timeline(spec: dict) -> tuple[str, list[str]]:
    notes = []
    tracks = spec.get("tracks") or []
    if not tracks:
        raise SpecError("timeline needs 'tracks'")
    dated = isinstance(spec.get("start"), str)
    unit = spec.get("unit", "month")
    t0 = _to_num(spec["start"], unit)
    t1 = _to_num(spec["end"], unit, end=True)
    if t1 <= t0:
        raise SpecError("timeline 'end' must be after 'start'")
    cv = _Canvas()
    width = spec.get("width", COLUMN_PT)
    lab_w = max(text_width(t["label"], SIZE_LABEL) for t in tracks) + 10
    lab_w = min(lab_w, 150)
    x0 = M + lab_w
    x1 = width - M - 6
    sx = lambda t: x0 + (t - t0) / (t1 - t0) * (x1 - x0)
    y = _title_block(cv, dict(spec, _width_hint=width), M)
    ms = spec.get("milestones") or []
    # milestone labels, staggered to avoid overlap
    levels = []
    ms_draw = []
    for m in sorted(ms, key=lambda m: _to_num(m["at"], unit)):
        t = _to_num(m["at"], unit)
        if not t0 <= t <= t1:
            raise SpecError(f"milestone '{m['label']}' at {m['at']} is outside the timeline")
        x = sx(t)
        tw = text_width(m["label"], SIZE_SMALL, "italic")
        lx = min(max(x - tw / 2, M), width - M - tw)
        lvl = 0
        while lvl < len(levels) and levels[lvl] > lx - 4:
            lvl += 1
        if lvl == len(levels):
            levels.append(0)
        levels[lvl] = lx + tw
        ms_draw.append((x, lx, tw, lvl, m))
    ms_h = len(levels) * SIZE_SMALL * 1.3 + (6 if levels else 0)
    top = y + ms_h
    row_h = 18.0
    bar_h = 8.0
    for i, tr in enumerate(tracks):
        ry = top + i * row_h
        cv.text_block(wrap(tr["label"], 148)[:1], x0 - 8, ry + (row_h - SIZE_LABEL) / 2, size=SIZE_LABEL,
                      colour=INK, anchor="end")
        for sp in tr.get("spans") or []:
            a, b = _to_num(sp[0], unit), _to_num(sp[1], unit, end=True)
            if not (t0 <= a < b <= t1):
                raise SpecError(f"span {sp} of '{tr['label']}' is empty or outside the timeline")
            focal = bool(tr.get("focal"))
            if focal:
                cv.accent_uses += 1
            fill = ACCENT if focal else MUTED
            bx, bw = sx(a), sx(b) - sx(a)
            cv.add(f'<rect x="{_f(bx)}" y="{_f(ry + (row_h - bar_h)/2)}" width="{_f(bw)}" height="{_f(bar_h)}" '
                   f'fill="{fill}"{_box_meta("bar", tr["label"], bx, ry + (row_h-bar_h)/2, bw, bar_h)}/>')
        for p in tr.get("points") or []:
            px = sx(_to_num(p, unit))
            cy = ry + row_h / 2
            cv.add(f'<path d="M{_f(px)},{_f(cy-4)} L{_f(px+4)},{_f(cy)} L{_f(px)},{_f(cy+4)} L{_f(px-4)},{_f(cy)} Z" fill="{INK}"/>')
    bottom = top + len(tracks) * row_h
    for x, lx, tw, lvl, m in ms_draw:
        ly = y + lvl * SIZE_SMALL * 1.3
        cv.add(f'<line x1="{_f(x)}" y1="{_f(ly + SIZE_SMALL*1.1)}" x2="{_f(x)}" y2="{_f(bottom)}" '
               f'stroke="{INK}" stroke-width="0.5" stroke-dasharray="1.5,2"/>')
        cv.text_block([m["label"]], lx, ly, size=SIZE_SMALL, style="italic", colour=TEXT_MUTED, anchor="start")
        cv.boxes.append(("label", m["label"], lx, ly, tw, SIZE_SMALL))
    # axis: range-frame from start to end, light ticks
    cv.add(f'<line x1="{_f(x0)}" y1="{_f(bottom + 4)}" x2="{_f(x1)}" y2="{_f(bottom + 4)}" stroke="{INK}" stroke-width="0.4"/>')
    if dated:
        ticks = []
        yr0, yr1 = int(t0 // 12), int(t1 // 12)
        step = 1 if (t1 - t0) <= 30 else (3 if (t1 - t0) <= 60 else 6)
        if (t1 - t0) > 36:
            step = 6
        for t in range(int(math.ceil(t0)), int(t1) + 1):
            if t % step == 0 or (t1 - t0 <= 14):
                ticks.append(t)
        months = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
        lab = lambda t: (months[int(t) % 12] + (" " + str(int(t) // 12) if int(t) % 12 == 0 or t == ticks[0] else ""))
    else:
        ticks = _nice_ticks(t0, t1)
        lab = lambda t: _f(t)
    last_end = -1e9
    for t in ticks:
        x = sx(t)
        cv.add(f'<line x1="{_f(x)}" y1="{_f(bottom + 4)}" x2="{_f(x)}" y2="{_f(bottom + 7)}" stroke="{INK}" stroke-width="0.4"/>')
        s = lab(t)
        tw = text_width(s, SIZE_SMALL)
        if x - tw / 2 > last_end + 3:
            cv.text_block([s], x, bottom + 9, size=SIZE_SMALL, colour=INK)
            last_end = x + tw / 2
    axis_label = spec.get("axis_label", "" if dated else unit.capitalize() + "s")
    yy = bottom + 9 + SIZE_SMALL * 1.3
    if axis_label:
        cv.text_block([axis_label], x1, yy, size=SIZE_SMALL, colour=TEXT_MUTED, anchor="end")
        yy += SIZE_SMALL * 1.3
    return _finish(cv, spec, width, yy + M, notes)


# ---------------------------------------------------------------------------
# Safe SVG reading (for InkSight panels and the checker)
# ---------------------------------------------------------------------------
_REMOTE = re.compile(r"""(?:href|src)\s*=\s*["']\s*(?:https?:|//|data:text/html|javascript:)|@import|url\(\s*["']?\s*(?:https?:|//)""", re.I)


def _screen_svg(text: str, where: str = "svg") -> None:
    # A plain DOCTYPE (matplotlib writes one) is harmless; entity declarations and
    # internal subsets enable expansion attacks, so they are refused.
    if re.search(r"<!ENTITY", text, re.I) or re.search(r"<!DOCTYPE[^>]*\[", text, re.I):
        raise SpecError(f"{where}: ENTITY declarations and DOCTYPE internal subsets are not allowed")
    if re.search(r"<script|<foreignObject|\son[a-z]+\s*=", text, re.I):
        raise SpecError(f"{where}: scripts, event handlers and foreignObject are not allowed")
    if _REMOTE.search(text):
        raise SpecError(f"{where}: remote references (links, fonts, images) are not allowed")


def _read_svg(path) -> str:
    p = Path(path)
    if p.suffix.lower() != ".svg":
        raise SpecError(f"{path}: panels must be .svg files (save InkSight figures with .svg)")
    if p.stat().st_size > 20_000_000:
        raise SpecError(f"{path}: larger than 20 MB")
    text = p.read_text(encoding="utf-8")
    _screen_svg(text, str(p.name))
    return re.sub(r"<!DOCTYPE[^>]*>", "", text, flags=re.I)


def _svg_size(root_attrs: str):
    def num(name):
        m = re.search(rf'\b{name}\s*=\s*["\']([\d.]+)\s*(pt|px|in|mm|cm)?["\']', root_attrs)
        if not m:
            return None
        v, u = float(m.group(1)), (m.group(2) or "px")
        return v * {"pt": 1, "px": 0.75, "in": 72, "mm": 72 / 25.4, "cm": 72 / 2.54}[u]
    w, h = num("width"), num("height")
    vb = re.search(r'viewBox\s*=\s*["\']([-\d.eE]+)[ ,]+([-\d.eE]+)[ ,]+([\d.eE]+)[ ,]+([\d.eE]+)["\']', root_attrs)
    vbox = tuple(float(x) for x in vb.groups()) if vb else None
    if vbox and (w is None or h is None):
        w, h = vbox[2] * 0.75, vbox[3] * 0.75
    if w is None or h is None:
        raise SpecError("panel SVG has no width/height or viewBox")
    return w, h, vbox


def _prefix_ids(body: str, prefix: str) -> str:
    """Give every id in an embedded panel a unique prefix (matplotlib and
    svglite both reuse ids such as 'figure_1' or clip-path hashes)."""
    ids = {m.group(2) for m in re.finditer(r'\bid\s*=\s*(["\'])(.+?)\1', body)}
    if not ids:
        return body
    alt = "|".join(re.escape(i) for i in sorted(ids, key=len, reverse=True))
    body = re.sub(rf'\bid\s*=\s*(["\'])({alt})\1', lambda m: f'id={m.group(1)}{prefix}{m.group(2)}{m.group(1)}', body)
    body = re.sub(rf'url\(\s*#({alt})\s*\)', lambda m: f'url(#{prefix}{m.group(1)})', body)
    body = re.sub(rf'((?:xlink:)?href\s*=\s*["\'])#({alt})(["\'])', lambda m: f'{m.group(1)}#{prefix}{m.group(2)}{m.group(3)}', body)
    return body


def _unify_fonts(body: str) -> str:
    """Point every font in an embedded panel at the shared serif stack, so an
    InkSight matplotlib panel (DejaVu Serif by default) matches the diagram."""
    fam = FONT_CSS  # unquoted, safe inside single- or double-quoted attributes
    name = r'(?:"[^"]*"|\'[^\']*\'|[\w -]+)'
    body = re.sub(r'font-family\s*=\s*(["\'])(?:(?!\1).)*\1', lambda m: f'font-family={m.group(1)}{fam}{m.group(1)}', body)
    body = re.sub(rf'font-family\s*:\s*{name}(?:\s*,\s*{name})*', f"font-family: {fam}", body)
    # matplotlib shorthand: font: 10px 'DejaVu Serif'  -> keep size, swap family
    body = re.sub(rf'(font\s*:\s*(?:[\w.-]+\s+)*?[\d.]+(?:px|pt))\s+{name}(?:\s*,\s*{name})*',
                  lambda m: f"{m.group(1)} {fam}", body)
    return body


def compose_panels(spec: dict, base_dir: str | Path = ".") -> tuple[str, list[str]]:
    """Multi-panel figure: FrameDesign diagrams and InkSight charts on one page.

    Each panel is {"file": "fig.svg"} (InkSight saves .svg) or {"spec": {...}}
    (a FrameDesign spec rendered in place), plus an optional "label" and "span".
    """
    panels = spec.get("panels") or []
    if not panels:
        raise SpecError("panels spec needs 'panels'")
    cols = int(spec.get("cols", 2))
    width = float(spec.get("width", COLUMN_PT))
    gap = float(spec.get("gap", 14.0))
    notes = []
    base = Path(base_dir)
    letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    cell_w = (width - 2 * M - (cols - 1) * gap) / cols
    cv = _Canvas()
    y = _title_block(cv, dict(spec, _width_hint=width), M)
    col = 0
    row_h = 0.0
    scales = []
    for i, p in enumerate(panels):
        span = min(int(p.get("span", 1)), cols)
        if col + span > cols:
            y += row_h + gap
            col, row_h = 0, 0.0
        if "file" in p:
            fp = Path(p["file"])
            if ".." in fp.parts:
                raise SpecError("panel paths may not contain '..'")
            text = _read_svg(base / fp)
        elif "spec" in p:
            text, w2 = render(p["spec"])
            notes += [f"panel {letters[i]}: {w}" for w in w2]
        else:
            raise SpecError("each panel needs 'file' or 'spec'")
        m = re.search(r"<svg\b([^>]*)>(.*)</svg>\s*$", text, re.S)
        if not m:
            raise SpecError(f"panel {i+1}: not an SVG document")
        attrs, body = m.group(1), m.group(2)
        pw, ph, vbox = _svg_size(attrs)
        avail = cell_w * span + gap * (span - 1) - SIZE_PANEL  # minus the letter column
        scale = min(1.0, avail / pw) if spec.get("no_upscale", True) else avail / pw
        dw, dh = pw * scale, ph * scale
        scales.append((letters[i], scale, avail))
        if scale < 0.7:
            notes.append(f"panel {letters[i]} is shrunk to {scale:.0%}: its text may fall below 7 pt. Make it at the final size instead.")
        x = M + col * (cell_w + gap)
        body = _prefix_ids(body, f"p{i}-")
        if spec.get("unify_fonts", True):
            body = _unify_fonts(body)
        vb = f'{_f(vbox[0])} {_f(vbox[1])} {_f(vbox[2])} {_f(vbox[3])}' if vbox else f"0 0 {_f(pw)} {_f(ph)}"
        cm = re.search(r'\bclass\s*=\s*["\']([\w -]+)["\']', attrs)
        cls = f' class="{cm.group(1)}"' if cm else ""
        # keep the panel's own namespace declarations (Inkscape, C2PA, RDF ...)
        for pre, uri in re.findall(r'\bxmlns:([\w.-]+)\s*=\s*["\']([^"\']+)["\']', attrs):
            if pre != "xlink":
                cls += f' xmlns:{pre}="{_esc(uri)}"'

        cv.add(f'<svg x="{_f(x + SIZE_PANEL)}" y="{_f(y)}" width="{_f(dw)}" height="{_f(dh)}" viewBox="{vb}" '
               f'preserveAspectRatio="xMinYMin meet" overflow="hidden"{cls} data-fd="panel" data-fd-id="{letters[i]}">'
               f"{body}</svg>")
        lab = p.get("label", letters[i])
        cv.text_block([lab], x, y, size=SIZE_PANEL, style="bold", colour=INK, anchor="start")
        row_h = max(row_h, dh)
        col += span
    sc = [s for _, s, _ in scales]
    if sc and max(sc) - min(sc) > 0.12:
        detail = ", ".join(f"{l} {s:.0%} (fits {a:.0f} pt wide)" for l, s, a in scales)
        notes.append(f"Panels are scaled differently ({detail}), so type sizes will not match. "
                     "Build each panel at the width shown.")
    return _finish(cv, spec, width, y + row_h + M, notes)


# ---------------------------------------------------------------------------
# Dispatcher, checker, file output
# ---------------------------------------------------------------------------
_RENDERERS = {"flow": render_flow, "pipeline": render_flow, "dag": render_dag,
              "consort": render_consort, "cohort": render_cohort, "prisma": render_prisma,
              "timeline": render_timeline}


_LIST_KEYS = {"nodes", "edges", "arms", "steps", "groups", "tracks", "milestones",
              "panels", "reasons", "not_received", "lost", "discontinued",
              "excluded_analysis", "points", "spans", "databases", "registers",
              "full_text_excluded"}
_PAIR_KEYS = ("reasons", "not_received", "lost", "discontinued", "excluded_analysis",
              "databases", "registers", "full_text_excluded")


def _normalise(obj, key=None):
    """Make R/JSON input regular: scalars where lists are expected become
    one-item lists, a single [label, n] pair becomes [[label, n]], and whole
    numbers passed as floats (412.0) become ints."""
    if key in _LIST_KEYS and not isinstance(obj, list):
        obj = [obj]
    if isinstance(obj, dict):
        return {k: _normalise(v, k) for k, v in obj.items()}
    if isinstance(obj, list):
        if key in _PAIR_KEYS \
                and len(obj) == 2 and isinstance(obj[0], str) and not isinstance(obj[1], (list, dict)):
            obj = [obj]
        if key == "spans" and len(obj) == 2 and all(isinstance(v, (int, float, str)) for v in obj):
            obj = [obj]
        return [_normalise(v, None if key not in ("spans",) else "_span") for v in obj]
    if isinstance(obj, float) and obj.is_integer() and abs(obj) < 1e15:
        return int(obj)
    return obj


def render(spec: dict, base_dir: str | Path = ".") -> tuple[str, list[str]]:
    """Render any FrameDesign spec. Returns (svg_text, warnings)."""
    if not isinstance(spec, dict):
        raise SpecError("spec must be a JSON object")
    spec = _normalise(spec)
    t = spec.get("type")
    if t == "panels":
        svg, warns = compose_panels(spec, base_dir)
        return svg, warns + check_svg(svg)
    if t not in _RENDERERS:
        raise SpecError(f"type must be one of {sorted(list(_RENDERERS) + ['panels'])}")
    svg, warns = _RENDERERS[t](spec)
    return svg, warns + check_svg(svg)


_PHI = [
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), "looks like a Social Security number"),
    (re.compile(r"\b(?:19|20)\d{2}-[01]\d-[0-3]\d\b"), "contains an exact date (YYYY-MM-DD)"),
    (re.compile(r"\b[01]?\d/[0-3]?\d/(?:19|20)?\d{2}\b"), "contains an exact date (MM/DD/YYYY)"),
    (re.compile(r"\bMRN\s*[:#]?\s*\d+|\bmedical record\b", re.I), "mentions a medical record number"),
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+"), "contains an email address"),
    (re.compile(r"\b(?:\+?1[ .-]?)?\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b"), "contains a phone number"),
    (re.compile(r"\b(?:DOB|date of birth)\b", re.I), "mentions date of birth"),
]


def _lum(hexc):
    hexc = hexc.lstrip("#")
    if len(hexc) == 3:
        hexc = "".join(c * 2 for c in hexc)
    r, g, b = (int(hexc[i:i + 2], 16) / 255 for i in (0, 2, 4))
    f = lambda c: c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)


def contrast(a, b="#FFFFFF"):
    la, lb = sorted((_lum(a), _lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def _overlap(a, b, pad=0.5):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return ax + pad < bx + bw and bx + pad < ax + aw and ay + pad < by + bh and by + pad < ay + ah


def _seg_hits_box(p, q, box, shrink=1.0):
    x, y, w, h = box
    x0, y0, x1, y1 = x + shrink, y + shrink, x + w - shrink, y + h - shrink
    # Liang-Barsky clip
    dx, dy = q[0] - p[0], q[1] - p[1]
    t0, t1 = 0.0, 1.0
    for pp, qq in ((-dx, p[0] - x0), (dx, x1 - p[0]), (-dy, p[1] - y0), (dy, y1 - p[1])):
        if pp == 0:
            if qq < 0:
                return False
        else:
            t = qq / pp
            if pp < 0:
                t0 = max(t0, t)
            else:
                t1 = min(t1, t)
            if t0 > t1:
                return False
    return t1 - t0 > 1e-6


def check_svg(svg: str) -> list[str]:
    """Design, accuracy and privacy checks on an SVG. Returns a list of issues."""
    issues = []
    _screen_svg(svg)
    try:
        root = ET.fromstring(svg)
    except ET.ParseError as e:
        return [f"SVG does not parse: {e}"]
    ns = "{http://www.w3.org/2000/svg}"
    W = H = None
    vb = root.get("viewBox")
    if vb:
        _, _, W, H = (float(v) for v in vb.replace(",", " ").split())
    texts = []
    colours = set()
    for el in root.iter():
        for attr in ("fill", "stroke"):
            c = el.get(attr)
            if c and c.startswith("#"):
                colours.add(c.upper())
        if el.tag == ns + "text":
            s = "".join(el.itertext())
            texts.append(s)
            fill = el.get("fill", INK)
            if fill.startswith("#") and contrast(fill) < 4.5:
                issues.append(f"Text '{s[:30]}' has contrast {contrast(fill):.1f}:1 on white; use at least 4.5:1 (InkSight TEXT_MUTED {TEXT_MUTED}).")
            fs = el.get("font-size")
            if fs and float(fs) < 7:
                issues.append(f"Text '{s[:30]}' is {fs} pt: below 7 pt is illegible in print.")
            w, mw = el.get("data-fd-w"), el.get("data-fd-maxw")
            if w and mw and float(w) > float(mw) + 0.5:
                issues.append(f"Text '{s[:30]}' overflows its box by {float(w)-float(mw):.1f} pt.")
    ff = (root.get("font-family") or "") + " ".join(el.get("font-family", "") for el in root.iter())
    if ff.strip() and "serif" not in ff:
        issues.append("Font family has no serif fallback; InkSight and FrameDesign use serif type.")
    reds = {c for c in colours if re.fullmatch(r"#(?:[C-F][0-9A-F]|[89AB][0-9A-F])[0-4][0-9A-F][0-4][0-9A-F]", c)}
    greens = {c for c in colours if re.fullmatch(r"#[0-4][0-9A-F](?:[89A-F][0-9A-F])[0-4][0-9A-F]", c)}
    if reds and greens:
        issues.append("Red and green are both used: colour-deficient readers cannot separate them (Tufte p.183).")
    for s in texts:
        for rx, msg in _PHI:
            if rx.search(s):
                issues.append(f"Label '{s[:40]}' {msg}: remove identifiers before sharing.")
    # geometry checks on FrameDesign elements (skip nested panels)
    def own(el, parent_is_panel=False):
        for ch in el:
            if ch.get("data-fd") == "panel":
                continue
            yield ch
            yield from own(ch)
    boxes, edges, labels = [], [], []
    for el in own(root):
        kind = el.get("data-fd")
        if kind in ("node", "label", "bar", "group"):
            b = tuple(float(v) for v in el.get("data-fd-box").split(","))
            (boxes if kind == "node" else labels if kind == "label" else []).append((el.get("data-fd-id"), b))
            if W is not None and (b[0] < -0.5 or b[1] < -0.5 or b[0] + b[2] > W + 0.5 or b[1] + b[3] > H + 0.5):
                issues.append(f"{kind} '{el.get('data-fd-id')}' extends past the canvas edge.")
        elif kind == "edge":
            pts = [tuple(float(c) for c in p.split(",")) for p in el.get("data-fd-points").split()]
            edges.append((el.get("data-fd-id"), pts))
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            if _overlap(boxes[i][1], boxes[j][1]):
                issues.append(f"Nodes '{boxes[i][0]}' and '{boxes[j][0]}' overlap.")
    for lid, lb in labels:
        for nid, nb in boxes:
            if _overlap(lb, nb):
                issues.append(f"Label '{lid}' overlaps node '{nid}'.")
    for i in range(len(labels)):
        for j in range(i + 1, len(labels)):
            if _overlap(labels[i][1], labels[j][1]):
                issues.append(f"Labels '{labels[i][0]}' and '{labels[j][0]}' overlap.")
    for lid, lb in labels:
        for eid, pts in edges:
            if eid == lid:
                continue
            if any(_seg_hits_box(p, q, lb, shrink=0.3) for p, q in zip(pts, pts[1:])):
                issues.append(f"Label '{lid}' is crossed by edge '{eid}'.")
    for eid, pts in edges:
        ends = set(eid.split("->")) if "->" in eid else set()
        for nid, nb in boxes:
            if nid in ends:
                continue
            for p, q in zip(pts, pts[1:]):
                if _seg_hits_box(p, q, nb, shrink=1.5):
                    issues.append(f"Edge '{eid}' passes through node '{nid}'.")
                    break
    return sorted(set(issues), key=issues.index)


def write_svg(svg: str, path, overwrite: bool = False, html: bool = False) -> Path:
    """Write the SVG (and optionally a self-contained HTML viewer) to disk."""
    p = Path(path)
    if ".." in p.parts:
        raise SpecError("relative '..' paths are not allowed")
    if p.suffix.lower() not in (".svg", ".html"):
        raise SpecError("use a .svg or .html file name")
    if p.exists() and not overwrite:
        raise SpecError(f"{p} exists; pass overwrite=True to replace it")
    if p.suffix.lower() == ".html" or html:
        hp = p.with_suffix(".html")
        if hp.exists() and not overwrite:
            raise SpecError(f"{hp} exists; pass overwrite=True to replace it")
        hp.write_text("<!DOCTYPE html><html><head><meta charset='utf-8'><title>Figure</title>"
                      "<style>body{margin:24px;background:#fff}</style></head><body>"
                      + svg + "</body></html>", encoding="utf-8")
    if p.suffix.lower() == ".svg":
        p.write_text(svg, encoding="utf-8")
    return p


def export_png(svg_path, png_path, dpi: int = 300, overwrite: bool = False) -> Path:
    """PNG via cairosvg when it is installed. In R: rsvg::rsvg_png(svg, png, width = ...)."""
    try:
        import cairosvg  # optional, local library call
    except ImportError as e:
        raise SpecError("PNG export needs cairosvg (pip install cairosvg), or in R: "
                        "rsvg::rsvg_png('fig.svg', 'fig.png', width = 1950)") from e
    out = Path(png_path)
    if out.exists() and not overwrite:
        raise SpecError(f"{out} exists; pass overwrite=True to replace it")
    cairosvg.svg2png(url=str(svg_path), write_to=str(out), dpi=dpi, scale=dpi / 72)
    return out


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(prog="framedesign", description="Editorial research diagrams (FrameDesign)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render", help="render a JSON spec to SVG")
    r.add_argument("spec")
    r.add_argument("-o", "--out", required=True)
    r.add_argument("--html", action="store_true", help="also write a self-contained .html viewer")
    r.add_argument("--overwrite", action="store_true")
    r.add_argument("--base-dir", help="folder that panel 'file' paths are relative to (default: the spec's folder)")
    g = sub.add_parser("dagitty", help="print a DAG spec as a dagitty model and its adjustment sets")
    g.add_argument("spec")
    c = sub.add_parser("check", help="check an SVG for design, accuracy and privacy issues")
    c.add_argument("svg")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "render":
            sp = Path(a.spec)
            spec = json.loads(sp.read_text(encoding="utf-8"))
            svg, warns = render(spec, base_dir=a.base_dir or sp.parent)
            out = write_svg(svg, a.out, overwrite=a.overwrite, html=a.html)
            print(f"wrote {out}")
            for w in warns:
                print(f"  - {w}")
            return 0
        if a.cmd == "dagitty":
            spec = _normalise(json.loads(Path(a.spec).read_text(encoding="utf-8")))
            dag_checks(spec)
            print(to_dagitty(spec))
            sets = adjustment_sets(spec)
            if sets is not None:
                print("\n# Minimal sufficient adjustment sets (backdoor criterion):")
                for s in sets or []:
                    print("#   {" + ", ".join(s) + "}")
                if not sets:
                    print("#   none: not identifiable by adjustment")
            return 0
        text = Path(a.svg).read_text(encoding="utf-8")
        issues = check_svg(text)
        print("no issues found" if not issues else "\n".join(f"- {i}" for i in issues))
        return 1 if issues else 0
    except SpecError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
