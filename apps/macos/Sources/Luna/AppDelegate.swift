import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var panels: PanelController?
    private var statusItem: NSStatusItem?
    private var core: CoreClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Запись в pipe умершего ядра должна вернуть ошибку, а не убить приложение.
        signal(SIGPIPE, SIG_IGN)

        panels = PanelController(state: state)
        setupStatusItem()
        KeyboardShortcuts.onKeyDown(for: .toggleInput) { [state] in state.toggleInput() }
        KeyboardShortcuts.onKeyDown(for: .openLastResult) { [state] in state.toggleLastResult() }
        KeyboardShortcuts.onKeyDown(for: .toggleTasks) { [state] in state.toggleTasks() }
        #if DEBUG
        if let panels { DebugCommands.install(state: state, panels: panels) }
        #endif
        startCore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        core?.stop()
    }

    private func startCore() {
        do {
            let client = CoreClient(launch: try CoreLocator.locate())
            client.onTaskEvent = { [state] in state.apply($0) }
            client.onExit = { [state] in state.coreStopped(status: $0) }
            try client.start()
            core = client
            state.core = client

            _Concurrency.Task {
                do {
                    let hello: HelloResult = try await client.request("core.hello")
                    state.apply(hello)
                } catch {
                    state.problem = error.localizedDescription
                    return
                }
                // История — не повод для неполадки: не загрузилась, и список просто пуст.
                if let list: TaskListResult = try? await client.request("task.list") {
                    state.applyHistory(list.tasks)
                }
            }
        } catch {
            state.problem = error.localizedDescription
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "moon.stars", accessibilityDescription: "Luna")

        let menu = NSMenu()
        menu.addItem(menuItem("Спросить…", #selector(askClicked), shortcut: .toggleInput))
        menu.addItem(menuItem("Последний результат", #selector(lastResultClicked), shortcut: .openLastResult))
        menu.addItem(menuItem("Список задач", #selector(tasksClicked), shortcut: .toggleTasks))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти из Luna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector, shortcut: KeyboardShortcuts.Name) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.setShortcut(for: shortcut)
        return item
    }

    // Панель раскрываем после закрытия меню: иначе оно тут же отберёт у неё клавиатуру.
    @objc private func askClicked() {
        DispatchQueue.main.async { [state] in state.toggleInput() }
    }

    @objc private func lastResultClicked() {
        DispatchQueue.main.async { [state] in state.openLastResult() }
    }

    @objc private func tasksClicked() {
        DispatchQueue.main.async { [state] in state.showTasks() }
    }
}
