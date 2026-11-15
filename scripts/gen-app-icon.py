#!/usr/bin/env python3
"""生成 iOS App 图标和启动图（不依赖任何在线服务）。

用法：python3 scripts/gen-app-icon.py

- ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png：1024x1024 不透明图标
- ios/App/App/Assets.xcassets/Splash.imageset/splash-*.png：透明背景 + 居中的圆角图标
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / 'ios/App/App/Assets.xcassets/AppIcon.appiconset'
SPLASH = ROOT / 'ios/App/App/Assets.xcassets/Splash.imageset'

SIZE = 1024
TOP = (96, 138, 255)  # #608AFF
BOTTOM = (44, 70, 214)  # #2C46D6


def gradient(size: int) -> Image.Image:
    img = Image.new('RGB', (size, size))
    draw = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        color = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        draw.line([(0, y), (size, y)], fill=color)
    return img


def icon(size: int = SIZE) -> Image.Image:
    img = gradient(size)
    draw = ImageDraw.Draw(img)

    # 白色对话气泡：圆角矩形 + 左下角的小尾巴
    pad = round(size * 0.22)
    bubble = [pad, round(size * 0.2), size - pad, round(size * 0.62)]
    radius = round(size * 0.11)
    draw.rounded_rectangle(bubble, radius=radius, fill=(255, 255, 255))

    tail = round(size * 0.34)
    tail_h = round(size * 0.12)
    draw.polygon(
        [
            (bubble[0] + tail, bubble[3] - round(size * 0.02)),
            (bubble[0] + tail, bubble[3] + tail_h),
            (bubble[0] + tail + round(size * 0.19), bubble[3] - round(size * 0.02)),
        ],
        fill=(255, 255, 255),
    )

    # 气泡里的三个点
    dot_r = round(size * 0.045)
    dot_y = round(size * 0.41)
    for i, cx in enumerate((0.38, 0.5, 0.62)):
        x = round(size * cx)
        draw.ellipse(
            [x - dot_r, dot_y - dot_r, x + dot_r, dot_y + dot_r],
            fill=BOTTOM if i != 1 else TOP,
        )
    return img


def rounded_icon(size: int, radius_ratio: float = 0.22) -> Image.Image:
    tile = icon(size).convert('RGBA')
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=round(size * radius_ratio), fill=255
    )
    tile.putalpha(mask)
    return tile


def splash(canvas: int = 2732, logo: int = 640) -> Image.Image:
    img = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    tile = rounded_icon(logo)
    offset = (canvas - logo) // 2
    img.alpha_composite(tile, (offset, offset))
    return img


def main() -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    SPLASH.mkdir(parents=True, exist_ok=True)

    app_icon = icon()
    app_icon.save(ICONSET / 'AppIcon-512@2x.png')

    shot = splash()
    for name in ('splash-2732x2732.png', 'splash-2732x2732-1.png', 'splash-2732x2732-2.png'):
        shot.save(SPLASH / name)

    print('icon  ->', ICONSET / 'AppIcon-512@2x.png')
    print('splash->', SPLASH)


if __name__ == '__main__':
    main()
