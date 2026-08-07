import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let iconChoices = [
        "waveform",
        "speaker.wave.2.fill",
        "hifispeaker.fill",
        "slider.horizontal.3",
        "music.note",
    ]

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var lastError: String?

    @Published var showVolumeHUD: Bool {
        didSet { defaults.set(showVolumeHUD, forKey: "showVolumeHUD") }
    }

    /// Fine = 1/32 (~3%) per key press instead of the macOS-style 1/16 (~6%).
    @Published var fineVolumeKeys: Bool {
        didSet { defaults.set(fineVolumeKeys, forKey: "fineVolumeKeys") }
    }

    @Published var menuBarIcon: String {
        didSet { defaults.set(menuBarIcon, forKey: "menuBarIcon") }
    }

    var volumeKeyStep: Float {
        fineVolumeKeys ? 1.0 / 32.0 : 1.0 / 16.0
    }

    private let defaults = UserDefaults.standard

    private init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        showVolumeHUD = defaults.object(forKey: "showVolumeHUD") as? Bool ?? true
        fineVolumeKeys = defaults.bool(forKey: "fineVolumeKeys")
        menuBarIcon = defaults.string(forKey: "menuBarIcon") ?? "waveform"
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // Registration needs a real .app bundle; a bare `swift run` binary is rejected.
            lastError = "Launch at Login could not be changed: \(error.localizedDescription) Build the app bundle (scripts/make-app.sh) and run it from /Applications."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func dismissError() {
        lastError = nil
    }
}
