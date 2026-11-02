#!/usr/bin/env python3
"""Draws the Noria app icon and the menu bar icon.

The mark is a water wheel (five curved blades around a hub) with water flowing
underneath. The numbers match NoriaMarkGeometry in App/DesignSystem/NoriaMark.swift,
which draws the same mark (animated) inside the app.

Writes:
  App/Resources/Assets.xcassets/AppIcon.appiconset   (light tile, macOS icon grid)
  App/Resources/Assets.xcassets/MenuBarIcon.imageset (black template image)

Usage: python3 Tools/make_app_icon.py   (requires Pillow)
"""
import json, math, os
from PIL import Image, ImageDraw, ImageChops

ROOT = os.path.join(os.path.dirname(__file__), '..')
ASSETS = os.path.join(ROOT, 'App', 'Resources', 'Assets.xcassets')

BLADES = 5
HUB = 0.24      # blades start here
TIP = 0.90      # outer reach
CURL = 72.0     # degrees the spine turns from hub to tip
WIDTH = 0.80    # max half-width (fraction of radius)
LEAN = 0.62     # share of the width on the trailing (counter-clockwise) side

def spine(phi, t):
    r = HUB + (TIP - HUB) * t
    a = math.radians(phi + CURL * t ** 1.15 - 90)
    return (r * math.cos(a), r * math.sin(a))

def leaf(phi, width=WIDTH, lean=LEAN, shift=0.0, n=80):
    """Closed outline of one blade around its spine; rounded at the tip."""
    left, right = [], []
    for i in range(n + 1):
        t = 1 - (1 - i / n) ** 2      # denser samples near the rounded tip
        x, y = spine(phi + shift, t)
        x2, y2 = spine(phi + shift, min(1, t + 1e-3))
        x1, y1 = spine(phi + shift, max(0, t - 1e-3))
        tx, ty = x2 - x1, y2 - y1
        l = math.hypot(tx, ty) or 1
        nx, ny = -ty / l, tx / l          # left normal (counter-clockwise side)
        h = width * (0.30 + 0.70 * t ** 0.8) * math.sqrt(max(0.0, 1 - t ** 3.2))
        left.append((x + nx * h * lean, y + ny * h * lean))
        right.append((x - nx * h * (1 - lean), y - ny * h * (1 - lean)))
    return left + right[::-1]

def wave(r_mid, thick, a_from, a_to, lift=0.10, n=140):
    """A tapered band hugging the bottom of the wheel, rising at its right end."""
    outer, inner = [], []
    for i in range(n + 1):
        u = i / n
        ang = math.radians(a_from + (a_to - a_from) * u - 90)
        r = r_mid + lift * u ** 2
        h = thick * math.sin(math.pi * u) ** 0.7
        outer.append(((r + h / 2) * math.cos(ang), (r + h / 2) * math.sin(ang)))
        inner.append(((r - h / 2) * math.cos(ang), (r - h / 2) * math.sin(ang)))
    return outer, inner

WATER = (0.86, 0.36, 256, 74)
CREST = (0.79, 0.15, 238, 92, 0.12)

