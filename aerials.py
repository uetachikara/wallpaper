#!/usr/bin/env python3
"""macOS の Aerial 壁紙（空撮映像）を扱う共通処理。

import-aerials.sh と settings-server.py の両方から使う。
保存先は OS のバージョンで変わるため、候補を順に探す。
"""

import json
import os
import re
import subprocess

HOME = os.path.expanduser("~")

# 映像の置き場。macOS 26 は利用者ごとの領域、それ以前は共有領域
VIDEO_DIRS = [
    f"{HOME}/Library/Application Support/com.apple.wallpaper/aerials/videos",
    "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS",
    "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR",
    "/Library/Application Support/com.apple.idleassetsd/Customer/2KSDR",
    "/Library/Application Support/com.apple.idleassetsd/Customer/4KHDR",
    "/Library/Application Support/com.apple.idleassetsd/Customer/2KHDR",
]

# 名前の対応表。複数あるので日本語が取れるものを優先する
CATALOG_DIRS = [
    f"{HOME}/Library/Application Support/com.apple.wallpaper/aerials/manifest",
    "/Library/Application Support/com.apple.idleassetsd/Customer",
]

THUMB_DIRS = [
    f"{HOME}/Library/Application Support/com.apple.wallpaper/aerials/thumbnails",
]

PREFIX = "aerial_"        # 配布物から外すための目印

# 4K・240fps と重い素材なので、負荷と容量を抑える
MAX_SECONDS = 60          # ループ再生するので長く持つ必要がない
TARGET_FPS = 30
BITRATE = "6M"


def _localized(catalog_dir):
    """その対応表フォルダの日本語名を読む。無ければ空。"""
    path = os.path.join(catalog_dir, "TVIdleScreenStrings.bundle", "ja.lproj",
                        "Localizable.nocache.strings")
    if not os.path.exists(path):
        return {}
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {}


def catalog():
    """映像 ID から表示名を引く表を作る。

    対応表が複数あるため、日本語名が取れたものを優先する。
    英語名しか無い場合はそれを使う。
    """
    names = {}
    for d in CATALOG_DIRS:
        entries_path = os.path.join(d, "entries.json")
        if not os.path.exists(entries_path):
            continue
        try:
            assets = json.load(open(entries_path))["assets"]
        except (json.JSONDecodeError, KeyError, OSError):
            continue

        loc = _localized(d)
        for a in assets:
            ja = loc.get(a.get("localizedNameKey", ""), "")
            en = a.get("accessibilityLabel", "")
            for key in (a.get("id"), a.get("shotID")):
                if not key:
                    continue
                # 既に日本語で入っていれば上書きしない
                if key in names and names[key]["ja"]:
                    continue
                names[key] = {"ja": ja, "en": en}
    return {k: (v["ja"] or v["en"] or k) for k, v in names.items()}


def safe_name(name):
    """ファイル名に使える形へ整える。日本語はそのまま残す。"""
    cleaned = re.sub(r"[^\w\sぁ-んァ-ヶ一-龥ー－]", "", name).strip()
    return cleaned.replace(" ", "_")[:60] or "aerial"


def thumbnail_path(asset_id):
    for d in THUMB_DIRS:
        p = os.path.join(d, asset_id + ".png")
        if os.path.exists(p):
            return p
    return None


def _probe(path, entries):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", entries, "-of", "csv=p=0", path],
        capture_output=True, text=True).stdout.strip()
    return out.split("\n")[0]


def is_hdr(path):
    """HDR かどうかを色特性から判定する。そのまま縮小すると白っぽく潰れる。"""
    return _probe(path, "stream=color_transfer") in ("smpte2084", "arib-std-b67")


