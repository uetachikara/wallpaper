#!/bin/bash
# NASA Image and Video Library（images-api.nasa.gov）から地球・自然系の画像と短い動画を取得する。
# 使い方: ./fetch-nasa.sh [キーワードあたりの件数] [キーワード...]
#   例:   ./fetch-nasa.sh 6 "aurora from space" "earth limb"
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PER="${1:-5}"; shift || true

# 既定のキーワード。畏敬を感じやすい「地球規模のスケール」を軸に選んである
if [ "$#" -eq 0 ]; then
  set -- "earth from space" "aurora from space" "earthrise" \
         "hurricane from orbit" "milky way night sky" "iss cupola earth"
fi

python3 - "$DIR" "$PER" "$@" <<'PYEOF'
import json, os, re, subprocess, sys, urllib.parse, urllib.request

base, per, queries = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
outdir = os.path.join(base, "media", "nasa-library")
os.makedirs(outdir, exist_ok=True)

MIN_WIDTH = 1600            # 静止画の最小横幅
MAX_VIDEO_MB = 60           # 動画1本の上限サイズ

# ナレーションや字幕が主体の解説動画は休憩用に向かないため題名で除外する
VIDEO_TITLE_NG = re.compile(
    r"whats up|skywatching|tips|explained|explainer|briefing|press|interview|"
    r"news|update|top \d|benefits|how to|why |what is|science of|meet |"
    r"anniversary|celebrat|mission overview|animation of the|trailer|episode",
    re.I)
API = "https://images-api.nasa.gov/search"

def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "awe-viewer/1.0"})
    return json.load(urllib.request.urlopen(req, timeout=60))

def pixel_width(path):
    """macOS の sips で横幅を取得する。読めない場合は 0 を返す。"""
    try:
        out = subprocess.run(["sips", "-g", "pixelWidth", path],
                             capture_output=True, text=True, timeout=20).stdout
        m = re.search(r"pixelWidth:\s*(\d+)", out)
        return int(m.group(1)) if m else 0
    except Exception:
        return 0

def safe_name(title, ext):
    t = re.sub(r'[^\w\s-]', '', title).strip()[:70].replace(" ", "_")
    return f"{t or 'nasa'}{ext}"

def pick_asset(collection_url, media_type):
    """アセット一覧から実際に落とすファイルURLを1つ選ぶ。"""
    assets = get_json(collection_url)
    if media_type == "image":
        # 解像度の高い順に候補を見る
        for suffix in ("~orig.jpg", "~large.jpg", "~medium.jpg"):
            for a in assets:
                if a.lower().endswith(suffix):
                    return a
    else:
        # 原本(~orig.mp4)は数GBになることがあるため中間サイズを優先する
        for suffix in ("~small.mp4", "~mobile.mp4", "~preview.mp4", "~orig.mp4"):
            for a in assets:
                if a.lower().endswith(suffix):
                    return a
    return None

saved = skipped = 0
for q in queries:
    for media_type in ("image", "video"):
        url = f"{API}?{urllib.parse.urlencode({'q': q, 'media_type': media_type})}"
        try:
            items = get_json(url)["collection"]["items"][:per]
        except Exception as e:
            print(f"  検索失敗: {q} / {media_type} ({e})")
            continue

        for it in items:
            data = (it.get("data") or [{}])[0]
            title = data.get("title", q)
            if media_type == "video" and VIDEO_TITLE_NG.search(title):
                skipped += 1
                continue
            try:
                asset = pick_asset(it["href"], media_type)
            except Exception:
                asset = None
            if not asset:
                continue

            ext = ".jpg" if media_type == "image" else ".mp4"
            path = os.path.join(outdir, safe_name(title, ext))
            if os.path.exists(path):
                continue
            try:
                urllib.request.urlretrieve(asset, path)
            except Exception as e:
                print(f"  失敗: {title[:50]} ({e})")
                continue

            mb = os.path.getsize(path) / 1024 / 1024
            if media_type == "image":
                w = pixel_width(path)
                if w < MIN_WIDTH:
                    os.remove(path); skipped += 1; continue
                print(f"  画像: {os.path.basename(path)} ({w}px, {mb:.1f} MB)")
            else:
                if mb > MAX_VIDEO_MB:
                    os.remove(path); skipped += 1; continue
                print(f"  動画: {os.path.basename(path)} ({mb:.1f} MB)")
            saved += 1

print(f"{saved} 件を保存（条件外 {skipped} 件を除外）")
PYEOF

"$DIR/refresh.sh"
