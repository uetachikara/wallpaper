#!/bin/bash
# NASA APOD（Astronomy Picture of the Day）からランダムに画像を取得して media/ に保存する。
# APOD の画像は原則パブリックドメイン。第1引数で候補件数を指定（既定 30、最大 100）。
# 全画面表示に耐えない低解像度の古いエントリは保存後に破棄する。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
COUNT="${1:-30}"
MIN_WIDTH=1600   # これ未満の横幅は全画面で粗くなるため不採用

python3 - "$DIR" "$COUNT" "$MIN_WIDTH" <<'PYEOF'
import json, os, re, subprocess, sys, urllib.request

base, count, min_width = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
outdir = os.path.join(base, "media", "nasa-apod")
os.makedirs(outdir, exist_ok=True)

def pixel_width(path):
    """macOS の sips で横幅を取得する。読めない場合は 0 を返す。"""
    try:
        out = subprocess.run(["sips", "-g", "pixelWidth", path],
                             capture_output=True, text=True, timeout=20).stdout
        m = re.search(r"pixelWidth:\s*(\d+)", out)
        return int(m.group(1)) if m else 0
    except Exception:
        return 0

# DEMO_KEY は 1時間30回・1日50回の制限あり。多用するなら api.nasa.gov で無料キーを取得する
api = f"https://api.nasa.gov/planetary/apod?api_key=DEMO_KEY&count={count}"
print("APOD の一覧を取得中...")
items = json.load(urllib.request.urlopen(api, timeout=60))

saved = skipped = 0
for it in items:
    if it.get("media_type") != "image":   # YouTube 等の動画エントリは対象外
        continue
    url = it.get("hdurl") or it.get("url")
    if not url:
        continue
    ext = os.path.splitext(url.split("?")[0])[1].lower() or ".jpg"
    # ファイル名がそのままキャプションになるので、タイトルを安全な形に整える
    title = re.sub(r'[^\w\s-]', '', it.get("title", "apod")).strip()[:70]
    name = f"{it.get('date','')}_{title}{ext}".replace(" ", "_")
    path = os.path.join(outdir, name)
    if os.path.exists(path):
        continue
    try:
        urllib.request.urlretrieve(url, path)
    except Exception as e:
        print(f"  失敗: {name} ({e})")
        continue
    w = pixel_width(path)
    if w < min_width:
        os.remove(path)
        skipped += 1
        continue
    saved += 1
    print(f"  保存: {name} ({w}px, {os.path.getsize(path)//1024} KB)")

print(f"{saved} 枚を保存（低解像度 {skipped} 枚を除外）")
PYEOF

"$DIR/refresh.sh"
