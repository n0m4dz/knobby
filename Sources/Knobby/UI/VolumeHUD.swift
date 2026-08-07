import AppKit
import SwiftUI

/// Floating volume bezel shown when the keyboard volume keys are handled in
/// software (macOS shows no native HUD for devices without hardware volume).
@MainActor
final class VolumeHUD {

    final class Model: ObservableObject {
        @Published var volume: Float = 0
        @Published var muted = false
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var showGeneration = 0

    func show(volume: Float, muted: Bool) {
        model.volume = volume
        model.muted = muted
        showGeneration += 1

        let panel = ensurePanel()
        position(panel)
        // Cancel any in-flight fade so a fresh show can't be ordered out by
        // the previous fade's completion.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fadeOut()
            }
        }
    }

    private func fadeOut() {
        guard let panel else { return }
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.showGeneration == generation else { return }
            panel.orderOut(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        newPanel.level = .screenSaver
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.ignoresMouseEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.contentView = NSHostingView(rootView: VolumeHUDView(model: model))
        panel = newPanel
        return newPanel
    }

    private func position(_ panel: NSPanel) {
        // Prefer the screen the mouse is on — with several displays that is the
        // best guess for where the user is looking.
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        guard let screen = mouseScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.12))
    }
}

struct VolumeHUDView: View {
    @ObservedObject var model: VolumeHUD.Model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 22)
            ProgressView(value: Double(min(max(model.muted ? 0 : model.volume, 0), 1)))
                .progressViewStyle(.linear)
            Text(model.muted ? "Muted" : "\(Int((model.volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(width: 240, height: 52)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var symbol: String {
        if model.muted || model.volume <= 0 {
            return "speaker.slash.fill"
        }
        switch model.volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
