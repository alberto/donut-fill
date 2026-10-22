"""Generates assets/logo.svg: a sunburst donut with a bite taken out."""
import colorsys, math, sys

C = 512
GAP = 0.018  # radians between segments

def pt(r, a):
    # angle 0 = 12 o'clock, clockwise
    return C + r * math.sin(a), C - r * math.cos(a)

def arc(r0, r1, a0, a1):
    a0, a1 = a0 + GAP / 2, a1 - GAP / 2
    large = 1 if a1 - a0 > math.pi else 0
    x0, y0 = pt(r1, a0); x1, y1 = pt(r1, a1)
    x2, y2 = pt(r0, a1); x3, y3 = pt(r0, a0)
    return (f"M{x0:.1f},{y0:.1f} A{r1},{r1} 0 {large} 1 {x1:.1f},{y1:.1f} "
            f"L{x2:.1f},{y2:.1f} A{r0},{r0} 0 {large} 0 {x3:.1f},{y3:.1f}Z")

def color(a, depth):
    h = (a / (2 * math.pi) + 0.92) % 1
    s, v = (0.48, 1.0) if depth == 0 else (0.58, 0.93)
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    return f"#{int(r*255):02x}{int(g*255):02x}{int(b*255):02x}"

# (fraction of circle, children fractions within parent; None = empty slot)
tree = [
    (0.30, [0.5, 0.3, None]),
    (0.22, [0.6, 0.25]),
    (0.18, [0.4, 0.4]),
    (0.16, [0.7]),
    (0.14, [0.5, 0.3]),
]

paths = []
a = 0.0
for frac, kids in tree:
    span = frac * 2 * math.pi
    paths.append((arc(132, 222, a, a + span), color(a + span / 2, 0)))
    k = a
    for kf in kids:
        if kf is None:
            break
        ks = kf * span
        paths.append((arc(230, 318, k, k + ks), color(k + ks / 2, 1)))
        k += ks
    a += span

segs = "\n    ".join(f'<path d="{d}" fill="{c}"/>' for d, c in paths)

# bite: three overlapping circles at ~1:30 o'clock
bite_a = math.radians(42)
bites = [(372, bite_a), (338, bite_a - 0.33), (338, bite_a + 0.33)]
bite_circles = "\n      ".join(
    f'<circle cx="{pt(r, ba)[0]:.1f}" cy="{pt(r, ba)[1]:.1f}" r="{rad}"/>'
    for (r, ba), rad in zip(bites, [98, 58, 58]))
crumbs = [(395, bite_a - 0.10, 10), (430, bite_a + 0.06, 7), (402, bite_a + 0.22, 5)]
crumb_svg = "\n  ".join(
    f'<circle cx="{pt(r, ba)[0]:.1f}" cy="{pt(r, ba)[1]:.1f}" r="{s}" fill="#ffd27a" opacity="0.9"/>'
    for r, ba, s in crumbs)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2b2350"/>
      <stop offset="1" stop-color="#141026"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0.55" stop-color="#ff9ad5" stop-opacity="0.22"/>
      <stop offset="1" stop-color="#ff9ad5" stop-opacity="0"/>
    </radialGradient>
    <mask id="bite">
      <rect width="1024" height="1024" fill="white"/>
      <g fill="black">
      {bite_circles}
      </g>
    </mask>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity="0.45"/>
    </filter>
  </defs>
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>
  <circle cx="{C}" cy="{C}" r="400" fill="url(#glow)"/>
  <g mask="url(#bite)" filter="url(#shadow)">
    <path d="M{C-330},{C} a330,330 0 1,0 660,0 a330,330 0 1,0 -660,0 M{C-118},{C} a118,118 0 1,1 236,0 a118,118 0 1,1 -236,0" fill="#e2a15e" fill-rule="evenodd"/>
    <circle cx="{C}" cy="{C}" r="118" fill="none" stroke="#b97a3c" stroke-width="10"/>
    {segs}
  </g>
  {crumb_svg}
</svg>
'''
open(sys.argv[1], "w").write(svg)
