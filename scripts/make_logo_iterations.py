"""Generates iterations on the sunburst, gauge and df logos in assets/iterations/."""
import colorsys, math, os, sys

OUT = sys.argv[1]
C = 512
TREE = [(0.30, [0.5, 0.3]), (0.22, [0.6, 0.25]), (0.18, [0.4, 0.4]), (0.16, [0.7]), (0.14, [0.5, 0.3])]

def pt(r, a, cx=C, cy=C):
    return cx + r * math.sin(a), cy - r * math.cos(a)

def ring_arc(r0, r1, a0, a1, cx=C, cy=C, gap=0.0):
    a0, a1 = a0 + gap / 2, a1 - gap / 2
    large = 1 if a1 - a0 > math.pi else 0
    x0, y0 = pt(r1, a0, cx, cy); x1, y1 = pt(r1, a1, cx, cy)
    x2, y2 = pt(r0, a1, cx, cy); x3, y3 = pt(r0, a0, cx, cy)
    return (f"M{x0:.1f},{y0:.1f} A{r1},{r1} 0 {large} 1 {x1:.1f},{y1:.1f} "
            f"L{x2:.1f},{y2:.1f} A{r0},{r0} 0 {large} 0 {x3:.1f},{y3:.1f}Z")

def annulus(r0, r1, cx=C, cy=C):
    return (f"M{cx-r1},{cy} a{r1},{r1} 0 1,0 {2*r1},0 a{r1},{r1} 0 1,0 {-2*r1},0 "
            f"M{cx-r0},{cy} a{r0},{r0} 0 1,1 {2*r0},0 a{r0},{r0} 0 1,1 {-2*r0},0")

def hue(a, depth, offset=0.92):
    h = (a / (2 * math.pi) + offset) % 1
    s, v = (0.48, 1.0) if depth == 0 else (0.58, 0.93)
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    return f"#{int(r*255):02x}{int(g*255):02x}{int(b*255):02x}"

def sunburst(rings, cx=C, cy=C, a_start=0.0, a_span=2 * math.pi, gap=0.018, tree=TREE):
    """rings: [(r0, r1)] for depth 0 (and optionally depth 1)."""
    out, a = [], a_start
    for frac, kids in tree:
        span = frac * a_span
        out.append(f'<path d="{ring_arc(*rings[0], a, a + span, cx, cy, gap)}" fill="{hue(a + span/2, 0)}"/>')
        if len(rings) > 1:
            k = a
            for kf in kids:
                ks = kf * span
                out.append(f'<path d="{ring_arc(*rings[1], k, k + ks, cx, cy, gap)}" fill="{hue(k + ks/2, 1)}"/>')
                k += ks
        a += span
    return "".join(out)

def bite_mask(id_, circles):
    cs = "".join(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}"/>' for x, y, r in circles)
    return f'<mask id="{id_}"><rect width="1024" height="1024" fill="white"/><g fill="black">{cs}</g></mask>'

def bite_at(r_edge, a, scale, cx=C, cy=C):
    return [(*pt(r_edge + 40 * scale, a, cx, cy), 98 * scale),
            (*pt(r_edge + 8 * scale, a - 0.33, cx, cy), 58 * scale),
            (*pt(r_edge + 8 * scale, a + 0.33, cx, cy), 58 * scale)]

def crumbs(r_edge, a, scale, color, cx=C, cy=C):
    return "".join(f'<circle cx="{pt(r_edge + dr*scale, a + da, cx, cy)[0]:.1f}" cy="{pt(r_edge + dr*scale, a + da, cx, cy)[1]:.1f}" r="{s*scale:.1f}" fill="{color}"/>'
                   for dr, da, s in [(65, -0.10, 10), (100, 0.06, 7), (72, 0.22, 5)])

