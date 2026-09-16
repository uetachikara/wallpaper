// デスクトップアイコンの直下に画像や動画を敷き、
// ゆっくりズームさせながら一定間隔でクロスフェードする常駐アプリ。
//
// macOS の壁紙 API（NSWorkspace.setDesktopImageURL）は静止画を瞬時に差し替えるだけで、
// フェードもズームも動画も扱えない。そこで壁紙そのものではなく、
// 「壁紙より上・アイコンより下」の階層に自前のウインドウを敷いて描画する。
// アプリを終了すれば元の壁紙がそのまま見えるため、システム設定は汚さない。
//
// 描画は layer-backed な NSView ではなく自前の CALayer で行う。
// AppKit が管理するレイヤーに transform アニメーションを載せると
// レイアウト更新で打ち消されることがあるため。

import AppKit
import AVFoundation

// MARK: - 設定

struct Options {
    var dir = NSHomeDirectory() + "/Awe/wallpaper"
    var interval: TimeInterval = 10    // 静止画を変える間隔（秒）
    var videoInterval: TimeInterval = 0 // 動画のときの表示秒数。0 なら interval と同じ
    var fade: TimeInterval = 2.5       // クロスフェードにかける時間（秒）
    var zoom = 0.08                    // ズーム量（0.08 = 8%。0 でズーム無効）
    var pan = 0.02                     // 横方向の流し量（画面幅比）
    var selftest: TimeInterval = 0     // >0 で内部状態を出力して終了（動作確認用）
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--dir":       if let v = it.next() { o.dir = (v as NSString).expandingTildeInPath }
        case "--interval":  if let v = it.next(), let d = Double(v) { o.interval = d }
        case "--fade":      if let v = it.next(), let d = Double(v) { o.fade = d }
        case "--zoom":      if let v = it.next(), let d = Double(v) { o.zoom = d }
        case "--pan":       if let v = it.next(), let d = Double(v) { o.pan = d }
        case "--selftest":  if let v = it.next(), let d = Double(v) { o.selftest = d }
        case "--video-interval":
                            if let v = it.next(), let d = Double(v) { o.videoInterval = d }
        default:
            FileHandle.standardError.write("不明な引数: \(a)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    // フェードが間隔以上だと次の切り替えに食い込むため上限を設ける
    o.fade = min(o.fade, max(0.1, min(o.interval, o.videoInterval > 0 ? o.videoInterval : o.interval) - 0.5))
    return o
}

/// 表示する中身。静止画と動画を同じ経路で扱えるようにする。
enum Media {
    case image(CGImage)
    case video(URL)
}

// MARK: - 1画面ぶんの表示

/// 画面1枚に対応する背景ウインドウ。
/// 器のレイヤーを2枚重ね、交互に不透明度を animate してフェードさせる。
final class BackdropWindow {
    let window: NSWindow
    private let host: NSView
    private var layers: [CALayer] = []
    private var players: [AVQueuePlayer?] = [nil, nil]
    private var loopers: [AVPlayerLooper?] = [nil, nil]
    private var frontIndex = 0        // 次に描画する器

    init(screen: NSScreen) {
        window = NSWindow(contentRect: screen.frame,
                          styleMask: .borderless,
                          backing: .buffered,
                          defer: false,
                          screen: screen)
        // 壁紙より上・デスクトップアイコンより下。アイコンを隠さないための階層指定
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        // 全スペースに出し、Mission Control のウインドウ循環からは外す
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true      // クリックはデスクトップに素通しする
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.displaysWhenScreenProfileChanges = true

        host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        guard let root = host.layer else { fatalError("レイヤーを作成できません") }
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true            // ズームではみ出した分を切り落とす

        // 静止画は contents に直接入れ、動画は AVPlayerLayer を子として差し込む
        for _ in 0..<2 {
            let l = CALayer()
            l.frame = host.bounds
            l.contentsGravity = .resizeAspect
            l.opacity = 0
            l.masksToBounds = true
            root.addSublayer(l)
            layers.append(l)
        }

        // ARC 管理下では自動解放させない。close() で明示的に片付ける
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
    }

