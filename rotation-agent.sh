#!/bin/bash
# 壁紙の自動切り替えを launchd に登録・解除する。
# 使い方:
#   ./rotation-agent.sh install [間隔秒]   既定 900 秒（15分）
#   ./rotation-agent.sh uninstall
#   ./rotation-agent.sh status
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.awe-wallpaper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CMD="${1:-status}"
INTERVAL="${2:-900}"

case "$CMD" in
  install)
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DIR/rotate-wallpaper.sh</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$DIR/.rotation.log</string>
  <key>StandardErrorPath</key><string>$DIR/.rotation.log</string>
</dict>
</plist>
PLISTEOF
    # 既に動いていれば入れ替える
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "登録しました（${INTERVAL}秒ごと）: $PLIST"
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "解除しました"
    ;;
  status)
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      launchctl print "gui/$(id -u)/$LABEL" | grep -E "state|program|run interval" || true
    else
      echo "未登録"
    fi
    ;;
  *)
    echo "使い方: $0 {install [間隔秒]|uninstall|status}" >&2; exit 1 ;;
esac
