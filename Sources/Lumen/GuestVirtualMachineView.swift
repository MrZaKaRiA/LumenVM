import AppKit
import Virtualization
import LumenCore

/// Give the native guest view a Cocoa edit responder. SPICE transports text;
/// these actions ask the focused guest application to consume that clipboard.
@MainActor
final class GuestVirtualMachineView: VZVirtualMachineView, NSMenuItemValidation {
    var guestRecord: VirtualMachineRecord?
    var guestIsRunning = false

    static let focusChanged = Notification.Name("LumenGuestClipboardFocusChanged")

    var supportsGuestEditing: Bool {
        guestIsRunning && guestRecord?.guest.isLinux == true && guestRecord?.clipboardSharing == true
    }

    var terminalShortcuts: Bool {
        get {
            guard let record = guestRecord else { return false }
            return UserDefaults.standard.object(forKey: defaultsKey(record)) as? Bool
                ?? (record.guest == .abyssLinux)
        }
        set {
            guard let record = guestRecord else { return }
            UserDefaults.standard.set(newValue, forKey: defaultsKey(record))
            notifyFocusChanged()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { notifyFocusChanged() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { notifyFocusChanged() }
        return accepted
    }

    private func notifyFocusChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.focusChanged, object: nil) }
    }

    private func defaultsKey(_ record: VirtualMachineRecord) -> String {
        "terminalClipboardShortcuts-" + record.id.uuidString
    }

    @objc func paste(_ sender: Any?) {
        guard supportsGuestEditing, NSPasteboard.general.types?.contains(.string) == true else { return }
        sendGuestEdit(keyCode: 9, terminal: terminalShortcuts)
    }

    @objc func copy(_ sender: Any?) {
        guard supportsGuestEditing else { return }
        sendGuestEdit(keyCode: 8, terminal: terminalShortcuts)
    }

    @objc func cut(_ sender: Any?) {
        guard supportsGuestEditing, !terminalShortcuts else { return }
        sendGuestEdit(keyCode: 7, terminal: false)
    }

    override func selectAll(_ sender: Any?) {
        // Ctrl+A moves the cursor in a terminal; it must not be labelled Select All.
        guard supportsGuestEditing, !terminalShortcuts else { return }
        sendGuestEdit(keyCode: 0, terminal: false)
    }

    @objc func pasteInGuestTerminal(_ sender: Any?) {
        guard supportsGuestEditing, NSPasteboard.general.types?.contains(.string) == true else { return }
        sendGuestEdit(keyCode: 9, terminal: true)
    }

    @objc func toggleGuestTerminalShortcuts(_ sender: Any?) {
        guard supportsGuestEditing else { return }
        terminalShortcuts.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)), #selector(pasteInGuestTerminal(_:)):
            return supportsGuestEditing && NSPasteboard.general.types?.contains(.string) == true
        case #selector(copy(_:)):
            return supportsGuestEditing
        case #selector(cut(_:)), #selector(selectAll(_:)):
            return supportsGuestEditing && !terminalShortcuts
        case #selector(toggleGuestTerminalShortcuts(_:)):
            item.state = terminalShortcuts ? .on : .off
            return supportsGuestEditing
        default:
            return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleGuestEditShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleGuestEditShortcut(event) { super.keyDown(with: event) }
    }

    private func handleGuestEditShortcut(_ event: NSEvent) -> Bool {
        guard supportsGuestEditing, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags == .command || flags == [.command, .shift] else { return false }
        switch (event.keyCode, flags.contains(.shift)) {
        case (9, false): paste(nil)
        case (9, true): pasteInGuestTerminal(nil)
        case (8, false): copy(nil)
        case (7, false): cut(nil)
        case (0, false): selectAll(nil)
        default: return false
        }
        return true
    }

    private func sendGuestEdit(keyCode: UInt16, terminal: Bool) {
        guard window?.isKeyWindow == true, window?.firstResponder === self,
              window?.attachedSheet == nil else { return }
        // Command may already be down in Linux because capturesSystemKeys is on.
        // Clear it before pressing Control, or the guest receives Super+Ctrl+V.
        let original = NSEvent.modifierFlags
        modifier(55, [])
        modifier(54, [])
        let control = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x1)
        let shifted = control.union(NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2))
        modifier(59, control)
        if terminal { modifier(56, shifted) }
        let flags = terminal ? shifted : control
        let character = keyCode == 9 ? "v" : keyCode == 8 ? "c" : keyCode == 7 ? "x" : "a"
        if let event = keyEvent(.keyDown, code: keyCode, flags: flags, characters: character) { super.keyDown(with: event) }
        if let event = keyEvent(.keyUp, code: keyCode, flags: flags, characters: character) { super.keyUp(with: event) }
        if terminal { modifier(56, control) }
        modifier(59, [])
        // Preserve physically held modifiers for subsequent guest shortcuts.
        if original.contains(.shift) {
            modifier(original.rawValue & 0x4 != 0 ? 60 : 56, original)
        }
        if original.contains(.command) {
            modifier(original.rawValue & 0x10 != 0 ? 54 : 55, original)
        }
    }

    private func modifier(_ code: UInt16, _ flags: NSEvent.ModifierFlags) {
        if let event = keyEvent(.flagsChanged, code: code, flags: flags, characters: "") { super.flagsChanged(with: event) }
    }

    private func keyEvent(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags, characters: String) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window?.windowNumber ?? 0, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)
    }
}
