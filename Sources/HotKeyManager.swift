import AppKit
import Combine

/// トグル録音ホットキー。
/// SettingsStore.hotKeyCode のキーを押すたびに onToggle を呼ぶ。
/// キーリリースは無視する。
///
/// 2 つの方式を設定で切り替える（Issue #112）:
/// - **修飾キー単独**（`hotKeyExtra == nil`）: `flagsChanged` の NSEvent 監視だけを張る
/// - **修飾キー + 通常キー**（例: 右⌥ + S）: `CGEventTap` で keyDown/keyUp を見て、
///   一致した押下は**飲み込む**（前面アプリに ß 等を打ち込ませない）。keyDown を監視するのは
///   キーロガー相当なので、この方式が選ばれているときだけ張る
@MainActor
final class HotKeyManager {
    var onToggle: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// 飲み込んだ keyDown に対応する keyUp も飲み込むために覚えておく。
    private var swallowedKeyCode: UInt16?

    private var settingsObserver: AnyCancellable?
    private var wakeObserver: AnyCancellable?

    /// 監視を張れているか。権限が付いたあとに張り直したかの判断に使う（Issue #78）。
    private(set) var isRunning = false

    init() {
        // 方式が変わったら張り直す（再起動なしで反映。Issue #112）。
        settingsObserver = SettingsStore.shared.$hotKeyExtra
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                // didSet の途中で購読が走るので、値が確定してから張り直す。
                Task { @MainActor in self.start() }
            }
        // スリープ復帰後はタップが黙って死んでいることがあるので作り直す。
        wakeObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRunning, self.tap != nil else { return }
                    self.start()
                }
            }
    }

    /// 監視を張る。**何度呼んでも二重に張らない**。
    ///
    /// グローバル監視はアクセシビリティで trusted でないと一度も発火しないので、
    /// 権限が後から付いたときに呼び直せる必要がある（Issue #78）。
    func start() {
        stop()
        if SettingsStore.shared.hotKeyExtra == nil {
            startModifierMonitors()
            isRunning = true
        } else {
            // タップは権限が無いと作れない。false のままにして許可後の再登録に任せる。
            isRunning = startTap()
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isDown = false
        stopTap()
        isRunning = false
    }

    // MARK: - 修飾キー単独

    private func startModifierMonitors() {
        // 自アプリがアクティブなとき（設定・履歴ウィンドウを開いているとき）は
        // global monitor にイベントが配送されない。local も張らないと
        // 「ウィンドウを開いていると右⌥ が効かない」ことになる（Issue #78）。
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            self?.handle(keyCode: event.keyCode, flags: event.modifierFlags)
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                self?.handle(keyCode: keyCode, flags: flags)
            }
        }) {
            monitors.append(global)
        }
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard keyCode == SettingsStore.shared.hotKeyCode else { return }
        let pressed = SettingsStore.isKeyDown(keyCode: keyCode, flags: flags)

        if pressed && !isDown {
            // 離すまで再発火させないので、トグルしない場合でも押下は記録する。
            isDown = true
            // 設定画面でホットキーを録っている最中は、その押下は設定用（録音しない）。
            guard !HotKeyCapture.shared.isCapturing else { return }
            // 他の修飾キーと一緒なら、ショートカット操作なので録音しない（Issue #78）。
            guard SettingsStore.isSoloPress(keyCode: keyCode, flags: flags) else { return }
            onToggle?()
        } else if !pressed {
            isDown = false
        }
    }

    // MARK: - 修飾キー + 通常キー（CGEventTap）

    private func startTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotKeyTapCallback,
            userInfo: userInfo
        ) else {
            NSLog("koebun: ホットキーのイベントタップを作れませんでした（アクセシビリティ権限が無い可能性）")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // main run loop に載せる＝コールバックは main thread で呼ばれる。
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.tapSource = source
        return true
    }

    private func stopTap() {
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        swallowedKeyCode = nil
    }

    /// タップのコールバック本体。**判定して main へ投げるだけ**（ここで重い処理をすると
    /// 全アプリのキー入力が遅れ、遅すぎると OS にタップを切られる）。
    /// 戻り値は「このイベントを飲み込むか」。
    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // OS が切ったら張り直す。放置すると黙って効かなくなる。
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let extra = SettingsStore.shared.hotKeyExtra, keyCode == extra.keyCode else { return false }
            guard !HotKeyCapture.shared.isCapturing else { return false }
            // NSEvent.ModifierFlags は CGEventFlags と同じビット配置（左右のデバイスマスク込み）。
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let modifier = SettingsStore.shared.hotKeyCode
            guard SettingsStore.isKeyDown(keyCode: modifier, flags: flags),
                  SettingsStore.isSoloPress(keyCode: modifier, flags: flags) else { return false }
            swallowedKeyCode = keyCode
            // 押しっぱなしのオートリピートでは 1 回だけ。
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.onToggle?() }
            }
            return true

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard swallowedKeyCode == keyCode else { return false }
            swallowedKeyCode = nil
            return true

        default:
            return false
        }
    }
}

