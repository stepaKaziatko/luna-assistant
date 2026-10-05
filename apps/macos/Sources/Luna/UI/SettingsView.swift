import KeyboardShortcuts
import SwiftUI

/// Какая вкладка настроек открыта.
@MainActor
final class SettingsNavigation: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case general, avatar, sounds

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "Основные"
            case .avatar: "Аватар"
            case .sounds: "Звуки"
            }
        }
    }

    @Published var tab = Tab.general
}

/// Окно настроек: шторка и сочетания клавиш, облик Luna, звуки.
struct SettingsView: View {
    @EnvironmentObject private var settings: LunaSettings
    @EnvironmentObject private var navigation: SettingsNavigation
    let sounds: SoundPlayer

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел", selection: $navigation.tab) {
                ForEach(SettingsNavigation.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)

            Group {
                switch navigation.tab {
                case .general: general
                case .avatar: avatar
                case .sounds: soundsForm
                }
            }
            .formStyle(.grouped)
            // Фон формы — фон окна: полоса с вкладками не отделяется от содержимого.
            .scrollContentBackground(.hidden)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height, alignment: .top)
    }

    private var general: some View {
        Form {
            Section("Шторка") {
                Toggle("Раскрывать при наведении", isOn: $settings.hoverPeek)
                Toggle("Аватары агентов в шторке", isOn: $settings.pillAvatars)
                Toggle("Подпись рядом со счётчиками", isOn: $settings.pillText)
            }
            Section("Сочетания клавиш") {
                KeyboardShortcuts.Recorder("Спросить", name: .toggleInput)
                KeyboardShortcuts.Recorder("Последний результат", name: .openLastResult)
                KeyboardShortcuts.Recorder("Список задач", name: .toggleTasks)
                KeyboardShortcuts.Recorder("Агенты", name: .toggleAgents)
            }
        }
    }

    private var avatar: some View {
        Form {
            Section {
                LabeledContent("Цвет") {
                    choices(AvatarTint.allCases, selected: settings.tint, title: \.title) { tint in
                        AvatarLook(hue: tint.hue, saturation: tint.saturation, seed: AvatarLook.luna.seed, accessory: settings.accessory)
                    } select: { settings.tint = $0 }
                }
                LabeledContent("Аксессуар") {
                    choices(AvatarAccessory.allCases, selected: settings.accessory, title: \.title) { accessory in
                        AvatarLook(hue: settings.tint.hue, saturation: settings.tint.saturation, seed: AvatarLook.luna.seed, accessory: accessory)
                    } select: { settings.accessory = $0 }
                }
            } header: {
                Text("Luna")
            } footer: {
                Text("Сессии агентов красятся по проекту: у одного проекта — один цвет.")
            }
            Section {
                Toggle("Оживлять аватары", isOn: $settings.animateAvatars)
            }
        }
    }

    private var soundsForm: some View {
        Form {
            Section {
                Toggle("Звуки", isOn: $settings.soundsEnabled)
                LabeledContent("Громкость") {
                    Slider(value: $settings.soundVolume, in: 0...1) { editing in
                        // Отпустили ползунок — слышно, что получилось.
                        if !editing { sounds.preview(settings.sound(for: .done) ?? SoundEvent.done.defaultSound) }
                    }
                    .frame(width: 180)
                }
                .disabled(!settings.soundsEnabled)
                ForEach(SoundEvent.allCases) { event in
                    Picker(event.title, selection: sound(of: event)) {
                        Text("Без звука").tag("")
                        Divider()
                        ForEach(soundNames(including: settings.sounds[event]), id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(!settings.soundsEnabled)
                }
            } footer: {
                Text("Звуки — системные, из «Настроек» macOS.")
            }
        }
    }

    /// Выбор из аватаров: каждый вариант показан так, как будет выглядеть на острове.
    private func choices<Value: Identifiable & Equatable>(
        _ values: [Value], selected: Value, title: KeyPath<Value, String>,
        look: @escaping (Value) -> AvatarLook, select: @escaping (Value) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(values) { value in
                Button(action: { select(value) }) {
                    MoonAvatar(look: look(value), mood: .listening, size: 26)
                        .padding(5)
                        .background(.black, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: value == selected ? 2 : 0)
                        )
                }
                .buttonStyle(.plain)
                .help(value[keyPath: title])
                .accessibilityLabel(value[keyPath: title])
                .accessibilityAddTraits(value == selected ? .isSelected : [])
            }
        }
    }

    /// Выбор звука сразу его проигрывает.
    private func sound(of event: SoundEvent) -> Binding<String> {
        Binding(
            get: { settings.sounds[event] ?? "" },
            set: { name in
                settings.setSound(name.isEmpty ? nil : name, for: event)
                if !name.isEmpty { sounds.preview(name) }
            }
        )
    }

    /// Выбранный звук остаётся в списке, даже если его файла уже нет.
    private func soundNames(including current: String?) -> [String] {
        guard let current, !current.isEmpty, !SoundPlayer.available.contains(current) else { return SoundPlayer.available }
        return [current] + SoundPlayer.available
    }
}
