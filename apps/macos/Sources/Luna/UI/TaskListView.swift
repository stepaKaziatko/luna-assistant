import SwiftUI

/// Список активных и завершённых задач: новые сверху, выбор стрелками, открытие по ↩ или клику.
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
                    ForEach(state.listedTasks, id: \.id) { task in
                        TaskRow(task: task, isSelected: task.id == state.selectedTaskId, isUnseen: state.unseen.contains(task.id))
                            .id(task.id)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 20), Layout.taskListMaxHeight))
            .onChange(of: state.selectedTaskId) { _, selected in
                if let selected { proxy.scrollTo(selected) }
            }
        }
    }
}

private struct TaskRow: View {
    let task: TaskInfo
    let isSelected: Bool
    let isUnseen: Bool

    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            indicator.frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.prompt)
                    .font(.system(size: 13, weight: isUnseen ? .semibold : .regular))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(task.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)

            if let source = task.context, source.sourceLabel != nil {
                SourceLabel(source: source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 170, alignment: .trailing)
            }
            if task.isActive {
                Button(action: { state.cancel(taskId: task.id) }) {
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
        .onTapGesture { state.open(taskId: task.id) }
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
