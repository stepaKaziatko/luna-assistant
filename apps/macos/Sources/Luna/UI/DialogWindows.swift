import AppKit
import Combine
import SwiftUI

/// Окно «Открыть полностью» — панель, а не обычное окно приложения: не активирует Luna,
/// не видна в `⌘Tab` и Mission Control, при открытии не забирает клавиатуру. Ключевой становится
/// только по клику в неё — тогда работают выделение, `⌘C`, `⌘A` и `esc`.
final class DialogPanel: NSPanel {
    var onClose: (() -> Void)?
    /// Ключевой панель становится только по клику. Иначе, когда карточка уходит с экрана,
    /// AppKit отдал бы клавиатуру окну вместо приложения пользователя.
    private var clicked = false

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: DialogWindows.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        // Поверх обычных окон, но ниже карточки (`.statusBar`): карточка под окном не прячется.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Luna никогда не активна: окно не должно прятаться вместе с ней.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = .black
        contentMinSize = NSSize(width: 360, height: 240)
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { clicked }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { clicked = true }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        clicked = false
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performEditingShortcut(event) || super.performKeyEquivalent(with: event)
    }
}

/// Окна «Открыть полностью»: по панели на каждый диалог из `AppState.openWindows` и на каждую сессию
/// агента из `AppState.agentWindows`. Состояние решает, какие окна открыты; контроллер только создаёт,
/// поднимает и закрывает панели.
@MainActor
final class DialogWindows: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 720, height: 800)
    /// Ключ `UserDefaults`: последний размер окна, оставленный пользователем, строкой `{ширина, высота}`.
    static let sizeKey = "dialogWindowSize"
    /// Каждое следующее окно смещается, чтобы не накрыть предыдущее целиком.
    private static let cascadeStep: CGFloat = 28

    private let state: AppState
    private var panels: [String: DialogPanel] = [:]
    /// Окна сессий агентов — по id сессии.
    private var agentPanels: [String: DialogPanel] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state
        super.init()
        // $openWindows публикует значение до записи; хоп на следующий тик — как у карточки.
        state.$openWindows
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sync($0) }
            .store(in: &subscriptions)
        // Повторное «Открыть полностью» поднимает окно, но клавиатуру оставляет там, где она была.
        state.windowRaised
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.panels[$0]?.orderFrontRegardless() }
            .store(in: &subscriptions)
        state.$agentWindows
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncAgents($0) }
            .store(in: &subscriptions)
        state.agentWindowRaised
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.agentPanels[$0]?.orderFrontRegardless() }
            .store(in: &subscriptions)
    }

    private func syncAgents(_ open: [String]) {
        for (sessionId, panel) in agentPanels where !open.contains(sessionId) {
            agentPanels[sessionId] = nil
            panel.close()
        }
        for sessionId in open where agentPanels[sessionId] == nil {
            showAgent(sessionId)
        }
    }

    private func showAgent(_ sessionId: String) {
        let panel = DialogPanel()
        panel.title = state.agent(id: sessionId)?.displayTitle ?? "Luna"
        panel.delegate = self
        panel.onClose = { [weak state] in state?.closeAgentWindow(id: sessionId) }
        let content = FirstMouseHostingView(
            rootView: AgentWindowView(sessionId: sessionId)
                .environmentObject(state)
                .environmentObject(state.settings)
                .onExitCommand { [weak state] in state?.closeAgentWindow(id: sessionId) }
        )
        content.sizingOptions = []
        panel.contentView = content
        panel.setFrame(frame(cascade: panels.count + agentPanels.count), display: false)
        agentPanels[sessionId] = panel
        // Не makeKey: клавиатура остаётся у приложения пользователя.
        panel.orderFrontRegardless()
    }

    private func sync(_ open: [String]) {
        for (threadId, panel) in panels where !open.contains(threadId) {
            panels[threadId] = nil
            panel.close()
        }
        for threadId in open where panels[threadId] == nil {
            show(threadId)
        }
    }

    private func show(_ threadId: String) {
        let panel = DialogPanel()
        panel.title = state.dialog(threadId: threadId)?.title ?? "Luna"
        panel.delegate = self
        panel.onClose = { [weak state] in state?.closeWindow(threadId: threadId) }
        let content = FirstMouseHostingView(
            rootView: DialogWindowView(threadId: threadId)
                .environmentObject(state)
                .onExitCommand { [weak state] in state?.closeWindow(threadId: threadId) }
        )
        // Размер окна задаёт пользователь, а не содержимое.
        content.sizingOptions = []
        panel.contentView = content
        panel.setFrame(frame(cascade: panels.count + agentPanels.count), display: false)
        panels[threadId] = panel
        // Не makeKey: клавиатура остаётся у карточки или у приложения пользователя.
        panel.orderFrontRegardless()
    }

    /// Монитор с курсором, по центру видимой области, с запомненным размером.
    private func frame(cascade index: Int) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        var size = Self.savedSize ?? Self.defaultSize
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height)
        let offset = CGFloat(index % 8) * Self.cascadeStep
        let x = min(visible.midX - size.width / 2 + offset, visible.maxX - size.width)
        let y = max(visible.midY - size.height / 2 - offset, visible.minY)
        return NSRect(origin: NSPoint(x: max(x, visible.minX), y: y), size: size)
    }

    private static var savedSize: NSSize? {
        guard let string = UserDefaults.standard.string(forKey: sizeKey) else { return nil }
        let size = NSSizeFromString(string)
        return size.width > 0 && size.height > 0 ? size : nil
    }

    private func threadId(of window: Any?) -> String? {
        panels.first { $0.value === window as AnyObject? }?.key
    }

    // MARK: - NSWindowDelegate

    /// Кнопка закрытия: окно уходит из состояния. Закрытие из `sync` сюда не доходит — панель уже снята.
    func windowWillClose(_ notification: Notification) {
        if let threadId = threadId(of: notification.object) {
            panels[threadId] = nil
            state.closeWindow(threadId: threadId)
        } else if let sessionId = agentPanels.first(where: { $0.value === notification.object as AnyObject? })?.key {
            agentPanels[sessionId] = nil
            state.closeAgentWindow(id: sessionId)
        }
    }

    /// Запоминается только размер, который пользователь оставил мышью.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: Self.sizeKey)
    }
}

