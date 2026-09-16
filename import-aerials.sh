#!/bin/bash
# macOS がダウンロード済みの Aerial 壁紙（空撮映像）を取り込む。
#
# システム設定 → 壁紙 で選ぶと、映像が
# /Library/Application Support/com.apple.idleassetsd/Customer/ 配下に落ちてくる。
# それを画面サイズに変換して wallpaper/ へ入れる。
#
# 注意: Apple の著作物なので、このマシンの中だけで使うこと。
#       package.sh と .gitignore で配布物からは除外してある。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
W="${1:-2560}"; H="${2:-1440}"

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg が必要です" >&2; exit 1; }

python3 - "$DIR" "$W" "$H" <<'PYEOF'
import json, os, re, subprocess, sys

base, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
SRC = "/Library/Application Support/com.apple.idleassetsd/Customer"
WALL = os.path.join(base, "wallpaper")
LINKS = os.path.join(base, "media", "apple-aerials")
PREFIX = "aerial_"          # 配布物から外すための目印

# 画質の良い順に探す。HDR は色変換が必要になるため SDR を優先する
FOLDER_ORDER = ["4KSDR240FPS", "4KSDR", "2KSDR", "2KAVC", "4KHDR", "2KHDR"]
HDR_FOLDERS = {"4KHDR", "2KHDR"}

def load_names():
    """映像 ID から日本語名を引けるようにする。取れなければ英語名を使う。"""
    entries = json.load(open(os.path.join(SRC, "entries.json")))["assets"]

    localized = {}
    strings = os.path.join(SRC, "TVIdleScreenStrings.bundle", "ja.lproj",
                           "Localizable.nocache.strings")
    if os.path.exists(strings):
        out = subprocess.run(["plutil", "-convert", "json", "-o", "-", strings],
                             capture_output=True, text=True).stdout
        try:
            localized = json.loads(out)
        except json.JSONDecodeError:
            localized = {}

    names = {}
    for a in entries:
        label = localized.get(a.get("localizedNameKey", ""), "") or a.get("accessibilityLabel", "")
        # ファイル名は id でも shotID でも来る可能性があるので両方引けるようにする
        for key in (a.get("id"), a.get("shotID")):
            if key:
                names[key] = label or key
    return names

def safe(name):
    return re.sub(r"[^\w\sぁ-んァ-ン一-龥ー-]", "", name).strip().replace(" ", "_")[:60] or "aerial"

def find_sources():
    """同じ映像が複数の解像度で落ちている場合、優先度の高い1つだけ選ぶ。"""
    found = {}
    for folder in FOLDER_ORDER:
        d = os.path.join(SRC, folder)
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            if not n.lower().endswith((".mov", ".mp4")):
                continue
            stem = os.path.splitext(n)[0]
            if stem not in found:
                found[stem] = (os.path.join(d, n), folder)
    return found

def probe_fps(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=r_frame_rate", "-of", "csv=p=0", path],
        capture_output=True, text=True).stdout.strip()
    try:
        num, den = out.split("/")
        return float(num) / float(den)
    except (ValueError, ZeroDivisionError):
        return 30.0

names = load_names()
sources = find_sources()

if not sources:
    print("ダウンロード済みの Aerial 映像が見つかりません。")
    print()
    print("システム設定 → 壁紙 で使いたい空撮壁紙をクリックすると、その場で落ちてきます。")
    print("何本か選んでから、もう一度このスクリプトを実行してください。")
    print()
    print(f"カタログには {len(set(names.values()))} 本が登録されています。")
    sys.exit(0)

os.makedirs(LINKS, exist_ok=True)
made = skipped = 0

for stem, (src, folder) in sorted(sources.items()):
    label = names.get(stem, stem)
    out_name = PREFIX + safe(label) + ".mp4"
    dst = os.path.join(WALL, out_name)
    if os.path.exists(dst):
        skipped += 1
        continue

    vf = f"scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H}"
    if folder in HDR_FOLDERS:
        # HDR のまま変換すると白っぽく潰れるため、SDR へ落としてから縮小する
        vf = ("tonemap=hable," + vf)

    cmd = ["ffmpeg", "-v", "error", "-i", src, "-vf", vf,
           "-c:v", "libx264", "-preset", "medium", "-crf", "23",
           "-pix_fmt", "yuv420p", "-movflags", "+faststart",
           "-an",                      # 音声は入れない
           "-y", dst]
    # 高フレームレート素材はそのまま変換すると肥大するので落とす
    if probe_fps(src) > 60:
        cmd[-1:-1] = ["-r", "30"]

    print(f"  変換中: {label}（{folder}）")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(dst):
        print(f"    失敗: {(r.stderr or '').strip()[:150]}")
        skipped += 1
        continue

    # 設定画面でカテゴリ表示するための目印。原本は複製せず参照だけ置く
    link = os.path.join(LINKS, os.path.splitext(out_name)[0] + ".mov")
    if not os.path.lexists(link):
        os.symlink(src, link)

    mb = os.path.getsize(dst) / 1024 / 1024
    print(f"    完了: {out_name}（{mb:.0f} MB）")
    made += 1

print(f"\n{made} 本を取り込みました（既存 {skipped} 本）")
if made:
    # 常駐アプリに一覧の取り直しを促す
    cfg = os.path.join(base, "config.json")
    if os.path.exists(cfg):
        os.utime(cfg, None)
PYEOF
