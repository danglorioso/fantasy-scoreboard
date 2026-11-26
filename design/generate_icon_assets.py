#!/usr/bin/env python3
"""Generate the tvOS app icon layers and Top Shelf images.

Draws everything as SVG and rasterizes with `rsvg-convert` (librsvg), so the
artwork can be tweaked here and regenerated at every required size.

    python3 design/generate_icon_assets.py            # write into the asset catalog
    python3 design/generate_icon_assets.py --out DIR  # write somewhere else (previews)
"""
import argparse
import math
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "FantasyOverlay", "Assets.xcassets",
                     "App Icon & Top Shelf Image.brandassets")

# ---------------------------------------------------------------- football ---
BALL_ANGLE = -28          # degrees, screen space
BALL_TIP = 340            # half length (local units)
BALL_CTRL = (300, 290)    # cubic control point -> half width ~= 0.75 * 290
BALL_D = (f"M {-BALL_TIP},0 "
          f"C {-BALL_CTRL[0]},{-BALL_CTRL[1]} {BALL_CTRL[0]},{-BALL_CTRL[1]} {BALL_TIP},0 "
          f"C {BALL_CTRL[0]},{BALL_CTRL[1]} {-BALL_CTRL[0]},{BALL_CTRL[1]} {-BALL_TIP},0 Z")


def seam_y(x, depth):
    """y on the quadratic seam from tip to tip that dips `depth` at the middle."""
    s = x / BALL_TIP
    return -depth * (1 - s * s)


def lace_bar_path():
    pts = [(x, seam_y(x, 48)) for x in range(-128, 129, 8)]
    return "M " + " L ".join(f"{x:.1f},{y:.1f}" for x, y in pts)


def football(cx, cy, uid):
    """Football + soft shadow, centered at (cx, cy) in the caller's space."""
    t = f"translate({cx},{cy}) rotate({BALL_ANGLE})"
    # Big, bold cross-stitches (as in the original art), following the seam curve.
    stitches = []
    for x in (-100, -50, 0, 50, 100):
        y = seam_y(x, 48)
        slope = math.degrees(math.atan(96 * x / BALL_TIP ** 2))
        stitches.append(
            f'<rect x="{x - 11}" y="{y - 50}" width="22" height="100" rx="4" '
            f'transform="rotate({slope:.2f} {x} {y:.1f})"/>')
    stitches = "\n        ".join(stitches)
    return f"""
  <defs>
    <clipPath id="ballClip{uid}"><path transform="{t}" d="{BALL_D}"/></clipPath>
    <!-- leather grain: fine pebbles plus a broader mottling -->
    <filter id="pebble{uid}" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency="0.32" numOctaves="1" seed="7" result="n"/>
      <feColorMatrix in="n" type="matrix" values="0 0 0 0 0.18  0 0 0 0 0.07  0 0 0 0 0.02  0 0 0 -6 3.4"/>
    </filter>
    <filter id="pebbleLight{uid}" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency="0.32" numOctaves="1" seed="21"/>
      <feColorMatrix type="matrix" values="0 0 0 0 0.85  0 0 0 0 0.55  0 0 0 0 0.35  0 0 0 -6 3.3"/>
    </filter>
    <filter id="mottle{uid}" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency="0.018" numOctaves="3" seed="4"/>
      <feColorMatrix type="matrix" values="0 0 0 0 0.25  0 0 0 0 0.1  0 0 0 0 0.03  0 0 0 -1.6 0.9"/>
    </filter>
    <filter id="soft{uid}" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="22"/>
    </filter>
    <filter id="laceShadow{uid}" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0.5" dy="4" stdDeviation="1.5" flood-color="#2a1004" flood-opacity="0.45"/>
    </filter>
  </defs>

  <!-- cast shadow onto the field -->
  <path transform="translate({cx + 22},{cy + 40}) rotate({BALL_ANGLE}) scale(0.97 0.9)" d="{BALL_D}"
        fill="#000" opacity="0.45" filter="url(#soft{uid})"/>

  <g clip-path="url(#ballClip{uid})">
    <rect x="{cx - 420}" y="{cy - 420}" width="840" height="840" fill="#8b4a22"/>
    <rect x="{cx - 420}" y="{cy - 420}" width="840" height="840" filter="url(#mottle{uid})" opacity="0.35"/>
    <rect x="{cx - 420}" y="{cy - 420}" width="840" height="840" filter="url(#pebble{uid})" opacity="0.55"/>
    <rect x="{cx - 420}" y="{cy - 420}" width="840" height="840" filter="url(#pebbleLight{uid})" opacity="0.22"/>
    <g transform="{t}">
      <!-- panel seams -->
      <path d="M {-BALL_TIP},0 Q 0,{-96} {BALL_TIP},0" fill="none" stroke="#3a1606" stroke-width="5" opacity="0.6"/>
      <path d="M {-BALL_TIP},0 Q 0,290 {BALL_TIP},0" fill="none" stroke="#3a1606" stroke-width="5" opacity="0.5"/>
      <!-- stripes wrap around the ball -->
      <g fill="none" stroke="#f4f4f4" stroke-width="30">
        <path d="M 222,-320 Q 268,0 222,320"/>
        <path d="M -222,-320 Q -268,0 -222,320"/>
      </g>
      <!-- laces -->
      <g fill="#f4f4f4" filter="url(#laceShadow{uid})">
        <path d="{lace_bar_path()}" fill="none" stroke="#f4f4f4" stroke-width="22" stroke-linecap="butt"/>
        {stitches}
      </g>
    </g>
  </g>
  <!-- rim -->
  <path transform="{t}" d="{BALL_D}" fill="none" stroke="#5c2e16" stroke-width="14"/>
"""


