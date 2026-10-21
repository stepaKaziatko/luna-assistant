#if !APPSTORE
import SwiftUI

// MARK: - Названия и значки целей (LUNA-77)
//
// Кнопки «Запустить агента» больше нет: запрос с проектом сам запускает агента в фоне (LUNA-80).
// Остались тексты целей — ими пользуется «Открыть в…» (LUNA-79, `AgentHandoffViews.swift`).

/// Тексты целей: ru/en в каталоге строк.
enum AgentLaunchText {
    static func name(_ target: AgentLaunchTarget) -> String {
        switch target {
        case .vscode:        return "VS Code"
        case .terminal:      return String(localized: "agent.launch.target.terminal", defaultValue: "Terminal")
        case .claudeDesktop: return "Claude Desktop"
        }
    }

    static func icon(_ target: AgentLaunchTarget) -> String {
        switch target {
        case .vscode:        return "chevron.left.forwardslash.chevron.right"
        case .terminal:      return "terminal"
        case .claudeDesktop: return "macwindow"
        }
    }

    static func blocked(_ reason: AgentLaunchMenu.Blocked) -> String {
        switch reason {
        case .noVSCodeExtension:
            return String(localized: "agent.launch.blocked.no-extension", defaultValue: "No Claude Code extension")
        case .noTerminalHandler:
            return String(localized: "agent.launch.blocked.no-handler", defaultValue: "Run claude in a terminal once")
        }
    }
}
#endif
