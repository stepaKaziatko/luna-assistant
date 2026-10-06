import AppKit
import SwiftUI

/// Окно настроек — обычное окно, в отличие от панелей острова: его открывают явной командой,
/// и ему нужна клавиатура (запись сочетаний клавиш). Пока оно открыто, Luna — активное приложение;
/// закрылось — активным снова становится то, с которым пользователь работал.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let size = CGSize(width: 480, height: 640)

    private let settings: LunaSettings
    private let sounds: SoundPlayer
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    /// Приложение, которое было активным до открытия настроек.
    private var previousApp: NSRunningApplication?

    /// Что делает ⌘Q и кнопка «Выйти из Luna».
    private let quit: () -> Void

    init(settings: LunaSettings, sounds: SoundPlayer, quit: @escaping () -> Void) {
        self.settings = settings
        self.sounds = sounds
        self.quit = quit
    }

    func show() {
        if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = CommandClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.onQuit = quit
        window.title = "Настройки Luna"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: SettingsView(sounds: sounds, quit: quit).environmentObject(settings).environmentObject(navigation)
        )
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // У приложения-агента других обычных окон нет: без этого фокус остался бы в пустоте.
        if NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }
}

/// У приложения-агента нет главного меню, поэтому `⌘W` и `⌘Q` окно обрабатывает само.
final class CommandClosingWindow: NSWindow {
    /// Завершение приложения по `⌘Q`.
    var onQuit: () -> Void = { NSApp.terminate(nil) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command {
            if event.isLetterKey("w", keyCode: 13) {
                performClose(nil)
                return true
            }
            if event.isLetterKey("q", keyCode: 12) {
                onQuit()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

private extension NSEvent {
    /// Нажата клавиша с этой буквой. На нелатинской раскладке (русской) буква другая, и тогда
    /// узнаём клавишу по коду: `⌘Q` не должен зависеть от раскладки.
    func isLetterKey(_ letter: String, keyCode code: UInt16) -> Bool {
        guard let characters = charactersIgnoringModifiers?.lowercased() else { return false }
        if characters == letter { return true }
        return keyCode == code && !characters.allSatisfy(\.isASCII)
    }
}

#if DEBUG
extension SettingsWindow {
    var debugIsVisible: Bool { window?.isVisible ?? false }

    func debugSelect(tab: String) {
        if let tab = SettingsNavigation.Tab(rawValue: tab) { navigation.tab = tab }
    }

    func debugSetModelDraft(_ text: String) {
        navigation.modelDraft = text
    }

    func debugClose() {
        window?.performClose(nil)
    }

    /// Нажатие клавиши в окне настроек так, как его доставил бы оконный сервер.
    func debugKeyDown(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        guard let window,
              let event = NSEvent.keyEvent(
                  with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber, context: nil, characters: characters,
                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
              ) else { return }
        window.sendEvent(event)
    }

    /// PNG с содержимым окна — без записи экрана и её разрешений.
    func debugSnapshot() -> Data? {
        guard let view = window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