/// `CGEventTap` の C コールバック。クロージャは捕捉できないので userInfo で self を受け取る。
private func hotKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    // タップは main run loop に載せているので main thread で呼ばれる。
    let swallow = MainActor.assumeIsolated { manager.handleTap(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// 設定画面の「ホットキーを録る」状態。
///
/// **View の `@State` に置かない**。`SettingsWindowController` はウィンドウを使い回す
/// （`isReleasedWhenClosed = false`）ので、閉じても SwiftUI の `.onDisappear` は発火せず、
/// 監視が張られたまま残る。次に ⌘C を押しただけで録音キーがそれに書き換わり、
/// 画面は閉じているので何も表示されない（Issue #78）。
/// ここに出しておけば `windowWillClose` からも確実に止められる。
@MainActor
final class HotKeyCapture: ObservableObject {
    static let shared = HotKeyCapture()

    @Published private(set) var isCapturing = false
    private var monitors: [Any] = []
    /// 押されたまま離されていない修飾キー。これを押したまま通常キーを押せば組み合わせ、
    /// 押さずに離せば単独キーとして確定する（Issue #112）。
    private var pendingModifier: UInt16?

    private init() {}

    /// 修飾キーの押下（と、押したままの通常キー）を拾ってホットキーにする。
    ///
    /// global monitor は**他アプリ**へ配送されるイベントしか受け取らない。設定ウィンドウは
    /// `NSApp.activate` で前面＝アクティブなので、自アプリに配送される押下は local monitor
    /// でないと拾えない（Issue #68）。修飾キーは両方張り、先に来た方を採用する。
    /// 通常キーは自アプリ宛てにしか要らないので local だけ（global の keyDown 監視は張らない）。
    func start() {
        cancel()
        isCapturing = true
        pendingModifier = nil

        // 修飾キーの押下・解放。戻り値は「飲み込むか」。
        let acceptFlags: @MainActor (UInt16, NSEvent.ModifierFlags) -> Bool = { [weak self] code, flags in
            guard let self else { return false }
            let pressed = SettingsStore.isKeyDown(keyCode: code, flags: flags)
            if pressed, self.pendingModifier == nil {
                self.pendingModifier = code
                return true
            }
            if !pressed, self.pendingModifier == code {
                self.commit(modifier: code, extra: nil)
                return true
            }
            return false
        }
        // 修飾キーを押したままの通常キー。Esc は録りをやめる。
        let acceptKey: @MainActor (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            if event.keyCode == 53 {
                Task { @MainActor in self.cancel() }
                return true
            }
            guard let modifier = self.pendingModifier,
                  SettingsStore.isKeyDown(keyCode: modifier, flags: event.modifierFlags) else { return false }
            let label = HotKeyExtra.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            self.commit(modifier: modifier, extra: HotKeyExtra(keyCode: event.keyCode, label: label))
            return true
        }

        // local monitor は main thread で同期に呼ばれる。global は既存コードに合わせて main へ投げる。
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            // 採用した押下は飲み込む（設定画面のフォーカスを動かさない）。
            MainActor.assumeIsolated { acceptFlags(event.keyCode, event.modifierFlags) } ? nil : event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { event in
            let code = event.keyCode
            let flags = event.modifierFlags
            Task { @MainActor in _ = acceptFlags(code, flags) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            MainActor.assumeIsolated { acceptKey(event) } ? nil : event
        }) {
            monitors.append(local)
        }
    }

    /// 監視のコールバック中に監視を外さないよう、確定は次のターンで行う。
    /// 待ちだけは即座に消す（組み合わせ確定の直後に来る修飾キーの解放で単独に上書きしない）。
    private func commit(modifier: UInt16, extra: HotKeyExtra?) {
        pendingModifier = nil
        Task { @MainActor in
            SettingsStore.shared.hotKeyCode = modifier
            SettingsStore.shared.hotKeyExtra = extra
            self.cancel()
        }
    }

    func cancel() {
        isCapturing = false
        pendingModifier = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
