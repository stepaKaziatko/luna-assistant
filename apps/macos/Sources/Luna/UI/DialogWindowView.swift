import SwiftUI

/// Содержимое окна «Открыть полностью»: диалог целиком, с прокруткой и выделением текста.
/// Следует за `AppState.tasks`: новые уточнения, прогресс и ответы появляются без переоткрытия.
struct DialogWindowView: View {
    let threadId: String

    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let dialog = state.dialog(threadId: threadId) {
                header(dialog)
                Divider().opacity(0.4)
                conversation(dialog)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    /// Шапка — первый запрос и источник диалога; «Копировать» берёт последний ответ.
    private func header(_ dialog: Dialog) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dialog.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                if let source = dialog.first.context, source.sourceLabel != nil {
                    SourceLabel(source: source)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(source.url ?? source.title ?? "")
                }
                // Модель последней задачи: у задач диалога модели могут различаться. Выбора здесь нет.
                if let model = dialog.modelTitle {
                    Text("Claude Code · \(model)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let answer = dialog.tasks.last(where: { $0.status == .done })?.result {
                CopyButton(text: answer)
            }
        }
        .padding(.horizontal, 20)
        // Сверху — полоса заголовка окна с кнопкой закрытия: за неё окно перетаскивается.
        .padding(.top, Self.titlebarHeight)
        .padding(.bottom, 12)
    }

    private func conversation(_ dialog: Dialog) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(dialog.tasks.enumerated()), id: \.element.id) { index, task in
                        DialogTaskView(task: task, showsQuestion: index > 0)
                            .id(task.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            // Последняя задача диалога видна с начала: вопрос уточнения, затем прогресс и ответ —
            // окно следует за ней, как карточка, и когда она появляется, и когда приходит ответ.
            .onAppear { proxy.scrollTo(dialog.last.id, anchor: .top) }
            .onChange(of: dialog.last) { proxy.scrollTo(dialog.last.id, anchor: .top) }
        }
    }

    static let titlebarHeight: CGFloat = 28
}
