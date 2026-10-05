import AppKit
import SwiftUI

/// Сессии агентов сеткой плиток: кто работает, кто ждёт человека, кто закончил ход.
/// Выбор стрелками, ↩ — карточка сессии, ⌘↩ — сразу к её окну.
struct AgentsView: View {
    @EnvironmentObject private var state: AppState
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Агенты").font(.system(size: 12, weight: .medium))
                StatusChips(chips: StatusChip.make(tasks: [], unseen: [], hasProblem: false, agents: state.agentsSummary))
                Spacer()
                Text("↩ подробнее · ⌘↩ к окну · esc").font(.system(size: 11))
            }
            .foregroundStyle(.secondary)

            if state.agents.isEmpty {
                Text("Агентов не видно. Запустите Claude Code в редакторе или терминале — сессия появится здесь.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                grid
            }
        }
        .padding(16)
        .frame(width: Layout.cardWidth, alignment: .leading)
    }

    /// Ряды по `AppState.agentColumns` плиток: по ним же ходят стрелки вверх и вниз.
    private var rows: [[AgentSession]] {
        stride(from: 0, to: state.agents.count, by: AppState.agentColumns).map {
            Array(state.agents[$0..<min($0 + AppState.agentColumns, state.agents.count)])
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.tileSpacing) {
                    ForEach(rows, id: \.first?.id) { row in
                        HStack(alignment: .top, spacing: Layout.tileSpacing) {
                            ForEach(row, id: \.id) { session in
                                AgentTile(
                                    session: session,
                                    isFinished: state.finishedAgents.contains(session.id),
                                    isSelected: session.id == state.selectedAgentId,
                                    showsTitle: true
                                )
                                .id(session.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 20), Layout.agentGridMaxHeight))
            .onChange(of: state.selectedAgentId) { _, selected in
                if let selected { proxy.scrollTo(selected) }
            }
        }
    }
}

/// Что агент делает или чего ждёт; у работающего строка мерцает.
struct AgentStatusLine: View {
    let session: AgentSession
    let isFinished: Bool

    var body: some View {
        switch session.state {
        case .working:
            ShimmerText(text: session.statusLine)
        case .waiting:
            Text(session.statusLine).foregroundStyle(.orange)
        case .idle:
            Text("\(session.statusLine) · \(Self.ago(session.updatedAt))")
                .foregroundStyle(isFinished ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
    }

    /// «5 мин назад» по времени последнего изменения сессии.
    static func ago(_ updatedAt: Int, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000)
        guard now.timeIntervalSince(date) >= 60 else { return "только что" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Значок и имя приложения-хозяина.
struct HostLabel: View {
    let host: AgentHost

    var body: some View {
        HStack(spacing: 4) {
            if host.appPath != nil || host.kind == .terminal {
                HostIcon(host: host, size: 13)
            }
            Text(host.name ?? (host.kind == .terminal ? "Терминал" : ""))
                .lineLimit(1)
        }
    }
}

/// Текст, по которому раз в пару секунд пробегает блик: агент занят.
struct ShimmerText: View {
    let text: String

    private var motion = Motion()

    init(text: String) {
        self.text = text
    }

    var body: some View {
        if motion.isStill {
            Text(text).foregroundStyle(.secondary)
        } else {
            TimelineView(IslandClock.schedule()) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                let center = -0.3 + phase * 1.6
                Text(text).foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.5), location: center - 0.3),
                            .init(color: .white, location: center),
                            .init(color: .white.opacity(0.5), location: center + 0.3),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            }
        }
    }
}