# ------------------------------------------------------------------ badge ---
def badge(cx, cy, r, uid):
    fs = r * 1.08
    return f"""
  <defs>
    <linearGradient id="face{uid}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#6fe36b"/>
      <stop offset="1" stop-color="#25b842"/>
    </linearGradient>
    <!-- edge light: bright rim on top fading out, faint darker rim at bottom -->
    <linearGradient id="edge{uid}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.75"/>
      <stop offset="0.35" stop-color="#ffffff" stop-opacity="0"/>
      <stop offset="1" stop-color="#0b4d17" stop-opacity="0.35"/>
    </linearGradient>
    <filter id="badgeShadow{uid}" x="-50%" y="-50%" width="200%" height="200%">
      <feDropShadow dx="0" dy="{r * 0.06:.1f}" stdDeviation="{r * 0.09:.1f}" flood-color="#000" flood-opacity="0.35"/>
    </filter>
    <filter id="glyphShadow{uid}" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="{r * 0.02:.1f}" stdDeviation="{r * 0.03:.1f}" flood-color="#0b5a1c" flood-opacity="0.35"/>
    </filter>
  </defs>
  <circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#face{uid})" filter="url(#badgeShadow{uid})"/>
  <circle cx="{cx}" cy="{cy}" r="{r - r * 0.015:.1f}" fill="none" stroke="url(#edge{uid})" stroke-width="{r * 0.03:.1f}"/>
  <text x="{cx - r * 0.03}" y="{cy + fs * 0.36}" text-anchor="middle"
        font-family="Inter Display" font-weight="800" font-size="{fs:.0f}" letter-spacing="{-fs * 0.03:.1f}"
        fill="#ffffff" filter="url(#glyphShadow{uid})">+6</text>
"""



