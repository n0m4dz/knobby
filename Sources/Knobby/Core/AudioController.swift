import AppKit
import ApplicationServices
import Combine
import CoreAudio
import Foundation

@MainActor
final class AudioController: ObservableObject {

    struct DeviceControlState {
        var volume: Float?
        var muted = false
        var canMute = false
        /// True when volume is applied in software via a global tap
        /// (devices like HDMI/DisplayPort displays with no hardware volume).
        var isSoftware = false
    }

    struct AppAudio: Identifiable {
        let pid: pid_t
        let objectID: AudioObjectID
        let bundleID: String?
        let name: String
        let icon: NSImage?
        let isPlaying: Bool
        var volume: Float
        var redirectUID: String?

        var id: pid_t { pid }

        var wantsEngine: Bool {
            abs(volume - 1) > 0.001 || redirectUID != nil
        }
    }

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultOutputID: AudioDeviceID = 0
    @Published private(set) var defaultInputID: AudioDeviceID = 0
    @Published private(set) var effectsDeviceID: AudioDeviceID = 0
    @Published private(set) var outputState = DeviceControlState()
    @Published private(set) var inputState = DeviceControlState()
    @Published private(set) var effectsState = DeviceControlState()
    @Published private(set) var apps: [AppAudio] = []
    @Published private(set) var lastError: String?
    @Published private(set) var permissionHint: PermissionKind?

    enum PermissionKind {
        case accessibility
        case audioCapture

