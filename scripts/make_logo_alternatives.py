"""Generates five alternative logo concepts in assets/alternatives/."""
import math, os, sys

OUT = sys.argv[1]
C = 512

def pt(r, a, cx=C, cy=C):
    return cx + r * math.sin(a), cy - r * math.cos(a)

def ring_arc(r0, r1, a0, a1, cx=C, cy=C):
    large = 1 if a1 - a0 > math.pi else 0
    x0, y0 = pt(r1, a0, cx, cy); x1, y1 = pt(r1, a1, cx, cy)
    x2, y2 = pt(r0, a1, cx, cy); x3, y3 = pt(r0, a0, cx, cy)
    return (f"M{x0:.1f},{y0:.1f} A{r1},{r1} 0 {large} 1 {x1:.1f},{y1:.1f} "
            f"L{x2:.1f},{y2:.1f} A{r0},{r0} 0 {large} 0 {x3:.1f},{y3:.1f}Z")

def annulus(r0, r1, cx=C, cy=C):
    return (f"M{cx-r1},{cy} a{r1},{r1} 0 1,0 {2*r1},0 a{r1},{r1} 0 1,0 {-2*r1},0 "
            f"M{cx-r0},{cy} a{r0},{r0} 0 1,1 {2*r0},0 a{r0},{r0} 0 1,1 {-2*r0},0")

def svg(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
            f'width="1024" height="1024"><defs>{defs}</defs>{body}</svg>\n')

TILE = '<rect x="100" y="100" width="824" height="824" rx="185" fill="{}"/>'

# 1. Gauge — flat, light: frosting fills the donut like a disk-usage meter
def gauge():
    fill_to = math.radians(-135 + 270 * 0.72)
    body = TILE.format("#fff4e6")
    body += f'<path d="{ring_arc(150, 300, math.radians(-135), math.radians(135))}" fill="#f2c48d"/>'
    body += f'<path d="{ring_arc(150, 300, math.radians(-135), fill_to)}" fill="#ff5fa2"/>'
    # round caps
    for a, col in [(-135, "#ff5fa2"), (135, "#f2c48d")]:
        cx, cy = pt(225, math.radians(a))
        body += f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="75" fill="{col}"/>'
    cx, cy = pt(225, fill_to)
    body += f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="75" fill="#ff5fa2"/>'
    # sprinkles on frosting
    for r, a, rot, col in [(250, -80, 30, "#fff"), (190, -30, -40, "#5fd3ff"),
                           (260, 10, 70, "#ffe14d"), (200, 55, 10, "#fff"), (255, -120, -20, "#5fd3ff")]:
        x, y = pt(r, math.radians(a))
        body += (f'<rect x="{x-20:.0f}" y="{y-7:.0f}" width="40" height="14" rx="7" fill="{col}" '
                 f'transform="rotate({rot} {x:.0f} {y:.0f})"/>')
    # needle
    nx, ny = pt(115, fill_to)
    body += f'<line x1="{C}" y1="{C}" x2="{nx:.1f}" y2="{ny:.1f}" stroke="#3a2340" stroke-width="22" stroke-linecap="round"/>'
    body += f'<circle cx="{C}" cy="{C}" r="34" fill="#3a2340"/>'
    return svg(body)

# 2. Platter — a hard-disk platter glazed like a donut, read arm on top
def platter():
    defs = '''<linearGradient id="p-bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#3a4150"/><stop offset="1" stop-color="#14171e"/></linearGradient>
    <linearGradient id="p-metal" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#f4f6fa"/><stop offset="0.45" stop-color="#9aa3b2"/>
      <stop offset="0.55" stop-color="#d9dee7"/><stop offset="1" stop-color="#6b7383"/></linearGradient>
    <linearGradient id="p-glaze" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ff8cc6"/><stop offset="1" stop-color="#e2448f"/></linearGradient>'''
    body = TILE.format("url(#p-bg)")
    body += f'<path d="{annulus(70, 330)}" fill="url(#p-metal)" fill-rule="evenodd"/>'
    # glaze with wavy outer edge
    pts = []
    for i in range(0, 361, 4):
        a = math.radians(i)
        r = 285 + 16 * math.sin(i * math.pi / 22.5)
        pts.append("%.1f,%.1f" % pt(r, a))
    body += f'<path d="M{" L".join(pts)}Z M{C-110},{C} a110,110 0 1,1 220,0 a110,110 0 1,1 -220,0" fill="url(#p-glaze)" fill-rule="evenodd"/>'
    for r in (140, 175, 210, 245):
        body += f'<circle cx="{C}" cy="{C}" r="{r}" fill="none" stroke="#fff" stroke-opacity="0.13" stroke-width="3"/>'
    body += f'<path d="{annulus(70, 110)}" fill="#c3cad6" fill-rule="evenodd"/>'
    body += f'<circle cx="{C}" cy="{C}" r="70" fill="url(#p-bg)"/>'
    # actuator arm
    body += ('<g transform="rotate(-28 790 790)"><rect x="770" y="380" width="40" height="420" rx="20" fill="#e9edf3"/>'
             '<rect x="772" y="360" width="36" height="60" rx="10" fill="#ffd34d"/></g>')
    body += '<circle cx="790" cy="790" r="62" fill="#e9edf3"/><circle cx="790" cy="790" r="26" fill="#9aa3b2"/>'
    return svg(body, defs)

