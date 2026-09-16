#!/bin/bash
# 他の Mac へ持ち出すためのアーカイブを作る。
# 使い方:
#   ./package.sh            壁紙のみ同梱（軽い。すぐ使える）
#   ./package.sh --full     素材フォルダ media/ も同梱（再生成やビューア用）
#   ./package.sh --scripts  スクリプトのみ（素材は移動先で取得し直す）
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:---wallpaper}"
OUT="$HOME/Desktop/Awe-$(date +%Y%m%d).tar.gz"

# 常に入れるもの。バイナリのソースも入れて、移動先で再ビルドできるようにする
COMMON=(awe.html install.sh backdrop-agent.sh make-wallpaper.sh refresh.sh import-aerials.sh
        rotate-wallpaper.sh rotation-agent.sh
        settings.sh settings.html settings-server.py
        fetch-apod.sh fetch-nasa.sh fetch-nature.sh bin)

case "$MODE" in
  --full)     TARGETS=("${COMMON[@]}" wallpaper media) ;;
  --wallpaper) TARGETS=("${COMMON[@]}" wallpaper) ;;
  --scripts)  TARGETS=("${COMMON[@]}") ;;
  *) echo "使い方: $0 [--wallpaper|--full|--scripts]" >&2; exit 1 ;;
esac

cd "$DIR"
# ログや状態ファイルは持ち出さない（移動先のパスと食い違うため）
# Apple の Aerial 由来のファイルは著作物なので持ち出さない
tar --exclude=".backdrop.log" --exclude=".rotation.log" --exclude=".last-wallpaper" \
    --exclude=".thumbs" --exclude="aerial_*" --exclude="apple-aerials" \
    -czf "$OUT" "${TARGETS[@]}"

echo "作成: $OUT"
echo "サイズ: $(du -h "$OUT" | cut -f1)"
echo
echo "移動先の Mac での手順:"
echo "  mkdir -p ~/Awe && tar -xzf $(basename "$OUT") -C ~/Awe"
echo "  ~/Awe/install.sh"
