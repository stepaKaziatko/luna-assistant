import MarkdownUI
import SwiftUI

/// Карточка диалога: запрос и ответ каждой его задачи, внизу — поле продолжения.
struct ResultView: View {
    let threadId: String

    @EnvironmentObject private var state: AppState
    @State private var contentHeight: CGFloat = 0
    @State private var copied = false
    @FocusState private var followUpFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dialog = state.dialog(threadId: threadId) {
                header(dialog)
                conversation(dialog)
                footer(dialog)
            } else {
                Text("Задача не найдена").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: Layout.cardWidth, alignment: .leading)
        .hangingCard()
        .onChange(of: state.followUpFocusRequest) { followUpFocused = true }
    }

    /// Шапка — первый запрос диалога и источник, с которого он начался.
    private func header(_ dialog: Dialog) -> some View {
        HStack(spacing: 8) {
            Text(dialog.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if let source = dialog.first.context, source.sourceLabel != nil {
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

    /// Задачи диалога по порядку; первый запрос — в шапке, у уточнений запрос над ответом.
    /// Карточка растёт вместе с диалогом, длинный прокручивается и держится у последней задачи.
    private func conversation(_ dialog: Dialog) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(dialog.tasks.enumerated()), id: \.element.id) { index, task in
                        VStack(alignment: .leading, spacing: 8) {
                            if index > 0 { question(task.prompt) }
                            content(task)
                        }
                        .id(task.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 20), Layout.resultMaxHeight))
            .onAppear { proxy.scrollTo(dialog.last.id, anchor: .bottom) }
            .onChange(of: dialog.last) { proxy.scrollTo(dialog.last.id, anchor: .bottom) }
            .onChange(of: contentHeight) { proxy.scrollTo(dialog.last.id, anchor: .bottom) }
        }
    }

    private func question(_ prompt: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .bold))
            Text(prompt).textSelection(.enabled)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
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

    @ViewBuilder
    private func footer(_ dialog: Dialog) -> some View {
        if dialog.continuationPoint != nil && !state.isSendingFollowUp {
            followUpField
        }
        if let error = state.followUpError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
        if dialog.last.status == .done {
            HStack {
                Text(caption(dialog.last))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Скопировано" : "Копировать") { copy(dialog.last.result ?? "") }
                    .controlSize(.small)
            }
        }
    }

    /// Фокус — по `Tab` или клику; `↩` отправляет, пустое не уходит, `esc` закрывает карточку.
    private var followUpField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            TextField("Продолжить диалог…", text: $state.followUpDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($followUpFocused)
                .onSubmit(state.submitFollowUp)
            if followUpFocused {
                Text("↩ отправить").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("tab").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
