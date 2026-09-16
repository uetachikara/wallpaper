# Awe

畏敬の念を誘う写真と映像を、macOS のデスクトップ背景としてゆっくり切り替え続けるツール。
休憩中に大自然や宇宙を眺めるための道具立て。

- デスクトップアイコンの下に自前のウインドウを敷き、画像をクロスフェードで切り替える
- 静止画は表示中ゆっくりズーム・パン（Ken Burns）
- 動画にも対応（常時ミュート・ループ再生）
- 全画面ビューア `awe.html` を同梱（ブラウザだけで動く）

macOS の壁紙設定そのものは変更しない。壁紙より上・アイコンより下の階層に描画するだけなので、
停止すれば元の壁紙がそのまま戻る。

## 動作要件

| 用途 | 必要なもの |
|---|---|
| 背景の常駐表示 | macOS 14 以降 |
| ビルド | Xcode Command Line Tools（`xcode-select --install`） |
| 素材の取得・変換 | `python3`、`ffmpeg`（`brew install ffmpeg`） |

## セットアップ

```bash
git clone <このリポジトリ> ~/Awe
cd ~/Awe
./fetch-nature.sh 8      # 自然の写真を取得（20分ほどかかる）
./fetch-apod.sh 40       # 宇宙の写真を取得
./make-wallpaper.sh      # 画面サイズに合わせて書き出し
./install.sh             # ビルドしてログイン項目に登録
```

`install.sh` は引数で挙動を変えられる。

```bash
./install.sh 30 5 0.05 60   # 画像30秒 / フェード5秒 / ズーム5% / 動画60秒
```

## 設定画面

表示する画像の選択と、間隔・フェード・ズーム量の調整はブラウザから行う。

```bash
./settings.sh
```

`http://localhost:8787` が開く。できることは3つ。

- **表示する画像の選択**: サムネイルをクリックして ON/OFF。カテゴリ単位の一括切替もできる
- **表示の調整**: 間隔、フェード、ズーム量をスライダーで変更
- **画像・動画の追加**: 上部の枠へドラッグするか「ファイルを選ぶ」。
  jpg / png / webp / heic / mp4 / mov に対応（1ファイル 300MB まで）

追加したファイルは `media/user/` に原本を置き、画面サイズに合わせて `wallpaper/` へ書き出す。
横長は切り抜き、縦長と正方形に近いものは黒帯を付ける。音声は必ず除去する。
画面幅より小さい素材は追加できるが、粗くなる旨を警告する。

選択と調整は保存すると `config.json` に書き出され、追加は即座に反映される。
いずれも常駐プロセスが数秒で拾うため **再起動は不要**。

外部には公開せず `127.0.0.1` のみで待ち受ける。設定し終えたら Control-C で終了してよい。

設定ファイルを直接編集してもよい。

```json
{
  "setWallpaper": true,  // Mac の壁紙も同じ画像に合わせるか
  "interval": 10,        // 画像の表示秒数
  "videoInterval": 30,   // 動画の表示秒数
  "fade": 2.5,           // クロスフェードの秒数
  "zoom": 0.08,          // ズーム量（0 で無効）
  "pan": 0.02,           // 横方向の流し量
  "exclude": []          // 表示しないファイル名
}
```

`config.json` が無ければ `install.sh` に渡した値で動く。

### Mac の壁紙を合わせる理由

背景はウインドウとして描いているため、Mission Control やウインドウを浮かせる操作では
他のウインドウと一緒に隠れ、その下の本物の壁紙が見えてしまう。
`setWallpaper` を有効にすると、表示中の静止画を macOS の壁紙にも設定するので、
隠れたときも見た目が変わらない。動画のときは直前の画像のままになる。

## 操作

```bash
./backdrop-agent.sh status      # 状態とログを見る
./backdrop-agent.sh uninstall   # 停止して登録も削除
./make-wallpaper.sh 3840 2160   # 別の解像度で作り直す
```

素材を増やしたら `make-wallpaper.sh` を実行したあと、設定画面で保存するか
`config.json` を触れば一覧を取り直す。常駐プロセスの入れ直しは不要。

