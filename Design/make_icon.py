#!/usr/bin/env python3
"""Generate the AllMyTokens app icon as an SVG.

Design (after the user's reference): dark navy rounded tile, a gauge arc
sweeping blue (left) into gold (right), a chrome "T" whose diagonal needle
points at the arc with a lens-flare star at the tip, and three blue
"speed lines" below. Uses only CoreSVG-safe features: paths, gradients,
strokes, opacity — no filters, masks or <use>.
"""
import math, os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'icon.svg')

CX, CY, R, W = 512.0, 470.0, 252.0, 54.0   # gauge circle + stroke width

def pt(deg, r=R):
    a = math.radians(deg)
    return (CX + r * math.cos(a), CY + r * math.sin(a))

def arc(d1, d2, r=R):
    """Arc path from angle d1 to d2 (degrees, y-down, increasing = clockwise
    on screen: 90 = bottom, 180 = left, 270 = top, 360 = right)."""
    x1, y1 = pt(d1, r)
    x2, y2 = pt(d2, r)
    large = 1 if (d2 - d1) > 180 else 0
    return f'M{x1:.1f} {y1:.1f} A{r:.1f} {r:.1f} 0 {large} 1 {x2:.1f} {y2:.1f}'

BLUE_ARC = arc(135, 273)     # bottom-left, up over the top
GOLD_ARC = arc(268, 405)     # top, down the right side to bottom-right

# Needle: from beside the stem to the arc's 315-degree point.
TIPX, TIPY = pt(315)                       # (690.2, 291.8)
BX, BY = 467.0, 562.0                      # blade base center
dx, dy = TIPX - BX, TIPY - BY
L = math.hypot(dx, dy)
px_, py_ = -dy / L, dx / L                 # perpendicular unit
HW = 8.0                                   # blade half-width at base
BLADE = (f'M{BX + px_*HW:.1f} {BY + py_*HW:.1f} '
         f'L{TIPX:.1f} {TIPY:.1f} '
         f'L{BX - px_*HW:.1f} {BY - py_*HW:.1f} Z')

def diamond(cx, cy, ang, half_len, half_w):
    a = math.radians(ang)
    d = (math.cos(a), math.sin(a))
    p = (-d[1], d[0])
    pts = [(cx + d[0]*half_len, cy + d[1]*half_len),
           (cx + p[0]*half_w,  cy + p[1]*half_w),
           (cx - d[0]*half_len, cy - d[1]*half_len),
           (cx - p[0]*half_w,  cy - p[1]*half_w)]
    return 'M' + ' L'.join(f'{x:.1f} {y:.1f}' for x, y in pts) + ' Z'

FLARE = ''.join(f'<path d="{d}" fill="#ffffff" opacity="{o}"/>' for d, o in [
    (diamond(TIPX, TIPY,   0, 120, 9), 0.95),
    (diamond(TIPX, TIPY,  90, 120, 9), 0.95),
    (diamond(TIPX, TIPY,  45,  54, 5), 0.85),
    (diamond(TIPX, TIPY, 135,  54, 5), 0.85),
])

def rrect(x, y, w, h, rx, extra=''):
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" {extra}/>'

def line_group(y, w, opacity):
    x = 512 - w / 2
    return (f'<rect x="{x-7}" y="{y-7}" width="{w+14}" height="29" rx="14.5" '
            f'fill="#4a9eff" opacity="{0.15*opacity:.2f}"/>'
            f'<rect x="{x}" y="{y}" width="{w}" height="15" rx="7.5" '
            f'fill="url(#lineBlue)" opacity="{opacity}"/>')

SPEED_LINES = line_group(700, 230, 1.0) + line_group(748, 178, 0.8) + line_group(796, 122, 0.6)

# Chrome T pieces (drawn inside a skew group for the italic slant).
# The stem is drawn first, the needle laid over it, then the crossbar +
# chip on top so the needle passes BEHIND the bar — keeping the T solid.
CHROME = 'fill="url(#silver)" stroke="url(#silver)" stroke-width="10" stroke-linejoin="round"'
NAVY   = 'fill="#141b36" stroke="#141b36" stroke-width="26" stroke-linejoin="round"'
STEM_GROUP = (rrect(492, 360, 88, 285, 6, NAVY)
            + rrect(492, 360, 88, 285, 6, CHROME)
            + rrect(496, 368, 8, 266, 4, 'fill="#ffffff" opacity="0.30"'))
BAR_GROUP = (rrect(330, 352, 96, 62, 6, NAVY)
           + rrect(448, 352, 172, 62, 6, NAVY)
           + rrect(330, 352, 96, 62, 6, CHROME)
           + rrect(448, 352, 172, 62, 6, CHROME)
           + rrect(335, 354, 86, 7, 3.5, 'fill="#ffffff" opacity="0.55"')
           + rrect(453, 354, 162, 7, 3.5, 'fill="#ffffff" opacity="0.55"')
           + rrect(335, 405, 86, 6, 3, 'fill="#2c3654" opacity="0.45"')
           + rrect(453, 405, 162, 6, 3, 'fill="#2c3654" opacity="0.45"'))

