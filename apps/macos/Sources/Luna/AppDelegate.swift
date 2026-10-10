import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState(settings: AppDelegate.loadSettings())
    private lazy var menu = LunaMenu(state: state, quit: { NSApp.terminate(nil) })
    private var panels: PanelController?
    private var windows: DialogWindows?
    private var settingsWindow: SettingsWindow?
    private var statusItem: NSStatusItem?
    private var core: CoreClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Запись в pipe умершего ядра должна вернуть ошибку, а не убить приложение.
        signal(SIGPIPE, SIG_IGN)

        panels = PanelController(state: state, menu: { [menu] in menu.make() })
        windows = DialogWindows(state: state)
        let sounds = SoundPlayer(settings: state.settings)
        let settingsWindow = SettingsWindow(
            settings: state.settings, permissions: state.permissions, agentHook: state.agentHook, sounds: sounds,
            quit: { NSApp.terminate(nil) }
        )
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

    /// Luna.app открыли снова, пока она работает (Spotlight, Finder, `open`): у неё нет Dock и, возможно,
    /// не видно значка, поэтому открывается окно настроек — оттуда можно и выйти. Второй экземпляр не запускается.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state.openSettings()
        return false
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
        item.menu = menu.make()
        statusItem = item
    }
}
