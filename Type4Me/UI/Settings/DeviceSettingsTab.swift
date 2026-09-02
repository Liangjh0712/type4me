import SwiftUI

/// Status and controls for an attached AI Passport voice device.
///
/// The device is a remote microphone plus a remote hotkey: hold its top key to
/// record, and the audio takes over from the Mac's microphone for that recording.
/// This page exists mostly to answer "is it connected?", which was previously only
/// visible in the debug log.
struct DeviceSettingsTab: View, SettingsCardHelpers {

    /// Mirrors `PassportLink.snapshot`, refreshed on its change notification rather
    /// than observed — link state changes rarely, and frame-rate data must never
    /// drive SwiftUI invalidation.
    @State private var snapshot = PassportLink.snapshot
    @State private var isReconnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: L("硬件", "HARDWARE"),
                title: L("外接语音设备", "External Voice Device"),
                description: L(
                    "AI Passport 作为远程麦克风与快捷键：按住顶部按键说话，松开完成。",
                    "AI Passport works as a remote microphone and hotkey: hold its top key to talk, release to finish."
                )
            )

            statusCard

            Spacer().frame(height: 16)

            usageCard
        }
        .onReceive(NotificationCenter.default.publisher(for: PassportLink.stateDidChange)) { _ in
            snapshot = PassportLink.snapshot
        }
        .onAppear {
            snapshot = PassportLink.snapshot
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        settingsGroupCard(L("连接状态", "Connection"), icon: "cable.connector") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(
                    label: L("状态", "Status"),
                    value: statusText,
                    statusColor: statusColor
                )

                if let deviceName = snapshot.deviceName {
                    SettingsDivider()
                    SettingsRow(label: L("端口", "Port"), value: deviceName)
                }

                if snapshot.lastDeviceDrop > 0 {
                    SettingsDivider()
                    SettingsRow(
                        label: L("上次录音丢帧", "Dropped last recording"),
                        value: L("\(snapshot.lastDeviceDrop) 帧", "\(snapshot.lastDeviceDrop) frames"),
                        statusColor: TF.settingsAccentAmber
                    )
                }

                SettingsDivider()

                HStack(spacing: 8) {
                    Text(hintText)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if !snapshot.isConnected {
                        reconnectButton
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private var reconnectButton: some View {
        Button {
            isReconnecting = true
            Task {
                await PassportLink.shared.connect()
                snapshot = PassportLink.snapshot
                // Hold the spinner briefly even on a fast failure, or the click
                // produces no visible feedback at all.
                try? await Task.sleep(for: .milliseconds(400))
                isReconnecting = false
            }
        } label: {
            Text(isReconnecting ? L("连接中…", "Connecting…") : L("重新连接", "Reconnect"))
                .font(.system(size: 12, weight: .medium))
        }
        .disabled(isReconnecting)
        .buttonStyle(.borderless)
        .foregroundStyle(TF.settingsAccentAmber)
        .fixedSize()
    }

    private var statusText: String {
        if snapshot.isStreaming { return L("录音中", "Recording") }
        if snapshot.isConnected { return L("已连接", "Connected") }
        return L("未连接", "Not connected")
    }

    private var statusColor: Color {
        if snapshot.isStreaming { return TF.recording }
        if snapshot.isConnected { return TF.success }
        return TF.settingsTextTertiary
    }

    private var hintText: String {
        snapshot.isConnected
            ? L(
                "拔掉设备后自动回到 Mac 麦克风。",
                "Unplugging hands recording back to the Mac microphone.")
            : L(
                "用支持数据传输的 USB 线连接设备，会自动识别。",
                "Connect the device with a data-capable USB cable; it is detected automatically.")
    }

    // MARK: - Usage

    private var usageCard: some View {
        settingsGroupCard(L("按键", "Keys"), icon: "hand.tap") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(
                    label: L("按住顶部按键", "Hold the top key"),
                    value: L("说话，松开完成", "Talk, release to finish"))
                SettingsDivider()
                SettingsRow(
                    label: L("单击下方按键", "Click the bottom key"),
                    value: L("回车", "Return"))
                SettingsDivider()
                SettingsRow(
                    label: L("长按下方按键", "Hold the bottom key"),
                    value: L("清空输入框", "Clear the field"))

                SettingsDivider()

                Text(
                    L(
                        "录音使用当前选中的模式，与键盘快捷键一致；键盘的「按住 / 切换」设置不影响设备。",
                        "Recordings use the currently selected mode, same as the keyboard. The keyboard's hold/toggle preference does not affect the device."
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            }
        }
    }
}
