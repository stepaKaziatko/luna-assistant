#if !APPSTORE
import SwiftUI

// MARK: - «Открыть в…» на странице агента (LUNA-79)
//
// Иконка в одном ряду с «Перейти к агенту» и меню целей в стиле меню запуска (LUNA-77); строка
// переноса над кнопками. Логика — AgentHandoffPlan.swift (без окна, под тестом), исполнение —
// AgentHandoff.swift. Меню — всплывающее окно: приложение пользователя остаётся активным.

struct AgentHandoffButton: View {
    @ObservedObject var state: AppState
    let session: AgentSessionInfo
    @State private var isPresented = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { isPresented.toggle() }
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "agentPreview.handoff.button.help", defaultValue: "Open in another app"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentHandoffMenuView(state: state, sessionId: session.id, isPresented: $isPresented)
                .frame(width: 270)
        }
    }
}

/// Меню целей: VS Code и Claude Desktop — только установленные, затем команда для терминала.
struct AgentHandoffMenuView: View {
    @ObservedObject var state: AppState
    let sessionId: String
    @Binding var isPresented: Bool
    @State private var apps: AgentLaunchApps? = nil
    @State private var folderExists = false

    private var session: AgentSessionInfo? { state.agentSessions.first { $0.id == sessionId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentPreview.handoff.title", defaultValue: "Open in…"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#8A8F98"))
            if let session, let apps {
                let items = AgentHandoffMenu.items(pill: session.pill, sessionId: session.key.session,
                                                   who: session.who, phase: session.phase,
                                                   waiting: session.wait != nil, apps: apps,
                                                   folderExists: folderExists)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in row(item, session: session) }
                }
                Text(String(localized: "agentPreview.handoff.hint",
                            defaultValue: "Luna opens the session there once you close it where it runs now: the conversation is never open in two places."))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#5C6370"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(hex: "#16171B"))
        .onAppear {
            // По открытию меню, не в фоне: установленные приложения и папка проекта.
            apps = AgentLaunch.installedApps()
            folderExists = session.flatMap { AgentHandoffPlan.folder(of: $0.who) }.map(AgentHandoff.folderExists) ?? false
        }
        // Сессия закрылась, пока меню открыто, — меню больше не о чем.
        .onChange(of: session == nil) { _, gone in if gone { isPresented = false } }
    }

    private func choose(_ item: AgentHandoffMenu.Item, session: AgentSessionInfo) {
        switch item.action {
        case .open(let target):
            if state.requestAgentHandoff(target, session: session) { SoundEngine.shared.play("blip") }
        case .copyCommand:
            state.copyAgentResumeCommand(session)
        }
        isPresented = false
    }

    private func row(_ item: AgentHandoffMenu.Item, session: AgentSessionInfo) -> some View {
        let accent = Color(hex: ChatProvider.claudeCode.accentHex)
        return Button { choose(item, session: session) } label: {
            HStack(spacing: 8) {
                Image(systemName: AgentHandoffText.icon(item.action))
                    .font(.system(size: 11))
                    .foregroundColor(item.isEnabled ? accent : Color(hex: "#5C6370"))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AgentHandoffText.name(item.action))
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: item.isEnabled ? "#C8CDD4" : "#5C6370"))
                        .lineLimit(1).truncationMode(.tail)
                    if let blocked = item.blocked {
                        Text(AgentHandoffText.blocked(blocked))
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
}

/// Строка переноса на странице агента: ждём закрытия (с «Отменить»), открываю, отменён, ошибка.
struct AgentHandoffStatusLine: View {
    @ObservedObject var state: AppState
    let sessionKey: String

    var body: some View {
        if let status = state.agentHandoffStatus, status.sessionKey == sessionKey {
            VStack(alignment: .leading, spacing: 3) {
                Text(AgentHandoffText.status(status))
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(hex: status.isWaiting ? "#C8CDD4" : "#F5A524"))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if status.isWaiting {
                    Button { state.cancelAgentHandoff() } label: {
                        Text(String(localized: "agentPreview.handoff.cancel", defaultValue: "Cancel"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(hex: "#F1F2F4"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.09)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Тексты переноса: ru/en в каталоге строк.
@MainActor
enum AgentHandoffText {
    static func targetName(_ target: AgentHandoffTarget) -> String {
        switch target {
        case .vscode:        return AgentLaunchText.name(.vscode)
        case .claudeDesktop: return AgentLaunchText.name(.claudeDesktop)
        }
    }

    static func name(_ action: AgentHandoffMenu.Item.Action) -> String {
        switch action {
        case .open(let target): return targetName(target)
        case .copyCommand:
            return String(localized: "agentPreview.handoff.copy", defaultValue: "Copy command for Terminal")
        }
    }

    static func icon(_ action: AgentHandoffMenu.Item.Action) -> String {
        switch action {
        case .open(.vscode):        return AgentLaunchText.icon(.vscode)
        case .open(.claudeDesktop): return AgentLaunchText.icon(.claudeDesktop)
        case .copyCommand:          return "doc.on.doc"
        }
    }

    static func blocked(_ reason: AgentHandoffBlocked) -> String {
        switch reason {
        case .agentWorking:
            return String(localized: "agentPreview.handoff.blocked.working",
                          defaultValue: "The agent is working — wait for the turn to end")
        case .agentWaiting:
            return String(localized: "agentPreview.handoff.blocked.waiting", defaultValue: "The agent is waiting for your answer")
        case .noVSCodeExtension:
            return AgentLaunchText.blocked(.noVSCodeExtension)
        case .folderMissing:
            return String(localized: "agentPreview.hint.folder-missing", defaultValue: "Project folder not found")
        }
    }

    static func status(_ status: AgentHandoffStatus) -> String {
        switch status {
        case .waiting(let pending):
            let target = targetName(pending.plan.target)
            let host = AgentHostApps.name(for: pending.hostBundleId)
                ?? String(localized: "agentPreview.handoff.host.unknown", defaultValue: "its app")
            if ClaudeHost.isTerminal(bundleId: pending.hostBundleId) {
                return String(localized: "agentPreview.handoff.waiting.terminal",
                              defaultValue: "Close the session in \(host) (/exit) — Luna will open it in \(target)")
            }
            return String(localized: "agentPreview.handoff.waiting",
                          defaultValue: "Close the session in \(host) — Luna will open it in \(target)")
        case .opening(let target, _):
            return String(localized: "agentPreview.handoff.opening", defaultValue: "Opening in \(targetName(target))…")
        case .cancelled(.resumed, _):
            return String(localized: "agentPreview.handoff.cancelled.resumed",
                          defaultValue: "The session went on working — handoff cancelled")
        case .cancelled(.timedOut, _):
            return String(localized: "agentPreview.handoff.cancelled.timeout",
                          defaultValue: "The session did not close — handoff cancelled")
        case .cancelled(.byUser, _):
            return String(localized: "agentPreview.handoff.cancelled", defaultValue: "Handoff cancelled")
        case .appMissing(let target, _):
            return String(localized: "agentPreview.handoff.app-missing", defaultValue: "\(targetName(target)) not found")
        case .folderMissing:
            return String(localized: "agentPreview.hint.folder-missing", defaultValue: "Project folder not found")
        case .copied:
            return String(localized: "agentPreview.handoff.copied",
                          defaultValue: "Command copied — paste it into a terminal")
        }
    }
}
#endif
