import AppKit
import Combine
import SwiftUI

/// Держит единственную панель у верхнего края экрана и подгоняет её под текущий режим.
@MainActor
final class PanelController {
    private let state: AppState
    private let panel = FloatingPanel()
    private var subscriptions: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state
        panel.contentView = FirstMouseHostingView(rootView: RootView().environmentObject(state))
        panel.onCancel = { [weak state] in state?.collapse() }
        panel.onKeyDown = { [weak state] in state?.handleCardKey($0.keyCode) ?? false }
        panel.onKeyIntercept = { [weak state] event in
            state?.handleListKey(keyCode: event.keyCode, command: event.modifierFlags.contains(.command)) ?? false
        }

        // $mode публикует значение до записи; хоп на следующий тик избавляет от реентерабельности.
        state.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &subscriptions)

        // Клик мимо панели возвращает фокус приложению пользователя — сворачиваемся.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak state] _ in state?.collapse() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.place(for: state.mode) }
            .store(in: &subscriptions)
    }

    private func apply(_ mode: AppState.Mode) {
        if mode == .pill {
            panel.allowsKey = false
            // orderOut отдаёт клавиатуру обратно приложению пользователя.
            if panel.isKeyWindow { panel.orderOut(nil) }
            place(for: mode)
            panel.orderFrontRegardless()
        } else {
            panel.allowsKey = true
            place(for: mode)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func place(for mode: AppState.Mode) {
        // Раскрываемся на мониторе с курсором; pill остаётся там, где им пользовались.
        let screen = mode == .pill ? (panel.screen ?? Self.screenWithMouse()) : Self.screenWithMouse()
        guard let screen else { return }

        let size = Self.size(for: mode)
        // Под вырезом на MacBook, под строкой меню на остальных мониторах.
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: top - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func size(for mode: AppState.Mode) -> NSSize {
        switch mode {
        case .pill: NSSize(width: 360, height: 44)
        case .input: NSSize(width: Layout.cardWidth + 2 * Layout.shadowMargin, height: 260)
        // Запас под поиск, подсказку и кнопку очистки.
        case .tasks: NSSize(width: Layout.cardWidth + 2 * Layout.shadowMargin, height: Layout.taskListMaxHeight + 180)
        // Запас под шапку и подвал: поле продолжения, ошибку отправки, «Копировать».
        case .result: NSSize(width: Layout.cardWidth + 2 * Layout.shadowMargin, height: Layout.resultMaxHeight + 200)
        }
    }

    private static func screenWithMouse() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }
}

private extension AppState {
    /// `Tab` в карточке — фокус в поле продолжения. Сюда доходят только нажатия, которые не забрало
    /// поле ввода; клавиши списка задач перехватываются раньше (`handleListKey`).
    func handleCardKey(_ keyCode: UInt16) -> Bool {
        if case .result = mode, keyCode == 48 { return focusFollowUp() }
        return false
    }
}

#if DEBUG
extension PanelController {
    /// Отправляет панели нажатие клавиши так, как это сделал бы оконный сервер.
    func debugKeyDown(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return }
        panel.sendEvent(event)
    }

    /// PNG с содержимым панели — без записи экрана и её разрешений.
    func debugSnapshot() -> Data? {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    var debugPanelInfo: [String: String] {
        ["frame": NSStringFromRect(panel.frame), "isKey": String(panel.isKeyWindow), "isVisible": String(panel.isVisible)]
    }
}
#endif
