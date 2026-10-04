import MarkdownUI
import SwiftUI

struct ResultView: View {
    let taskId: String

    @EnvironmentObject private var state: AppState
    @State private var contentHeight: CGFloat = 0
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let task = state.task(id: taskId) {
                header(task)
                content(task)
                if task.status == .done { footer(task) }
            } else {
                Text("Задача не найдена").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: Layout.cardWidth, alignment: .leading)
        .hangingCard()
    }

    private func header(_ task: TaskInfo) -> some View {
        HStack(spacing: 8) {
            Text(task.prompt)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if let source = task.context, source.sourceLabel != nil {
                SourceLabel(source: source)
                    .font(.system(size: 11))
                    .frame(maxWidth: 200, alignment: .leading)
                    .help(source.url ?? source.title ?? "")
            }
            Spacer()
            headerButton("list.bullet", help: "Список задач", action: state.showTasks)
            headerButton("xmark", help: "Закрыть (esc)", action: state.collapse)
        }
        .foregroundStyle(.secondary)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func content(_ task: TaskInfo) -> some View {
        switch task.status {
        case .queued, .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(task.progress ?? (task.status == .queued ? "В очереди…" : "Думаю…"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отменить") { state.cancel(taskId: task.id) }
                    .controlSize(.small)
            }
        case .done:
            ScrollView {
                Markdown(task.result ?? "")
                    .markdownTheme(.luna)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // Карточка растёт вместе с ответом, а длинный ответ прокручивается.
            .frame(height: min(max(contentHeight, 20), Layout.resultMaxHeight))
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Label(task.error?.message ?? "Неизвестная ошибка", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if let hint = hint(for: task.error?.kind) {
                    Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        case .cancelled:
            Text("Задача отменена").foregroundStyle(.secondary)
        }
    }

    private func footer(_ task: TaskInfo) -> some View {
        HStack {
            Text(caption(task))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(copied ? "Скопировано" : "Копировать") { copy(task.result ?? "") }
                .controlSize(.small)
        }
    }

    private func caption(_ task: TaskInfo) -> String {
        task.durationSeconds.map { "Claude Code · \($0) с" } ?? "Claude Code"
    }

    private func hint(for kind: TaskErrorKind?) -> String? {
        switch kind {
        case .auth: "Откройте терминал, запустите `claude` и выполните /login."
        case .rateLimit: "Лимит подписки исчерпан. Попробуйте позже."
        case .notInstalled: "Установите Claude Code: https://claude.com/claude-code"
        case .sessionNotFound: "Разговор у исполнителя не сохранился. Задайте вопрос заново"
        case .unknown, nil: nil
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private extension Theme {
    /// GitHub-тема без собственного фона: карточка уже тёмная.
    static let luna = Theme.gitHub
        .text {
            ForegroundColor(.white)
            BackgroundColor(nil)
            FontSize(14)
        }
}
