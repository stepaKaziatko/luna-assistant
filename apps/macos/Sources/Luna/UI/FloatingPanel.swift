import AppKit
import SwiftUI

/// Панель поверх всех окон, которая принимает ввод, не активируя приложение
/// и не забирая фокус у приложения пользователя.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Клавиши, которые не забрало содержимое панели. Возвращает true, если нажатие обработано.
    var onKeyDown: ((NSEvent) -> Bool)?
    /// Клавиши, которые панель забирает раньше поля ввода в фокусе (стрелки, ↩, esc, ⌘⌫ списка
    /// задач). Возвращает true, если нажатие обработано и дальше не идёт.
    var onKeyIntercept: ((NSEvent) -> Bool)?
    /// Правый клик. Возвращает true, если меню показано; панель при этом остаётся неключевой.
    var onRightClick: ((NSEvent) -> Bool)?
    /// В режиме pill панель не должна перехватывать клавиатуру.
    var allowsKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyIntercept?(event) == true { return }
        if event.type == .rightMouseDown, onRightClick?(event) == true { return }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘⌫ приходит сюда раньше, чем в sendEvent: поле поиска не должно стереть строку.
        if onKeyIntercept?(event) == true { return true }
        if performEditingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

extension NSPanel {
    /// У приложения-агента нет меню «Правка», поэтому стандартные сочетания
    /// редактирования сами до текстового поля не доходят — панель отправляет их сама.
    func performEditingShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action: Selector? = switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// Клик по pill должен срабатывать сразу, хотя панель не является ключевым окном.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