    /// 画面構成が変わったときに古いウインドウを完全に破棄する。
    /// 閉じ忘れると NSApp がウインドウを保持し続け、古い画像が画面に残る。
    func close() {
        clear(0)
        clear(1)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// 表示中レイヤーの「今まさに描画されている」拡大率。動作確認用。
    var visibleScale: Double? {
        guard let t = layers[1 - frontIndex].presentation()?.transform else { return nil }
        return Double(t.m11)
    }

    /// 表示中レイヤーが動画を再生しているか。動作確認用。
    var visibleIsPlayingVideo: Bool {
        guard let p = players[1 - frontIndex] else { return false }
        return p.rate > 0
    }

    /// 器の中身を空にして、動画なら再生も止める。
    private func clear(_ i: Int) {
        players[i]?.pause()
        players[i] = nil
        loopers[i] = nil        // AVPlayerLooper は解放時にループ登録を解除する
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers[i].sublayers?.forEach { $0.removeFromSuperlayer() }
        layers[i].contents = nil
        layers[i].removeAllAnimations()
        CATransaction.commit()
    }

    /// 次の中身へ切り替える。初回はフェードせず即座に表示する。
    func show(_ media: Media, fade: TimeInterval, hold: TimeInterval,
              zoom: Double, pan: Double, animated: Bool) {
        let idx = frontIndex
        let incoming = layers[idx]
        let outgoing = layers[1 - idx]
        frontIndex = 1 - frontIndex

        // これから使う器には「2つ前」の中身が残っている。既にフェードし終えているので片付けてよい。
        // 一方 outgoing はこれからフェードアウトするので、動画なら再生させたままにする。
        clear(idx)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.frame = host.bounds
        outgoing.frame = host.bounds
        incoming.transform = CATransform3DIdentity
        CATransaction.commit()

        var isVideo = false
        switch media {
        case .image(let img):
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            incoming.contents = img
            CATransaction.commit()

        case .video(let url):
            isVideo = true
            let player = AVQueuePlayer()
            player.isMuted = true                 // 会社で音が鳴らないよう常にミュート
            player.actionAtItemEnd = .none
            // 表示時間より短い動画でも途切れないよう繰り返し再生する
            let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            let pl = AVPlayerLayer(player: player)
            pl.frame = incoming.bounds
            pl.videoGravity = .resizeAspectFill   // 画面比が違っても余白を作らない
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            incoming.addSublayer(pl)
            CATransaction.commit()
            players[idx] = player
            loopers[idx] = looper
            player.play()
        }

        // ズームは静止画にだけ掛ける。動画は元から動いているため重ねない
        if zoom > 0 && !isVideo {
            let zoomIn = Bool.random()
            let dir: CGFloat = Bool.random() ? 1 : -1
            let dx = CGFloat(pan) * host.bounds.width * dir
            let big = CATransform3DTranslate(
                CATransform3DMakeScale(CGFloat(1 + zoom), CGFloat(1 + zoom), 1), dx, 0, 0)
            let small = CATransform3DIdentity

            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = zoomIn ? small : big
            a.toValue = zoomIn ? big : small
            a.duration = hold + fade   // 次へフェードし終わるまで動かし続ける
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            incoming.add(a, forKey: "kenburns")
        }

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            incoming.opacity = 1
            outgoing.opacity = 0
            CATransaction.commit()
            return
        }

        // 不透明度を交差させてクロスフェードする
        for (layer, from, to) in [(incoming, 0.0, 1.0), (outgoing, 1.0, 0.0)] {
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = from
            f.toValue = to
            f.duration = fade
            f.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            f.fillMode = .forwards
            f.isRemovedOnCompletion = false
            layer.add(f, forKey: "crossfade")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = Float(to)
            CATransaction.commit()
        }
    }
}

// MARK: - 本体

final class Controller: NSObject {
    private let opts: Options
    private var windows: [BackdropWindow] = []
    private var files: [String] = []
    private var lastIndex = -1
    private var bag: [Int] = []       // 未表示ぶんの取り出し袋。空になったら詰め直す
    private var cycle = 0             // 何巡目か（動作確認用）
    private var timer: Timer?
    private var screenTimer: Timer?
    private var lastScreenFrames: [NSRect] = []
    private var currentMedia: Media?
    private var currentHold: TimeInterval = 0
    private var first = true

    private static let videoExts = ["mp4", "m4v", "mov"]
    private static let imageExts = ["jpg", "jpeg", "png"]

    init(opts: Options) {
        self.opts = opts
        super.init()
    }

    func start() {
        reloadFiles()
        guard !files.isEmpty else {
            FileHandle.standardError.write("表示できるファイルがありません: \(opts.dir)\n".data(using: .utf8)!)
            exit(1)
        }
        rebuildWindows()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        advance()
        if opts.selftest > 0 { startSelftest() }
    }

