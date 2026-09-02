#!/usr/bin/env python3
"""从 Codex pet sprite sheet 生成设备固件用的吉祥物位图。

素材来自 `~/.codex/pets/<id>/spritesheet.webp`(Codex pet v2 格式:8 列 × 11 行,
每行一种动画)。这里只取四帧当状态表情用 —— 不做逐帧动画,因为表情本身就是状态
指示,比动画更有信息量,也不用为帧缓冲额外花内存。

输出 `pet_frames.c`,LV_COLOR_FORMAT_RGB565A8 格式。需要 alpha 通道:设备背景是
蓝天加草地,不透明的矩形位图会切出一个可见的方框。

用法:
    python3 gen_pet_frames.py ~/.codex/pets/fantuan/spritesheet.webp \\
        > /tmp/folo-fw/main/pet_frames.c
"""

import sys
from PIL import Image

# sprite sheet 网格(Codex pet v2 固定 8×11)
CELL_W, CELL_H = 192, 208

# 四帧在网格里的位置。行号对应动画类型,列号是该动画的第几帧;
# 挑的是每种情绪里表达最清楚的那一帧(见 /tmp/pet/picks.png 的对比图)。
PICKS = [
    ("idle",   0, 0),   # 微笑站立 —— 待机
    ("listen", 3, 1),   # 举手 —— 录音中,"我在听"
    ("think",  8, 1),   # 抱手歪头 —— 识别中
    ("sad",    5, 0),   # 难过 —— 电脑断连
]

# 四帧共用的裁剪框,取并集后统一缩放,这样切换表情时人物不会跳动或忽大忽小。
UNION_BOX = (36, 5, 156, 203)
TARGET_H = 104          # 63×104,单帧 19KB,四帧 76KB(app 分区有 2.9MB 空闲)


def emit(sheet_path: str) -> str:
    sheet = Image.open(sheet_path).convert("RGBA")
    box_w = UNION_BOX[2] - UNION_BOX[0]
    box_h = UNION_BOX[3] - UNION_BOX[1]
    target_w = round(box_w * TARGET_H / box_h)

    lines = [
        "// main/pet_frames.c —— 吉祥物位图(生成物,勿手改)",
        "//",
        "// 由 device-firmware/tools/gen_pet_frames.py 从 Codex pet sprite sheet 生成。",
        "// 换表情或换素材就改那个脚本的 PICKS 表后重新生成。",
        "//",
        "// 格式 LV_COLOR_FORMAT_RGB565A8:先 W*H*2 字节 RGB565(小端),紧跟 W*H 字节 alpha。",
        '#include "pet_frames.h"',
        "",
    ]

    for name, row, col in PICKS:
        cell = sheet.crop((col * CELL_W, row * CELL_H,
                           col * CELL_W + CELL_W, row * CELL_H + CELL_H))
        cell = cell.crop(UNION_BOX).resize((target_w, TARGET_H), Image.LANCZOS)
        px = cell.load()

        rgb, alpha = [], []
        for y in range(TARGET_H):
            for x in range(target_w):
                r, g, b, a = px[x, y]
                v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
                rgb += [v & 0xFF, (v >> 8) & 0xFF]
                alpha.append(a)

        data = rgb + alpha
        lines.append(f"static const uint8_t {name}_map[] = {{")
        for i in range(0, len(data), 16):
            lines.append("    " + "".join(f"0x{b:02x}, " for b in data[i:i + 16]).rstrip())
        lines.append("};")
        lines.append(f"""
const lv_image_dsc_t pet_{name} = {{
    .header = {{
        .magic = LV_IMAGE_HEADER_MAGIC,
        .cf = LV_COLOR_FORMAT_RGB565A8,
        .w = {target_w},
        .h = {TARGET_H},
        .stride = {target_w * 2},
    }},
    .data_size = sizeof({name}_map),
    .data = {name}_map,
}};
""")

    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.stdout.write(emit(sys.argv[1]))