def svg(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{defs}</defs>{body}</svg>\n')

TILE = '<rect x="100" y="100" width="824" height="824" rx="185" fill="{}"/>'
DARK_BG = '''<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#2b2350"/><stop offset="1" stop-color="#141026"/></linearGradient>'''
SHADOW = '<filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#000" flood-opacity="{}"/></filter>'
DOUGH = '''<radialGradient id="dough" cx="0.42" cy="0.38" r="0.65">
  <stop offset="0" stop-color="#f3bd78"/><stop offset="1" stop-color="#c9843f"/></radialGradient>'''

def donut(r_hole, r_out, rings, cx=C, cy=C, a_bite=math.radians(42), bite=True, mask_id="bite"):
    s = r_out / 330
    defs = bite_mask(mask_id, bite_at(r_out, a_bite, s, cx, cy)) if bite else ""
    m = f' mask="url(#{mask_id})"' if bite else ""
    body = (f'<g{m} filter="url(#sh)"><path d="{annulus(r_hole, r_out, cx, cy)}" fill="url(#dough)" fill-rule="evenodd"/>'
            f'{sunburst(rings, cx, cy)}</g>')
    return defs, body

# --- Sunburst donut ---------------------------------------------------------

def sunburst_light():
    """Original, on a light tile with shaded dough."""
    d, b = donut(118, 330, [(132, 222), (230, 318)])
    defs = d + DOUGH + SHADOW.format(0.18)
    body = TILE.format("#fff4e6") + b + crumbs(330, math.radians(42), 1, "#e2a15e")
    return svg(body, defs)

def sunburst_bold():
    """Single fat ring — reads at 16px, bite does the talking."""
    d, b = donut(130, 340, [(146, 326)])
    defs = d + DOUGH + DARK_BG + SHADOW.format(0.45)
    body = TILE.format("url(#bg)") + b + crumbs(340, math.radians(42), 1, "#ffd27a")
    return svg(body, defs)

# --- Gauge ------------------------------------------------------------------

G0, G1 = math.radians(-135), math.radians(135)

def gauge_base(fill, icing, dough, needle, r0=150, r1=300, end_cap=True):
    fill_to = G0 + (G1 - G0) * fill
    rm, cap = (r0 + r1) / 2, (r1 - r0) / 2
    body = f'<path d="{ring_arc(r0, r1, G0, G1)}" fill="{dough}"/>'
    body += icing(r0, r1, fill_to)
    for a, col in [(G1, dough)] if end_cap else []:
        x, y = pt(rm, a); body += f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{cap}" fill="{col}"/>'
    nx, ny = pt(r0 - 35, fill_to)
    tail = (f'<line x1="{C}" y1="{C}" x2="{nx:.1f}" y2="{ny:.1f}" stroke="{needle}" stroke-width="22" stroke-linecap="round"/>'
            f'<circle cx="{C}" cy="{C}" r="34" fill="{needle}"/>')
    return body, tail, fill_to

def gauge_sunburst():
    """Gauge whose icing is the sunburst palette — ties it to the chart."""
    def icing(r0, r1, fill_to):
        rm, cap = (r0 + r1) / 2, (r1 - r0) / 2
        tree = [(f, []) for f, _ in TREE]
        out = sunburst([(r0, r1)], a_start=G0, a_span=fill_to - G0, gap=0.03, tree=tree)
        span = fill_to - G0
        x, y = pt(rm, G0 + 0.015)
        out = f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{cap}" fill="{hue(G0 + span * TREE[0][0] / 2, 0)}"/>' + out
        x, y = pt(rm, fill_to - 0.015)
        return out + f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{cap}" fill="{hue(fill_to - span * TREE[-1][0] / 2, 0)}"/>'
    body, tail, _ = gauge_base(0.72, icing, "#f2c48d", "#3a2340")
    return svg(TILE.format("#fff4e6") + body + tail)

def gauge_bitten():
    """Dark gauge: the empty end of the dial has been eaten."""
    def icing(r0, r1, fill_to):
        rm, cap = (r0 + r1) / 2, (r1 - r0) / 2
        out = f'<path d="{ring_arc(r0, r1, G0, fill_to)}" fill="#ff5fa2"/>'
        for a in (G0, fill_to):
            x, y = pt(rm, a); out += f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{cap}" fill="#ff5fa2"/>'
        for r, a, rot, col in [(250, -105, 30, "#fff"), (190, -60, -40, "#5fd3ff"),
                               (260, -15, 70, "#ffe14d"), (200, 25, 10, "#fff"), (255, -140, -20, "#5fd3ff")]:
            x, y = pt(r, math.radians(a))
            out += (f'<rect x="{x-20:.0f}" y="{y-7:.0f}" width="40" height="14" rx="7" fill="{col}" '
                    f'transform="rotate({rot} {x:.0f} {y:.0f})"/>')
        return out
    body, tail, _ = gauge_base(0.62, icing, "url(#dough)", "#fff", end_cap=False)
    a = math.radians(135)
    mask = bite_mask("gbite", [(*pt(292, a + 0.02), 46), (*pt(225, a + 0.10), 52), (*pt(160, a + 0.04), 40)])
    defs = DARK_BG + DOUGH + mask + SHADOW.format(0.45)
    body = TILE.format("url(#bg)") + f'<g mask="url(#gbite)" filter="url(#sh)">{body}</g>' + tail
    body += crumbs(250, a + 0.12, 0.9, "#ffd27a")
    return svg(body, defs)

# --- df ---------------------------------------------------------------------

def df_glyphs(ink, bowl, cx=380, cy=600):
    out = bowl
    out += f'<rect x="{cx+92}" y="300" width="56" height="450" rx="28" fill="{ink}"/>'
    out += f'<path d="M640,750 V420 q0,-110 110,-110 h40" fill="none" stroke="{ink}" stroke-width="56" stroke-linecap="round"/>'
    out += f'<line x1="590" y1="480" x2="770" y2="480" stroke="{ink}" stroke-width="56" stroke-linecap="round"/>'
    return out

def df_terminal():
    """Terminal `$ df` with the sunburst donut as the d's bowl."""
    g = "#7CFFB2"
    cx, cy = 380, 600
    bowl = (f'<path d="{annulus(56, 150, cx, cy)}" fill="url(#dough)" fill-rule="evenodd"/>'
            + sunburst([(64, 104), (108, 146)], cx, cy, gap=0.03))
    body = TILE.format("#0e1116")
    body += '<rect x="100" y="100" width="824" height="96" fill="#1c222b" clip-path="url(#tile)"/>'
    for i, col in enumerate(["#ff5f57", "#febc2e", "#28c840"]):
        body += f'<circle cx="{190 + i*52}" cy="150" r="17" fill="{col}"/>'
    body += f'<g transform="translate(125 40) scale(0.86)">{df_glyphs(g, bowl, cx, cy)}'
    body += f'<rect x="820" y="700" width="34" height="50" fill="{g}" opacity="0.7"/></g>'
    body += '<path d="M190,615 l60,40 l-60,40" fill="none" stroke="#5c6773" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>'
    defs = DOUGH + '<clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>'
    return svg(body, defs)

def df_paper():
    """Light typographic df; the d's bowl is the bitten sunburst donut."""
    ink = "#2b2350"
    cx, cy = 380, 600
    d, b = donut(56, 150, [(64, 104), (108, 146)], cx, cy, a_bite=math.radians(-60), mask_id="dbite")
    body = TILE.format("#fff4e6") + df_glyphs(ink, b, cx, cy)
    body += f'<rect x="820" y="700" width="34" height="50" rx="6" fill="#ff5fa2"/>'
    body += crumbs(150, math.radians(-60), 0.55, "#e2a15e", cx, cy)
    return svg(body, d + DOUGH + SHADOW.format(0.15))

for name, fn in [("sunburst-light", sunburst_light), ("sunburst-bold", sunburst_bold),
                 ("gauge-sunburst", gauge_sunburst), ("gauge-bitten", gauge_bitten),
                 ("df-terminal", df_terminal), ("df-paper", df_paper)]:
    open(os.path.join(OUT, f"{name}.svg"), "w").write(fn())