    /// ズームと動画再生が実際に効いているかを、内部状態を定期的に読んで確かめる。
    private func startSelftest() {
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let w = self?.windows.first else { return }
            let scale = w.visibleScale.map { String(format: "%.4f", $0) } ?? "-"
            print("  scale=\(scale) video=\(w.visibleIsPlayingVideo)")
            fflush(stdout)
        }
        RunLoop.main.add(t, forMode: .common)
        Timer.scheduledTimer(withTimeInterval: opts.selftest, repeats: false) { _ in
            print("自己診断を終了します")
            exit(0)
        }
    }

    private func reloadFiles() {
        let fm = FileManager.default
        let ok = Set(Controller.videoExts + Controller.imageExts)
        files = ((try? fm.contentsOfDirectory(atPath: opts.dir)) ?? [])
            .filter { ok.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { opts.dir + "/" + $0 }
    }

    private func rebuildWindows() {
        // 作り直す前に必ず古いウインドウを閉じる。
        // ここを怠ると画面上に前の画像を映したままのウインドウが積み上がる。
        windows.forEach { $0.close() }
        windows = NSScreen.screens.map { BackdropWindow(screen: $0) }
        lastScreenFrames = NSScreen.screens.map { $0.frame }
    }

    @objc private func screensChanged() {
        // 通知は画面構成の変更中に何度も連続で飛ぶため、落ち着くまで待ってから処理する
        screenTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.applyScreenChange()
        }
        RunLoop.main.add(t, forMode: .common)
        screenTimer = t
    }

    private func applyScreenChange() {
        // 実際に構成が変わったときだけ作り直す。
        // 無条件に作り直すと、ウインドウ生成自体が次の通知を呼んで際限なく増える
        let frames = NSScreen.screens.map { $0.frame }
        guard frames != lastScreenFrames else { return }

        rebuildWindows()

        // 表示中のものをそのまま出し直す。ここで advance() を呼ぶと
        // 画面をまたぐたびに順番が飛んでしまう
        if let media = currentMedia {
            for w in windows {
                w.show(media, fade: opts.fade, hold: currentHold,
                       zoom: opts.zoom, pan: opts.pan, animated: false)
            }
        }
    }

    private func isVideo(_ path: String) -> Bool {
        Controller.videoExts.contains((path as NSString).pathExtension.lowercased())
    }

    private func loadCGImage(_ path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 中身ごとに表示時間が変わるため、毎回タイマーを取り直す
    private func scheduleNext(after delay: TimeInterval) {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.advance()
        }
        // メニュー操作中などでもタイマーを止めない
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 全件を一巡してから詰め直す方式で次の1件を選ぶ。
    /// 毎回ランダムに選ぶ方式だと、数回のうちに同じものが再登場してしまうため。
    private func nextIndex() -> Int {
        if bag.isEmpty {
            bag = Array(files.indices).shuffled()
            cycle += 1
            // 巡の切れ目で直前と同じものが続かないよう、先頭だけ入れ替える
            if bag.count > 1, bag.last == lastIndex {
                bag.swapAt(bag.count - 1, 0)
            }
        }
        return bag.removeLast()
    }

    private func advance() {
        let i = nextIndex()
        lastIndex = i
        let path = files[i]

        let media: Media
        var hold = opts.interval
        if isVideo(path) {
            media = .video(URL(fileURLWithPath: path))
            // 動画は静止画より長く見せたいことが多いので別の秒数を持てるようにしてある
            hold = opts.videoInterval > 0 ? opts.videoInterval : opts.interval
        } else {
            guard let img = loadCGImage(path) else {
                // 読めないファイルは飛ばして次へ
                scheduleNext(after: 0.2)
                return
            }
            media = .image(img)
        }

        currentMedia = media
        currentHold = hold
        let animated = !first
        first = false
        for w in windows {
            w.show(media, fade: opts.fade, hold: hold,
                   zoom: opts.zoom, pan: opts.pan, animated: animated)
        }
        scheduleNext(after: hold)

        // 動作確認と不具合調査のため、切り替えた中身を記録する
        let stamp = ISO8601DateFormatter().string(from: Date())
        let kind = isVideo(path) ? "動画" : "画像"
        let pos = files.count - bag.count
        print("\(stamp) [\(kind)] \(cycle)巡目 \(pos)/\(files.count) \((path as NSString).lastPathComponent)")
        fflush(stdout)
    }
}

let opts = parseArgs()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dock にも Cmd+Tab にも出さない
let controller = Controller(opts: opts)
controller.start()
app.run()
