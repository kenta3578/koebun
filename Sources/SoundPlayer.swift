import AppKit

/// 録音開始音・停止音の一覧と再生（Issue #71）。
///
/// 選択肢は「なし」＋ macOS 同梱のシステム音＋ `~/koebun/sounds/` に置いた音声ファイル。
/// 設定に保存するのは名前の文字列だけ（システム音は `NSSound(named:)` の名前、
/// 自分の音は拡張子を除いたファイル名）。自分の音が同名なら自分の音を優先する。
@MainActor
enum SoundPlayer {
    static let none = "なし"

    static let systemSounds: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk",
        "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
        "Sosumi", "Submarine", "Tink"
    ]

    /// 自分の音の置き場。ここに aiff / wav / mp3 / m4a / caf を置くと選択肢に出る。
    static var customDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("koebun", isDirectory: true)
            .appendingPathComponent("sounds", isDirectory: true)
    }

    private static let supportedExtensions: Set<String> = ["aiff", "aif", "wav", "mp3", "m4a", "caf"]

    /// `~/koebun/sounds/` にある音の名前（拡張子なし、名前順）。
    static func customSounds() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: customDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return items
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 設定の選択肢。「なし」→ 自分の音 → システム音。
    static func choices() -> [String] {
        [none] + customSounds() + systemSounds
    }

    /// 名前が今も選べるか（ファイルを消したあとの設定を「なし」に戻すために使う）。
    static func isAvailable(_ name: String) -> Bool {
        name == none || systemSounds.contains(name) || customFileURL(for: name) != nil
    }

    static func play(_ name: String) {
        guard name != none else { return }
        if let url = customFileURL(for: name) {
            // 前の再生が終わる前に次を鳴らしても切れないよう、毎回インスタンスを作る。
            let sound = NSSound(contentsOf: url, byReference: true)
            sound?.play()
            retain(sound)
        } else {
            NSSound(named: .init(name))?.play()
        }
    }

    private static func customFileURL(for name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for ext in ["aiff", "aif", "wav", "mp3", "m4a", "caf"] {
            let url = customDirectory.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// `NSSound(contentsOf:)` は参照を保持しないと再生途中で解放されることがある。
    private static var playing: [NSSound] = []
    private static func retain(_ sound: NSSound?) {
        guard let sound else { return }
        playing.append(sound)
        // 数秒後に掃除する（効果音は短いので、それまでに再生は終わっている）。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            playing.removeAll { $0 === sound || !$0.isPlaying }
        }
    }
}
