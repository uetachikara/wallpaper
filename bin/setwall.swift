// 指定した画像を全ディスプレイの壁紙に設定する小さなツール。
// macOS 14 以降は AppleScript（System Events）での壁紙変更が効かないため、
// NSWorkspace の API を直接叩く。
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write("使い方: setwall <画像パス>\n".data(using: .utf8)!)
    exit(1)
}
let url = URL(fileURLWithPath: args[1]).standardizedFileURL
guard FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write("ファイルが見つかりません: \(url.path)\n".data(using: .utf8)!)
    exit(1)
}

let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
    .allowClipping: true,
]

var failed = false
for screen in NSScreen.screens {
    do {
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    } catch {
        FileHandle.standardError.write("設定失敗: \(error)\n".data(using: .utf8)!)
        failed = true
    }
}
exit(failed ? 1 : 0)
