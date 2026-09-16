#!/bin/bash
# フェード付き背景アプリ（bin/awewall）を launchd に常駐登録・解除する。
# 使い方:
#   ./backdrop-agent.sh install [間隔秒] [フェード秒] [ズーム量] [動画の表示秒数]
#        既定 10 秒 / 2.5 秒 / 0.08（8%）/ 30 秒。
#        ズーム量に 0 を渡すと静止画のままになる。動画にはズームを掛けない
#   ./backdrop-agent.sh uninstall
#   ./backdrop-agent.sh status
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.awe-backdrop"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CMD="${1:-status}"
INTERVAL="${2:-10}"
FADE="${3:-2.5}"
ZOOM="${4:-0.08}"
VIDEO_INTERVAL="${5:-30}"

case "$CMD" in
  install)
    [ -x "$DIR/bin/awewall" ] || { echo "bin/awewall がありません" >&2; exit 1; }
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DIR/bin/awewall</string>
    <string>--dir</string><string>$DIR/wallpaper</string>
    <string>--interval</string><string>$INTERVAL</string>
    <string>--fade</string><string>$FADE</string>
    <string>--zoom</string><string>$ZOOM</string>
    <string>--video-interval</string><string>$VIDEO_INTERVAL</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/.backdrop.log</string>
  <key>StandardErrorPath</key><string>$DIR/.backdrop.log</string>
</dict>
</plist>
PLISTEOF
    # 二重に敷かれると手前のウインドウだけが見えて挙動が読めなくなる。
    # 常駐を先に外してから、相対パス起動を含む取りこぼしを掃除する
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    pkill -f "bin/awewall" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "登録しました（画像${INTERVAL}秒 / 動画${VIDEO_INTERVAL}秒 / フェード${FADE}秒 / ズーム${ZOOM}）: $PLIST"
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    pkill -f "bin/awewall" 2>/dev/null || true
    rm -f "$PLIST"
    echo "解除しました（元の壁紙に戻ります）"
    ;;
  status)
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      launchctl print "gui/$(id -u)/$LABEL" | grep -E "^\s+(state|program) " || true
      echo "直近のログ:"; tail -3 "$DIR/.backdrop.log" 2>/dev/null || echo "  （なし）"
    else
      echo "未登録"
    fi
    ;;
  *)
    echo "使い方: $0 {install [間隔秒] [フェード秒]|uninstall|status}" >&2; exit 1 ;;
esac
