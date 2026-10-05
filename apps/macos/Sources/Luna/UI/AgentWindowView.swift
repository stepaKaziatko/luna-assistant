import MarkdownUI
import SwiftUI

/// Содержимое окна сессии агента: подробная лента — запросы человека, текст агента целиком,
/// вызовы инструментов. Следует за сессией: новые шаги появляются без переоткрытия.
/// Сессия завершилась — окно остаётся с тем, что успели прочитать.
struct AgentWindowView: View {
    let sessionId: String

    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = state.agent(id: sessionId) ?? state.agentWindowSessions[sessionId] {
                header(session, isLive: state.agent(id: sessionId) != nil)
                Divider().opacity(0.4)
                transcript(session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func header(_ session: AgentSession, isLive: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            MoonAvatar(look: .session(session), mood: isLive ? session.mood(finished: false) : .sleeping, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text("\(session.project) · \(session.agentName)")
                    if session.host.name != nil {
                        Text("·")
                        HostLabel(host: session.host)
                    }
                    Text("·")
                    if isLive {
                        AgentStatusLine(session: session, isFinished: false)
                    } else {
                        Text("сессия завершена")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(session.cwd)
            }
            Spacer()
            if isLive {
                // Переход в сам чат агента: окно Luna остаётся открытым рядом.
                Button(session.host.jumpTitle) { state.jumpToAgent(id: session.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        // Сверху — полоса заголовка окна с кнопкой закрытия: за неё окно перетаскивается.
        .padding(.top, DialogWindowView.titlebarHeight)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func transcript(_ session: AgentSession) -> some View {
        if let steps = state.agentTranscripts[sessionId] {
            if steps.isEmpty {
                placeholder("У сессии пока нет шагов.")
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                TranscriptStep(step: step, isCurrent: index == steps.count - 1 && session.state == .working)
                            }
                        }
                        .padding(20)
                        // Короткая лента начинается сверху, а не прижимается к низу окна.
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                    // Длинная держится у свежих шагов, пока её не прокрутили вверх.
                    .defaultScrollAnchor(.bottom)
                }
            }
        } else {
            placeholder("Читаю журнал сессии…")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Шаг подробной ленты: запрос человека — плашкой, текст агента — как ответ, инструмент — строкой.
private struct TranscriptStep: View {
    let step: AgentStep
    let isCurrent: Bool

    var body: some View {
        switch step.kind {
        case .prompt:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: step.symbol).font(.system(size: 11, weight: .semibold))
                Text(step.text)
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 6)
        case .text:
            Markdown(step.text)
                .markdownTheme(.luna)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            StepRow(step: step, isCurrent: isCurrent)
        }
    }
}
