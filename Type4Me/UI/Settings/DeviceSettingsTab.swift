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
    @AppStorage(PassportLinkPreferences.bluetoothEnabledKey) private var bluetoothEnabled = true

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
                    SettingsRow(label: L("连接方式", "Link"), value: transportText)
                    SettingsDivider()
                    SettingsRow(label: L("设备", "Device"), value: deviceName)
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

                bluetoothToggleRow

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

    /// Wireless can be turned off to keep the link wired-only — useful while
    /// debugging, since the wired channel carries a console, and it avoids a pairing
    /// prompt for anyone without the hardware.
    private var bluetoothToggleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("通过蓝牙连接", "Connect over Bluetooth"))
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsText)
                Text(L("关闭后仅使用 USB", "When off, only USB is used"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            Spacer()
            Toggle("", isOn: $bluetoothEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 10)
        .onChange(of: bluetoothEnabled) { _, enabled in
            // Applying immediately is what makes the switch feel like a switch:
            // turning it off drops an active wireless link, turning it on starts
            // looking right away instead of at the next discovery tick.
            Task {
                if enabled {
                    await PassportLink.shared.connect()
                } else if snapshot.transport == .bluetooth {
                    await PassportLink.shared.disconnect()
                }
                snapshot = PassportLink.snapshot
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

    private var transportText: String {
        switch snapshot.transport {
        case .bluetooth: return L("蓝牙", "Bluetooth")
        case .usb: return L("USB", "USB")
        case nil: return "—"
        }
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
                "设备按键录设备麦克风，Mac 快捷键仍录 Mac 麦克风，互不影响。",
                "The device key records from the device; Mac hotkeys keep using the Mac microphone.")
            : L(
                "用支持数据传输的 USB 线连接，或开启蓝牙后靠近电脑即可。",
                "Connect a data-capable USB cable, or bring the device near the Mac with Bluetooth on.")
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
                        "设备录音使用当前选中的模式，与键盘一致；但麦克风各自独立——键盘快捷键始终录 Mac 麦克风。",
                        "The device records with the currently selected mode, same as the keyboard — but the microphones are separate: a keyboard hotkey always records from the Mac."
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
