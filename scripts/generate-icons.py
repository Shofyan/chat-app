#!/usr/bin/env python3
"""Render the native vector icon using librsvg's rsvg-convert."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
mobile = root / 'mobile'
source = mobile / 'branding/ruang.svg'

def render(path, size):
    subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), '-o', str(path), str(source)], check=True)

for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    render(mobile / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png', size)

icons = mobile / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
for item in json.loads((icons / 'Contents.json').read_text())['images']:
    if 'filename' in item:
        render(icons / item['filename'], round(float(item['size'].split('x')[0]) * float(item['scale'].rstrip('x'))))

for path in (mobile / 'web/icons').glob('*.png'):
    render(path, int(path.stem.split('-')[-1]))
render(mobile / 'web/favicon.png', 32)
