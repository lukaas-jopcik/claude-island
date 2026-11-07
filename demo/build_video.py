#!/usr/bin/env python3
"""Turns demo/raw.mov (from demo/record.sh) into docs/demo.mp4, docs/demo.gif and docs/poster.jpg.

Needs: ffmpeg, Pillow, macOS (San Francisco font). Run: python3 demo/build_video.py
Everything on screen is the real app running on made-up data (see demo/fixture.sh).
"""
import os
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops
import random

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RAW = os.path.join(ROOT, "demo", "raw.mov")
OUT = os.path.join(ROOT, "docs")
TMP = os.path.join(ROOT, "demo", ".build")
os.makedirs(OUT, exist_ok=True)
os.makedirs(TMP, exist_ok=True)

W, H = 1920, 1080
CW, CH = 980, 888            # the "display" the footage plays in
CX, CY = 880, 96
INTRO, OUTRO = 2.0, 2.8
# the cut: (raw start, raw end, playback speed). Only the beats that sell the product, played fast.
SEGMENTS = [(2.0, 6.5, 1.6), (9.0, 13.5, 1.6), (16.2, 20.0, 1.7), (34.9, 47.0, 1.4)]
MAIN = sum((b - a) / s for a, b, s in SEGMENTS)
TOTAL = INTRO + MAIN + OUTRO


def vt(raw_t):
    """Raw-footage time -> time in the final video (clamped into the cut)."""
    off = INTRO
    for a, b, s in SEGMENTS:
        if raw_t <= a:
            return off
        if raw_t <= b:
            return off + (raw_t - a) / s
        off += (b - a) / s
    return off
FONT = "/System/Library/Fonts/SFNS.ttf"
REPO = os.environ.get("ISLAND_REPO_URL", "github.com/lukaas-jopcik/claude-island")

# Catppuccin Mocha, same colours as the app
TEXT, SUB, BASE = (205, 214, 244), (147, 153, 178), (17, 17, 27)
MAUVE, YELLOW, GREEN, TEAL = (203, 166, 247), (249, 226, 175), (166, 227, 161), (148, 226, 213)
SAPPHIRE, BLUE, LAV, PINK = (116, 199, 236), (137, 180, 250), (180, 190, 254), (245, 194, 231)


def font(size, weight="Regular"):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def wrap(draw, text, fnt, width):
    lines, cur = [], ""
    for word in text.split():
        t = (cur + " " + word).strip()
        if draw.textlength(t, font=fnt) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = word
    return lines + [cur]


# --- background -------------------------------------------------------------------------------------------------------
def make_bg():
    random.seed(7)
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(0, W):
            t = (x / W * 0.55 + y / H * 0.45)
            px[x, y] = (int(23 - 14 * t), int(21 - 13 * t), int(34 - 20 * t))
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(glow)
    for (x, y, r, c) in [(420, 180, 560, (110, 80, 170)), (1550, 260, 640, (60, 100, 190)), (900, 1050, 600, (40, 110, 110))]:
        d.ellipse([x - r, y - r, x + r, y + r], fill=c)
    glow = glow.filter(ImageFilter.GaussianBlur(190))
    img = ImageChops.add(img, Image.eval(glow, lambda v: int(v * 0.55)))
    # faint dot grid
    d = ImageDraw.Draw(img, "RGBA")
    for gy in range(40, H, 48):
        for gx in range(40, W, 48):
            d.ellipse([gx - 1, gy - 1, gx + 1, gy + 1], fill=(255, 255, 255, 14))
    # grain
    noise = Image.effect_noise((W, H), 14).convert("RGB")
    img = Image.blend(img, ImageChops.add(img, noise, scale=1, offset=-128), 0.18)
    return img.convert("RGBA")


def rounded_mask(size, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], r, fill=255)
    return m


def make_card_layers():
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    blob = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(blob).rounded_rectangle([CX, CY + 24, CX + CW, CY + CH + 24], 30, fill=(0, 0, 0, 200))
    shadow = Image.alpha_composite(shadow, blob.filter(ImageFilter.GaussianBlur(38)))
    ring = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle([CX, CY, CX + CW, CY + CH], 30, outline=(255, 255, 255, 46), width=2)
    return shadow, ring


# --- captions ---------------------------------------------------------------------------------------------------------
CAPTIONS = [
    # raw start, raw end, tag, colour, title, sub  (times measured from the recording, see demo/record.sh)
    (2.0, 6.5,   "WAITING ON YOU", MAUVE, "Claude asked.\nYou saw it.", "From whatever app you are in, the moment it needs an answer."),
    (9.0, 13.5,  "PERMISSIONS", YELLOW, "Know what it\nwants to run.", "The exact command, so you know what you are saying yes to."),
    (16.2, 20.0, "DONE",      GREEN,   "Done lights up.", "A calm green pulse. No sound, no popups."),
    (34.9, 42.0, "OVERVIEW",  BLUE,    "Every session,\nat a glance.", "Who is working, who is blocked, and your usage limits."),
    (42.0, 47.0, "TASK QUEUES", LAV,   "Queue the work.\nWalk away.", "Verify, then ship. It only stops when it is blocked."),
]


