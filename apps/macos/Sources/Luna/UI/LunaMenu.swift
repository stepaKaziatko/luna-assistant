import AppKit
import KeyboardShortcuts

/// Меню Luna: его открывает и значок в строке меню, и правый клик по шторке. Собирается в одном
/// месте, поэтому пункты и действия у двух путей не расходятся. У приложения-агента нет главного
/// меню и responder chain до приложения не доходит, поэтому у каждого пункта явный `target`,
/// в том числе у «Выйти из Luna».
@MainActor
final class LunaMenu: NSObject {
    private let state: AppState
    private let quit: () -> Void

    init(state: AppState, quit: @escaping () -> Void) {
        self.state = state
        self.quit = quit
    }

    /// Новое меню: одно и то же `NSMenu` двум родителям не отдаётся.
    func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Спросить…", #selector(askClicked), shortcut: .toggleInput))
        menu.addItem(item("Последний результат", #selector(lastResultClicked), shortcut: .openLastResult))
        menu.addItem(item("Список задач", #selector(tasksClicked), shortcut: .toggleTasks))
        menu.addItem(item("Агенты", #selector(agentsClicked), shortcut: .toggleAgents))
        menu.addItem(.separator())
        menu.addItem(item("Настройки…", #selector(settingsClicked), key: ","))
        menu.addItem(item("Выйти из Luna", #selector(quitClicked), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, shortcut: KeyboardShortcuts.Name) -> NSMenuItem {
        let item = item(title, action, key: "")
        item.setShortcut(for: shortcut)
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
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

    @objc private func quitClicked() {
        quit()
    }
}
