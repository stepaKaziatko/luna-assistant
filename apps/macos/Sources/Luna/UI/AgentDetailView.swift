import SwiftUI

/// Одна сессия агента, чуть подробнее плитки: слева — кто это и о чём сессия, справа — живая лента
/// шагов. Совсем подробно — в отдельном окне (пробел) или в самом чате агента (↩).
struct AgentDetailView: View {
    let sessionId: String

    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let session = state.agent(id: sessionId) {
                // Запрос подтверждения — над полосой сессии: карточка вырастает на высоту блока (до
                // `agentApprovalMaxHeight`), фигуру острова по-прежнему рисует RootView.
                VStack(alignment: .leading, spacing: 12) {
                    if let approval = session.approval {
                        SessionApprovalBlock(sessionId: session.id, approval: approval)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        summary(session).frame(width: 224, alignment: .leading)
                        feed(session)
                    }
                    .frame(height: Layout.agentCardHeight - 2 * Self.inset)
                }
            } else {
                Text("Сессия завершилась")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Layout.agentCardHeight - 2 * Self.inset)
            }
        }
        .padding(Self.inset)
        .frame(width: Layout.cardWidth, alignment: .topLeading)
    }

    private static let inset: CGFloat = 16

    private func summary(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                MoonAvatar(look: .session(session), mood: session.mood(finished: false), size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.project)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(session.agentName)
                        if session.host.name != nil {
                            Text("·")
                            HostLabel(host: session.host)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Отдельной строкой: в колонке 224 pt вместе с хозяином она обрезала бы его, а он нужен для перехода.
                    if let model = session.modelTitle {
                        Text(model)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .help(session.cwd)

            Text(session.displayTitle)
                .font(.system(size: 12.5))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            AgentStatusLine(session: session, isFinished: false)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                action("Открыть", key: "↩", prominent: true, help: session.host.jumpTitle) {
                    state.jumpToAgent(id: session.id)
                } icon: {
                    HostIcon(host: session.host, size: 14)
                }
                action("В окне", key: "␣", prominent: false, help: "Подробная лента в отдельном окне") {
                    state.openAgentWindow(id: session.id)
                } icon: {
                    Image(systemName: "macwindow").font(.system(size: 11))
                }
            }
        }
    }

    /// Лента шагов — «экран», на котором видно работу агента; держится у последнего шага.
    private func feed(_ session: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(state.agentSteps.enumerated()), id: \.offset) { index, step in
                        StepRow(step: step, isCurrent: index == state.agentSteps.count - 1 && session.state == .working)
                            .id(index)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    if state.agentSteps.isEmpty {
                        Text("Шагов пока нет").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    Color.clear.frame(height: 0).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.agentSteps.count)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: state.agentSteps) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                cornerButton("chevron.left", help: "К списку агентов (esc)", action: state.showAgents)
                cornerButton("xmark", help: "Закрыть", action: state.collapse)
            }
            .padding(6)
        }
    }

    private func action(
        _ title: String, key: String, prominent: Bool, help: String,
        action: @escaping () -> Void, @ViewBuilder icon: () -> some View
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon()
                Text(title)
                Text(key).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.white.opacity(prominent ? 0.16 : 0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func cornerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.5), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Шаг ленты: значок рода шага и строка; текущий шаг работающего агента мерцает.
struct StepRow: View {
    let step: AgentStep
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: step.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(step.kind == .prompt ? .primary : .tertiary)
                .frame(width: 14)
            Group {
                if isCurrent {
                    ShimmerText(text: step.text)
                } else {
                    Text(step.text)
                        .foregroundStyle(step.kind == .prompt ? .primary : .secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 12, weight: step.kind == .prompt ? .medium : .regular))
            .lineLimit(step.kind == .tool ? 1 : 3)
        }
    }
}

/// Блок подтверждения сессии агента — в карточке и в окне сессии, над лентой. Не выше
/// `Layout.agentApprovalMaxHeight`: длинное содержимое прокручивается внутри, кнопки блока остаются наверху.
struct SessionApprovalBlock: View {
    let sessionId: String
    let approval: ApprovalRequest

    var body: some View {
        ScrollView(.vertical) {
            ApprovalBlock(subject: .session(id: sessionId), approval: approval)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Layout.agentApprovalMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}
