#!/bin/bash
# Apple の配信元から Aerial 映像を取得して取り込む。
#
# 使い方: ./fetch-aerials.sh [分類] [本数上限]
#   分類: nature（既定）/ landscapes / underwater / space / cities / all
#
# 1本ずつ「取得 → 変換 → 元ファイル削除」を繰り返すため、
# 途中で止めても作業済みぶんは残り、ディスクも一時的にしか使わない。
#
# 注意: Apple の著作物なので、このマシンの中だけで使うこと。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KIND="${1:-nature}"
LIMIT="${2:-0}"

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg が必要です" >&2; exit 1; }

python3 -u - "$DIR" "$KIND" "$LIMIT" <<'PYEOF'
import concurrent.futures, json, os, shutil, sys, tempfile, time, urllib.request

base, kind, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
sys.path.insert(0, base)
import aerials

WALL = os.path.join(base, "wallpaper")

# カタログ上の分類。id は entries.json の categories に入っている値
CATEGORY_IDS = {
    "landscapes": "A33A55D9-EDEA-4596-A850-6C10B54FBBB5",
    "cities":     "5EF41171-4862-4F93-800C-AD86CE5E6891",
    "underwater": "8BE8B524-6EAE-43F5-A3E8-01DCFA1BCD4B",
    "space":      "55B7C95D-CEAF-4FD8-ADEF-F5BC657D8F6D",
}
GROUPS = {
    "nature": ["landscapes", "underwater"],
    "all": list(CATEGORY_IDS),
}
wanted_names = GROUPS.get(kind, [kind])
wanted = {CATEGORY_IDS[n] for n in wanted_names if n in CATEGORY_IDS}
if not wanted:
    sys.exit(f"分類が不明です: {kind}（指定できるのは {', '.join(list(CATEGORY_IDS) + list(GROUPS))}）")

manifest = None
for d in aerials.CATALOG_DIRS:
    p = os.path.join(d, "entries.json")
    if os.path.exists(p):
        manifest = p
        break
if not manifest:
    sys.exit("カタログが見つかりません")

names = aerials.catalog()
done = {a["file"] for a in aerials.available(WALL) if a["imported"]}

targets = []
for a in json.load(open(manifest))["assets"]:
    if not (set(a.get("categories", [])) & wanted):
        continue
    url = a.get("url-4K-SDR-240FPS")
    if not url:
        continue
    label = names.get(a["id"], a["id"])
    out_name = aerials.PREFIX + aerials.safe_name(label) + ".mp4"
    if out_name in done:
        continue
    targets.append({"id": a["id"], "name": label, "url": url, "file": out_name})

if limit > 0:
    targets = targets[:limit]

print(f"対象: {len(targets)} 本（分類: {'+'.join(wanted_names)}）")
if not targets:
    sys.exit(0)

tmpdir = tempfile.mkdtemp(prefix="awe-aerial-")
made = failed = 0
started = time.time()

def download(t):
    """1本を一時領域へ取得する。戻り値は (対象, 保存先, エラー)。"""
    tmp = os.path.join(tmpdir, t["id"] + ".mov")
    try:
        req = urllib.request.Request(t["url"], headers={"User-Agent": "awe/1.0"})
        with urllib.request.urlopen(req, timeout=180) as r, open(tmp, "wb") as f:
            shutil.copyfileobj(r, f, 1024 * 1024)
        return t, tmp, None
    except Exception as e:
        if os.path.exists(tmp):
            os.remove(tmp)
        return t, None, str(e)[:120]

try:
    # 変換している間に次を取得しておく。取得87秒・変換39秒と待ち時間が長いため
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(download, targets[0])
        for i, t in enumerate(targets, 1):
            got, tmp, err = pending.result()
            if i < len(targets):
                pending = pool.submit(download, targets[i])

            print(f"[{i}/{len(targets)}] {got['name']}")
            if err:
                print(f"    取得失敗: {err}")
                failed += 1
                continue

            mb = os.path.getsize(tmp) / 1024 / 1024
            t0 = time.time()
            name, cerr = aerials.convert_file(tmp, got["name"], WALL)
            os.remove(tmp)      # 原本は残さない（42GB 級になるため）
            if cerr:
                print(f"    変換失敗: {cerr}")
                failed += 1
                continue
            out_mb = os.path.getsize(os.path.join(WALL, name)) / 1024 / 1024
            print(f"    {mb:.0f} MB → {out_mb:.0f} MB / 変換 {time.time()-t0:.0f} 秒")
            made += 1
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)

print(f"\n{made} 本を追加しました（失敗 {failed} 本 / 所要 {(time.time()-started)/60:.0f} 分）")
if made:
    cfg = os.path.join(base, "config.json")
    if os.path.exists(cfg):
        os.utime(cfg, None)
PYEOF
