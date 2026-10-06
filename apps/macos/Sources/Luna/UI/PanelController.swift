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
    /// Отложенное `orderOut` после ухода шторки: сначала анимация.
    private var hide: DispatchWorkItem?
    private var pointerTimer: Timer?
    /// Рамка, где панель стояла в последний раз: по ней, а не по `panel.screen` снятой с экрана панели,
    /// шторка находит свой монитор при появлении.
    private var restingFrame: NSRect?
    /// Экран острова и геометрия выреза на нём — из последней расстановки (`place`): от них считаются
    /// рамка видимой фигуры и точка, куда смотрят аватары.
    private var placement: (screen: NSRect, notch: NotchGeometry)?
    private var hover = HoverIntent()
    /// Показывает ли экран острова полноэкранное приложение; спрашивается только на экране с вырезом.
    private let fullscreenWatch = FullscreenWatch()
    /// Меню Luna для правого клика по шторке — то же, что у значка в строке меню.
    private let makeMenu: () -> NSMenu
    #if DEBUG
    /// Подменённое положение курсора в координатах экрана; nil — настоящий курсор.
    var debugPointer: NSPoint?
    /// Меню правого клика, пока оно раскрыто.
    private(set) var openMenu: NSMenu?
    /// Подменённая геометрия выреза экрана острова; nil — настоящая.
    private var notchOverride: NotchOverride?
    /// Подменённый результат определения полноэкранного режима; nil — настоящий.
    private var fullscreenOverride: Bool?
    /// Сколько раз тело острова с плечами получило размер, который не помещается в окно: фигура обрезалась бы.
    private(set) var clippedResizes = 0
    /// Сколько раз после сжатия окна до pill тело или окно острова разошлись с раскладкой pill.
    private(set) var collapsedMismatches = 0
    /// Сколько раз раскрытый остров после роста остался высотой с полосу, то есть размером pill: карточки не видно.
    private(set) var expandedMismatches = 0
    /// Отложенная проверка раскрытого острова; новая смена режима её отменяет.
    private var expandedCheck: DispatchWorkItem?
    #endif

    init(state: AppState, menu makeMenu: @escaping () -> NSMenu) {
        self.state = state
        self.makeMenu = makeMenu
        panel.contentView = FirstMouseHostingView(
            rootView: RootView().environmentObject(state).environmentObject(state.settings)
        )
        panel.onCancel = { [weak state] in state?.collapse() }
        panel.onRightClick = { [weak self] in self?.showMenu(for: $0) ?? false }
        panel.onKeyDown = { [weak state] in state?.handleCardKey($0.keyCode) ?? false }
        panel.onKeyIntercept = { [weak state] event in
            guard let state else { return false }
            let command = event.modifierFlags.contains(.command)
            return state.handleListKey(keyCode: event.keyCode, command: command)
                || state.handleAgentKey(keyCode: event.keyCode, command: command)
        }

        // Окно раскрытого острова встаёт сразу после записи режима, до того как `RootView` начнёт рост фигуры:
        // иначе первые кадры роста рисовались бы в окне pill и фигура обрезалась бы. Только рамка — показ,
        // клавиатура и отложенное уменьшение остаются за `apply`.
        state.modeDidChange = { [weak self] in self?.prepareFrame(for: $0) }
        // $mode публикует значение до записи; хоп на следующий тик избавляет от реентерабельности.
        state.$mode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &subscriptions)
        #if DEBUG
        // Новый размер тела публикуется в тот же проход, где начинается его анимация: окно на этот момент
        // должно уже вмещать фигуру.
        state.$islandSize
            .sink { [weak self] in self?.checkFits($0) }
            .store(in: &subscriptions)
        #endif

        // Клик мимо панели возвращает фокус приложению пользователя — сворачиваемся.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak state] _ in state?.collapse() }
            .store(in: &subscriptions)
        // Смена разрешения или «Больше места», подключение и отключение монитора: геометрия выреза — заново.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screenParametersChanged() }
            .store(in: &subscriptions)
        // Показ и скрытие шторки в режиме «В фоне»; опрос курсора зависит от того же.
        state.$islandShown
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.presenceChanged($0) }
            .store(in: &subscriptions)
        state.settings.$hoverPeek
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePointerTracking() }
            .store(in: &subscriptions)
        state.settings.$islandMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePointerTracking() }
            .store(in: &subscriptions)
        // Скрытая шторка стоит с первого кадра: ни таймера оживлений, ни вспышки при запуске.
        MotionGate.shared.setActive(state.islandShown)

        // Полноэкранный режим — только на экране с вырезом; без выреза окна не спрашиваются.
        fullscreenWatch.target = { [weak self] in
            guard let placement = self?.placement, placement.notch.hasNotch, let main = NSScreen.screens.first else { return nil }
            return (FullscreenDetection.displayRect(screen: placement.screen, mainScreen: main.frame), placement.notch.barHeight)
        }
        fullscreenWatch.onChange = { [weak self] _ in self?.publishFullscreen() }
        fullscreenWatch.start()
    }

    /// Полноэкранный режим экрана острова — в состояние; в debug-сборке с подменой `fullscreen:`.
    private func publishFullscreen() {
        var value = fullscreenWatch.isFullscreen
        #if DEBUG
        value = fullscreenOverride ?? value
        #endif
        if state.screenFullscreen != value { state.screenFullscreen = value }
    }

    // MARK: - Показ и скрытие

    private func presenceChanged(_ shown: Bool) {
        hide?.cancel()
        hide = nil
        updatePointerTracking()
        if shown {
            MotionGate.shared.setActive(true)
            // Окно показывается раньше анимации: без `makeKey` и без активации приложения.
            if !panel.isVisible {
                place(for: state.mode)
                panel.orderFrontRegardless()
            }
            // Следующий такт: остров уже на экране прозрачным и плавно проявляется.
            DispatchQueue.main.async { [weak self] in
                guard let self, state.islandShown else { return }
                state.islandPresented = true
            }
        } else {
            state.islandPresented = false
            let work = DispatchWorkItem { [weak self] in
                guard let self, !state.islandShown else { return }
                panel.orderOut(nil)
                MotionGate.shared.setActive(false)
            }
            hide = work
            // Анимация уходит целиком, и только потом окно снимается с экрана.
            DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.collapseDuration + 0.05, execute: work)
        }
    }

    // MARK: - Курсор

    /// Положение курсора опрашивается, а не приходит событиями: панель не ключевая, окно острова
    /// больше видимой фигуры, и события мыши над прозрачной частью достаются приложениям под ней.
    /// Приём Coucou; у Luna опрос реже — ей нужно только «над островом или нет».
    private func updatePointerTracking() {
        let needed = IslandPresence.needsPointerPolling(
            mode: state.settings.islandMode, isShown: state.islandShown, hoverPeek: state.settings.hoverPeek
        )
        guard needed != (pointerTimer != nil) else { return }
        pointerTimer?.invalidate()
        pointerTimer = nil
        hover = HoverIntent()
        guard needed else {
            MotionGate.shared.pointerNear = false
            return
        }
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
        // Курсор рядом — шторка оживает: к ней, похоже, идут. «Рядом» — прямоугольник с запасом, это не попадание.
        MotionGate.shared.pointerNear = islandFrame.insetBy(dx: -Self.nearMargin, dy: -Self.nearMargin).contains(pointer)
        // Над фигурой — по её контуру с плечами: курсор, идущий по строке меню мимо, блок не открывает.
        let inside = islandContains(pointer)
        // В «В фоне» курсор над шторкой удерживает её; срок проверяется здесь же, на каждом опросе.
        state.pointerMoved(overIsland: inside)
        guard pointerTimer != nil else { return }
        let action = state.settings.hoverPeek ? hover.update(inside: inside, at: ProcessInfo.processInfo.systemUptime) : nil
        switch action {
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

    // MARK: - Меню

    /// Правый клик по фигуре острова (в том числе по блоку под курсором и по плечам) открывает меню Luna.
    /// Остальное окно прозрачно и клики не получает: оконный сервер отдаёт их приложениям под ним. Меню — не окно приложения:
    /// активным остаётся приложение пользователя, панель неключевая.
    private func showMenu(for event: NSEvent) -> Bool {
        guard state.mode == .pill || state.mode == .peek, let view = panel.contentView else { return false }
        let point = panel.convertPoint(toScreen: event.locationInWindow)
        guard islandContains(point) else { return false }
        let menu = makeMenu()
        #if DEBUG
        openMenu = menu
        defer { openMenu = nil }
        #endif
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return true
    }

    /// Тело фигуры острова в координатах экрана, без плеч. Тело прижато к верхнему краю экрана по центру выреза,
    /// у pill — со сдвигом на разницу крыльев; до первой расстановки — к верхней середине окна.
    private var islandFrame: NSRect {
        let width = max(state.islandSize.width, 72)
        let height = max(state.islandSize.height, 14)
        let centerX = (placement?.notch.centerX ?? panel.frame.midX) + state.islandBodyOffset
        let top = placement?.screen.maxY ?? panel.frame.maxY
        return NSRect(x: centerX - width / 2, y: top - height, width: width, height: height)
    }

    /// Точка экрана над фигурой острова: тело с плечами, низ со скруглением текущего режима. Запаса нет:
    /// промах на пару точек закрывает блок только через `HoverIntent.closeDelay`.
    private func islandContains(_ point: NSPoint) -> Bool {
        let body = islandFrame
        return IslandShape.contains(
            point, body: body.size, centerX: body.midX, top: body.maxY,
            bottomRadius: IslandShape.bottomRadius(collapsed: state.mode == .pill)
        )
    }

    private func apply(_ mode: AppState.Mode) {
        shrink?.cancel()
        #if DEBUG
        checkExpanded(mode)
        #endif
        if mode == .pill {
            panel.allowsKey = false
            let wasVisible = panel.isVisible
            // orderOut отдаёт клавиатуру обратно приложению пользователя.
            if panel.isKeyWindow { panel.orderOut(nil) }
            // Скрытая шторка на экран не возвращается; уходящая — доигрывает анимацию, окно снимет `presenceChanged`.
            if state.islandShown || wasVisible { panel.orderFrontRegardless() }
            // Остров сворачивается внутри большого окна; окно уменьшается, когда анимация закончилась.
            let work = DispatchWorkItem { [weak self] in
                self?.place(for: .pill)
                #if DEBUG
                self?.checkCollapsed()
                #endif
            }
            shrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (panel.frame.isEmpty ? 0 : IslandMotion.collapseDuration), execute: work)
        } else if mode == .peek {
            // Блок под курсором клавиатуру не трогает: это взгляд, а не вызов панели.
            panel.allowsKey = false
            place(for: mode)
            panel.orderFrontRegardless()
        } else {
            panel.allowsKey = true
            // Панель, вызванная при скрытой шторке, появляется вместе с ней.
            hide?.cancel()
            hide = nil
            state.islandPresented = true
            MotionGate.shared.setActive(true)
            place(for: mode)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Раскрытый режим — окно раскрытого острова сразу, синхронно со сменой режима. Отложенное уменьшение
    /// отменяется: фигура растёт из текущего размера, окно не мигает до размера pill. Pill здесь не трогается:
    /// окно уменьшается только после анимации сворачивания.
    private func prepareFrame(for mode: AppState.Mode) {
        guard mode != .pill else { return }
        shrink?.cancel()
        place(for: mode, display: false)
    }

    private func place(for mode: AppState.Mode, display: Bool = true) {
        // Раскрываемся на мониторе с курсором; pill и блок под курсором остаются там, где шторка.
        let stays = mode == .pill || mode == .peek
        let screen = stays ? (restingScreen ?? Self.screenWithMouse()) : Self.screenWithMouse()
        guard let screen else { return }

        // Окно — от самого верхнего края экрана, серединой на центре выреза (без выреза — на середине экрана).
        let notch = notchGeometry(of: screen)
        let size = mode == .pill ? Layout.pillPanel(for: notch) : Layout.expandedPanel
        let top = screen.frame.maxY
        let origin = NSPoint(x: notch.centerX - size.width / 2, y: top - size.height)
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame { panel.setFrame(frame, display: display) }
        restingFrame = panel.frame
        // Экран острова сменился или поменялась его геометрия: полноэкранного режима нет до следующей смены
        // Space или активного приложения.
        let moved = placement.map { $0.screen != screen.frame || $0.notch != notch } ?? false
        placement = (screen.frame, notch)
        if moved { fullscreenWatch.reset() }
        // Вырез и полоса — виду острова; AppKit ставит окно в целые точки, и фигура сдвигается на остаток.
        let island = IslandPlacement(notch: notch, correction: notch.centerX - panel.frame.midX)
        if state.islandPlacement != island { state.islandPlacement = island }
        // Остров прижат к верхней середине окна — туда смотрят аватары, когда следят за курсором.
        IslandPointer.anchor = CGPoint(x: notch.centerX, y: top)
    }

    /// Параметры экранов поменялись (или их подменила debug-команда): остров встаёт заново по свежей геометрии.
    private func screenParametersChanged() {
        place(for: state.mode)
    }

    /// Геометрия выреза экрана, считанная заново; в debug-сборке — с подменой `notch:`.
    private func notchGeometry(of screen: NSScreen) -> NotchGeometry {
        #if DEBUG
        if let notchOverride { return notchOverride.geometry(for: screen) }
        #endif
        return screen.notchGeometry
    }

    /// Монитор, где шторка стояла в последний раз; nil — не стояла или монитор отключён.
    private var restingScreen: NSScreen? {
        guard let frame = restingFrame else { return nil }
        let top = NSPoint(x: frame.midX, y: frame.maxY - 1)
        return NSScreen.screens.first { NSMouseInRect(top, $0.frame, false) }
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

    /// Подмена геометрии выреза командой `notch:`.
    enum NotchOverride {
        /// Вырез заданной ширины по середине экрана, полоса заданной высоты.
        case notch(width: CGFloat, barHeight: CGFloat)
        /// Экран без выреза; высота строки меню, nil — `NSStatusBar.system.thickness`.
        case flat(barHeight: CGFloat?)

        func geometry(for screen: NSScreen) -> NotchGeometry {
            switch self {
            case let .notch(width, barHeight):
                NotchGeometry(notchWidth: width, barHeight: barHeight, centerX: screen.frame.midX)
            case let .flat(barHeight):
                .flat(frame: screen.frame, barHeight: barHeight ?? NSStatusBar.system.thickness)
            }
        }
    }

    /// Подменить геометрию выреза (nil — снова настоящая) и переставить остров тем же путём,
    /// что и при смене параметров экрана.
    func debugSetNotch(_ override: NotchOverride?) {
        notchOverride = override
        screenParametersChanged()
    }

    /// Подменить результат определения полноэкранного режима (nil — снова настоящий).
    func debugSetFullscreen(_ override: Bool?) {
        fullscreenOverride = override
        publishFullscreen()
    }

    /// Помещается ли тело с плечами в окно: по ширине — от середины выреза со сдвигом тела, по высоте — от верха
    /// окна. Полточки — на округление окна. Не помещается — счётчик `panel.clipped` в `dump:`.
    private func checkFits(_ body: CGSize) {
        guard panel.isVisible, let placement else { return }
        let frame = panel.frame
        let half = body.width / 2 + IslandShape.shoulderSize
        // Сдвиг тела — по режиму, а не `islandBodyOffset`: его `RootView` выставляет позже размера.
        let center = placement.notch.centerX + (state.mode == .pill ? state.pillLayout.bodyOffset : 0)
        let fits = center - half >= frame.minX - 0.5 && center + half <= frame.maxX + 0.5
            && body.height <= frame.height + 0.5
        if !fits { clippedResizes += 1 }
    }

    /// Окно сжато до pill: тело острова — по раскладке pill, окно — по геометрии выреза. Иначе свёрнутый остров
    /// остался размером с карточку — счётчик `panel.pillMismatch` в `dump:`. Окно проверяется на следующем
    /// такте: содержимое, которое не помещается, растягивает его уже после `setFrame`.
    private func checkCollapsed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, state.mode == .pill, panel.isVisible, let placement else { return }
            func same(_ a: CGSize, _ b: CGSize) -> Bool { abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5 }
            if !same(state.islandSize, state.pillLayout.body) || !same(panel.frame.size, Layout.pillPanel(for: placement.notch)) {
                collapsedMismatches += 1
            }
        }
    }

    /// Раскрытый режим через `expandedCheckDelay` после открытия: тело выше полосы — под ней содержимое. Высотой
    /// с полосу — тело осталось размером pill, карточки не видно: счётчик `panel.expandedMismatch` в `dump:`.
    private func checkExpanded(_ mode: AppState.Mode) {
        expandedCheck?.cancel()
        expandedCheck = nil
        guard mode != .pill else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, state.mode == mode, panel.isVisible, let placement else { return }
            if state.islandSize.height <= placement.notch.barHeight + 0.5 { expandedMismatches += 1 }
        }
        expandedCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandedCheckDelay, execute: work)
    }

    /// Рост и вставка содержимого заканчиваются раньше: пружина роста — около 0,4 с, содержимое — с задержкой 0,1 с.
    private static let expandedCheckDelay: TimeInterval = 0.8

    var debugPanelInfo: [String: String] {
        var info = [
            "frame": NSStringFromRect(panel.frame), "isKey": String(panel.isKeyWindow), "isVisible": String(panel.isVisible),
            "menuOpen": String(openMenu != nil), "pointerPolling": String(pointerTimer != nil),
            "islandShown": String(state.islandShown), "clipped": String(clippedResizes),
            "pillMismatch": String(collapsedMismatches), "expandedMismatch": String(expandedMismatches),
            // Рамка видимой фигуры острова в координатах экрана — та, по которой ловятся наведение и клики.
            "island": NSStringFromRect(islandFrame),
        ]
        if let placement {
            let notch = placement.notch
            info["notch"] = "width=\(notch.notchWidth) bar=\(notch.barHeight) center=\(notch.centerX) override=\(notchOverride != nil)"
            info["screen"] = NSStringFromRect(placement.screen)
        }
        // Раскладка pill: крылья, промежуток над вырезом и сдвиг тела от середины выреза.
        let layout = state.pillLayout
        info["wings"] = "left=\(layout.leftWing) gap=\(layout.gap) right=\(layout.rightWing) offset=\(layout.bodyOffset)"
        info["correction"] = String(describing: state.islandPlacement.correction)
        // Полноэкранный режим: действующее значение, что определено и подменено ли; что видно у свёрнутого
        // острова; сколько раз спрошен список окон.
        info["fullscreen"] = "value=\(state.screenFullscreen) detected=\(fullscreenWatch.isFullscreen) override=\(fullscreenOverride != nil)"
        info["presence"] = state.collapsedIsland.rawValue
        info["windowQueries"] = String(fullscreenWatch.queries)
        return info
    }

    /// Точка внутри видимой фигуры острова — «курсор над шторкой».
    var debugIslandPoint: NSPoint {
        NSPoint(x: islandFrame.midX, y: islandFrame.maxY - 3)
    }

    /// Точка в окне панели по смещению от верхней середины острова: x вправо, y вниз.
    private func debugWindowPoint(dx: CGFloat, dy: CGFloat) -> NSPoint {
        let island = islandFrame
        return NSPoint(x: island.midX - panel.frame.minX + dx, y: island.maxY - panel.frame.minY - dy)
    }

    /// Клик по острову так, как его доставил бы оконный сервер; точка — от верхней середины острова,
    /// x вправо, y вниз. Панель при этом не ключевая — как под настоящим курсором.
    func debugClick(dx: CGFloat, dy: CGFloat) {
        let location = debugWindowPoint(dx: dx, dy: dy)
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

    /// Меню, которое откроет правый клик по шторке: заголовки пунктов, разделитель — пустой строкой.
    var debugMenuTitles: [String] {
        makeMenu().items.map { $0.isSeparatorItem ? "" : $0.title }
    }

    /// Правый клик по острову так, как его доставил бы оконный сервер; точка — как у `debugClick`.
    /// Пока меню раскрыто, главный цикл занят его отслеживанием и команды из скрипта не доходят, поэтому
    /// состояние снимает `whileOpen`, вызванный через `delay` секунд, — после него меню закрывается.
    func debugRightClick(dx: CGFloat, dy: CGFloat, after delay: TimeInterval, whileOpen: @escaping @MainActor () -> Void) {
        let location = debugWindowPoint(dx: dx, dy: dy)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                whileOpen()
                self?.openMenu?.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        panel.sendEvent(event)
    }

    /// Достаётся ли панели клик в точке экрана: окно, которое оконный сервер считает верхним в ней.
    /// Так проверяется, что прозрачная часть окна острова пропускает клики к приложениям под ней.
    func debugReceivesClick(at point: NSPoint) -> Bool {
        NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == panel.windowNumber
    }
}
#endif
