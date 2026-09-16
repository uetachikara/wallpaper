#!/bin/bash
# Wikimedia Commons の「Featured pictures（秀逸な画像）」から自然の写真を取得する。
# 使い方: ./fetch-nature.sh [カテゴリあたりの取得枚数] [カテゴリ名...]
#   カテゴリを省略すると、既定の自然カテゴリ一式を巡回する。
#   例: ./fetch-nature.sh 12 "Category:Featured pictures of ice"
#   'search:' で始めると全文検索になる（カテゴリが用意されていない題材向け）。
#   例: ./fetch-nature.sh 14 'search:Milky Way incategory:"Quality images"'
#
# Featured pictures はコミュニティの査読を通った高品質画像のみで、
# 検索でゴミを拾いにくい。ライセンスは CC 系が中心のため、
# 作者とライセンスを media/nature/CREDITS.txt に記録する。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PER="${1:-8}"
shift || true

python3 - "$DIR" "$PER" "$@" <<'PYEOF'
import json, os, random, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

base, per, cli_categories = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
outdir = os.path.join(base, "media", "nature")
os.makedirs(outdir, exist_ok=True)

API = "https://commons.wikimedia.org/w/api.php"
UA = {"User-Agent": "awe-wallpaper/1.0 (personal desktop use)"}

# 畏敬を感じやすい「規模の大きい自然」を軸にカテゴリを選んである
CATEGORIES = [
    "Category:Featured pictures of landscapes",
    "Category:Featured pictures of mountains",
    "Category:Featured pictures of forests",
    "Category:Featured pictures of coasts",
    "Category:Featured pictures of bodies of water",
    "Category:Featured pictures of volcanoes",
    "Category:Featured pictures of natural phenomena",
    "Category:Featured pictures of aurora",
]

MIN_WIDTH = 2560      # 壁紙に使うため画面幅以上を必須にする
MIN_RATIO = 1.2       # 縦長は壁紙で黒帯だらけになるため除外
MAX_RATIO = 2.4       # 横に極端なパノラマは切り抜くと何も残らないため除外
THUMB_WIDTH = 3840    # 原本は数十MBあるため 4K 相当の縮小版を取る
REQUEST_GAP = 0.8     # 連続アクセスで 429 を返されるため間隔を空ける

def api(params, tries=4):
    """Commons API を叩く。429 が返ったら間隔を倍にして待ち直す。"""
    params = {**params, "format": "json", "formatversion": "2"}
    url = API + "?" + urllib.parse.urlencode(params)
    wait = 2.0
    for n in range(tries):
        try:
            time.sleep(REQUEST_GAP)
            return json.load(urllib.request.urlopen(
                urllib.request.Request(url, headers=UA), timeout=60))
        except urllib.error.HTTPError as e:
            if e.code == 429 and n < tries - 1:
                print(f"  混雑のため {wait:.0f} 秒待機します")
                time.sleep(wait)
                wait *= 2
                continue
            raise

def safe_name(title):
    t = title.replace("File:", "")
    t = os.path.splitext(t)[0]
    t = re.sub(r"[^\w\s-]", "", t).strip()[:70]
    return t.replace(" ", "_") or "nature"

def strip_html(s):
    return re.sub(r"<[^>]+>", "", s or "").strip()

credits = []
saved = skipped = 0

for cat in (cli_categories or CATEGORIES):
    try:
        if cat.startswith("search:"):
            # 星景のように専用カテゴリが無い題材は全文検索で拾う
            members = api({"action": "query", "list": "search",
                           "srsearch": cat[len("search:"):],
                           "srnamespace": "6", "srlimit": "40"}
                          )["query"]["search"]
        else:
            members = api({"action": "query", "list": "categorymembers",
                           "cmtitle": cat, "cmtype": "file", "cmlimit": "500"}
                          )["query"]["categorymembers"]
    except Exception as e:
        print(f"  取得失敗: {cat} ({e})")
        continue
    if not members:
        continue

    if not cat.startswith("search:"):
        random.shuffle(members)   # カテゴリは順不同なので毎回違う顔ぶれにする
    picked = 0
    for m in members:
        if picked >= per:
            break
        title = m["title"]
        if not title.lower().endswith((".jpg", ".jpeg", ".png")):
            continue

        try:
            info = api({"action": "query", "titles": title, "prop": "imageinfo",
                        "iiprop": "url|size|extmetadata", "iiurlwidth": str(THUMB_WIDTH)}
                       )["query"]["pages"][0]["imageinfo"][0]
        except Exception:
            continue

        w, h = info.get("width", 0), info.get("height", 1)
        if w < MIN_WIDTH or h == 0 or not (MIN_RATIO <= w / h <= MAX_RATIO):
            skipped += 1
            continue

        url = info.get("thumburl") or info.get("url")
        dst = os.path.join(outdir, safe_name(title) + ".jpg")
        if os.path.exists(dst):
            continue
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=180) as r, open(dst, "wb") as f:
                f.write(r.read())
        except Exception as e:
            print(f"  失敗: {title[:50]} ({e})")
            continue

        meta = info.get("extmetadata", {})
        credits.append("{}\n  作者: {}\n  ライセンス: {}\n  出典: {}\n".format(
            os.path.basename(dst),
            strip_html(meta.get("Artist", {}).get("value")) or "不明",
            strip_html(meta.get("LicenseShortName", {}).get("value")) or "不明",
            "https://commons.wikimedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))))
        print(f"  {os.path.basename(dst)} ({w}x{h}, {os.path.getsize(dst)//1024} KB)")
        saved += 1
        picked += 1

if credits:
    path = os.path.join(outdir, "CREDITS.txt")
    with open(path, "a") as f:
        f.write("\n".join(credits) + "\n")
    print(f"クレジットを追記: {path}")

print(f"{saved} 枚を保存（条件外 {skipped} 枚を除外）")
PYEOF

"$DIR/refresh.sh"