def make_caption(tag, color, title, sub):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x = 112
    ft, fs, fg = font(76, "Bold"), font(31, "Regular"), font(22, "Semibold")
    lines = title.split("\n")
    sub_lines = wrap(d, sub, fs, 650)
    block = 52 + len(lines) * 88 + 30 + len(sub_lines) * 46
    y = (H - block) // 2
    # tag pill
    tw = d.textlength(tag, font=fg) + 3 * len(tag) * 0.6
    d.rounded_rectangle([x, y, x + tw + 62, y + 40], 20, fill=color + (36,), outline=color + (90,), width=1)
    d.ellipse([x + 16, y + 14, x + 28, y + 26], fill=color + (255,))
    cx = x + 42
    for ch in tag:
        d.text((cx, y + 7), ch, font=fg, fill=color + (255,))
        cx += d.textlength(ch, font=fg) + 1.6
    y += 52 + 22
    for ln in lines:
        d.text((x, y), ln, font=ft, fill=TEXT + (255,))
        y += 88
    y += 18
    for ln in sub_lines:
        d.text((x, y), ln, font=fs, fill=SUB + (255,))
        y += 46
    return img


def icon_image(px):
    icns = os.path.join(TMP, "iconset")
    if not os.path.exists(os.path.join(icns, "icon_512x512@2x.png")):
        subprocess.run(["swift", os.path.join(ROOT, "bundle", "icon.swift"), icns], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return Image.open(os.path.join(icns, "icon_512x512@2x.png")).convert("RGBA").resize((px, px), Image.LANCZOS)


def center_text(d, y, text, fnt, fill):
    d.text(((W - d.textlength(text, font=fnt)) / 2, y), text, font=fnt, fill=fill)


def make_title(bg, headline, sub, foot=None):
    img = bg.copy()
    icon = icon_image(300)
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([W / 2 - 240, 170, W / 2 + 240, 650], fill=MAUVE + (95,))
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(110)))
    img.alpha_composite(icon, ((W - 300) // 2, 250))
    d = ImageDraw.Draw(img)
    center_text(d, 590, headline, font(104, "Bold"), TEXT + (255,))
    center_text(d, 725, sub, font(40, "Regular"), SUB + (255,))
    if foot:
        center_text(d, 850, foot, font(30, "Semibold"), BLUE + (255,))
    return img


# --- camera: smooth zoom over the raw footage -------------------------------------------------------------------------------
RAW_W, RAW_H = 1280, 1160
# (raw time, zoom): banners are shown big, the overview and the queue editor need the whole screen
ZOOM = [(0.0, 1.9), (21.4, 1.9), (22.2, 1.3), (33.9, 1.3), (34.9, 1.12), (41.7, 1.12), (42.6, 1.0), (46.6, 1.0), (47.5, 1.5), (60, 1.5)]


def zoom_at(t):
    for (t0, z0), (t1, z1) in zip(ZOOM, ZOOM[1:]):
        if t0 <= t <= t1:
            x = (t - t0) / (t1 - t0)
            return z0 + (z1 - z0) * x * x * (3 - 2 * x)
    return ZOOM[-1][1]


def make_card_video(path):
    """Crops and scales the raw footage per frame (sub-pixel, so the zoom is smooth) into a CW x CH video."""
    k = CW / RAW_W
    enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{CW}x{CH}", "-r", "60",
                            "-i", "-", "-c:v", "libx264", "-preset", "fast", "-crf", "10", "-pix_fmt", "yuv420p", path],
                           stdin=subprocess.PIPE)
    size = RAW_W * RAW_H * 3
    for a, b, speed in SEGMENTS:
        dec = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", str(a), "-t", str(b - a), "-i", RAW,
                                "-vf", f"setpts=PTS/{speed},fps=60",
                                "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
        n = 0
        while True:
            buf = dec.stdout.read(size)
            if len(buf) < size:
                break
            z = zoom_at(a + n / 60 * speed)
            vw, vh = CW / (k * z), CH / (k * z)
            x0 = (RAW_W - vw) / 2
            frame = Image.frombytes("RGB", (RAW_W, RAW_H), buf).resize((CW, CH), Image.LANCZOS, box=(x0, 0, x0 + vw, min(vh, RAW_H)))
            enc.stdin.write(frame.tobytes())
            n += 1
        dec.wait()
    enc.stdin.close()
    enc.wait()