def available(wallpaper_dir):
    """設定画面で扱える映像を一覧する。

    原本が手元にあるもの（取り込める）と、
    原本を消したあとでも変換済みで残っているものの両方を返す。
    """
    names = catalog()
    seen = {}
    taken = set()     # 同じ映像を id と shotID で二重に数えないための控え

    def add(stem, src):
        if stem in seen:
            return
        label = names.get(stem, stem)
        out_name = PREFIX + safe_name(label) + ".mp4"
        if out_name in taken:
            return
        taken.add(out_name)
        seen[stem] = {
            "id": stem,
            "name": label,
            "file": out_name,
            "imported": os.path.exists(os.path.join(wallpaper_dir, out_name)),
            "sizeMB": round(os.path.getsize(src) / 1024 / 1024) if src else 0,
            "hasThumb": thumbnail_path(stem) is not None,
            "hasSource": src is not None,
        }

    for d in VIDEO_DIRS:
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            if n.lower().endswith((".mov", ".mp4")):
                add(os.path.splitext(n)[0], os.path.join(d, n))

    # 原本が無くても、変換済みのものは一覧に残す
    if os.path.isdir(wallpaper_dir):
        converted = {n for n in os.listdir(wallpaper_dir) if n.startswith(PREFIX)}
        for asset_id, label in names.items():
            out_name = PREFIX + safe_name(label) + ".mp4"
            if out_name in converted:
                add(asset_id, None)

    return sorted(seen.values(), key=lambda x: x["name"])


def _encoder():
    out = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"],
                         capture_output=True, text=True).stdout
    if "h264_videotoolbox" in out:
        return ["-c:v", "h264_videotoolbox", "-b:v", BITRATE]
    return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"]


def _hwaccel():
    out = subprocess.run(["ffmpeg", "-hide_banner", "-hwaccels"],
                         capture_output=True, text=True).stdout
    return "videotoolbox" in out


def source_path(asset_id):
    for d in VIDEO_DIRS:
        for ext in (".mov", ".mp4"):
            p = os.path.join(d, asset_id + ext)
            if os.path.exists(p):
                return p
    return None


def convert_file(src, label, wallpaper_dir, width=2560, height=1440):
    """任意の場所にある映像を、表示名を指定して変換する。

    配信元から直接取得した場合など、Apple の保存先に無いものを扱うために使う。
    """
    out_name = PREFIX + safe_name(label) + ".mp4"
    dst = os.path.join(wallpaper_dir, out_name)
    if os.path.exists(dst):
        return out_name, None
    err = _run_convert(src, dst, width, height)
    if err:
        return None, err
    link_marker(wallpaper_dir, out_name, src)
    return out_name, None


def convert(asset_id, wallpaper_dir, width=2560, height=1440):
    """1本を画面サイズへ変換して wallpaper/ に置く。

    戻り値は (出力ファイル名, エラー文字列)。成功時はエラーが None。
    """
    src = source_path(asset_id)
    if not src:
        return None, "元の映像が見つかりません"

    label = catalog().get(asset_id, asset_id)
    out_name = PREFIX + safe_name(label) + ".mp4"
    dst = os.path.join(wallpaper_dir, out_name)
    if os.path.exists(dst):
        return out_name, None

    err = _run_convert(src, dst, width, height)
    if err:
        return None, err
    link_marker(wallpaper_dir, out_name, src)
    return out_name, None


def _run_convert(src, dst, width, height):
    """実際の変換。成功なら None、失敗ならエラー文字列を返す。"""
    # 縮小の前にフレームを間引く。240fps のまま拡縮すると無駄に重い
    vf = (f"fps={TARGET_FPS},scale={width}:{height}:"
          f"force_original_aspect_ratio=increase,crop={width}:{height}")
    if is_hdr(src):
        vf = "tonemap=hable," + vf

    cmd = ["ffmpeg", "-v", "error"]
    if _hwaccel():
        cmd += ["-hwaccel", "videotoolbox"]   # 4K のデコードが律速なので効果が大きい
    cmd += ["-i", src, "-t", str(MAX_SECONDS), "-vf", vf,
            *_encoder(),
            "-pix_fmt", "yuv420p", "-movflags", "+faststart",
            "-an",                            # 音声は入れない
            "-y", dst]

    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(dst):
        if os.path.exists(dst):
            os.remove(dst)
        return (r.stderr or "変換に失敗しました").strip()[:200]
    return None


def link_marker(wallpaper_dir, out_name, src):
    """設定画面でカテゴリ表示するための目印を media/apple-aerials/ に置く。

    原本は数百MBあるため複製せず、シンボリックリンクで参照だけ張る。
    """
    media = os.path.join(os.path.dirname(wallpaper_dir), "media", "apple-aerials")
    os.makedirs(media, exist_ok=True)
    link = os.path.join(media, os.path.splitext(out_name)[0] + ".mov")
    if not os.path.lexists(link):
        os.symlink(src, link)
