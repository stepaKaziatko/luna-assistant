#if !APPSTORE
import AppKit

// MARK: - Запуск агента из Luna: исполнитель (LUNA-77)
//
// Решение — `AgentLaunchPlan` (без окна, под тестом). Здесь только открытие папки и
// ссылок через `NSWorkspace`: никаких подпроцессов, скриптов и записи в чужие настройки. Новых
// разрешений macOS не нужно. Только по явному клику на цель в меню «Запустить агента».

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

    /// Выполняет план. false — приложение цели не нашлось (удалили между открытием меню и кликом).
    @discardableResult
    static func run(_ plan: AgentLaunchPlan) -> Bool {
        let workspace = NSWorkspace.shared
        let appURL: URL?
        if let bundleId = plan.target.bundleId {
            appURL = workspace.urlForApplication(withBundleIdentifier: bundleId)
        } else {
            appURL = terminalHandler()
        }
        guard let appURL else {
            launchLog("Launch agent: \(plan.target.rawValue) is not installed")
            return false
        }
        // Схема ссылки проверяется ещё раз: открываются только ссылки трёх целей плана.
        let links = plan.steps.compactMap { step -> URL? in
            if case .openURL(let url) = step { return url }
            return nil
        }
        guard links.allSatisfy({ $0.scheme.map(AgentLaunchPlan.allowedSchemes.contains) == true }) else {
            launchLog("Launch agent: a link with an unexpected scheme, nothing opened")
            return false
        }

        switch (plan.steps.first, plan.steps.dropFirst().first) {
        case (.openFolder(let folder), .openURL(let link)?):
            // VS Code: ссылку получает окно в фокусе — сначала окно с папкой проекта. Не запущенный
            // VS Code сперва стартует: ждём его окна дольше.
            let bundleId = plan.target.bundleId ?? ""
            let running = workspace.runningApplications.contains { $0.bundleIdentifier == bundleId }
            AgentJump.openFolderThenLink(folder, link: link, appURL: appURL, bundleId: bundleId,
                                         waitLimit: running ? AgentJumpPlan.linkWaitLimit
                                                            : AgentLaunchPlan.coldStartLinkWaitLimit)
        case (.openURL(let link), nil):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.open([link], withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error { launchLog("Launch agent: the link was not opened: \(error.localizedDescription)") }
            }
        default:
            launchLog("Launch agent: an unexpected plan, nothing opened")
            return false
        }
        return true
    }

    private nonisolated static func launchLog(_ message: String) { appendAppLog("luna.log", message) }
}
#endif
