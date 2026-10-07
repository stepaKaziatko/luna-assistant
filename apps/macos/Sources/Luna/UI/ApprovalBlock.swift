import SwiftUI

/// Блок подтверждения внутри задачи диалога: что исполнитель собирается сделать и две кнопки — «Разрешить»
/// и «Отклонить». Рисуется из `TaskInfo.approval` и ничего не знает об инструментах: `summary`, `target`
/// и `detail` — строки от ядра, показываются как текст, не Markdown и не ссылками. Кнопки — над подробностями,
/// чтобы быть видными без прокрутки; разрешение даётся только кликом: клавиш-сокращений у кнопок нет.
/// Фон — как у поля продолжения, своей чёрной фигуры у блока нет.
struct ApprovalBlock: View {
    let task: TaskInfo
    let approval: ApprovalRequest

    @EnvironmentObject private var state: AppState

    /// Ответ уже ушёл ядру, снимка ещё нет: кнопки неактивны, повторный клик не уходит.
    private var isPending: Bool { state.approvalPending.contains(approval.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(approval.summary)
                    .font(.system(size: 13, weight: .semibold))
                if let target = approval.target {
                    Text(target)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(target)
                }
                Spacer(minLength: 8)
                Button("Отклонить") { state.approve(taskId: task.id, allow: false) }
                    .controlSize(.small)
                    .disabled(isPending)
                Button("Разрешить") { state.approve(taskId: task.id, allow: true) }
                    .controlSize(.small)
                    .disabled(isPending)
            }
            if let detail = approval.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = state.approvalError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
