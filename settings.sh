#!/bin/bash
# 設定画面を開く。終了するまでこのターミナルを占有する（Control-C で終了）。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${AWE_SETTINGS_PORT:-8787}"

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg が必要です（brew install ffmpeg）" >&2; exit 1; }

# サーバーが立ち上がってからブラウザを開く
( for _ in $(seq 40); do
    if curl -s -o /dev/null "http://localhost:$PORT/api/items"; then
      open "http://localhost:$PORT"; break
    fi
    sleep 0.25
  done ) &

exec python3 "$DIR/settings-server.py"