def mark(S, rotation=0.0):
    """The Noria mark on a transparent S×S layer: wheel, hub and water."""
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    c = S / 2
    k = S * 0.44
    P = lambda pts: [(c + x * k, c + y * k) for x, y in pts]
    clear = (0, 0, 0, 0)
    def gradient(c1, c2):
        px = Image.linear_gradient('L').resize((S, S)).rotate(45)
        return Image.composite(Image.new('RGBA', (S, S), c2 + (255,)), Image.new('RGBA', (S, S), c1 + (255,)), px)
    blade_fill = gradient((40, 170, 236), (5, 80, 160))
    fold_fill = gradient((150, 225, 250), (36, 150, 225))
    def shape(points, grow=0.0):
        m = Image.new('L', (S, S), 0)
        d = ImageDraw.Draw(m)
        d.polygon(points, fill=255)
        if grow:
            d.line(points + [points[0]], fill=255, width=int(k * grow), joint="curve")
        return m
    for i in range(BLADES):
        phi = rotation + i * 360 / BLADES
        outline = P(leaf(phi))
        layer.paste(clear, (0, 0), shape(outline, grow=0.05))     # gap to the blade below
        body = shape(outline)
        layer.paste(blade_fill, (0, 0), body)
        fold = ImageChops.multiply(shape(P(leaf(phi, width=WIDTH * 0.62, lean=1.0, shift=3))), body)
        layer.paste(fold_fill, (0, 0), fold)
    outer, inner = wave(*WATER[:4])
    water = P(outer + inner[::-1])
    beyond = [(1.6 * math.cos(math.radians(WATER[2] + (WATER[3] - WATER[2]) * i / 140 - 90)),
               1.6 * math.sin(math.radians(WATER[2] + (WATER[3] - WATER[2]) * i / 140 - 90))) for i in range(141)]
    layer.paste(clear, (0, 0), shape(P(outer) + P(beyond)[::-1]))   # nothing peeks out below the water
    layer.paste(clear, (0, 0), shape(water, grow=0.08))
    wmask = shape(water)
    layer.paste(gradient((40, 170, 236), (5, 80, 160)), (0, 0), wmask)
    co, ci = wave(*CREST[:4], lift=CREST[4])
    layer.paste(fold_fill, (0, 0), ImageChops.multiply(shape(P(co + ci[::-1])), wmask))
    d = ImageDraw.Draw(layer)
    ring, core = k * 0.31, k * 0.17
    d.ellipse([c - ring, c - ring, c + ring, c + ring], fill=clear)
    d.ellipse([c - core, c - core, c + core, c + core], fill=(28, 152, 224, 255))
    return layer

def app_icon(size=1024):
    """Light rounded tile with a soft shadow on the macOS icon grid (824 px tile)."""
    S = size * 2
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    inset, radius = int(S * 0.098), int(S * 0.185)
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + S // 100, S - inset, S - inset + S // 100], radius, fill=(10, 40, 80, 60))
    from PIL import ImageFilter
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(S // 70)))
    tile = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(tile).rounded_rectangle([inset, inset, S - inset, S - inset], radius, fill=(255, 255, 255, 255))
    # Subtle top-to-bottom sheen on the tile.
    sheen = Image.linear_gradient('L').resize((S, S)).point(lambda v: 255 - v // 14)
    tint = Image.merge('RGBA', (sheen.point(lambda v: v - 6), sheen.point(lambda v: v - 3), sheen, tile.getchannel('A')))
    img.alpha_composite(tint)
    m = mark(int(S * 0.70))
    offset = (S - m.size[0]) // 2
    img.alpha_composite(m, (offset, offset))
    return img.resize((size, size), Image.LANCZOS)

def menu_bar_icon(px):
    """Black silhouette of the mark for a template image."""
    S = px * 8
    alpha = mark(S).getchannel('A')
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    img.putalpha(alpha)
    return img.resize((px, px), Image.LANCZOS)

def write_app_icon():
    out = os.path.join(ASSETS, 'AppIcon.appiconset')
    os.makedirs(out, exist_ok=True)
    icon = app_icon()
    images = []
    for pt in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            px = pt * scale
            name = f'icon_{pt}x{pt}@{scale}x.png'
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))
            images.append({'idiom': 'mac', 'scale': f'{scale}x', 'size': f'{pt}x{pt}', 'filename': name})
    with open(os.path.join(out, 'Contents.json'), 'w') as f:
        json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1}}, f, indent=2)

def write_menu_bar_icon():
    out = os.path.join(ASSETS, 'MenuBarIcon.imageset')
    os.makedirs(out, exist_ok=True)
    images = []
    for scale in [1, 2]:
        name = f'menubar@{scale}x.png'
        menu_bar_icon(18 * scale).save(os.path.join(out, name))
        images.append({'idiom': 'universal', 'scale': f'{scale}x', 'filename': name})
    with open(os.path.join(out, 'Contents.json'), 'w') as f:
        json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1},
                   'properties': {'template-rendering-intent': 'template'}}, f, indent=2)

if __name__ == '__main__':
    write_app_icon()
    write_menu_bar_icon()
    print('Wrote AppIcon and MenuBarIcon')
