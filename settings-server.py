#!/usr/bin/env python3
"""設定画面を提供するローカルサーバー。

wallpaper/ の中身をサムネイル付きで一覧し、表示する・しないを選ばせる。
選択結果と表示間隔などは config.json に書き出す。
常駐アプリは config.json の更新時刻を見ているので、保存すれば数秒で反映される。

localhost のみで待ち受ける。外部からは接続できない。
"""

import http.server
import json
import mimetypes
import os
import socketserver
import subprocess
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aerials

BASE = os.path.dirname(os.path.abspath(__file__))
WALLPAPER = os.path.join(BASE, "wallpaper")
MEDIA = os.path.join(BASE, "media")
CONFIG = os.path.join(BASE, "config.json")
THUMBS = os.path.join(BASE, ".thumbs")
PORT = int(os.environ.get("AWE_SETTINGS_PORT", "8787"))

VIDEO_EXT = (".mp4", ".m4v", ".mov")
IMAGE_EXT = (".jpg", ".jpeg", ".png", ".webp", ".heic", ".tif", ".tiff")
THUMB_WIDTH = 320

# 追加したファイルの置き場。素材の出所を混ぜないよう専用フォルダに入れる
UPLOAD_DIR = os.path.join(MEDIA, "user")

# 書き出す解像度。make-wallpaper.sh の既定値と揃えてある
OUT_W = int(os.environ.get("AWE_WIDTH", "2560"))
OUT_H = int(os.environ.get("AWE_HEIGHT", "1440"))

# 1ファイルの上限。動画を含むため大きめに取る
MAX_UPLOAD_BYTES = 300 * 1024 * 1024

# 既定値。config.json が無いときはこれを表示する
DEFAULTS = {
    "interval": 10,
    "videoInterval": 30,
    "fade": 2.5,
    "zoom": 0.08,
    "pan": 0.02,
    "exclude": [],
}

# media/ のフォルダ名を画面に出す日本語名へ対応づける
CATEGORY_LABELS = {
    "nature": "自然",
    "nasa-apod": "宇宙",
    "nasa-library": "地球・ISS",
    "user": "追加分",
    "apple-aerials": "Mac空撮",
}


def build_category_map():
    """壁紙のファイル名から、素材がどのフォルダ由来かを引けるようにする。

    wallpaper/ は平坦なので、media/<カテゴリ>/ にある同名ファイルから逆引きする。
    """
    mapping = {}
    if not os.path.isdir(MEDIA):
        return mapping
    for category in sorted(os.listdir(MEDIA)):
        d = os.path.join(MEDIA, category)
        if not os.path.isdir(d) or category.startswith("."):
            continue
        for name in os.listdir(d):
            mapping[os.path.splitext(name)[0]] = category
    return mapping


def load_config():
    try:
        with open(CONFIG, encoding="utf-8") as f:
            return {**DEFAULTS, **json.load(f)}
    except (OSError, json.JSONDecodeError):
        return dict(DEFAULTS)


def save_config(cfg):
    """書き込み途中の状態を読まれないよう、一時ファイル経由で置き換える。"""
    tmp = CONFIG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, CONFIG)


def make_thumb(name):
    """サムネイルを作って返す。一度作ったら使い回す。"""
    os.makedirs(THUMBS, exist_ok=True)
    dst = os.path.join(THUMBS, os.path.splitext(name)[0] + ".jpg")
    src = os.path.join(WALLPAPER, name)
    if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
        return dst

    if name.lower().endswith(VIDEO_EXT):
        # 動画は冒頭が暗いことがあるので、少し進んだところを1枚取る
        cmd = ["ffmpeg", "-v", "error", "-ss", "3", "-i", src, "-frames:v", "1",
               "-vf", f"scale={THUMB_WIDTH}:-2", "-y", dst]
    else:
        cmd = ["ffmpeg", "-v", "error", "-i", src,
               "-vf", f"scale={THUMB_WIDTH}:-2", "-frames:v", "1", "-y", dst]
    subprocess.run(cmd, capture_output=True, timeout=120)
    return dst if os.path.exists(dst) else None


