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
# macOS 26 では利用者ごとの領域に落ちてくる。古い OS 向けに旧パスも見る
VIDEO_DIRS = [
    os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/aerials/videos"),
    "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS",
    "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR",
    "/Library/Application Support/com.apple.idleassetsd/Customer/2KSDR",
    "/Library/Application Support/com.apple.idleassetsd/Customer/4KHDR",
    "/Library/Application Support/com.apple.idleassetsd/Customer/2KHDR",
]
# 名前の対応表。利用者側のほうが新しいので先に見る
CATALOG_DIRS = [
    os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/aerials/manifest"),
    "/Library/Application Support/com.apple.idleassetsd/Customer",
]
SRC = "/Library/Application Support/com.apple.idleassetsd/Customer"
WALL = os.path.join(base, "wallpaper")
LINKS = os.path.join(base, "media", "apple-aerials")
PREFIX = "aerial_"          # 配布物から外すための目印

# 画質の良い順に探す。HDR は色変換が必要になるため SDR を優先する
FOLDER_ORDER = ["4KSDR240FPS", "4KSDR", "2KSDR", "2KAVC", "4KHDR", "2KHDR"]
HDR_FOLDERS = {"4KHDR", "2KHDR"}

# Aerial 素材は 4K・240fps と重いため、負荷と容量を抑える設定にしている
MAX_SECONDS = 60      # ループ再生するので長く持つ必要がない
TARGET_FPS = 30
BITRATE = "6M"

def load_names():
    """映像 ID から日本語名を引けるようにする。取れなければ英語名を使う。"""
    names = {}
    for d in CATALOG_DIRS:
        entries_path = os.path.join(d, "entries.json")
        if not os.path.exists(entries_path):
            continue
        try:
            entries = json.load(open(entries_path))["assets"]
        except (json.JSONDecodeError, KeyError):
            continue

        localized = {}
        strings = os.path.join(d, "TVIdleScreenStrings.bundle", "ja.lproj",
                               "Localizable.nocache.strings")
        if os.path.exists(strings):
            out = subprocess.run(["plutil", "-convert", "json", "-o", "-", strings],
                                 capture_output=True, text=True).stdout
            try:
                localized = json.loads(out)
            except json.JSONDecodeError:
                localized = {}

        for a in entries:
            label = localized.get(a.get("localizedNameKey", ""), "") or a.get("accessibilityLabel", "")
            # ファイル名は id でも shotID でも来る可能性があるので両方引けるようにする
            for key in (a.get("id"), a.get("shotID")):
                if key and key not in names:
                    names[key] = label or key
    return names

def safe(name):
    return re.sub(r"[^\w\sぁ-んァ-ン一-龥ー-]", "", name).strip().replace(" ", "_")[:60] or "aerial"

def find_sources():
    """同じ映像が複数の場所にある場合、先に見つかったほうを使う。"""
    found = {}
    for d in VIDEO_DIRS:
        if not os.path.isdir(d):
            continue
        folder = os.path.basename(d)
        for n in sorted(os.listdir(d)):
            if not n.lower().endswith((".mov", ".mp4")):
                continue
            stem = os.path.splitext(n)[0]
            if stem not in found:
                found[stem] = (os.path.join(d, n), folder)
    return found

def is_hdr(path):
    """HDR かどうかを色特性から判定する。そのまま縮小すると白っぽく潰れるため。"""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=color_transfer", "-of", "csv=p=0", path],
        capture_output=True, text=True).stdout.strip()
    return out in ("smpte2084", "arib-std-b67")

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

def pick_encoder():
    """4K 素材を大量に変換するため、使えるならハードウェア encoder を選ぶ。"""
    out = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"],
                         capture_output=True, text=True).stdout
    if "h264_videotoolbox" in out:
        return ["-c:v", "h264_videotoolbox", "-b:v", BITRATE]
    return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"]

def has_hwaccel():
    out = subprocess.run(["ffmpeg", "-hide_banner", "-hwaccels"],
                         capture_output=True, text=True).stdout
    return "videotoolbox" in out

ENCODER = pick_encoder()
HWACCEL = has_hwaccel()
names = load_names()
sources = find_sources()

def download_state():
    """システムの管理データから、実際に落ちてきた本数を読む。"""
    db = os.path.join(SRC, "..", "Aerial.sqlite")
    db = os.path.normpath(db)
    if not os.path.exists(db):
        return None
    out = subprocess.run(
        ["sqlite3", db,
         "SELECT COUNT(*) FROM ZASSET WHERE ZLASTDOWNLOADED IS NOT NULL;"],
        capture_output=True, text=True)
    try:
        return int(out.stdout.strip())
    except ValueError:
        return None

if not sources:
    downloaded = download_state()
    print("取り込める映像がありません。")
    print()
    if downloaded == 0:
        print("システム側の記録でもダウンロード済みは 0 本でした。")
        print("システム設定 → 壁紙 でサムネイルをクリックしただけでは落ちてきません。")
        print("その壁紙を実際に選び直す（適用する）とダウンロードが始まります。")
        print()
        print("以下も確認してください。")
        print("  ・低電力モードが入っていないか（入っていると保留される）")
        print("  ・ネットワークが従量制課金の設定になっていないか")
        print("  ・数百MBあるため、完了まで数分かかること")
    elif downloaded:
        print(f"システム側は {downloaded} 本を取得済みと記録していますが、")
        print(f"{SRC} 配下に実体が見つかりません。保存先が変わった可能性があります。")
    else:
        print("システム設定 → 壁紙 で使いたい空撮壁紙を選ぶと落ちてきます。")
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

    # 縮小の前にフレームを間引く。240fps のまま拡縮すると無駄に重い
    vf = f"fps={TARGET_FPS},scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H}"
    if folder in HDR_FOLDERS or is_hdr(src):
        # HDR のまま変換すると白っぽく潰れるため、SDR へ落としてから縮小する
        vf = "tonemap=hable," + vf

    cmd = ["ffmpeg", "-v", "error"]
    if HWACCEL:
        cmd += ["-hwaccel", "videotoolbox"]   # 4K のデコードが律速なので効果が大きい
    cmd += ["-i", src, "-t", str(MAX_SECONDS), "-vf", vf,
            *ENCODER,
            "-pix_fmt", "yuv420p", "-movflags", "+faststart",
            "-an",                     # 音声は入れない
            "-y", dst]

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
