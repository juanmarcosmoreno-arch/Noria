#!/usr/bin/env python3
"""Builds AppIcon.appiconset from the brand artwork (Design/noria-icon-source.webp).

The source is a rendered tile on a white background. This script crops the
tile, re-masks it with a rounded rectangle and places it on a transparent
1024×1024 canvas following the macOS icon grid (824 px tile, 100 px margin,
soft drop shadow), then writes every size macOS needs.

Usage: python3 Tools/make_app_icon.py [source] [appiconset-dir]   (requires Pillow)
"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), '..')
SOURCE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'Design', 'noria-icon-source.webp')
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'App', 'Resources', 'Assets.xcassets', 'AppIcon.appiconset')
# Tile bounds measured on the 1254×1254 source (left, top, right, bottom).
TILE_BOX = (134, 130, 1119, 1111)
CANVAS, TILE, RADIUS = 1024, 824, 185

def build():
    src = Image.open(SOURCE).convert('RGBA')
    scale = src.size[0] / 1254
    box = tuple(int(v * scale) for v in TILE_BOX)
    tile = src.crop(box).resize((TILE, TILE), Image.LANCZOS)
    mask = Image.new('L', (TILE * 4, TILE * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, TILE * 4 - 1, TILE * 4 - 1], RADIUS * 4, fill=255)
    tile.putalpha(mask.resize((TILE, TILE), Image.LANCZOS))

    canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - TILE) // 2
    shadow = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([offset, offset + 10, offset + TILE, offset + TILE + 10], RADIUS, fill=(60, 40, 20, 70))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(tile, (offset, offset))
    return canvas

def main():
    icon = build()
    os.makedirs(OUT, exist_ok=True)
    images = []
    for pt in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            px = pt * scale
            name = f'icon_{pt}x{pt}@{scale}x.png'
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({'idiom': 'mac', 'scale': f'{scale}x', 'size': f'{pt}x{pt}', 'filename': name})
    with open(os.path.join(OUT, 'Contents.json'), 'w') as f:
        json.dump({'images': images, 'info': {'author': 'xcode', 'version': 1}}, f, indent=2)
    print('Wrote', OUT)

if __name__ == '__main__':
    main()
