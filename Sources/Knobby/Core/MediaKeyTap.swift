import AppKit
import ApplicationServices
import CoreGraphics

/// Intercepts the keyboard volume/mute media keys with a CGEventTap so they
/// keep working when the output device has no hardware volume (macOS disables
/// them natively for HDMI/DisplayPort displays). Requires the Accessibility
/// permission. The tap runs on the main run loop.
final class MediaKeyTap {
    enum Key {
        case volumeUp
        case volumeDown
        case mute
    }

    /// Called on key-down (including auto-repeat). Return true to swallow the
    /// event, false to let macOS handle it natively.
    var handler: ((_ key: Key, _ isRepeat: Bool) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastKeyDownHandled = false

    var isActive: Bool { eventTap != nil }

    private static let systemDefinedEventType: UInt32 = 14 // NX_SYSDEFINED

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.process(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << Self.systemDefinedEventType),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        eventTap = nil
    }

    static func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else { // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) != 0

        let key: Key
        switch keyCode {
        case 0: key = .volumeUp   // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute       // NX_KEYTYPE_MUTE
        default: return Unmanaged.passUnretained(event)
        }

        guard let handler else { return Unmanaged.passUnretained(event) }

        if isKeyDown {
            lastKeyDownHandled = handler(key, isRepeat)
            return lastKeyDownHandled ? nil : Unmanaged.passUnretained(event)
        }
        // Swallow the matching key-up when we handled the key-down.
        return lastKeyDownHandled ? nil : Unmanaged.passUnretained(event)
    }
}
