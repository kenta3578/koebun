import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isRecording = false
    @State private var recordingMonitor: Any?

    var body: some View {
        Form {
            Section("サウンド") {
                Picker("録音開始音", selection: $settings.startSound) {
                    ForEach(SettingsStore.systemSounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: settings.startSound) { _, new in preview(new) }

                Picker("録音停止音", selection: $settings.stopSound) {
                    ForEach(SettingsStore.systemSounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: settings.stopSound) { _, new in preview(new) }
            }

            Section("ホットキー") {
                HStack {
                    Text("録音トリガー")
                    Spacer()
                    Text(isRecording
                         ? "modifier キーを押してください…"
                         : SettingsStore.keyName(for: settings.hotKeyCode))
                        .foregroundStyle(isRecording ? .secondary : .primary)
                    Button(isRecording ? "キャンセル" : "変更") {
                        isRecording ? cancelRecording() : startHotkeyRecording()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
        .onDisappear { cancelRecording() }
    }

    private func preview(_ name: String) {
        guard name != "なし" else { return }
        NSSound(named: .init(name))?.play()
    }

    private func startHotkeyRecording() {
        isRecording = true
        recordingMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            let code = event.keyCode
            let flags = event.modifierFlags
            guard SettingsStore.isKeyDown(keyCode: code, flags: flags) else { return }
            DispatchQueue.main.async {
                SettingsStore.shared.hotKeyCode = code
                self.cancelRecording()
            }
        }
    }

    private func cancelRecording() {
        isRecording = false
        if let m = recordingMonitor { NSEvent.removeMonitor(m) }
        recordingMonitor = nil
    }
}
