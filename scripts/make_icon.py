"""Generates assets/icon.svg: the app icon, a glazed sunburst donut with a bite.

Run: python3 scripts/make_icon.py && scripts/make_icns.sh
"""
import colorsys, math

C = 512
GAP = 0.022            # radians between glaze segments
R_DOUGH = (118, 336)   # inner, outer radius of the pastry ring
R_IN = (148, 236)      # inner glaze ring
R_OUT = (244, 316)     # outer glaze ring (children)

def pt(r, a):
    # angle 0 = 12 o'clock, clockwise
    return C + r * math.sin(a), C - r * math.cos(a)

def arc(r0, r1, a0, a1, gap=GAP):
    a0, a1 = a0 + gap / 2, a1 - gap / 2
    large = 1 if a1 - a0 > math.pi else 0
    x0, y0 = pt(r1, a0); x1, y1 = pt(r1, a1)
    x2, y2 = pt(r0, a1); x3, y3 = pt(r0, a0)
    return (f"M{x0:.1f},{y0:.1f} A{r1},{r1} 0 {large} 1 {x1:.1f},{y1:.1f} "
            f"L{x2:.1f},{y2:.1f} A{r0},{r0} 0 {large} 0 {x3:.1f},{y3:.1f}Z")

def ring(r0, r1):
    return (f"M{C - r1},{C} a{r1},{r1} 0 1,0 {2*r1},0 a{r1},{r1} 0 1,0 {-2*r1},0 "
            f"M{C - r0},{C} a{r0},{r0} 0 1,1 {2*r0},0 a{r0},{r0} 0 1,1 {-2*r0},0")

def hsv(h, s, v):
    r, g, b = colorsys.hsv_to_rgb(h % 1, s, v)
    return f"#{int(r*255):02x}{int(g*255):02x}{int(b*255):02x}"

def color(a, depth):
    h = a / (2 * math.pi) + 0.93
    return hsv(h, 0.50, 1.0) if depth == 0 else hsv(h, 0.60, 0.94)

def shade(a, depth):  # darker tone of the same hue for the segment's lower edge
    h = a / (2 * math.pi) + 0.93
    return hsv(h, 0.70, 0.72) if depth == 0 else hsv(h, 0.78, 0.66)

# (fraction of circle, children fractions within parent)
tree = [
    (0.30, [0.5, 0.3]),
    (0.22, [0.6, 0.25]),
    (0.18, [0.4, 0.4]),
    (0.16, [0.7]),
    (0.14, [0.5, 0.3]),
]

grads, segs = [], []
a = 0.0
n = 0
for frac, kids in tree:
    span = frac * 2 * math.pi
    for (r0, r1, a0, a1, depth) in [(R_IN[0], R_IN[1], a, a + span, 0)] + [
        (R_OUT[0], R_OUT[1], a + sum(kids[:i]) * span, a + sum(kids[:i + 1]) * span, 1)
        for i in range(len(kids))]:
        mid = (a0 + a1) / 2
        gid = f"s{n}"; n += 1
        segs.append(f'<path d="{arc(r0, r1, a0, a1)}" fill="{color(mid, depth)}"/>')
    a += span

# bite: three overlapping circles at ~1:30 o'clock
bite_a = math.radians(42)
bites = [(372, bite_a, 100), (338, bite_a - 0.34, 60), (338, bite_a + 0.34, 60)]
def circles(shrink=0, extra=""):
    return "\n      ".join(
        f'<circle cx="{pt(r, ba)[0]:.1f}" cy="{pt(r, ba)[1]:.1f}" r="{rad - shrink}"{extra}/>'
        for r, ba, rad in bites)

crumbs = [(400, bite_a - 0.12, 11), (436, bite_a + 0.05, 8), (408, bite_a + 0.24, 6), (452, bite_a - 0.04, 4)]
crumb_svg = "\n  ".join(
    f'<circle cx="{pt(r, ba)[0]:.1f}" cy="{pt(r, ba)[1]:.1f}" r="{s}" fill="#f3c98b"/>'
    for r, ba, s in crumbs)

# sprinkles: small rounded bars scattered over the glaze
sprinkles = [(192, 200, 20), (205, 290, -35), (280, 160, 70), (300, 330, 10),
             (170, 250, -70), (288, 20, 40), (210, 40, -20), (295, 100, 85),
             (178, 120, 55), (300, 230, -50), (205, 340, 75)]
spr = []
for r, deg, rot in sprinkles:
    x, y = pt(r, math.radians(deg))
    spr.append(f'<rect x="{x-14:.1f}" y="{y-4.5:.1f}" width="28" height="9" rx="4.5" '
               f'fill="#fffaf0" opacity="0.92" transform="rotate({rot} {x:.1f} {y:.1f})"/>')
