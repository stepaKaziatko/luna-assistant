import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState(settings: AppDelegate.loadSettings())
    private var panels: PanelController?
    private var windows: DialogWindows?
    private var settingsWindow: SettingsWindow?
    private var statusItem: NSStatusItem?
    private var core: CoreClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Запись в pipe умершего ядра должна вернуть ошибку, а не убить приложение.
        signal(SIGPIPE, SIG_IGN)

        panels = PanelController(state: state)
        windows = DialogWindows(state: state)
        let sounds = SoundPlayer(settings: state.settings)
        let settingsWindow = SettingsWindow(settings: state.settings, sounds: sounds)
        self.settingsWindow = settingsWindow
        state.playSound = { sounds.play($0) }
        state.enliven = { MotionGate.shared.burst() }
        state.showSettings = { settingsWindow.show() }
        setupStatusItem()
        KeyboardShortcuts.onKeyDown(for: .toggleInput) { [state] in state.toggleInput() }
        KeyboardShortcuts.onKeyDown(for: .openLastResult) { [state] in state.toggleLastResult() }
        KeyboardShortcuts.onKeyDown(for: .toggleTasks) { [state] in state.toggleTasks() }
        KeyboardShortcuts.onKeyDown(for: .toggleAgents) { [state] in state.toggleAgents() }
        #if DEBUG
        if let panels, let windows {
            DebugCommands.install(state: state, panels: panels, windows: windows, settings: settingsWindow)
        }
        #endif
        startCore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        core?.stop()
    }

    /// Настройки пользователя. Debug-сборка может держать их отдельно (`LUNA_SETTINGS_SUITE`),
    /// чтобы проверка интерфейса не меняла настройки установленной Luna.
    private static func loadSettings() -> LunaSettings {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["LUNA_SETTINGS_SUITE"], let defaults = UserDefaults(suiteName: suite) {
            return LunaSettings(defaults: defaults)
        }
        #endif
        return LunaSettings()
    }

    private func startCore() {
        do {
            let client = CoreClient(launch: try CoreLocator.locate())
            client.onTaskEvent = { [state] in state.apply($0) }
            client.onAgentsEvent = { [state] in state.applyAgents($0) }
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
                // С первого запроса ядро начинает присылать изменения списка агентов.
                if let list: AgentListResult = try? await client.request("agents.list") {
                    state.applyAgents(list.sessions)
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
        menu.addItem(menuItem("Агенты", #selector(agentsClicked), shortcut: .toggleAgents))
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
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

    @objc private func agentsClicked() {
        DispatchQueue.main.async { [state] in state.showAgents() }
    }

    @objc private func settingsClicked() {
        DispatchQueue.main.async { [state] in state.openSettings() }
    }
}
