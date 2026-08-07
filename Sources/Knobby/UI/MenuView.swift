import AppKit
import CoreAudio
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var controller: AudioController
    @EnvironmentObject private var settings: AppSettings

    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if showSettings {
                settingsCard
            }
            sectionLabel("SYSTEM")
            systemCard
            sectionLabel("APPLICATIONS")
            appsCard
            if let error = controller.lastError {
                errorBanner(error, showsPermissionButtons: true) {
                    controller.dismissError()
                }
            }
            if let error = settings.lastError {
                errorBanner(error, showsPermissionButtons: false) {
                    settings.dismissError()
                }
            }
            footerBar
        }
        .padding(12)
        .frame(width: 360)
        .background(hiddenQuitShortcut)
        .onAppear {
            controller.menuOpened()
            settings.refresh()
        }
        .onDisappear { controller.menuClosed() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Knobby")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(showSettings ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Text("Knobby \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Quit") { controller.quit() }
                .controlSize(.small)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Settings

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingRow("Launch at Login") {
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
            }
            settingRow("Show volume HUD") {
                Toggle("", isOn: $settings.showVolumeHUD)
            }
            settingRow("Fine volume key steps (3%)") {
                Toggle("", isOn: $settings.fineVolumeKeys)
            }
            settingRow("Menu bar icon") {
                HStack(spacing: 5) {
                    ForEach(AppSettings.iconChoices, id: \.self) { icon in
                        Button {
                            settings.menuBarIcon = icon
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 11))
                                .frame(width: 26, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(settings.menuBarIcon == icon
                                            ? Color.accentColor.opacity(0.25)
                                            : Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private func settingRow(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            control()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private var hiddenQuitShortcut: some View {
        Button("") { controller.quit() }
            .keyboardShortcut("q")
            .hidden()
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    // MARK: - Cards

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private var systemCard: some View {
        VStack(spacing: 0) {
            SystemRow(
                title: "Output",
                icon: "speaker.wave.2.fill",
                mutedIcon: "speaker.slash.fill",
                state: controller.outputState,
                devices: controller.outputDevices,
                selectedID: controller.defaultOutputID,
                onVolume: { controller.setOutputVolume($0) },
                onMute: { controller.toggleOutputMute() },
                onSelect: { controller.setDefaultOutput($0) })
            CardDivider()
            SystemRow(
                title: "Input",
                icon: "mic.fill",
                mutedIcon: "mic.slash.fill",
                state: controller.inputState,
                devices: controller.inputDevices,
                selectedID: controller.defaultInputID,
                onVolume: { controller.setInputVolume($0) },
                onMute: { controller.toggleInputMute() },
                onSelect: { controller.setDefaultInput($0) })
            CardDivider()
            SystemRow(
                title: "Sound Effects",
                icon: "bell.fill",
                mutedIcon: "bell.slash.fill",
                state: controller.effectsState,
                devices: controller.outputDevices,
                selectedID: controller.effectsDeviceID,
                onVolume: { controller.setEffectsVolume($0) },
                onMute: { controller.toggleEffectsMute() },
                onSelect: { controller.setEffectsDevice($0) })
        }
        .padding(.horizontal, 12)
        .background(cardBackground)
    }

    private var appsCard: some View {
        Group {
            if controller.apps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18))
                        .foregroundStyle(.quaternary)
                    Text("Apps appear here once they play audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(cardBackground)
            } else if controller.apps.count > 4 {
                ScrollView(showsIndicators: false) {
                    appRows
                }
                .frame(height: 296)
                .background(cardBackground)
            } else {
                appRows
                    .background(cardBackground)
            }
        }
    }

    private var appRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.apps.enumerated()), id: \.element.id) { index, app in
                if index > 0 {
                    CardDivider()
                }
                AppRow(
                    app: app,
                    outputDevices: controller.outputDevices,
                    onVolume: { controller.setAppVolume(app.pid, $0) },
                    onRedirect: { controller.setAppRedirect(app.pid, $0) })
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Error banner

    private func errorBanner(_ error: String,
                             showsPermissionButtons: Bool,
                             onDismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            if showsPermissionButtons, controller.permissionHint != nil {
                HStack(spacing: 8) {
                    Button("Open System Settings…") {
                        controller.openPermissionSettings()
                    }
                    if controller.permissionHint == .accessibility {
                        Button("Retry") {
                            controller.retryMediaKeys()
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - Rows

private struct CardDivider: View {
    var body: some View {
        Divider().opacity(0.6)
    }
}

struct SystemRow: View {
    let title: String
    let icon: String
    let mutedIcon: String
    let state: AudioController.DeviceControlState
    let devices: [AudioDevice]
    let selectedID: AudioDeviceID
    let onVolume: (Float) -> Void
    let onMute: () -> Void
    let onSelect: (AudioDeviceID) -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                DevicePicker(
                    devices: devices,
                    selectedID: selectedID,
                    fallbackIcon: icon,
                    onSelect: onSelect)
            }
            HStack(spacing: 9) {
                Button(action: onMute) {
                    Image(systemName: state.muted ? mutedIcon : icon)
                        .font(.system(size: 12))
                        .foregroundStyle(state.muted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .disabled(!state.canMute)
                .help(state.canMute ? "Mute \(title)" : "\(title) can't be muted on this device")

                VolumeSlider(
                    value: Binding(
                        get: { state.volume ?? 0 },
                        set: { onVolume($0) }),
                    disabled: state.volume == nil)

                Text(state.volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                    .help(state.isSoftware ? "Software volume (device has no hardware control)" : "")
            }
        }
        .padding(.vertical, 10)
    }
}

struct AppRow: View {
    let app: AudioController.AppAudio
    let outputDevices: [AudioDevice]
    let onVolume: (Float) -> Void
    let onRedirect: (String?) -> Void

    private var redirectName: String {
        guard let uid = app.redirectUID else { return "Default" }
        return outputDevices.first { $0.uid == uid }?.name ?? "Default"
    }

    private var volumeSymbol: String {
        if app.volume <= 0 { return "speaker.slash.fill" }
        switch app.volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 17, height: 17)

                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if app.isPlaying {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                }

                Spacer(minLength: 8)

                Menu {
                    Button {
                        onRedirect(nil)
                    } label: {
                        if app.redirectUID == nil {
                            Label("Default Output", systemImage: "checkmark")
                        } else {
                            Text("Default Output")
                        }
                    }
                    Divider()
                    ForEach(outputDevices) { device in
                        Button {
                            onRedirect(device.uid)
                        } label: {
                            if app.redirectUID == device.uid {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(redirectName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(maxWidth: 150, alignment: .trailing)
            }
            HStack(spacing: 9) {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VolumeSlider(
                    value: Binding(
                        get: { app.volume },
                        set: { onVolume($0) }))

                Text("\(Int((app.volume * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.vertical, 10)
    }
}

struct DevicePicker: View {
    let devices: [AudioDevice]
    let selectedID: AudioDeviceID
    let fallbackIcon: String
    let onSelect: (AudioDeviceID) -> Void

    private var selected: AudioDevice? {
        devices.first { $0.id == selectedID }
    }

    var body: some View {
        Menu {
            ForEach(devices) { device in
                Button {
                    onSelect(device.id)
                } label: {
                    if device.id == selectedID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected?.symbolName ?? fallbackIcon)
                    .font(.system(size: 9))
                Text(selected?.name ?? "None")
                    .font(.system(size: 11))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: 180, alignment: .trailing)
    }
}

// MARK: - Slider

/// Slim custom slider: thin capsule track, tinted fill, white knob.
struct VolumeSlider: View {
    @Binding var value: Float
    var disabled: Bool = false

    private let knobSize: CGFloat = 13
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let usable = max(width - knobSize, 1)
            let progress = CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(disabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint))
                    .frame(width: progress * usable + knobSize / 2, height: trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .offset(x: progress * usable)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard !disabled else { return }
                        let raw = (drag.location.x - knobSize / 2) / usable
                        value = Float(min(max(raw, 0), 1))
                    })
        }
        .frame(height: 20)
        .opacity(disabled ? 0.45 : 1)
    }
}
