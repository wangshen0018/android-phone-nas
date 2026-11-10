"""生成两个 App 的图标。

同一个储物柜线稿，用底色区分：
  client（看照片）墨绿 #1E3A34
  server（当库房）深靛蓝 #20304A，右上角多一颗运行指示灯

不用渐变和阴影，缩到 48px 仍认得出是柜子。

每个 App 都出三套：
1. mipmap-*/ic_launcher.png / ic_launcher_round.png   （老系统直用，也是兜底）
2. mipmap-*/ic_launcher_foreground.png               （Android 8+ 自适应前景）
3. mipmap-anydpi-v26/ic_launcher.xml                 （自适应声明）

用法（在仓库根执行）：python apps/make-icon.py
"""

import os
from PIL import Image, ImageDraw

S = 1024
FG = (244, 241, 232)          # 米白
CLIENT_BG = (30, 58, 52)      # 墨绿
SERVER_BG = (32, 48, 74)     # 深靛蓝

DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
FG_DENSITIES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def draw_cabinet(bg=None, scale=1.0, dot=False):
    """画柜体。bg 为 None 时透明，用于自适应图标前景。"""
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

    d.rounded_rectangle(box(272, 232, 752, 792), radius=r, outline=FG, width=lw)
    d.line([px(272, 452), px(752, 452)], fill=FG, width=lw)
    d.line([px(512, 452), px(512, 792)], fill=FG, width=lw)
    d.line([px(452, 540), px(452, 680)], fill=FG, width=lw)
    d.line([px(572, 540), px(572, 680)], fill=FG, width=lw)

    if dot:
        a, b = px(790, 190)
        rad = 46 * k
        d.ellipse([a - rad, b - rad, a + rad, b + rad], fill=FG)
    return img


def circle_mask(size):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).ellipse([0, 0, size - 1, size - 1], fill=255)
    return m


ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""


def emit(res, bg, hex_bg, dot=False, mother=None):
    square = draw_cabinet(bg=bg, dot=dot)
    round_src = draw_cabinet(bg=bg, scale=0.84, dot=dot)
    fore = draw_cabinet(bg=None, dot=dot)

    for name, size in DENSITIES.items():
        d = os.path.join(res, "mipmap-" + name)
        os.makedirs(d, exist_ok=True)
        square.resize((size, size), Image.LANCZOS).save(
            os.path.join(d, "ic_launcher.png"))
        rd = round_src.resize((size, size), Image.LANCZOS)
        rd.putalpha(circle_mask(size))
        rd.save(os.path.join(d, "ic_launcher_round.png"))

    for name, size in FG_DENSITIES.items():
        d = os.path.join(res, "mipmap-" + name)
        fore.resize((size, size), Image.LANCZOS).save(
            os.path.join(d, "ic_launcher_foreground.png"))

    anydpi = os.path.join(res, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    for fn in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, fn), "w", encoding="utf-8", newline="\n") as f:
            f.write(ADAPTIVE_XML)

    vals = os.path.join(res, "values")
    os.makedirs(vals, exist_ok=True)
    with open(os.path.join(vals, "colors.xml"), "w", encoding="utf-8", newline="\n") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<resources>\n'
                '    <color name="ic_launcher_background">%s</color>\n'
                '</resources>\n' % hex_bg)

    if mother:
        square.save(mother)


def main():
    emit(os.path.join("apps", "client", "src", "main", "res"),
         CLIENT_BG, "#1E3A34",
         mother=os.path.join("apps", "client", "icon-pantry-1024.png"))
    emit(os.path.join("apps", "server", "src", "main", "res"),
         SERVER_BG, "#20304A", dot=True,
         mother=os.path.join("apps", "server", "icon-server-1024.png"))
    print("ok: client / server 两套图标")


if __name__ == "__main__":
    main()