        var settingsURL: URL? {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            case .audioCapture:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
            }
        }
    }

    var outputDevices: [AudioDevice] { devices.filter(\.hasOutput) }
    var inputDevices: [AudioDevice] { devices.filter(\.hasInput) }

    private var appEngines: [pid_t: TapEngine] = [:]
    private var systemEngine: TapEngine?
    private var systemEngineExcludes: Set<AudioObjectID> = []
    private var softwareMutedUIDs: Set<String> = []
    private var sessionActivePIDs: Set<pid_t> = []
    private var refreshTimer: Timer?
    private var lastDefaultOutputUID: String?
    private var listenerBlocks: [AudioObjectPropertyListenerBlock] = []
    private let defaults = UserDefaults.standard
    private let mediaKeyTap = MediaKeyTap()
    private let volumeHUD = VolumeHUD()

    init() {
        refreshAll()
        installListeners()
        setupMediaKeys()
    }

    // MARK: - Menu lifecycle

    func menuOpened() {
        refreshAll()
        // Accessibility may have been granted since launch — retry silently.
        attemptMediaKeyStart(promptIfNeeded: false)
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAll()
            }
        }
    }

    func menuClosed() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func quit() {
        for engine in appEngines.values {
            engine.stop()
        }
        appEngines.removeAll()
        systemEngine?.stop()
        systemEngine = nil
        NSApp.terminate(nil)
    }

    // MARK: - Default devices

    func setDefaultOutput(_ id: AudioDeviceID) {
        CA.set(CA.system, CA.addr(kAudioHardwarePropertyDefaultOutputDevice), id)
        refreshAll()
    }

    func setDefaultInput(_ id: AudioDeviceID) {
        CA.set(CA.system, CA.addr(kAudioHardwarePropertyDefaultInputDevice), id)
        refreshAll()
    }

    func setEffectsDevice(_ id: AudioDeviceID) {
        CA.set(CA.system, CA.addr(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
        refreshAll()
    }

    // MARK: - System volume / mute

    func setOutputVolume(_ volume: Float) {
        if outputState.isSoftware {
            guard let uid = AudioDevice.uid(of: defaultOutputID) else { return }
            defaults.set(volume, forKey: softwareVolumeKey(uid))
            outputState.volume = volume
            applySystemEngine()
        } else {
            AudioDevice.setVolume(defaultOutputID, CA.outputScope, volume)
            outputState.volume = volume
        }
    }

    func toggleOutputMute() {
        if outputState.isSoftware {
            guard let uid = AudioDevice.uid(of: defaultOutputID) else { return }
            if softwareMutedUIDs.contains(uid) {
                softwareMutedUIDs.remove(uid)
            } else {
                softwareMutedUIDs.insert(uid)
            }
            outputState.muted = softwareMutedUIDs.contains(uid)
            applySystemEngine()
        } else {
            let muted = !outputState.muted
            AudioDevice.setMuted(defaultOutputID, CA.outputScope, muted)
            outputState.muted = muted
        }
    }

    func setInputVolume(_ volume: Float) {
        AudioDevice.setVolume(defaultInputID, CA.inputScope, volume)
        inputState.volume = volume
    }

    func toggleInputMute() {
        let muted = !inputState.muted
        AudioDevice.setMuted(defaultInputID, CA.inputScope, muted)
        inputState.muted = muted
    }

    func setEffectsVolume(_ volume: Float) {
        AudioDevice.setVolume(effectsDeviceID, CA.outputScope, volume)
        effectsState.volume = volume
    }

    func toggleEffectsMute() {
        let muted = !effectsState.muted
        AudioDevice.setMuted(effectsDeviceID, CA.outputScope, muted)
        effectsState.muted = muted
    }

    // MARK: - Media keys

    /// Volume keys are only intercepted while the output needs software volume;
    /// devices with hardware volume keep the native keys and bezel.
    private func setupMediaKeys() {
        mediaKeyTap.handler = { [weak self] key, _ in
            guard let self else { return false }
            return MainActor.assumeIsolated {
                self.handleMediaKey(key)
            }
        }
        attemptMediaKeyStart(promptIfNeeded: true)
    }

    func retryMediaKeys() {
        attemptMediaKeyStart(promptIfNeeded: false)
    }

    private func attemptMediaKeyStart(promptIfNeeded: Bool) {
        guard !mediaKeyTap.isActive else { return }
        if mediaKeyTap.start() {
            if permissionHint == .accessibility {
                dismissError()
            }
            return
        }
        // Rebuilt dev binaries get a new code hash, which silently invalidates
        // an existing Accessibility entry even though it still shows as enabled.
        if AXIsProcessTrusted() {
            lastError = "Accessibility is granted, but the volume-key tap could not start. Quit and relaunch Knobby."
        } else {
            if promptIfNeeded {
                MediaKeyTap.requestAccessibilityPermission()
            }
            lastError = "Volume keys need the Accessibility permission. If Knobby is already listed and enabled there, remove it with the − button, relaunch the app, and grant it again (a rebuilt binary invalidates the old entry)."
        }
        permissionHint = .accessibility
    }

    func openPermissionSettings() {
        guard let url = permissionHint?.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    func dismissError() {
        lastError = nil
        permissionHint = nil
    }

    private func reportEngineError(_ error: Error) {
        lastError = error.localizedDescription
        if let tapError = error as? TapEngineError, tapError.kind == .permission {
            permissionHint = .audioCapture
        } else {
            permissionHint = nil
        }
    }

    private func handleMediaKey(_ key: MediaKeyTap.Key) -> Bool {
        guard outputState.isSoftware else { return false }
        let step = AppSettings.shared.volumeKeyStep
        switch key {
        case .volumeUp:
            if outputState.muted {
                toggleOutputMute()
            }
            setOutputVolume(min(1, (outputState.volume ?? 0) + step))
        case .volumeDown:
            setOutputVolume(max(0, (outputState.volume ?? 0) - step))
        case .mute:
            toggleOutputMute()
        }
        if AppSettings.shared.showVolumeHUD {
            volumeHUD.show(volume: outputState.volume ?? 0, muted: outputState.muted)
        }
        return true
    }

    // MARK: - Per-app volume / redirect

    func setAppVolume(_ pid: pid_t, _ volume: Float) {
        guard let index = apps.firstIndex(where: { $0.pid == pid }) else { return }
        apps[index].volume = volume
        persistAppSettings(apps[index])
        applyAppEngine(apps[index])
    }

    func setAppRedirect(_ pid: pid_t, _ uid: String?) {
        guard let index = apps.firstIndex(where: { $0.pid == pid }) else { return }
        apps[index].redirectUID = uid
        persistAppSettings(apps[index])
        applyAppEngine(apps[index])
    }

    // MARK: - Refresh

    private func refreshAll() {
        refreshDevices()
        refreshApps()
        reconcileAppEngineRouting()
        applySystemEngine()
    }

    private func refreshDevices() {
        devices = AudioDevice.all().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        defaultOutputID = CA.get(CA.system, CA.addr(kAudioHardwarePropertyDefaultOutputDevice), default: AudioDeviceID(0))
        defaultInputID = CA.get(CA.system, CA.addr(kAudioHardwarePropertyDefaultInputDevice), default: AudioDeviceID(0))
        effectsDeviceID = CA.get(CA.system, CA.addr(kAudioHardwarePropertyDefaultSystemOutputDevice), default: AudioDeviceID(0))

        let outputUID = AudioDevice.uid(of: defaultOutputID)
        if outputUID != lastDefaultOutputUID {
            lastDefaultOutputUID = outputUID
            handleDefaultOutputChange()
        }
        refreshControlStates()
    }

    private func handleDefaultOutputChange() {
        // Software volume is per-device: drop the old engine, a new one is
        // built lazily by applySystemEngine when needed. App engines are
        // rerouted by reconcileAppEngineRouting on the same refresh pass.
        systemEngine?.stop()
        systemEngine = nil
        systemEngineExcludes = []
    }

    /// The device an app's engine should route to: the redirect target while
    /// it is present, otherwise the current default output.
    private func effectiveOutputUID(for app: AppAudio) -> String? {
        if let redirect = app.redirectUID, devices.contains(where: { $0.uid == redirect }) {
            return redirect
        }
        return AudioDevice.uid(of: defaultOutputID)
    }

    /// Keeps every app engine pointed at a device that still exists — covers
    /// both a changed default output and an unplugged redirect target (the
    /// redirect is kept as intent and re-applied when the device returns).
    private func reconcileAppEngineRouting() {
        for app in apps {
            guard let engine = appEngines[app.pid],
                  let targetUID = effectiveOutputUID(for: app),
                  engine.outputUID != targetUID else { continue }
            do {
                try engine.start(outputDeviceUID: targetUID)
            } catch {
                reportEngineError(error)
            }
        }
    }

    private func refreshControlStates() {
        outputState = outputControlState()
        inputState = hardwareControlState(defaultInputID, CA.inputScope)
        effectsState = hardwareControlState(effectsDeviceID, CA.outputScope)
    }

    private func outputControlState() -> DeviceControlState {
        if let hardware = AudioDevice.volume(defaultOutputID, CA.outputScope) {
            return DeviceControlState(
                volume: hardware,
                muted: AudioDevice.isMuted(defaultOutputID, CA.outputScope),
                canMute: AudioDevice.canMute(defaultOutputID, CA.outputScope),
                isSoftware: false)
        }
        guard let uid = AudioDevice.uid(of: defaultOutputID) else { return DeviceControlState() }
        return DeviceControlState(
            volume: softwareVolume(for: uid),
            muted: softwareMutedUIDs.contains(uid),
            canMute: true,
            isSoftware: true)
    }

    private func hardwareControlState(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> DeviceControlState {
        DeviceControlState(
            volume: AudioDevice.volume(id, scope),
            muted: AudioDevice.isMuted(id, scope),
            canMute: AudioDevice.canMute(id, scope),
            isSoftware: false)
    }

    private func refreshApps() {
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        var byPID: [pid_t: AudioProcessInfo] = [:]
        for process in AudioProcessList.all() where process.pid != selfPID {
            if let existing = byPID[process.pid] {
                if process.isRunningOutput && !existing.isRunningOutput {
                    byPID[process.pid] = process
                }
            } else {
                byPID[process.pid] = process
            }
        }

        var newApps: [AppAudio] = []
        for (pid, process) in byPID {
            guard let running = NSRunningApplication(processIdentifier: pid) else { continue }
            if process.isRunningOutput {
                sessionActivePIDs.insert(pid)
            }
            let hasEngine = appEngines[pid] != nil
            guard process.isRunningOutput || hasEngine || sessionActivePIDs.contains(pid) else { continue }
            let previous = apps.first { $0.pid == pid }
            // First sighting this session: restore the persisted settings.
            let volume = previous?.volume ?? persistedAppVolume(for: process.bundleID)
            let redirectUID = previous != nil
                ? previous?.redirectUID
                : persistedAppRedirect(for: process.bundleID)
            newApps.append(AppAudio(
                pid: pid,
                objectID: process.objectID,
                bundleID: process.bundleID,
                name: running.localizedName ?? process.bundleID ?? "PID \(pid)",
                icon: running.icon,
                isPlaying: process.isRunningOutput,
                volume: volume,
                redirectUID: redirectUID))
        }
        newApps.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        apps = newApps

        for pid in Array(appEngines.keys) where byPID[pid] == nil {
            appEngines.removeValue(forKey: pid)?.stop()
            sessionActivePIDs.remove(pid)
        }

        // Restored (persisted) settings need their engine brought up — the
        // user set nothing this session, so nobody else will create it.
        for app in apps where app.wantsEngine && appEngines[app.pid] == nil {
            applyAppEngine(app)
        }
    }

    // MARK: - Engines

    private func applyAppEngine(_ app: AppAudio) {
        if app.wantsEngine {
            guard let targetUID = effectiveOutputUID(for: app) else { return }
            if let engine = appEngines[app.pid] {
                if engine.outputUID != targetUID {
                    do {
                        try engine.start(outputDeviceUID: targetUID)
                    } catch {
                        reportEngineError(error)
                    }
                }
            } else {
                let engine = TapEngine(target: .process(app.objectID))
                do {
                    try engine.start(outputDeviceUID: targetUID)
                    appEngines[app.pid] = engine
                    dismissError()
                } catch {
                    reportEngineError(error)
                    return
                }
            }
        } else if let engine = appEngines.removeValue(forKey: app.pid) {
            engine.stop()
        }
        applySystemEngine()
    }

    /// Keeps the global software-volume engine in sync: running only when the
    /// current output needs software volume and it differs from unity, with all
    /// per-app-tapped processes (and ourselves) excluded to avoid double audio.
    private func applySystemEngine() {
        guard outputState.isSoftware, let uid = AudioDevice.uid(of: defaultOutputID) else {
            systemEngine?.stop()
            systemEngine = nil
            systemEngineExcludes = []
            updateAppEngineGains()
            return
        }

        let gain = softwareMutedUIDs.contains(uid) ? 0 : softwareVolume(for: uid)
        let needsEngine = abs(gain - 1) > 0.001

        guard needsEngine else {
            systemEngine?.stop()
            systemEngine = nil
            systemEngineExcludes = []
            updateAppEngineGains()
            return
        }

        guard let selfObject = CA.processObject(for: pid_t(ProcessInfo.processInfo.processIdentifier)) else {
            lastError = "Could not identify own audio process; software volume unavailable."
            updateAppEngineGains()
            return
        }
        var excludes: Set<AudioObjectID> = [selfObject]
        for app in apps where appEngines[app.pid] != nil {
            excludes.insert(app.objectID)
        }

        if let engine = systemEngine {
            engine.gain = gain
            if excludes != systemEngineExcludes {
                do {
                    try engine.update(target: .globalExcluding(Array(excludes)))
                    systemEngineExcludes = excludes
                } catch {
                    reportEngineError(error)
                }
            }
        } else {
            let engine = TapEngine(target: .globalExcluding(Array(excludes)))
            engine.gain = gain
            do {
                try engine.start(outputDeviceUID: uid)
                systemEngine = engine
                systemEngineExcludes = excludes
                dismissError()
            } catch {
                reportEngineError(error)
            }
        }
        updateAppEngineGains()
    }

    /// Per-app engines bypass the global tap (their processes are excluded), so
    /// the software system volume has to be folded into their gain.
    private func updateAppEngineGains() {
        let defaultUID = AudioDevice.uid(of: defaultOutputID)
        var systemGain: Float = 1
        if outputState.isSoftware, let uid = defaultUID {
            systemGain = softwareMutedUIDs.contains(uid) ? 0 : softwareVolume(for: uid)
        }
        for app in apps {
            guard let engine = appEngines[app.pid] else { continue }
            // Base this on where the engine actually routes (a missing
            // redirect target falls back to the default output).
            let targetsDefault = engine.outputUID == nil || engine.outputUID == defaultUID
            engine.gain = app.volume * (targetsDefault ? systemGain : 1)
        }
    }

    // MARK: - Software volume persistence

    private func softwareVolumeKey(_ uid: String) -> String {
        "softwareVolume.\(uid)"
    }

    private func softwareVolume(for uid: String) -> Float {
        guard defaults.object(forKey: softwareVolumeKey(uid)) != nil else { return 1 }
        return defaults.float(forKey: softwareVolumeKey(uid))
    }

    // MARK: - Per-app persistence

    /// Per-app volume/redirect is keyed by bundle ID so it survives both app
    /// and Knobby relaunches (PIDs don't). Unity volume / no redirect clears
    /// the keys, so defaults only holds apps the user actually adjusted.
    private func appVolumeKey(_ bundleID: String) -> String {
        "appVolume.\(bundleID)"
    }

    private func appRedirectKey(_ bundleID: String) -> String {
        "appRedirect.\(bundleID)"
    }

    private func persistedAppVolume(for bundleID: String?) -> Float {
        guard let bundleID, defaults.object(forKey: appVolumeKey(bundleID)) != nil else { return 1 }
        return min(max(defaults.float(forKey: appVolumeKey(bundleID)), 0), 1)
    }

    private func persistedAppRedirect(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return defaults.string(forKey: appRedirectKey(bundleID))
    }

    private func persistAppSettings(_ app: AppAudio) {
        guard let bundleID = app.bundleID else { return }
        if abs(app.volume - 1) > 0.001 {
            defaults.set(app.volume, forKey: appVolumeKey(bundleID))
        } else {
            defaults.removeObject(forKey: appVolumeKey(bundleID))
        }
        if let redirect = app.redirectUID {
            defaults.set(redirect, forKey: appRedirectKey(bundleID))
        } else {
            defaults.removeObject(forKey: appRedirectKey(bundleID))
        }
    }

    // MARK: - HAL listeners

    private func installListeners() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            kAudioHardwarePropertyProcessObjectList,
        ]
        for selector in selectors {
            var address = CA.addr(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshAll()
                }
            }
            AudioObjectAddPropertyListenerBlock(CA.system, &address, .main, block)
            listenerBlocks.append(block)
        }
    }
}