# 3. df — terminal monogram; `df` is the Unix disk-free command, the d's bowl is a donut
def df():
    body = TILE.format("#0e1116")
    body += '<rect x="100" y="100" width="824" height="96" rx="0" fill="#1c222b" clip-path="url(#d-tile)"/>'
    for i, col in enumerate(["#ff5f57", "#febc2e", "#28c840"]):
        body += f'<circle cx="{190 + i*52}" cy="150" r="17" fill="{col}"/>'
    cx, cy = 380, 600
    body += f'<path d="{annulus(62, 150, cx, cy)}" fill="#ff7ab8" fill-rule="evenodd"/>'
    for a, rot, col in [(20, 40, "#fff"), (100, -30, "#ffe14d"), (190, 60, "#5fd3ff"), (260, 0, "#fff"), (320, -50, "#ffe14d")]:
        x, y = pt(106, math.radians(a), cx, cy)
        body += (f'<rect x="{x-17:.0f}" y="{y-6:.0f}" width="34" height="12" rx="6" fill="{col}" '
                 f'transform="rotate({rot} {x:.0f} {y:.0f})"/>')
    g = "#7CFFB2"
    body += f'<rect x="{cx+150-58}" y="300" width="56" height="450" rx="28" fill="{g}"/>'
    # f
    body += f'<path d="M640,750 V420 q0,-110 110,-110 h40" fill="none" stroke="{g}" stroke-width="56" stroke-linecap="round"/>'
    body += f'<line x1="610" y1="480" x2="790" y2="480" stroke="{g}" stroke-width="56" stroke-linecap="round"/>'
    # cursor
    body += f'<rect x="820" y="700" width="34" height="50" fill="{g}" opacity="0.7"/>'
    defs = '<clipPath id="d-tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>'
    return svg(body, defs)

# 4. Box — top-down view of a donut box; empty slots are freed space
def box():
    defs = '''<filter id="b-sh"><feDropShadow dx="0" dy="8" stdDeviation="8" flood-opacity="0.25"/></filter>'''
    body = TILE.format("#7ec8c3")
    body += '<rect x="190" y="190" width="644" height="644" rx="48" fill="#fdf6ea"/>'
    body += '<rect x="190" y="190" width="644" height="644" rx="48" fill="none" stroke="#e6d6bb" stroke-width="10"/>'
    glazes = ["#ff6fa8", "#7a4a2b", None, "#ffd34d", None, "#b48cff", "#ff6fa8", "#5fd3ff", None]
    for i, gz in enumerate(glazes):
        cx = 300 + (i % 3) * 212; cy = 300 + (i // 3) * 212
        if gz is None:
            body += f'<circle cx="{cx}" cy="{cy}" r="82" fill="none" stroke="#e6d6bb" stroke-width="6" stroke-dasharray="14 12"/>'
            continue
        body += f'<g filter="url(#b-sh)"><path d="{annulus(26, 86, cx, cy)}" fill="#e7a862" fill-rule="evenodd"/>'
        body += f'<path d="{annulus(32, 74, cx, cy)}" fill="{gz}" fill-rule="evenodd"/></g>'
        for k in range(4):
            a = math.radians(i * 37 + k * 90)
            x, y = pt(54, a, cx, cy)
            body += (f'<rect x="{x-10:.0f}" y="{y-4:.0f}" width="20" height="8" rx="4" fill="#fff" opacity="0.9" '
                     f'transform="rotate({i*37 + k*90 + 90} {x:.0f} {y:.0f})"/>')
    return svg(body, defs)

# 5. Vortex — sprinkles spiralling down the donut hole like a drain
def vortex():
    defs = '''<radialGradient id="v-bg" cx="0.5" cy="0.5" r="0.7">
      <stop offset="0" stop-color="#5b2a86"/><stop offset="1" stop-color="#1a0b2e"/></radialGradient>
    <radialGradient id="v-ring" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0.3" stop-color="#ff9a5a"/><stop offset="1" stop-color="#ff3d7f"/></radialGradient>
    <radialGradient id="v-hole" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#2a0f45"/></radialGradient>'''
    body = TILE.format("url(#v-bg)")
    body += f'<path d="{annulus(150, 330)}" fill="url(#v-ring)" fill-rule="evenodd"/>'
    body += f'<circle cx="{C}" cy="{C}" r="150" fill="url(#v-hole)"/>'
    cols = ["#ffffff", "#ffe14d", "#5fd3ff", "#7CFFB2", "#ffffff"]
    for arm in range(5):
        for k in range(14):
            t = k / 13
            r = 300 - t * 250
            a = arm * 2 * math.pi / 5 + t * 2.6
            x, y = pt(r, a)
            size = 1 - 0.75 * t
            rot = math.degrees(a) + 60
            body += (f'<rect x="{x-18*size:.1f}" y="{y-6*size:.1f}" width="{36*size:.1f}" height="{12*size:.1f}" '
                     f'rx="{6*size:.1f}" fill="{cols[arm]}" opacity="{1 - 0.6*t:.2f}" '
                     f'transform="rotate({rot:.0f} {x:.1f} {y:.1f})"/>')
    return svg(body, defs)

for name, fn in [("1-gauge", gauge), ("2-platter", platter), ("3-df", df), ("4-box", box), ("5-vortex", vortex)]:
    open(os.path.join(OUT, f"{name}.svg"), "w").write(fn())
