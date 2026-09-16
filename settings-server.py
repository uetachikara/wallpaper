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

BASE = os.path.dirname(os.path.abspath(__file__))
WALLPAPER = os.path.join(BASE, "wallpaper")
MEDIA = os.path.join(BASE, "media")
CONFIG = os.path.join(BASE, "config.json")
THUMBS = os.path.join(BASE, ".thumbs")
PORT = int(os.environ.get("AWE_SETTINGS_PORT", "8787"))

VIDEO_EXT = (".mp4", ".m4v", ".mov")
THUMB_WIDTH = 320

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

    def do_POST(self):
        if urllib.parse.urlparse(self.path).path != "/api/config":
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
    socketserver.TCPServer.allow_reuse_address = True
    # 127.0.0.1 に限定する。他の端末からは接続できない
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        print(f"設定画面: http://localhost:{PORT}")
        print("終了するには Control-C")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n終了しました")


if __name__ == "__main__":
    main()
