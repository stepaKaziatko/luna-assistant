#if !APPSTORE
import AppKit

// MARK: - «Открыть в…»: исполнитель (LUNA-79)
//
// Решение — `AgentHandoffPlan` (без окна, под тестом). Здесь только открытие папки и ссылок
// через `NSWorkspace` и запись команды в буфер обмена: никаких подпроцессов, скриптов и записи в
// чужие настройки, новых разрешений macOS не нужно. Открывает перенос `AppState` — по `SessionEnd`
// сессии, для которой человек явно выбрал цель.

@MainActor
enum AgentHandoff {

    enum Outcome: Equatable {
        case opened
        /// Приложения цели нет (удалили, пока ждали).
        case appMissing
        /// Папки проекта для VS Code больше нет.
        case folderMissing
        /// План не прошёл проверку схемы — ничего не открыто.
        case refused
    }

    /// Есть ли папка на диске.
    static func folderExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Выполняет план переноса.
    static func run(_ plan: AgentHandoffPlan) -> Outcome {
        let workspace = NSWorkspace.shared
        let bundleId = plan.target.bundleId
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) else {
            handoffLog("Handoff: \(plan.target.rawValue) is not installed")
            return .appMissing
        }
        // Схема ссылки проверяется ещё раз: открываются только ссылки двух целей плана.
        let links = plan.steps.compactMap { step -> URL? in
            if case .openURL(let url) = step { return url }
            return nil
        }
        guard !links.isEmpty,
              links.allSatisfy({ $0.scheme.map(AgentHandoffPlan.allowedSchemes.contains) == true }) else {
            handoffLog("Handoff: a link with an unexpected scheme, nothing opened")
            return .refused
        }

        switch (plan.steps.first, plan.steps.dropFirst().first) {
        case (.openFolder(let folder), .openURL(let link)?):
            guard folderExists(folder) else {
                handoffLog("Handoff: the project folder is gone, nothing opened")
                return .folderMissing
            }
            // VS Code: ссылку получает окно в фокусе — сначала окно с папкой проекта. Не запущенный
            // VS Code сперва стартует: ждём его окна дольше.
            let running = workspace.runningApplications.contains { $0.bundleIdentifier == bundleId }
            AgentJump.openFolderThenLink(folder, link: link, appURL: appURL, bundleId: bundleId,
                                         waitLimit: running ? AgentJumpPlan.linkWaitLimit
                                                            : AgentLaunchPlan.coldStartLinkWaitLimit)
        case (.openURL(let link), nil):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.open([link], withApplicationAt: appURL, configuration: configuration) { _, error in
                if let error { handoffLog("Handoff: the link was not opened: \(error.localizedDescription)") }
            }
        default:
            handoffLog("Handoff: an unexpected plan, nothing opened")
            return .refused
        }
        handoffLog("Handoff: the session went to \(plan.target.rawValue)")
        return .opened
    }

    /// Команда для терминала — в буфер обмена (решение В2 = b). Luna её не запускает.
    static func copy(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    private nonisolated static func handoffLog(_ message: String) { appendAppLog("luna.log", message) }
}
#endif