spr_svg = "\n    ".join(spr)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3a2d6e"/>
      <stop offset="1" stop-color="#160f2d"/>
    </linearGradient>
    <radialGradient id="bgLight" cx="0.5" cy="0.08" r="0.9">
      <stop offset="0" stop-color="#9b7cff" stop-opacity="0.35"/>
      <stop offset="0.6" stop-color="#9b7cff" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0.6" stop-color="#ff9ad5" stop-opacity="0.28"/>
      <stop offset="1" stop-color="#ff9ad5" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="dough" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#f0bd7a"/>
      <stop offset="0.55" stop-color="#d9964f"/>
      <stop offset="1" stop-color="#a86a2e"/>
    </linearGradient>
    <radialGradient id="doughInner" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0.42" stop-color="#7a4518"/>
      <stop offset="0.5" stop-color="#b97a3c"/>
      <stop offset="0.6" stop-color="#b97a3c" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="gloss" x1="0" y1="0" x2="0.4" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.6"/>
      <stop offset="0.5" stop-color="#ffffff" stop-opacity="0.12"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="glazeShade" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0.35" stop-color="#000" stop-opacity="0"/>
      <stop offset="1" stop-color="#000" stop-opacity="0.14"/>
    </linearGradient>
    <mask id="bite">
      <rect width="1024" height="1024" fill="white"/>
      <g fill="black">
      {circles()}
      </g>
    </mask>
    <mask id="biteRim">
      <rect width="1024" height="1024" fill="white"/>
      <g fill="black">
      {circles(shrink=12)}
      </g>
    </mask>
    <clipPath id="doughClip"><path d="{ring(*R_DOUGH)}" clip-rule="evenodd"/></clipPath>
    <clipPath id="glazeClip"><path d="{ring(R_IN[0], R_OUT[1])}" clip-rule="evenodd"/></clipPath>
    <clipPath id="bgClip"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
    <filter id="shadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="26" stdDeviation="26" flood-color="#06030f" flood-opacity="0.6"/>
    </filter>
    <filter id="softShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="5" stdDeviation="4" flood-color="#000" flood-opacity="0.3"/>
    </filter>
    <filter id="blur"><feGaussianBlur stdDeviation="3"/></filter>
    {chr(10).join("    " + g for g in grads)}
  </defs>

  <!-- background tile -->
  <g clip-path="url(#bgClip)">
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" fill="url(#bgLight)"/>
    <circle cx="512" cy="512" r="420" fill="url(#glow)"/>
  </g>

  <!-- donut -->
  <g mask="url(#bite)" filter="url(#shadow)">
    <!-- pastry -->
    <path d="{ring(*R_DOUGH)}" fill="url(#dough)" fill-rule="evenodd"/>
    <circle cx="512" cy="512" r="{R_DOUGH[0] + 12}" fill="none" stroke="#8c5222" stroke-width="22" opacity="0.55" filter="url(#blur)" clip-path="url(#doughClip)"/>
    <circle cx="512" cy="512" r="{R_DOUGH[1] - 6}" fill="none" stroke="#ffe3b8" stroke-width="6" opacity="0.5" clip-path="url(#doughClip)"/>
    <!-- glaze -->
    <g filter="url(#softShadow)">
    {chr(10).join("    " + s for s in segs)}
    </g>
    <path d="{ring(R_IN[0], R_OUT[1])}" fill="url(#glazeShade)" fill-rule="evenodd"/>
    <!-- gloss highlight across the top of the glaze -->
    <g clip-path="url(#glazeClip)">
      <ellipse cx="400" cy="330" rx="320" ry="190" fill="url(#gloss)" transform="rotate(-30 400 330)"/>
    </g>
    <path d="M{pt(R_OUT[1]-14, math.radians(-62))[0]:.1f},{pt(R_OUT[1]-14, math.radians(-62))[1]:.1f} A{R_OUT[1]-14},{R_OUT[1]-14} 0 0 1 {pt(R_OUT[1]-14, math.radians(-14))[0]:.1f},{pt(R_OUT[1]-14, math.radians(-14))[1]:.1f}" fill="none" stroke="#fff" stroke-width="10" stroke-linecap="round" opacity="0.65"/>
    <!-- sprinkles -->
    {spr_svg}
  </g>
  <!-- exposed crumb along the bite -->
  <g clip-path="url(#doughClip)" mask="url(#biteRim)">
    <g fill="#f6d9a6">
      {circles()}
    </g>
  </g>
  <g filter="url(#softShadow)">
  {crumb_svg}
  </g>
</svg>
'''
open("assets/icon.svg", "w").write(svg)
print("wrote assets/icon.svg")
