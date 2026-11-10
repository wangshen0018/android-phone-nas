"""生成 Pantry 应用图标。

本体是一个墨绿底 + 米白线条的储物柜：外框、横层板、竖中缝、两个门把。
不用渐变和阴影，缩到 48px 仍然认得出是"柜子"。

输出三套，覆盖各版本 Android：
1. mipmap-*/ic_launcher.png / ic_launcher_round.png   —— 老系统直用，也是兜底
2. mipmap-*/ic_launcher_foreground.png               —— Android 8+ 自适应图标前景
3. mipmap-anydpi-v26/ic_launcher.xml                 —— 自适应图标声明

用法（在仓库根执行）：python app/make-icon.py
"""

import os
from PIL import Image, ImageDraw

S = 1024                      # 母图边长
BG = (30, 58, 52)             # 深墨绿
FG = (244, 241, 232)          # 米白

RES = os.path.join("app", "app", "src", "main", "res")
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
# 自适应图标画布是 108dp，按密度换算像素
FG_DENSITIES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def draw_cabinet(bg=None, scale=1.0):
    """画柜体。bg 为 None 时是透明背景，用于自适应图标前景。"""
    img = Image.new("RGBA", (S, S), bg if bg else (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    k = scale
    cx, cy = S / 2, S / 2

    def px(x, y):
        return (cx + (x - S / 2) * k, cy + (y - S / 2) * k)

    def box(x0, y0, x1, y1):
        a, b = px(x0, y0)
        c, e = px(x1, y1)
        return [a, b, c, e]

    lw = max(2, int(22 * k))
    r = 44 * k

    # 柜体外框
    d.rounded_rectangle(box(272, 232, 752, 792), radius=r, outline=FG, width=lw)
    # 上层横板
    d.line([px(272, 452), px(752, 452)], fill=FG, width=lw)
    # 竖中缝（只有下半截，上半是通长的开放格）
    d.line([px(512, 452), px(512, 792)], fill=FG, width=lw)
    # 两个门把，靠近中缝的竖条
    d.line([px(452, 540), px(452, 680)], fill=FG, width=lw)
    d.line([px(572, 540), px(572, 680)], fill=FG, width=lw)

    return img


def circle_mask(size):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse([0, 0, size - 1, size - 1], fill=255)
    return m


def main():
    square = draw_cabinet(bg=BG)
    # 圆形版整体收一点，裁成圆时不切到柜子边角
    round_src = draw_cabinet(bg=BG, scale=0.84)
    fore = draw_cabinet(bg=None)

    for name, size in DENSITIES.items():
        d = os.path.join(RES, "mipmap-" + name)
        os.makedirs(d, exist_ok=True)

        square.resize((size, size), Image.LANCZOS).save(
            os.path.join(d, "ic_launcher.png"))

        rd = round_src.resize((size, size), Image.LANCZOS)
        rd.putalpha(circle_mask(size))
        rd.save(os.path.join(d, "ic_launcher_round.png"))

    for name, size in FG_DENSITIES.items():
        d = os.path.join(RES, "mipmap-" + name)
        fore.resize((size, size), Image.LANCZOS).save(
            os.path.join(d, "ic_launcher_foreground.png"))

    # 自适应图标声明：背景用纯色，前景用上面那套 PNG
    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    xml = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""
    for fn in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, fn), "w", encoding="utf-8", newline="\n") as f:
            f.write(xml)

    vals = os.path.join(RES, "values")
    os.makedirs(vals, exist_ok=True)
    with open(os.path.join(vals, "colors.xml"), "w", encoding="utf-8", newline="\n") as f:
        f.write("""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#1E3A34</color>
</resources>
""")

    square.save(os.path.join("app", "app", "icon-pantry-1024.png"))
    print("ok: mipmap 各密度 + 自适应图标 + 母图")


if __name__ == "__main__":
    main()