SVG = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="512" y1="100" x2="512" y2="924" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#2a3559"/>
    <stop offset="0.45" stop-color="#1b2444"/>
    <stop offset="1" stop-color="#0e152e"/>
  </linearGradient>
  <radialGradient id="vig" cx="512" cy="440" r="640" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#6c86e0" stop-opacity="0.10"/>
    <stop offset="0.55" stop-color="#1b2444" stop-opacity="0"/>
    <stop offset="1" stop-color="#000010" stop-opacity="0.28"/>
  </radialGradient>
  <linearGradient id="blueArc" x1="360" y1="660" x2="500" y2="200" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#2e6fd6"/>
    <stop offset="0.6" stop-color="#5aa8ff"/>
    <stop offset="1" stop-color="#cfe2f8"/>
  </linearGradient>
  <linearGradient id="goldArc" x1="540" y1="200" x2="690" y2="660" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#ecdfc0"/>
    <stop offset="0.5" stop-color="#eccf8e"/>
    <stop offset="1" stop-color="#c49a52"/>
  </linearGradient>
  <linearGradient id="silver" x1="0" y1="340" x2="0" y2="660" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#ffffff"/>
    <stop offset="0.30" stop-color="#eef3fa"/>
    <stop offset="0.55" stop-color="#c3cddf"/>
    <stop offset="0.74" stop-color="#e6ebf4"/>
    <stop offset="1" stop-color="#a9b5c9"/>
  </linearGradient>
  <linearGradient id="blade" x1="{BX}" y1="{BY}" x2="{TIPX:.0f}" y2="{TIPY:.0f}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#c9d4e6"/>
    <stop offset="0.5" stop-color="#f4f8fd"/>
    <stop offset="1" stop-color="#ffffff"/>
  </linearGradient>
  <linearGradient id="lineBlue" x1="380" y1="0" x2="650" y2="0" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#3f8ceb"/>
    <stop offset="1" stop-color="#7cc0ff"/>
  </linearGradient>
  <radialGradient id="flareGlow" cx="{TIPX:.0f}" cy="{TIPY:.0f}" r="98" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.95"/>
    <stop offset="0.35" stop-color="#ffeecb" stop-opacity="0.45"/>
    <stop offset="1" stop-color="#ffeecb" stop-opacity="0"/>
  </radialGradient>
</defs>

<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#bg)"/>

<g fill="none" stroke-linecap="round">
  <path d="{BLUE_ARC}" stroke="#4a9eff" stroke-width="118" opacity="0.07"/>
  <path d="{BLUE_ARC}" stroke="#4a9eff" stroke-width="80" opacity="0.13"/>
  <path d="{GOLD_ARC}" stroke="#eccf8e" stroke-width="118" opacity="0.07"/>
  <path d="{GOLD_ARC}" stroke="#eccf8e" stroke-width="80" opacity="0.13"/>
  <path d="{BLUE_ARC}" stroke="url(#blueArc)" stroke-width="{W}"/>
  <path d="{GOLD_ARC}" stroke="url(#goldArc)" stroke-width="{W}"/>
</g>

{SPEED_LINES}

<g transform="matrix(1,0,-0.158,1,78,0)">
  {STEM_GROUP}
</g>

<path d="{BLADE}" fill="none" stroke="#141b36" stroke-width="5" stroke-linejoin="round" opacity="0.9"/>
<path d="{BLADE}" fill="url(#blade)"/>

<g transform="matrix(1,0,-0.158,1,78,0)">
  {BAR_GROUP}
</g>

<circle cx="{TIPX:.0f}" cy="{TIPY:.0f}" r="98" fill="url(#flareGlow)"/>
{FLARE}
<circle cx="{TIPX:.0f}" cy="{TIPY:.0f}" r="13" fill="#ffffff"/>

<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#vig)"/>
</svg>'''

open(OUT, 'w').write(SVG)
print('wrote', OUT)

# ---------------------------------------------------------------------------
# Foreground-only layer for the Icon Composer (.icon) bundle: same artwork
# minus the tile + vignette (the system supplies the squircle + fill), scaled
# up because .icon layers are full-bleed 1024 rather than the 824 Big Sur tile.

start = SVG.index('<g fill="none" stroke-linecap="round">')
end = SVG.index('<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#vig)"/>')
content = SVG[start:end]
defs_end = SVG.index('</defs>') + len('</defs>')
defs = SVG[SVG.index('<defs>'):defs_end]

FOREGROUND = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
    + defs
    + '<g transform="translate(512 512) scale(1.2) translate(-512 -512)">'
    + content
    + '</g></svg>'
)

fg_path = os.path.join(os.path.dirname(OUT), 'icon_foreground.svg')
open(fg_path, 'w').write(FOREGROUND)
print('wrote', fg_path)
