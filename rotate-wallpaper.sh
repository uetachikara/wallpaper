#!/bin/bash
# wallpaper/ からランダムに1枚選んで壁紙に設定する。
# 直前の1枚は候補から外し、同じ画像が続けて出ないようにする。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
WALL="$DIR/wallpaper"
STATE="$DIR/.last-wallpaper"
SETTER="$DIR/bin/setwall"

[ -x "$SETTER" ] || { echo "setwall がありません。~/Awe/bin/setwall をビルドしてください" >&2; exit 1; }

last=""
[ -f "$STATE" ] && last="$(cat "$STATE")"

pick="$(find "$WALL" -type f -name '*.jpg' ! -path "$last" | grep -v "^${last}$" | sort -R | head -1)"
[ -n "$pick" ] || { echo "wallpaper/ に画像がありません" >&2; exit 1; }

"$SETTER" "$pick"
printf '%s' "$pick" > "$STATE"
echo "$(basename "$pick")"