#if DEBUG
extension DialogWindows {
    struct DebugWindow: Encodable {
        let threadId: String
        let frame: String
        let isVisible: Bool
        let isKey: Bool
    }

    /// Открытые окна в порядке открытия.
    var debugWindows: [DebugWindow] {
        state.openWindows.compactMap { threadId in
            panels[threadId].map {
                DebugWindow(threadId: threadId, frame: NSStringFromRect($0.frame), isVisible: $0.isVisible, isKey: $0.isKeyWindow)
            }
        }
    }

    /// Окна сессий агентов в порядке открытия.
    var debugAgentWindows: [DebugWindow] {
        state.agentWindows.compactMap { sessionId in
            agentPanels[sessionId].map {
                DebugWindow(threadId: sessionId, frame: NSStringFromRect($0.frame), isVisible: $0.isVisible, isKey: $0.isKeyWindow)
            }
        }
    }

    /// PNG окна сессии агента.
    func debugAgentSnapshot(sessionId: String) -> Data? {
        guard let view = agentPanels[sessionId]?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Клик в окно так, как его доставил бы оконный сервер: окно становится ключевым.
    func debugClick(threadId: String) {
        guard let panel = panels[threadId] else { return }
        let location = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
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

    /// Нажатие клавиши в окне, если оно ключевое (после клика) — как у оконного сервера. false — ключевого окна нет.
    func debugKeyDown(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let panel = panels.values.first(where: \.isKeyWindow),
              let event = NSEvent.keyEvent(
                  with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: panel.windowNumber, context: nil, characters: characters,
                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
              ) else { return false }
        // Сочетания с ⌘ оконный сервер сначала предлагает как key equivalent.
        if modifiers.contains(.command), panel.performKeyEquivalent(with: event) { return true }
        panel.sendEvent(event)
        return true
    }

    /// PNG с содержимым окна — без записи экрана и её разрешений.
    func debugSnapshot(threadId: String) -> Data? {
        guard let view = panels[threadId]?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