## 全画面ビューア

`awe.html` をブラウザで開くと全画面のスライドショーになる。外部通信はしない。

| キー | 動作 |
|---|---|
| `Space` | 一時停止 |
| `←` `→` | 前後 |
| `F` | 全画面 |
| `S` | 並び替え |
| `K` | ズームの切替 |

素材を追加したら `./refresh.sh` で一覧を作り直す。

## 素材の取得元

| スクリプト | 提供元 | 内容 |
|---|---|---|
| `fetch-nature.sh` | Wikimedia Commons（Featured pictures） | 風景、山、森、海岸、火山、雷、氷雪、オーロラ、星景 |
| `fetch-apod.sh` | NASA APOD | 星雲、銀河、惑星、日食 |
| `fetch-nasa.sh` | NASA Image and Video Library | ISS からの地球、大気光、ハリケーン、砂漠 |

いずれも全画面表示に耐えない低解像度や極端なパノラマを自動で除外する。
ただし**自動取得だけでは図版・データ図・接写・人工物が混ざる**ため、
取り込んだあとに一度目視で選別することを勧める。

## macOS の Aerial 壁紙を使う

macOS に入っている空撮映像（アイスランド、パタゴニア、ヨセミテなど137本）を素材として使える。
自然の動画素材としては質が高い。

システム設定 → 壁紙 で使いたいものを選ぶとダウンロードされる。
保存先は macOS 26 では `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`、
それ以前は `/Library/Application Support/com.apple.idleassetsd/Customer/` で、
どちらも自動で探す。

そのあと以下を実行すると、画面サイズに変換して取り込む。

```bash
./import-aerials.sh
```

日本語名はシステムのカタログから引く。音声は除去し、HDR 素材は SDR へ変換する。

素材は 4K・240fps と重いため、ハードウェアデコードを使い、縮小の前にフレームを
30fps へ間引く。ループ再生するので長さは60秒で切る。
この設定で 1本あたり約40秒・約30MB に収まる（無調整だと約5分・約150MB）。

**これは Apple の著作物なので、そのマシンの中だけで使うこと。**
`package.sh` と `.gitignore` で配布物からは自動的に除外される。

## 取得物のライセンス

**リポジトリには画像・動画を含めていない。** 提供元ごとに条件が異なるため。

- **NASA**（APOD / Image Library）: 原則パブリックドメイン
- **Wikimedia Commons**: CC BY / CC BY-SA / CC0 などが混在する。
  `fetch-nature.sh` は取得時に作者・ライセンス・出典 URL を
  `media/nature/CREDITS.txt` に記録する。再配布する場合はこのファイルを確認すること

個人のデスクトップ背景として使うぶんには表示義務は生じないが、
取得物をそのまま再配布する場合は各ライセンスに従う必要がある。

## 構成

```
awe.html              全画面ビューア（単体で動く HTML）
bin/awewall.swift     背景描画の本体
bin/setwall.swift     壁紙を差し替える補助ツール
install.sh            ビルドと常駐登録
settings.sh           設定画面を開く
settings.html         設定画面の中身
settings-server.py    設定画面のローカルサーバー
backdrop-agent.sh     常駐の登録・解除・状態確認
make-wallpaper.sh     素材を画面サイズに合わせて書き出す
refresh.sh            awe.html のファイル一覧を更新
fetch-*.sh            素材の取得
package.sh            別の Mac へ持ち出すアーカイブを作る
```

## 仕組み

`NSWorkspace.setDesktopImageURL` は画像を瞬時に差し替えるだけで、フェードもズームも動画も扱えない。
macOS 14 以降は AppleScript による壁紙変更も効かない。

そこで壁紙そのものを変えず、`CGWindowLevelForKey(.desktopIconWindow) - 1` の階層に
ボーダーレスウインドウを敷いて描画する。クリックは素通しし、全スペースに表示する。
描画は AppKit 管理下のレイヤーではなく自前の `CALayer` で行う。
AppKit のレイヤーに `transform` アニメーションを載せるとレイアウト更新で打ち消されるため。

## ライセンス

コードは MIT。取得物については上記を参照。