def run(cmd):
    print("+", " ".join(cmd[:6]), "...")
    subprocess.run(cmd, check=True)


def main():
    if not os.path.exists(RAW):
        sys.exit("demo/raw.mov missing: run demo/record.sh first")
    bg = make_bg()
    bg.convert("RGB").save(f"{TMP}/bg.png")
    shadow, ring = make_card_layers()
    shadow.save(f"{TMP}/shadow.png")
    ring.save(f"{TMP}/ring.png")
    rounded_mask((CW, CH), 30).save(f"{TMP}/mask.png")
    make_title(bg, "Claude Island", "Never leave Claude waiting again.").save(f"{TMP}/intro.png")
    make_title(bg, "Claude Island", "Free and open source for macOS.", REPO).save(f"{TMP}/outro.png")
    for i, (_, _, tag, col, title, sub) in enumerate(CAPTIONS):
        make_caption(tag, col, title, sub).save(f"{TMP}/cap{i}.png")

    card = f"{TMP}/card.mp4"
    if not os.path.exists(card) or os.path.getmtime(card) < os.path.getmtime(__file__):
        make_card_video(card)
    ins = ["-framerate", "60", "-loop", "1", "-t", f"{TOTAL}", "-i", f"{TMP}/bg.png",
           "-i", card]
    for name in ["shadow", "mask", "ring"] + [f"cap{i}" for i in range(len(CAPTIONS))] + ["intro", "outro"]:
        ins += ["-framerate", "30", "-loop", "1", "-t", f"{TOTAL}", "-i", f"{TMP}/{name}.png"]
    idx = {"shadow": 2, "mask": 3, "ring": 4}
    cap0 = 5
    intro_i, outro_i = cap0 + len(CAPTIONS), cap0 + len(CAPTIONS) + 1

    g = [f"[0:v]format=rgba[bg]",
         f"[1:v]format=yuva420p[f0]",
         f"[3:v]format=gray[m]",
         f"[f0][m]alphamerge,setpts=PTS+{INTRO}/TB[f1]",
         f"[bg][2:v]overlay=0:0:format=auto[b1]",
         f"[b1][f1]overlay={CX}:{CY}:eof_action=pass:format=auto[b2]",
         f"[b2][4:v]overlay=0:0:format=auto[b3]"]
    last = "b3"
    for i, (a, b, *_rest) in enumerate(CAPTIONS):
        t0, t1 = vt(a), vt(b)
        if i == 0:
            t0 = INTRO - 0.2
        if i == len(CAPTIONS) - 1:
            t1 = INTRO + MAIN + 0.2
        g.append(f"[{cap0 + i}:v]format=rgba,fade=t=in:st={t0:.2f}:d=0.3:alpha=1,fade=t=out:st={t1 - 0.25:.2f}:d=0.25:alpha=1[c{i}]")
        g.append(f"[{last}][c{i}]overlay=0:0:format=auto[o{i}]")
        last = f"o{i}"
    g.append(f"[{intro_i}:v]format=rgba,fade=t=out:st={INTRO - 0.5:.2f}:d=0.5:alpha=1[ti]")
    g.append(f"[{last}][ti]overlay=0:0:format=auto[t1]")
    g.append(f"[{outro_i}:v]format=rgba,fade=t=in:st={TOTAL - OUTRO:.2f}:d=0.5:alpha=1[to]")
    g.append(f"[t1][to]overlay=0:0:format=auto,format=yuv420p[v]")

    out = f"{OUT}/demo.mp4"
    run(["ffmpeg", "-v", "error", "-y", *ins, "-filter_complex", ";".join(g), "-map", "[v]",
         "-t", f"{TOTAL}", "-r", "60", "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
         "-movflags", "+faststart", out])

    # poster (the overview scene) and a README gif of the story without intro/outro
    run(["ffmpeg", "-v", "error", "-y", "-ss", f"{vt(38.0)}", "-i", out, "-frames:v", "1", "-q:v", "3", f"{OUT}/poster.jpg"])
    pal = f"{TMP}/pal.png"
    vf = "fps=15,scale=960:-1:flags=lanczos"
    gt = f"{MAIN:.2f}"
    run(["ffmpeg", "-v", "error", "-y", "-ss", f"{INTRO}", "-t", gt, "-i", out, "-vf", f"{vf},palettegen=max_colors=160:stats_mode=diff", pal])
    run(["ffmpeg", "-v", "error", "-y", "-ss", f"{INTRO}", "-t", gt, "-i", out, "-i", pal, "-lavfi",
         f"{vf}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle", f"{OUT}/demo.gif"])
    print("done:", out)


if __name__ == "__main__":
    main()