# ------------------------------------------------------------------ field ---
def field(w, h, spacing, uid, perspective=True):
    vp_x, vp_y = w / 2, -h * 3.2     # vanishing point far above the frame
    # Perspective: yard lines converge toward the vanishing point; otherwise perfectly vertical.
    k = -vp_y / (h - vp_y) if perspective else 1.0
    n = int(w / spacing) + 4
    xs = [w / 2 + (i - n / 2) * spacing for i in range(n + 1)]

    def top(xb):
        return vp_x + (xb - vp_x) * k

    bands, lines = [], []
    for i in range(n):
        x0, x1 = xs[i], xs[i + 1]
        if i % 2 == 0:
            bands.append(f'<polygon points="{top(x0):.1f},0 {top(x1):.1f},0 {x1:.1f},{h} {x0:.1f},{h}"/>')
    for x in xs:
        lines.append(f'<line x1="{top(x):.1f}" y1="0" x2="{x:.1f}" y2="{h}"/>')
    # hash marks: short ticks along each yard line in two rows
    ticks = []
    for i in range(n):
        x0, x1 = xs[i], xs[i + 1]
        for row in (0.36, 0.7):
            y = h * row
            # interpolate x at this y on both lines
            def at(xb):
                return top(xb) + (xb - top(xb)) * (y / h)
            a, b = at(x0), at(x1)
            for j in range(1, 5):
                tx = a + (b - a) * j / 5
                # Aim each tick at the vanishing point so it runs parallel to the yard lines.
                slope = (tx - vp_x) / (y - vp_y) if perspective else 0.0
                d = h * 0.018
                ticks.append(f'<line x1="{tx - d * slope:.1f}" y1="{y - d:.1f}" '
                             f'x2="{tx + d * slope:.1f}" y2="{y + d:.1f}"/>')

    lw = max(2.0, h / 256)
    return f"""
  <defs>
    <linearGradient id="sky{uid}" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#16294f"/>
      <stop offset="0.5" stop-color="#0c1834"/>
      <stop offset="1" stop-color="#050a16"/>
    </linearGradient>
    <radialGradient id="lights{uid}" gradientUnits="userSpaceOnUse" cx="{w / 2}" cy="{-h * 0.25}" r="{max(w, h) * 0.65}">
      <stop offset="0" stop-color="#7fa6ff" stop-opacity="0.38"/>
      <stop offset="0.5" stop-color="#4a6fc0" stop-opacity="0.1"/>
      <stop offset="1" stop-color="#4a6fc0" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="vignette{uid}" gradientUnits="userSpaceOnUse" cx="{w / 2}" cy="{h * 0.45}" r="{math.hypot(w, h) * 0.6}">
      <stop offset="0.55" stop-color="#000" stop-opacity="0"/>
      <stop offset="1" stop-color="#000" stop-opacity="0.6"/>
    </radialGradient>
    <linearGradient id="lineFade{uid}" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="{h}">
      <stop offset="0" stop-color="#7fc8a8" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#5fa888" stop-opacity="0.25"/>
    </linearGradient>
    <filter id="grain{uid}" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency="{0.9 * 768 / h:.3f}" numOctaves="2" seed="3"/>
      <feColorMatrix type="matrix" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 -1.8 1.05"/>
    </filter>
    <filter id="lineGlow{uid}" x="-10%" y="-10%" width="120%" height="120%">
      <feGaussianBlur stdDeviation="{h / 110:.1f}"/>
    </filter>
  </defs>
  <rect width="{w}" height="{h}" fill="url(#sky{uid})"/>
  <g fill="#3fa37f" opacity="0.07">{''.join(bands)}</g>
  <g stroke="#7fd0ad" stroke-width="{lw * 3:.1f}" opacity="0.35" filter="url(#lineGlow{uid})">{''.join(lines)}</g>
  <g stroke="url(#lineFade{uid})" stroke-width="{lw:.1f}">{''.join(lines)}</g>
  <g stroke="#7fc8a8" stroke-width="{lw * 0.8:.1f}" opacity="0.14">{''.join(ticks)}</g>
  <rect width="{w}" height="{h}" fill="url(#lights{uid})"/>
  <rect width="{w}" height="{h}" filter="url(#grain{uid})" opacity="0.05"/>
  <rect width="{w}" height="{h}" fill="url(#vignette{uid})"/>
"""


# ------------------------------------------------------------- documents ---
def svg(w, h, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}">{body}</svg>')


