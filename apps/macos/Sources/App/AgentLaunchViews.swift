#if !APPSTORE
import SwiftUI

// MARK: - «Запустить агента» на странице запроса (LUNA-77)
//
// Кнопка рядом с чипом проекта — только у Claude Code по подписке (решение В5) — и меню целей.
// Логика — в AgentLaunchPlan.swift (без окна, под тестом), исполнение — AgentLaunch.swift.
// Меню — всплывающее окно, как выбор проекта и модели: приложение пользователя остаётся активным.

struct AgentLaunchButton: View {
    @ObservedObject var state: AppState
    @Binding var text: String
    @Binding var isPresented: Bool
    /// Папка выбранного проекта на диске: проверяется при показе и смене проекта, не на каждый ввод.
    @State private var folderState: ChatProjectFolder? = nil

    private var refusal: AgentLaunchRefusal? {
        AgentLaunchPlan.refusal(folder: state.activeChatProject?.path, folderState: folderState, text: text)
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isPresented.toggle() }
        } label: {
            ChatChipIcon(systemName: "arrow.up.forward.app")
        }
        .buttonStyle(.plain)
        // Неактивна, пока запуск невозможен; по клику меню скажет почему.
        .opacity(refusal == nil ? 1 : 0.45)
        .help(refusal.map(AgentLaunchText.refusal)
              ?? String(localized: "agent.launch.button.help", defaultValue: "Launch an agent in the project"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentLaunchMenuView(state: state, text: $text, isPresented: $isPresented)
                .frame(width: 290)
        }
        .onAppear(perform: inspect)
        .onChange(of: state.activeChatProject?.id) { _, _ in inspect() }
        .onChange(of: state.chatProjectsRevision) { _, _ in inspect() }
    }

    private func inspect() {
        folderState = state.activeChatProject.map { ChatProjectFolder.inspect($0.path) }
    }
}

/// Меню целей: только установленные, последняя выбранная первой.
struct AgentLaunchMenuView: View {
    @ObservedObject var state: AppState
    @Binding var text: String
    @Binding var isPresented: Bool
    @State private var apps: AgentLaunchApps? = nil
    @State private var folderState: ChatProjectFolder? = nil
    /// Что сказать после клика, если запуск не ушёл.
    @State private var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agent.launch.title", defaultValue: "Launch agent"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#8A8F98"))
            if let project = state.activeChatProject {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "#E07950"))
                    Text(project.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "#C8CDD4"))
                        .lineLimit(1).truncationMode(.middle)
                }
                .help(project.path)
            }
            if let refusal = AgentLaunchPlan.refusal(folder: state.activeChatProject?.path,
                                                     folderState: folderState, text: text) {
                message(AgentLaunchText.refusal(refusal), warning: true)
            } else if let apps {
                let items = AgentLaunchMenu.items(apps: apps, last: state.agentLaunchTarget)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.target) { item in row(item) }
                }
                if AgentLaunchMenu.nothingToLaunch(items) {
                    message(String(localized: "agent.launch.none",
                                   defaultValue: "No apps to launch in: VS Code with the Claude Code extension, Claude Desktop or Claude Code in a terminal."),
                            warning: false)
                } else {
                    message(String(localized: "agent.launch.hint",
                                   defaultValue: "The task is typed into a new Claude Code chat in the project folder. The agent starts when you press Enter there."),
                            warning: false)
                }
            }
            if let note { message(note, warning: true) }
        }
        .padding(14)
        .background(Color(hex: "#16171B"))
        .onAppear {
            // По открытию меню, не в фоне: установленные приложения и папка проекта.
            apps = AgentLaunch.installedApps()
            folderState = state.activeChatProject.map { ChatProjectFolder.inspect($0.path) }
        }
    }

    private func launch(_ target: AgentLaunchTarget) {
        note = nil
        switch state.launchAgent(target, text: text) {
        case .launched:
            text = ""
            isPresented = false
            SoundEngine.shared.play("blip")
        case .refused(let refusal):
            note = AgentLaunchText.refusal(refusal)
        case .appMissing:
            note = String(localized: "agent.launch.app-missing",
                          defaultValue: "The app is not found — it may have been removed.")
            apps = AgentLaunch.installedApps()
        }
    }

    private func row(_ item: AgentLaunchMenu.Item) -> some View {
        let accent = Color(hex: ChatProvider.claudeCode.accentHex)
        return Button { launch(item.target) } label: {
            HStack(spacing: 8) {
                Image(systemName: AgentLaunchText.icon(item.target))
                    .font(.system(size: 11))
                    .foregroundColor(item.isEnabled ? accent : Color(hex: "#5C6370"))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AgentLaunchText.name(item.target))
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: item.isEnabled ? "#C8CDD4" : "#5C6370"))
                    if let blocked = item.blocked {
                        Text(AgentLaunchText.blocked(blocked))
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#5C6370"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
    }

    private func message(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(.system(size: warning ? 11 : 10))
            .foregroundColor(warning ? .orange : Color(hex: "#5C6370"))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Тексты меню: ru/en в каталоге строк.
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

    static func refusal(_ refusal: AgentLaunchRefusal) -> String {
        switch refusal {
        case .noProject:
            return String(localized: "agent.launch.refusal.no-project", defaultValue: "Choose a project first")
        case .emptyText:
            return String(localized: "agent.launch.refusal.empty", defaultValue: "Type the task first")
        case .textTooLong:
            return String(localized: "agent.launch.refusal.too-long",
                          defaultValue: "The task is longer than 5000 characters — shorten it")
        case .invalidFolder:
            return String(localized: "agent.launch.refusal.invalid-folder",
                          defaultValue: "The project folder path cannot be used")
        case .folderMissing:
            return String(localized: "agent.launch.refusal.missing", defaultValue: "Project folder not found")
        case .folderNoAccess:
            return String(localized: "agent.launch.refusal.no-access", defaultValue: "No access to the project folder")
        }
    }
}
#endif