def list_items():
    cat_map = build_category_map()
    excluded = set(load_config()["exclude"])
    items = []
    for name in sorted(os.listdir(WALLPAPER)):
        if name.startswith("."):
            continue
        ext = os.path.splitext(name)[1].lower()
        if ext not in (".jpg", ".jpeg", ".png") + VIDEO_EXT:
            continue
        category = cat_map.get(os.path.splitext(name)[0], "other")
        items.append({
            "name": name,
            "category": category,
            "label": CATEGORY_LABELS.get(category, "その他"),
            "isVideo": ext in VIDEO_EXT,
            "enabled": name not in excluded,
        })
    return items


def safe_basename(name):
    """受け取った名前からパス要素を落とし、扱える文字だけ残す。"""
    name = os.path.basename(name.replace("\\", "/"))
    name = name.replace("\x00", "").strip()
    return name or "untitled"


def unique_path(directory, name):
    """同名があれば連番を付けて衝突を避ける。"""
    base, ext = os.path.splitext(name)
    candidate = name
    n = 2
    while os.path.exists(os.path.join(directory, candidate)):
        candidate = f"{base}-{n}{ext}"
        n += 1
    return os.path.join(directory, candidate)


def probe_size(path):
    """幅と高さを取得する。取れなければ (0, 0)。"""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0:s=x", path],
        capture_output=True, text=True, timeout=120).stdout.strip().split("\n")[0]
    try:
        w, h = out.split("x")[:2]
        return int(w), int(h)
    except ValueError:
        return 0, 0


def convert_for_wallpaper(src, dst_base, is_video):
    """画面サイズに合わせて wallpaper/ へ書き出す。

    横長は切り抜いて全面を使い、正方形に近いものと縦長は黒帯を付けて全体を残す。
    make-wallpaper.sh と同じ考え方。
    """
    w, h = probe_size(src)
    if h == 0:
        return None, "解像度を読み取れませんでした"

    if w / h >= 1.3:
        vf = f"scale={OUT_W}:{OUT_H}:force_original_aspect_ratio=increase,crop={OUT_W}:{OUT_H}"
    else:
        vf = (f"scale={OUT_W}:{OUT_H}:force_original_aspect_ratio=decrease,"
              f"pad={OUT_W}:{OUT_H}:(ow-iw)/2:(oh-ih)/2:black")

    if is_video:
        dst = unique_path(WALLPAPER, dst_base + ".mp4")
        cmd = ["ffmpeg", "-v", "error", "-i", src, "-vf", vf,
               "-c:v", "libx264", "-preset", "medium", "-crf", "23",
               "-pix_fmt", "yuv420p", "-movflags", "+faststart",
               "-an",                       # 音声は入れない
               "-y", dst]
    else:
        dst = unique_path(WALLPAPER, dst_base + ".jpg")
        cmd = ["ffmpeg", "-v", "error", "-i", src, "-vf", vf,
               "-q:v", "2", "-frames:v", "1", "-y", dst]

    r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    if r.returncode != 0 or not os.path.exists(dst):
        return None, (r.stderr or "変換に失敗しました").strip()[:200]

    warning = None
    if w < OUT_W:
        warning = f"元が {w}x{h} で画面幅より小さいため、拡大表示になり粗くなります"
    return (os.path.basename(dst), w, h), warning