def icon_front():
    # 1280x768 design frame; same composition as the original icon.
    return svg(1280, 768, football(550, 388, "f") + badge(948, 230, 170, "f"))


def icon_back():
    return svg(1280, 768, field(1280, 768, 128, "b", perspective=False))


def top_shelf(w, h, ball_c, scale, title_x, title_size, sub_size):
    # Place the 1280x768 front artwork, scaled, so the ball lands at ball_c.
    gx, gy = ball_c[0] - 550 * scale, ball_c[1] - 388 * scale
    art = f'<g transform="translate({gx:.1f},{gy:.1f}) scale({scale})">' \
          f'{football(550, 388, "t")}{badge(948, 230, 170, "t")}</g>'
    # Center the title + subtitle block vertically: from the title's cap height
    # (~0.73 em in Inter Display) down to the subtitle's x-height midline.
    sub_gap = title_size * 0.78           # title baseline -> subtitle baseline
    cap = title_size * 0.73
    ty = h / 2 + (cap - sub_gap + sub_size * 0.27) / 2
    text = f"""
  <defs>
    <linearGradient id="titleFill" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#d6e2f2"/>
    </linearGradient>
    <filter id="titleShadow" x="-10%" y="-30%" width="120%" height="160%">
      <feDropShadow dx="0" dy="{title_size * 0.05:.1f}" stdDeviation="{title_size * 0.06:.1f}"
                    flood-color="#000" flood-opacity="0.55"/>
    </filter>
  </defs>
  <text x="{title_x}" y="{ty:.0f}" font-family="Inter Display" font-weight="800" font-size="{title_size}"
        letter-spacing="{-title_size * 0.01:.1f}" fill="url(#titleFill)" filter="url(#titleShadow)">Fantasy Overlay</text>
  <text x="{title_x + title_size * 0.04:.0f}" y="{ty + sub_gap:.0f}" font-family="Inter Display" font-weight="600"
        font-size="{sub_size}" fill="#a9bdd6" filter="url(#titleShadow)">Live fantasy alerts over the game</text>
"""
    return svg(w, h, field(w, h, h * 0.278, "t") + art + text)


def render(svg_text, out_path, width, height, opaque):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
        src = f.name
    try:
        subprocess.run(["rsvg-convert", "-w", str(width), "-h", str(height), "-o", out_path, src], check=True)
    finally:
        os.unlink(src)
    if opaque:
        # Back layers and Top Shelf images must not carry alpha.
        from PIL import Image
        Image.open(out_path).convert("RGB").save(out_path, optimize=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="write flat files to this directory instead of the asset catalog")
    args = ap.parse_args()

    def dest(rel):
        if args.out:
            os.makedirs(args.out, exist_ok=True)
            return os.path.join(args.out, os.path.basename(rel))
        return os.path.join(BRAND, rel)

    front, back = icon_front(), icon_back()
    for stack, sizes in (("App Icon.imagestack", [(400, 240), (800, 480)]),
                         ("App Icon - App Store.imagestack", [(1280, 768)])):
        for w, h in sizes:
            render(front, dest(f"{stack}/Front.imagestacklayer/Content.imageset/front-{w}x{h}.png"), w, h, False)
            render(back, dest(f"{stack}/Back.imagestacklayer/Content.imageset/back-{w}x{h}.png"), w, h, True)

    shelf = top_shelf(1920, 720, ball_c=(470, 372), scale=0.88, title_x=1010, title_size=104, sub_size=42)
    for w, h in ((1920, 720), (3840, 1440)):
        render(shelf, dest(f"Top Shelf Image.imageset/topshelf-{w}x{h}.png"), w, h, True)

    wide = top_shelf(2320, 720, ball_c=(520, 372), scale=0.88, title_x=1060, title_size=120, sub_size=46)
    for w, h in ((2320, 720), (4640, 1440)):
        render(wide, dest(f"Top Shelf Image Wide.imageset/topshelf-{w}x{h}.png"), w, h, True)


if __name__ == "__main__":
    main()
