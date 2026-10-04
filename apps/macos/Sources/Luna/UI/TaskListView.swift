import SwiftUI

/// Список диалогов: строка на диалог, новые сверху, выбор стрелками, открытие по ↩ или клику.
struct TaskListView: View {
    @EnvironmentObject private var state: AppState
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Задачи").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("↑↓ выбрать · ↩ открыть · esc закрыть").font(.system(size: 11))
            }
            .foregroundStyle(.secondary)

            if state.tasks.isEmpty {
                Text("Задач пока нет.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                rows
            }
        }
        .padding(16)
        .frame(width: Layout.cardWidth, alignment: .leading)
        .hangingCard()
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(state.listedDialogs) { dialog in
                        DialogRow(
                            dialog: dialog,
                            isSelected: dialog.threadId == state.selectedThreadId,
                            isUnseen: dialog.tasks.contains { state.unseen.contains($0.id) }
                        )
                        .id(dialog.threadId)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 20), Layout.taskListMaxHeight))
            .onChange(of: state.selectedThreadId) { _, selected in
                if let selected { proxy.scrollTo(selected) }
            }
        }
    }
}

/// Заголовок и источник — от первого запроса диалога, состояние и время — от последней задачи.
private struct DialogRow: View {
    let dialog: Dialog
    let isSelected: Bool
    let isUnseen: Bool

    @EnvironmentObject private var state: AppState

    private var task: TaskInfo { dialog.last }

    var body: some View {
        HStack(spacing: 10) {
            indicator.frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dialog.title)
                        .font(.system(size: 13, weight: isUnseen ? .semibold : .regular))
                        .lineLimit(1)
                    if dialog.followUpCount > 0 {
                        Text("+\(dialog.followUpCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.white.opacity(0.1), in: Capsule())
                            .help("Уточнений: \(dialog.followUpCount)")
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(task.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)

            if let source = dialog.first.context, source.sourceLabel != nil {
                SourceLabel(source: source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 170, alignment: .trailing)
            }
            if dialog.activeTask != nil {
                Button(action: { state.cancel(threadId: dialog.threadId) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Отменить")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(isSelected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { state.open(threadId: dialog.threadId) }
    }

    @ViewBuilder
    private var indicator: some View {
        switch task.status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.8)
        case .done:
            if isUnseen {
                Circle().fill(.green).frame(width: 7, height: 7)
            } else {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
        case .failed:
            Circle().fill(.red).frame(width: 7, height: 7)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        switch task.status {
        case .queued: "В очереди"
        case .running: task.progress ?? "Думаю…"
        case .done: task.durationSeconds.map { "Готово · \($0) с" } ?? "Готово"
        case .failed: task.error?.message ?? "Ошибка"
        case .cancelled: "Отменена"
        }
    }
}
