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
                ModelPicker()
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

/// «Claude Code · Модель» — единственный элемент выбора в нижней строке панели ввода. Исполнитель
/// в нём пока подпись; его переключатель (LUNA-17) станет частью этого же элемента, а не вторым.
/// Меню — «По умолчанию» и список моделей, текущая отмечена; выбор пишется в настройки сразу.
private struct ModelPicker: View {
    @EnvironmentObject private var settings: LunaSettings

    private let executor = ExecutorId.claudeCode.rawValue

    var body: some View {
        Menu {
            choice(title: ModelName.defaultTitle, model: nil)
            Divider()
            ForEach(settings.models(for: executor), id: \.self) { model in
                choice(title: ModelName.short(model), model: model)
            }
        } label: {
            Text("Claude Code · \(current)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Модель, на которой уйдёт вопрос")
    }

    private var current: String {
        settings.model(for: executor).map(ModelName.short) ?? ModelName.defaultTitle
    }

    private func choice(title: String, model: String?) -> some View {
        Button {
            settings.setModel(model, for: executor)
        } label: {
            if settings.model(for: executor) == model {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
