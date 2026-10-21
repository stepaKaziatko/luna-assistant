#if !APPSTORE
import AppKit

// MARK: - Что из целей установлено (LUNA-77)
//
// Кнопки «Запустить агента» больше нет (LUNA-80): запрос с проектом сам запускает агента в фоне.
// Осталось то, на что опирается «Открыть в…» (LUNA-79): какие приложения есть на Mac. Только
// `NSWorkspace` и список имён в папке расширений VS Code: никаких подпроцессов и скриптов.

@MainActor
enum AgentLaunch {

    /// Что из целей установлено. Читается по открытию меню, не в фоне.
    static func installedApps(home: String = NSHomeDirectory()) -> AgentLaunchApps {
        let workspace = NSWorkspace.shared
        var apps = AgentLaunchApps()
        apps.vscode = AgentLaunchTarget.vscode.bundleId.flatMap(workspace.urlForApplication(withBundleIdentifier:)) != nil
        if apps.vscode {
            // Только имена каталогов: есть ли среди них расширение Claude Code (решение В3).
            let names = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.vscode/extensions")) ?? []
            apps.vscodeExtension = AgentLaunchMenu.hasClaudeCodeExtension(names)
        }
        apps.terminalHandler = terminalHandler() != nil
        apps.claudeDesktop = AgentLaunchTarget.claudeDesktop.bundleId
            .flatMap(workspace.urlForApplication(withBundleIdentifier:)) != nil
        return apps
    }

    /// Приложение, которое система зовёт на `claude-cli://` (обработчик Claude Code), или nil.
    private static func terminalHandler() -> URL? {
        guard let probe = URL(string: "\(AgentLaunchTarget.terminal.scheme)://open") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }
}
#endif
