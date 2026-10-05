import AppKit
import Combine
import SwiftUI

/// Держит единственную панель у верхнего края экрана. Остров внутри неё меняет форму сам
/// (`RootView`); панель лишь даёт ему место: большое окно, пока остров раскрыт или сворачивается,
/// и маленькое — под свёрнутый pill. Она же следит за курсором: задержался над шторкой —
/// выезжает блок с агентами и диалогами.
@MainActor
final class PanelController {
    private let state: AppState
    private let panel = FloatingPanel()
    private var subscriptions: Set<AnyCancellable> = []
    /// Отложенное уменьшение окна после сворачивания острова.
    private var shrink: DispatchWorkItem?
    private var pointerTimer: Timer?
    private var hover = HoverIntent()
    #if DEBUG
    /// Подменённое положение курсора в координатах экрана; nil — настоящий курсор.
    var debugPointer: NSPoint?
    #endif

    init(state: AppState) {
        self.state = state
        panel.contentView = FirstMouseHostingView(
            rootView: RootView().environmentObject(state).environmentObject(state.settings)
        )
        panel.onCancel = { [weak state] in state?.collapse() }
        panel.onKeyDown = { [weak state] in state?.handleCardKey($0.keyCode) ?? false }
        panel.onKeyIntercept = { [weak state] event in
            guard let state else { return false }
            let command = event.modifierFlags.contains(.command)
            return state.handleListKey(keyCode: event.keyCode, command: command)
                || state.handleAgentKey(keyCode: event.keyCode, command: command)
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
        state.settings.$hoverPeek
            .removeDuplicates()
            .sink { [weak self] in self?.trackPointer($0) }
            .store(in: &subscriptions)
    }

    // MARK: - Курсор

    /// Положение курсора опрашивается, а не приходит событиями: панель не ключевая, окно острова
    /// больше видимой фигуры, и события мыши над прозрачной частью достаются приложениям под ней.
    /// Приём Coucou; у Luna опрос реже — ей нужно только «над островом или нет».
    private func trackPointer(_ enabled: Bool) {
        pointerTimer?.invalidate()
        pointerTimer = nil
        hover = HoverIntent()
        guard enabled else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        timer.tolerance = 0.02
        // .common: опрос идёт и пока открыто меню или тянут ползунок.
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func pointerMoved() {
        var pointer = NSEvent.mouseLocation
        #if DEBUG
        pointer = debugPointer ?? pointer
        #endif
        // Курсор рядом — шторка оживает: к ней, похоже, идут.
        MotionGate.shared.pointerNear = islandFrame.insetBy(dx: -Self.nearMargin, dy: -Self.nearMargin).contains(pointer)
        switch hover.update(inside: islandFrame.contains(pointer), at: ProcessInfo.processInfo.systemUptime) {
        case .open:
            // С зажатой кнопкой мимо шторки что-то тащат — блок не мешает.
            if NSEvent.pressedMouseButtons == 0 { state.openPeek() }
        case .close:
            state.closePeek()
        case nil:
            break
        }
    }

    private static let nearMargin: CGFloat = 140

    /// Видимая фигура острова в координатах экрана. Тонкую полоску ловим с тем же запасом, что и клик;
    /// у раскрытого блока запас по краям — чтобы он не закрывался от промаха на пару точек.
    private var islandFrame: NSRect {
        let margin: CGFloat = state.mode == .peek ? 10 : 0
        let width = max(state.islandSize.width, 72) + 2 * margin
        let height = max(state.islandSize.height, 14) + margin
        return NSRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY - height, width: width, height: height)
    }

    private func apply(_ mode: AppState.Mode) {
        shrink?.cancel()
        if mode == .pill {
            panel.allowsKey = false
            // orderOut отдаёт клавиатуру обратно приложению пользователя.
            if panel.isKeyWindow { panel.orderOut(nil) }
            panel.orderFrontRegardless()
            // Остров сворачивается внутри большого окна; окно уменьшается, когда анимация закончилась.
            let work = DispatchWorkItem { [weak self] in self?.place(for: .pill) }
            shrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (panel.frame.isEmpty ? 0 : IslandMotion.collapseDuration), execute: work)
        } else if mode == .peek {
            // Блок под курсором клавиатуру не трогает: это взгляд, а не вызов панели.
            panel.allowsKey = false
            place(for: mode)
            panel.orderFrontRegardless()
        } else {
            panel.allowsKey = true
            place(for: mode)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func place(for mode: AppState.Mode) {
        // Раскрываемся на мониторе с курсором; pill и блок под курсором остаются там, где шторка.
        let stays = mode == .pill || mode == .peek
        let screen = stays ? (panel.screen ?? Self.screenWithMouse()) : Self.screenWithMouse()
        guard let screen else { return }

        let size = mode == .pill ? Layout.pillPanel : Layout.expandedPanel
        // Под вырезом на MacBook, под строкой меню на остальных мониторах.
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: top - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        // Остров прижат к верхней середине окна — туда смотрят аватары, когда следят за курсором.
        IslandPointer.anchor = CGPoint(x: screen.frame.midX, y: top)
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

    /// Точка внутри видимой фигуры острова — «курсор над шторкой».
    var debugIslandPoint: NSPoint {
        NSPoint(x: panel.frame.midX, y: panel.frame.maxY - 3)
    }

    /// Клик по острову так, как его доставил бы оконный сервер; точка — от верхней середины острова,
    /// x вправо, y вниз. Панель при этом не ключевая — как под настоящим курсором.
    func debugClick(dx: CGFloat, dy: CGFloat) {
        let location = NSPoint(x: panel.frame.width / 2 + dx, y: panel.frame.height - dy)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        // Нажатие уходит в цикл отслеживания мыши, который ждёт отпускания из очереди событий.
        NSApp.postEvent(up, atStart: false)
        panel.sendEvent(down)
    }

    /// Достаётся ли панели клик в точке экрана: окно, которое оконный сервер считает верхним в ней.
    /// Так проверяется, что прозрачная часть окна острова пропускает клики к приложениям под ней.
    func debugReceivesClick(at point: NSPoint) -> Bool {
        NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == panel.windowNumber
    }
}
#endif
