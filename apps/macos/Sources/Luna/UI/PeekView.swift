import KeyboardShortcuts
import SwiftUI

/// Блок, который выезжает из шторки, когда над ней задержался курсор. Растёт в ширину: полоса плиток
/// сессий агентов с превью работы, под ней — последние диалоги Luna. Клавиатуру не забирает —
/// работает только мышь: клик по плитке открывает карточку, значок приложения ведёт к окну сессии.
/// Курсор ушёл — блок убирается.
struct PeekView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: LunaSettings

    private static let padding: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !state.agents.isEmpty { agents }
            if !state.peekDialogs.isEmpty { dialogs }
            if state.agents.isEmpty, state.peekDialogs.isEmpty {
                Text("Сессии агентов и диалоги с Luna появятся здесь.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Self.padding)
        .frame(width: width, alignment: .leading)
    }

    /// Блок шириной в свои плитки: до четырёх в ряду.
    private var width: CGFloat {
        let tiles = Self.strip(min(state.agents.count, AppState.agentColumns), of: Layout.tileWidth)
        let chips = Self.strip(state.peekDialogs.count, of: Layout.peekDialogWidth)
        return min(max(tiles + 2 * Self.padding, chips + 2 * Self.padding, Layout.peekMinWidth), Layout.cardWidth)
    }

    private static func strip(_ count: Int, of width: CGFloat) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * width + CGFloat(count - 1) * Layout.tileSpacing
    }

    private var header: some View {
        let chips = state.statusChips
        return HStack(spacing: 8) {
            // Без дел Luna не спит, а смотрит на курсор: её только что позвали.
            MoonAvatar(look: settings.lunaLook, mood: state.pillPresentation?.mood ?? .listening, size: 24)
            if chips.isEmpty {
                Text("Тихо")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                StatusChips(chips: chips)
            }
            Spacer(minLength: 12)
            PeekButton(help: "Спросить Luna", action: state.toggleInput) {
                HStack(spacing: 5) {
                    Image(systemName: "plus.bubble").font(.system(size: 12))
                    if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleInput) {
                        Text(shortcut.description).font(.system(size: 11, weight: .medium))
                    }
                }
            }
            PeekButton(help: "Все агенты", action: state.showAgents) {
                Image(systemName: "square.grid.2x2").font(.system(size: 12))
            }
            PeekButton(help: "Все диалоги", action: state.showTasks) {
                Image(systemName: "list.bullet").font(.system(size: 12))
            }
            PeekButton(help: "Настройки", action: state.openSettings) {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
        }
    }

    /// Ряды по четыре плитки, не больше двух; что не поместилось — за плиткой-счётчиком.
    private var agents: some View {
        let peek = state.peekAgents
        let rows = stride(from: 0, to: peek.shown.count, by: AppState.agentColumns).map {
            Array(peek.shown[$0..<min($0 + AppState.agentColumns, peek.shown.count)])
        }
        return VStack(alignment: .leading, spacing: Layout.tileSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: Layout.tileSpacing) {
                    ForEach(row, id: \.id) { session in
                        AgentTile(session: session, isFinished: state.finishedAgents.contains(session.id))
                    }
                    if peek.hidden > 0, index == rows.count - 1 {
                        MoreTile(count: peek.hidden)
                    }
                }
            }
        }
    }

    private var dialogs: some View {
        HStack(spacing: Layout.tileSpacing) {
            ForEach(state.peekDialogs) { dialog in
                PeekDialogChip(dialog: dialog, isUnseen: dialog.tasks.contains { state.unseen.contains($0.id) })
            }
        }
    }
}

/// Маленькая кнопка блока: подсвечивается под курсором.
private struct PeekButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(isHovered ? .primary : .secondary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(.white.opacity(isHovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Плитка «ещё столько-то»: ведёт к сетке всех сессий.
private struct MoreTile: View {
    let count: Int

    @EnvironmentObject private var state: AppState
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            Text("+\(count)").font(.system(size: 20, weight: .semibold))
            Image(systemName: "square.grid.2x2").font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: Layout.tileWidth)
        .background(.white.opacity(isHovered ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: state.showAgents)
        .onHover { isHovered = $0 }
        .help("Все агенты")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ещё агентов: \(count)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Диалог Luna одной строкой: значок состояния и запрос. Подробности — в карточке.
private struct PeekDialogChip: View {
    let dialog: Dialog
    let isUnseen: Bool

    @EnvironmentObject private var state: AppState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            DialogIndicator(task: dialog.last, isUnseen: isUnseen)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14, height: 14)
            Text(dialog.title)
                .font(.system(size: 11.5, weight: isUnseen ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(width: Layout.peekDialogWidth, height: 28)
        .background(.white.opacity(isHovered ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { state.open(threadId: dialog.threadId) }
        .onHover { isHovered = $0 }
        .help("\(dialog.title) — \(dialog.last.statusLine)")
    }
}
