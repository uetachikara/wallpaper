#!/bin/bash
# 別の Mac に持ち込んだ Awe 一式をセットアップする。
# 使い方: ./install.sh [間隔秒] [フェード秒] [ズーム量] [動画の表示秒数]
#
# やること:
#   1. 同梱バイナリがその Mac で動くか確認し、動かなければソースから再ビルド
#   2. 壁紙フォルダが空なら素材から生成
#   3. ログイン項目（LaunchAgent）に登録
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "== Awe セットアップ =="
echo "設置先: $DIR"

# --- 1. バイナリの確認と再ビルド ---------------------------------------------
# 配布元と CPU が違う（Apple Silicon / Intel）場合はそのままでは動かない
need_build=0
if [ ! -x "$DIR/bin/awewall" ]; then
  echo "バイナリがありません"
  need_build=1
else
  # 存在しない引数を渡して起動だけ試す。
  # 引数エラーなら終了コード 1、CPU 種別が違って実行できなければ 126 以上が返る
  set +e
  "$DIR/bin/awewall" --__probe__ >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -ge 126 ]; then
    echo "同梱バイナリはこの Mac では動きません（終了コード $rc）"
    need_build=1
  fi
fi

if [ "$need_build" = "1" ]; then
  echo "この Mac 用にビルドし直します"
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "エラー: swiftc が見つかりません。以下を実行してから再試行してください" >&2
    echo "  xcode-select --install" >&2
    exit 1
  fi
  swiftc -O -o "$DIR/bin/awewall" "$DIR/bin/awewall.swift"
  [ -f "$DIR/bin/setwall.swift" ] && swiftc -O -o "$DIR/bin/setwall" "$DIR/bin/setwall.swift"
  echo "ビルド完了"
else
  echo "同梱バイナリをそのまま使います"
fi

# --- 2. 壁紙フォルダの準備 ---------------------------------------------------
count=$(ls "$DIR/wallpaper"/*.jpg "$DIR/wallpaper"/*.mp4 2>/dev/null | wc -l | tr -d ' ')
media_count=$(find "$DIR/media" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.mp4' \) 2>/dev/null | wc -l | tr -d ' ')

if [ "$count" = "0" ] && [ "$media_count" = "0" ]; then
  # clone した直後はどちらも空。何を実行すればよいか示して終わる
  cat >&2 <<'MSG'

素材がありません。先に取得してください。

  ./fetch-nature.sh 8      自然の写真（20分ほどかかる）
  ./fetch-apod.sh 40       宇宙の写真
  ./make-wallpaper.sh      画面サイズに合わせて書き出し

そのあと ./install.sh を再実行してください。
MSG
  exit 1
fi

if [ "$count" = "0" ]; then
  echo "壁紙フォルダが空です。media/ の $media_count 件から生成します"
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "エラー: ffmpeg が必要です（brew install ffmpeg）" >&2
    exit 1
  fi
  "$DIR/make-wallpaper.sh"
  count=$(ls "$DIR/wallpaper"/*.jpg "$DIR/wallpaper"/*.mp4 2>/dev/null | wc -l | tr -d ' ')
fi
echo "壁紙: $count 件"

# --- 3. 常駐登録 -------------------------------------------------------------
"$DIR/backdrop-agent.sh" install "${1:-10}" "${2:-2.5}" "${3:-0.08}" "${4:-30}"
echo
echo "完了。停止するには ./backdrop-agent.sh uninstall"
