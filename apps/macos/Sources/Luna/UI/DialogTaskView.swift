import AppKit
import MarkdownUI
import SwiftUI

/// Одна задача диалога так, как её показывают карточка и окно «Открыть полностью»:
/// у уточнения — запрос над ответом, ниже — ответ, прогресс, ошибка с подсказкой или отмена.
struct DialogTaskView: View {
    let task: TaskInfo
    /// Запрос первой задачи — в шапке, у уточнений он над ответом.
    let showsQuestion: Bool

    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsQuestion { question }
            content
        }
    }

    private var question: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .bold))
            Text(task.prompt).textSelection(.enabled)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
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
            Markdown(task.result ?? "")
                .markdownTheme(.luna)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func hint(for kind: TaskErrorKind?) -> String? {
        switch kind {
        case .auth: "Откройте терминал, запустите `claude` и выполните /login."
        case .rateLimit: "Лимит подписки исчерпан. Попробуйте позже."
        case .notInstalled: "Установите Claude Code: https://claude.com/claude-code"
        case .sessionNotFound: "Разговор у исполнителя не сохранился. Задайте вопрос заново"
        case .unknown, nil: nil
        }
    }
}

/// «Копировать» карточки и окна: кладёт текст в буфер и полторы секунды показывает «Скопировано».
struct CopyButton: View {
    let text: String

    @State private var copied = false

    var body: some View {
        Button(copied ? "Скопировано" : "Копировать") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            _Concurrency.Task {
                try? await _Concurrency.Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .controlSize(.small)
    }
}

private extension Theme {
    /// GitHub-тема без собственного фона: карточка и окно уже тёмные.
    static let luna = Theme.gitHub
        .text {
            ForegroundColor(.white)
            BackgroundColor(nil)
            FontSize(14)
        }
}
