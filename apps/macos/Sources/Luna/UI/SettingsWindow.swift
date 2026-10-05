import AppKit
import SwiftUI

/// Окно настроек — обычное окно, в отличие от панелей острова: его открывают явной командой,
/// и ему нужна клавиатура (запись сочетаний клавиш). Пока оно открыто, Luna — активное приложение;
/// закрылось — активным снова становится то, с которым пользователь работал.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let size = CGSize(width: 480, height: 440)

    private let settings: LunaSettings
    private let sounds: SoundPlayer
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    /// Приложение, которое было активным до открытия настроек.
    private var previousApp: NSRunningApplication?

    init(settings: LunaSettings, sounds: SoundPlayer) {
        self.settings = settings
        self.sounds = sounds
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
        window.title = "Настройки Luna"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: SettingsView(sounds: sounds).environmentObject(settings).environmentObject(navigation)
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

/// У приложения-агента нет главного меню, поэтому `⌘W` окно обрабатывает само.
private final class CommandClosingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

#if DEBUG
extension SettingsWindow {
    var debugIsVisible: Bool { window?.isVisible ?? false }

    func debugSelect(tab: String) {
        if let tab = SettingsNavigation.Tab(rawValue: tab) { navigation.tab = tab }
    }

    func debugClose() {
        window?.performClose(nil)
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
