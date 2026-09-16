#!/bin/bash
# media/ の画像から壁紙用の一式を wallpaper/ に書き出す。
# macOS の壁紙ローテーションはフォルダ単位で回すため、画面比に合わせた版を別に用意する。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
W="${1:-2560}"; H="${2:-1440}"

python3 - "$DIR" "$W" "$H" <<'PYEOF'
import os, re, shutil, subprocess, sys

base, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
# media/ 配下のフォルダを固定列挙すると、後から増えた分を取りこぼす
media_root = os.path.join(base, "media")
src_dirs = sorted(
    os.path.join(media_root, d) for d in os.listdir(media_root)
    if os.path.isdir(os.path.join(media_root, d)) and not d.startswith(".")
)
out = os.path.join(base, "wallpaper")
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)

TARGET = W / H
MIN_W = 1920          # これ未満は引き伸ばしで粗くなるため不採用
MIN_RATIO = 0.95      # 縦長は左右が黒帯だらけになるため不採用

def size(path):
    out_ = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                          capture_output=True, text=True).stdout
    w = re.search(r"pixelWidth:\s*(\d+)", out_)
    h = re.search(r"pixelHeight:\s*(\d+)", out_)
    return (int(w.group(1)), int(h.group(1))) if w and h else (0, 0)

made = skipped = 0
for d in src_dirs:
    if not os.path.isdir(d):
        continue
    for n in sorted(os.listdir(d)):
        low = n.lower()

        # 動画は画面比に合わせて切り抜き、音声を落として書き出す
        if low.endswith((".mp4", ".m4v", ".mov")):
            src = os.path.join(d, n)
            dst = os.path.join(out, os.path.splitext(n)[0] + ".mp4")
            vf = (f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H}")
            r = subprocess.run(
                ["ffmpeg", "-v", "error", "-i", src, "-vf", vf,
                 "-c:v", "libx264", "-preset", "medium", "-crf", "23",
                 "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                 "-an",                     # 音声は入れない（会社で鳴らさないため）
                 "-y", dst],
                capture_output=True, text=True)
            if r.returncode != 0 or not os.path.exists(dst):
                print(f"  動画の変換失敗: {n}")
                skipped += 1
            else:
                made += 1
            continue

        if not low.endswith((".jpg", ".jpeg", ".png")):
            continue
        src = os.path.join(d, n)
        w, h = size(src)
        if w < MIN_W or h == 0 or w / h < MIN_RATIO:
            skipped += 1
            continue

        # 画面比に近い横長は切り抜いて全面を使う。正方形に近いものは黒帯を付けて全体を残す
        if w / h >= 1.3:
            vf = (f"scale={W}:{H}:force_original_aspect_ratio=increase,"
                  f"crop={W}:{H}")
        else:
            vf = (f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
                  f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:black")

        dst = os.path.join(out, os.path.splitext(n)[0] + ".jpg")
        r = subprocess.run(["ffmpeg", "-v", "error", "-i", src, "-vf", vf,
                            "-q:v", "2", "-frames:v", "1", "-y", dst],
                           capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(dst):
            print(f"  失敗: {n}")
            skipped += 1
            continue
        made += 1

total = sum(os.path.getsize(os.path.join(out, f)) for f in os.listdir(out))
videos = sum(1 for f in os.listdir(out) if f.lower().endswith(".mp4"))
print(f"{made} 件を {W}x{H} で書き出しました"
      f"（うち動画 {videos} 本 / 対象外 {skipped} 件 / 合計 {total//1024//1024} MB）")
print(f"出力先: {out}")
PYEOF
