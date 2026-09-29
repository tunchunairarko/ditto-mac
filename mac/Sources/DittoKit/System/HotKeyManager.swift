import Foundation
import AppKit
import Carbon.HIToolbox

/// Port of `CHotKey` / `CHotKeys` (HotKeys.cpp).
///
/// Windows Ditto calls `RegisterHotKey`; the macOS equivalent is Carbon's
/// `RegisterEventHotKey`, which is still the only supported way for a
/// background app to claim a system-wide key combination.
final class HotKeyManager {

    static let shared = HotKeyManager()

    private struct Registration {
        var ref: EventHotKeyRef?
        var handler: () -> Void
        var hotKey: HotKey
        var label: String
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4469_7474        // 'Ditt'

    private init() {}

    // MARK: - Carbon plumbing

    func install() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }
            HotKeyManager.shared.handle(id: hotKeyID.id)
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    private func handle(id: UInt32) {
        guard let registration = registrations[id] else { return }
        Log.write("hot key fired: \(registration.label)")
        DispatchQueue.main.async {
            registration.handler()
        }
    }

    // MARK: - Registering

    @discardableResult
    func register(_ hotKey: HotKey,
                  label: String,
                  handler: @escaping () -> Void) -> UInt32? {
        install()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(hotKey.keyCode,
                                         hotKey.carbonModifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)

        guard status == noErr, let registered = ref else {
            Log.error("could not register \(label) (\(hotKey.description)): another app probably has it")
            return nil
        }

        registrations[id] = Registration(ref: registered,
                                         handler: handler,
                                         hotKey: hotKey,
                                         label: label)
        Log.write("registered \(label) as \(hotKey.description)")
        return id
    }

    @discardableResult
    func register(_ string: String,
                  label: String,
                  handler: @escaping () -> Void) -> UInt32? {
        guard let hotKey = HotKey(string: string) else { return nil }
        return register(hotKey, label: label, handler: handler)
    }

    func unregisterAll() {
        for (_, registration) in registrations {
            if let ref = registration.ref {
                UnregisterEventHotKey(ref)
            }
        }
        registrations.removeAll()
    }

    /// Which combinations are live, for the options window.
    var activeHotKeys: [(label: String, hotKey: HotKey)] {
        return registrations.values.map { ($0.label, $0.hotKey) }
            .sorted { $0.label < $1.label }
    }

    // MARK: - The Ditto set

    /// Register everything the options and the database ask for. Called at
    /// launch and whenever either changes.
    func reload(controller: DittoController) {
        unregisterAll()
        let options = Options.shared

        register(options.showQuickPasteHotKey, label: "Show Ditto") { [weak controller] in
            controller?.toggleQuickPasteWindow()
        }
        register(options.showQuickPasteHotKey2, label: "Show Ditto (2)") { [weak controller] in
            controller?.toggleQuickPasteWindow()
        }
        register(options.showStarredClipsHotKey, label: "Show starred clips") { [weak controller] in
            controller?.showStarredClips()
        }
        register(options.textOnlyPasteHotKey, label: "Paste as plain text") { [weak controller] in
            controller?.pasteTopClipAsPlainText()
        }
        register(options.saveClipboardHotKey, label: "Save the current clipboard") {
            ClipboardMonitor.shared.capture(reason: .explicit)
        }

        for position in 1...Options.firstTenCount {
            let string = options.pastePositionHotKey(position)
            guard string.isEmpty == false else { continue }
            register(string, label: "Paste position \(position)") { [weak controller] in
                controller?.pasteClip(atPosition: position)
            }
        }

        for buffer in 1...Options.copyBufferCount {
            let copyString = options.copyBufferHotKey(buffer)
            if copyString.isEmpty == false {
                register(copyString, label: "Copy to buffer \(buffer)") { [weak controller] in
                    controller?.copyToBuffer(buffer)
                }
            }
            let pasteString = options.pasteBufferHotKey(buffer)
            if pasteString.isEmpty == false {
                register(pasteString, label: "Paste buffer \(buffer)") { [weak controller] in
                    controller?.pasteBuffer(buffer)
                }
            }
        }

        // Per-clip global accelerators, from Main.lShortCut.
        do {
            for clip in try ClipRepository.shared.clipsWithGlobalShortcuts() {
                guard let hotKey = HotKey(packed: clip.shortcut) else { continue }
                register(hotKey, label: "Clip \(clip.id)") { [weak controller] in
                    controller?.pasteClip(id: clip.id)
                }
            }
        } catch {
            Log.error("could not load clip shortcuts: \(error)")
        }
    }
}
