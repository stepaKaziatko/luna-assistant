import SwiftUI

struct InputView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: LunaSettings
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MoonAvatar(look: settings.lunaLook, mood: .listening, size: 26)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 7 }
                TextField("Спросите что-нибудь…", text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(state.submit)
            }
            .font(.system(size: 17))

            if hasChips { ContextChips() }

            // Ошибка — над нижней строкой: выбор модели остаётся доступным, когда ядро отклонило запрос.
            if let problem = state.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack {
                InputModelPicker()
                Spacer()
                Text("↩ отправить · esc закрыть")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: Layout.cardWidth)
        .onAppear { focused = true }
    }

    private var hasChips: Bool {
        state.context?.payload != nil || !state.captureIssues.isEmpty
    }
}

/// Панель ввода: меню — «По умолчанию» и список моделей, текущая отмечена; выбор пишется в настройки сразу.
private struct InputModelPicker: View {
    @EnvironmentObject private var settings: LunaSettings

    private let executor = ExecutorId.claudeCode.rawValue

    var body: some View {
        ModelPicker(
            sections: ModelMenu.inputSections(models: settings.models(for: executor)),
            selected: settings.model(for: executor),
            help: "Модель, на которой уйдёт вопрос",
            onSelect: { settings.setModel($0, for: executor) }
        )
    }
}