def touch_config():
    """常駐アプリに一覧の取り直しを促すため、設定ファイルの更新時刻を進める。"""
    if not os.path.exists(CONFIG):
        save_config(dict(DEFAULTS))
    else:
        os.utime(CONFIG, None)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # アクセスログは出さない

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path

        if path in ("/", "/index.html"):
            with open(os.path.join(BASE, "settings.html"), "rb") as f:
                self._send(200, f.read(), "text/html; charset=utf-8")

        elif path == "/api/items":
            self._send(200, {"items": list_items(), "config": load_config()})

        elif path == "/api/aerials":
            # Mac にダウンロード済みの空撮壁紙を一覧する
            self._send(200, {"items": aerials.available(WALLPAPER)})

        elif path.startswith("/aerial-thumb/"):
            asset_id = urllib.parse.unquote(path[len("/aerial-thumb/"):])
            if "/" in asset_id or ".." in asset_id:
                self._send(404, {"error": "not found"})
                return
            thumb = aerials.thumbnail_path(asset_id)
            if not thumb:
                self._send(404, {"error": "no thumbnail"})
                return
            with open(thumb, "rb") as f:
                self._send(200, f.read(), "image/png")

        elif path.startswith("/thumb/"):
            name = urllib.parse.unquote(path[len("/thumb/"):])
            # ディレクトリを遡る指定を弾く
            if "/" in name or ".." in name:
                self._send(404, {"error": "not found"})
                return
            thumb = make_thumb(name)
            if not thumb:
                self._send(404, {"error": "thumbnail failed"})
                return
            with open(thumb, "rb") as f:
                self._send(200, f.read(), "image/jpeg")
        else:
            self._send(404, {"error": "not found"})

    def _handle_upload(self):
        """1ファイルを生データで受け取り、素材として取り込む。

        multipart の解析を避けるため、ファイル名はクエリ、中身は本文そのままで受ける。
        """
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        raw_name = safe_basename(urllib.parse.unquote(query.get("name", ["untitled"])[0]))
        ext = os.path.splitext(raw_name)[1].lower()

        if ext not in IMAGE_EXT + VIDEO_EXT:
            self._send(400, {"error": f"対応していない形式です（{ext or "拡張子なし"}）"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            self._send(400, {"error": "中身が空です"})
            return
        if length > MAX_UPLOAD_BYTES:
            self._send(413, {"error": f"大きすぎます（上限 {MAX_UPLOAD_BYTES // 1024 // 1024}MB）"})
            return

        os.makedirs(UPLOAD_DIR, exist_ok=True)
        src = unique_path(UPLOAD_DIR, raw_name)

        # 一度に読み込まず分割して書き出す（動画でメモリを使い切らないため）
        remaining = length
        with open(src, "wb") as f:
            while remaining > 0:
                chunk = self.rfile.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)

        if remaining > 0:
            os.remove(src)
            self._send(400, {"error": "転送が途中で切れました"})
            return

        try:
            result, note = convert_for_wallpaper(
                src, os.path.splitext(os.path.basename(src))[0], ext in VIDEO_EXT)
        except subprocess.TimeoutExpired:
            os.remove(src)
            self._send(500, {"error": "変換に時間がかかりすぎました"})
            return

        if result is None:
            # 変換できないものは素材側にも残さない
            os.remove(src)
            self._send(400, {"error": note})
            return

        name, w, h = result
        touch_config()
        self._send(200, {"ok": True, "name": name, "width": w, "height": h, "warning": note})

    def _handle_aerial_import(self):
        """空撮映像を1本だけ取り込む。変換に数十秒かかるため1本ずつ受ける。"""
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        asset_id = query.get("id", [""])[0]
        if not asset_id or "/" in asset_id or ".." in asset_id:
            self._send(400, {"error": "id が不正です"})
            return
        try:
            name, err = aerials.convert(asset_id, WALLPAPER, OUT_W, OUT_H)
        except Exception as e:
            self._send(500, {"error": str(e)[:200]})
            return
        if err:
            self._send(400, {"error": err})
            return
        touch_config()
        self._send(200, {"ok": True, "name": name})

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/aerials/import":
            self._handle_aerial_import()
            return
        if path == "/api/upload":
            self._handle_upload()
            return
        if path != "/api/config":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid json"})
            return

        cfg = load_config()
        for key in ("interval", "videoInterval", "fade", "zoom", "pan"):
            if key in payload:
                cfg[key] = float(payload[key])
        if "exclude" in payload:
            cfg["exclude"] = sorted(set(payload["exclude"]))
        save_config(cfg)
        self._send(200, {"ok": True, "enabled": len(list_items()) - len(cfg["exclude"])})


def main():
    if not os.path.isdir(WALLPAPER):
        sys.exit(f"wallpaper フォルダがありません: {WALLPAPER}")
    # 変換に数十秒かかる要求があるため、1本のスレッドで捌くと画面が固まる
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    # 127.0.0.1 に限定する。他の端末からは接続できない
    with Server(("127.0.0.1", PORT), Handler) as httpd:
        print(f"設定画面: http://localhost:{PORT}")
        print("終了するには Control-C")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n終了しました")


if __name__ == "__main__":
    main()
