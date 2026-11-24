import Cocoa
import Carbon

final class HotkeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: () -> Void

    init(handler: @escaping () -> Void) { self.handler = handler }

    func registerDefaultShortcut() {
        let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            HotkeyController.handleHotKey,
            1,
            [eventType],
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            NSLog("PinSnap: InstallEventHandler failed with status \(installStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: 0x50534E50, id: 1)
        let modifiers = UInt32(cmdKey | shiftKey)
        let registerStatus = RegisterEventHotKey(UInt32(kVK_ANSI_2), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if registerStatus != noErr {
            NSLog("PinSnap: RegisterEventHotKey failed with status \(registerStatus)")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    private static let handleHotKey: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { controller.handler() }
        return noErr
    }
}
