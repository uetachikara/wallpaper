#!/bin/bash
# media/ フォルダを走査して awe.html 内のメディア一覧を作り直す。
# file:// では JS からディレクトリ一覧を取れないため、事前に一覧をHTMLへ埋め込んでおく。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

python3 - "$DIR" <<'PYEOF'
import json, os, re, sys
from urllib.parse import quote

base = sys.argv[1]
media = os.path.join(base, "media")
exts = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif",
        ".mp4", ".m4v", ".mov", ".webm"}

files = []
for root, dirs, names in os.walk(media):
    dirs[:] = sorted(d for d in dirs if not d.startswith("."))  # 隠しフォルダは除外
    for n in sorted(names):
        if n.startswith("."):
            continue
        if os.path.splitext(n)[1].lower() in exts:
            rel = os.path.relpath(os.path.join(root, n), base)
            # file:// で読めるようパス各要素をURLエンコードする
            files.append("/".join(quote(p) for p in rel.split(os.sep)))

html_path = os.path.join(base, "awe.html")
html = open(html_path, encoding="utf-8").read()
block = ("/* AWE_MANIFEST_START — refresh.sh が自動生成。この範囲は手で編集しない */\n"
         "window.AWE_MEDIA = " + json.dumps(files, indent=2, ensure_ascii=False) + ";\n"
         "/* AWE_MANIFEST_END */")
new, n = re.subn(r"/\* AWE_MANIFEST_START.*?AWE_MANIFEST_END \*/", lambda m: block, html, flags=re.S)
if n != 1:
    sys.exit("awe.html にマーカーが見つかりません。awe.html を復元してください。")
open(html_path, "w", encoding="utf-8").write(new)

print(f"{len(files)} 件を awe.html に登録しました")
PYEOF
