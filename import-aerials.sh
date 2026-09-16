#!/bin/bash
# macOS がダウンロード済みの Aerial 壁紙（空撮映像）をまとめて取り込む。
#
# 1本ずつ選んで取り込むなら設定画面（./settings.sh）を使うほうが分かりやすい。
# こちらは全部まとめて入れたいとき向け。
#
# 使い方: ./import-aerials.sh [横px] [縦px]   既定 2560x1440
#
# 注意: Apple の著作物なので、このマシンの中だけで使うこと。
#       package.sh と .gitignore で配布物からは除外してある。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg が必要です" >&2; exit 1; }

python3 -u - "$DIR" "${1:-2560}" "${2:-1440}" <<'PYEOF'
import os, sys

base, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
sys.path.insert(0, base)
import aerials

wall = os.path.join(base, "wallpaper")
items = aerials.available(wall)

if not items:
    print("取り込める映像がありません。")
    print()
    print("システム設定 → 壁紙 で空撮壁紙を選ぶとダウンロードされます。")
    print("保存先の候補:")
    for d in aerials.VIDEO_DIRS[:2]:
        print(f"  {d.replace(os.path.expanduser('~'), '~')}")
    sys.exit(0)

todo = [a for a in items if not a["imported"]]
print(f"{len(items)} 本のうち、未取り込みは {len(todo)} 本")
if not todo:
    sys.exit(0)

made = failed = 0
for i, a in enumerate(todo, 1):
    print(f"  [{i}/{len(todo)}] {a['name']}")
    name, err = aerials.convert(a["id"], wall, W, H)
    if err:
        print(f"      失敗: {err}")
        failed += 1
        continue
    mb = os.path.getsize(os.path.join(wall, name)) / 1024 / 1024
    print(f"      完了: {name}（{mb:.0f} MB）")
    made += 1

print(f"\n{made} 本を取り込みました（失敗 {failed} 本）")
if made:
    # 常駐アプリに一覧の取り直しを促す
    cfg = os.path.join(base, "config.json")
    if os.path.exists(cfg):
        os.utime(cfg, None)
PYEOF
