import AppKit
import ApplicationServices

/// Выделенный текст и заголовок окна чужого приложения через Accessibility API.
enum AccessibilityProbe {
    enum Selection: Equatable {
        case text(String)
        /// Приложение ответило: ничего не выделено.
        case empty
        /// Приложение не отдаёт выделение через Accessibility (Chrome, Electron и т.п.).
        case unavailable
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос на доступ и открывает нужный раздел настроек.
    @MainActor
    static func requestTrust() {
        // Строковое значение kAXTrustedCheckOptionPrompt: сама константа — глобальная var и не дружит с concurrency.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openSettings(pane: "Privacy_Accessibility")
    }

    @MainActor
    static func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Вызовы Accessibility — синхронный IPC в чужое приложение; с главного потока не вызывать.
    static func read(pid: pid_t) -> (windowTitle: String?, selection: Selection) {
        let app = AXUIElementCreateApplication(pid)
        // Зависшее приложение не должно задерживать захват на системные 6 секунд.
        AXUIElementSetMessagingTimeout(app, 0.5)

        let window = element(app, kAXFocusedWindowAttribute)
        let title = window.flatMap { string($0, kAXTitleAttribute) }.flatMap { $0.isEmpty ? nil : $0 }

        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return (title, .unavailable) }
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) {
        case .success:
            let text = (value as? String) ?? ""
            return (title, text.isEmpty ? .empty : .text(text))
        case .noValue:
            return (title, .empty)
        default:
            return (title, .unavailable)
        }
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// Фолбэк для приложений без выделения в Accessibility: посылаем приложению ⌘C,
/// читаем буфер обмена и возвращаем в него прежнее содержимое.
@MainActor
enum ClipboardProbe {
    private static let keyC: CGKeyCode = 8

    static func copySelection(pid: pid_t) async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        // События идут напрямую приложению: клавиатуру в этот момент уже держит панель Luna.
        // Флаги задаём явно — пользователь ещё может держать ⌥ от хоткея.
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: keyDown) else { return nil }
            event.flags = .maskCommand
            event.postToPid(pid)
        }

        // Без выделения буфер не изменится — тогда выходим по таймауту.
        for _ in 0..<25 where pasteboard.changeCount == before {
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        guard pasteboard.changeCount != before else { return nil }

        let text = pasteboard.string(forType: .string)
        restore(saved, to: pasteboard)
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
