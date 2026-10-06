import SwiftUI

/// «Claude Code · Модель» — элемент выбора модели; общий для панели ввода и поля продолжения
/// диалога. Исполнитель в нём пока подпись; его переключатель (LUNA-17) станет частью этого же
/// элемента, а не вторым. Что в меню, что отмечено и куда пишется выбор — решает вызывающий.
struct ModelPicker: View {
    let sections: ModelMenuSections
    let selected: String?
    let help: String
    let onSelect: (String?) -> Void

    var body: some View {
        Menu {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, items in
                if index > 0 { Divider() }
                ForEach(items) { item in choice(item) }
            }
        } label: {
            Text("Claude Code · \(selected.map(ModelName.short) ?? ModelName.defaultTitle)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help(help)
    }

    private func choice(_ item: ModelMenuItem) -> some View {
        Button {
            onSelect(item.model)
        } label: {
            if selected == item.model {
                Label(item.title, systemImage: "checkmark")
            } else {
                Text(item.title)
            }
        }
    }
}
