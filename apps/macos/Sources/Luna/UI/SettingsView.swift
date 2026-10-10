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
    /// Что набрано в поле «добавить модель»: живёт здесь, чтобы debug-сборка могла показать подсветку ошибки.
    @Published var modelDraft = ""
    #if DEBUG
    /// Раздел вкладки «Основные», к которому прокрутить форму (`settingsScroll:`): снимок окна видит только экран.
    @Published var debugScrollTarget: String?
    #endif
}

/// Окно настроек: шторка, сочетания клавиш и модели, облик Luna, звуки.
struct SettingsView: View {
    @EnvironmentObject private var settings: LunaSettings
    @EnvironmentObject private var navigation: SettingsNavigation
    @EnvironmentObject private var permissions: ExecutorPermissions
    @EnvironmentObject private var agentHook: AgentHookSetup
    let sounds: SoundPlayer
    /// Завершает Luna: у приложения без Dock и главного меню выйти должно быть откуда-то ещё, кроме значка.
    let quit: () -> Void

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
        #if DEBUG
        ScrollViewReader { proxy in
            generalForm.onChange(of: navigation.debugScrollTarget) { _, target in
                if let target { proxy.scrollTo(target, anchor: .top) }
            }
        }
        #else
        generalForm
        #endif
    }

    private var generalForm: some View {
        Form {
            Section {
                Picker("Показывать шторку", selection: $settings.islandMode) {
                    ForEach(IslandMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Раскрывать при наведении", isOn: $settings.hoverPeek)
                if settings.islandMode == .background {
                    Text("В фоне шторка выезжает по событию, наведение на край её не вызывает; над показанной шторкой курсор раскрывает блок.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Аватары агентов в шторке", isOn: $settings.pillAvatars)
                Toggle("Подпись рядом со счётчиками", isOn: $settings.pillText)
            } header: {
                Text("Шторка")
            }
            modelsSection
            permissionsSection
            agentHookSection
            Section("Сочетания клавиш") {
                KeyboardShortcuts.Recorder("Спросить", name: .toggleInput)
                KeyboardShortcuts.Recorder("Последний результат", name: .openLastResult)
                KeyboardShortcuts.Recorder("Список задач", name: .toggleTasks)
                KeyboardShortcuts.Recorder("Агенты", name: .toggleAgents)
            }
            Section {
                Button("Выйти из Luna", action: quit)
            } footer: {
                Text("Идущие задачи прервутся.")
            }
        }
    }

    private let executor = ExecutorId.claudeCode.rawValue

    /// Список моделей Claude Code, которые предлагают панель ввода и поле продолжения, и модель по умолчанию.
    /// Список правится атомарными «добавить» и «убрать», поэтому набор «opu» вместо «opus» ничего не стирает.
    private var modelsSection: some View {
        let models = settings.models(for: executor)
        let verdict = ModelList.verdict(for: navigation.modelDraft, existing: models)
        return Section {
            ForEach(models, id: \.self) { model in
                HStack {
                    Text(ModelName.short(model))
                    if ModelName.short(model) != model {
                        Text(model).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        settings.setModels(models.filter { $0 != model }, for: executor)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Убрать из списка")
                    .accessibilityLabel("Убрать \(model)")
                }
            }
            HStack {
                TextField("Добавить модель", text: $navigation.modelDraft, prompt: Text("opus или claude-opus-4-8[1m]"))
                    .labelsHidden()
                    .onSubmit(addModel)
                    .foregroundStyle(verdict == .invalid ? Color.red : Color.primary)
                Button("Добавить", action: addModel)
                    .disabled(verdict != .valid)
            }
            switch verdict {
            case .invalid:
                Text("не принято: «\(navigation.modelDraft.trimmingCharacters(in: .whitespacesAndNewlines))» — латиница, цифры и . _ : [ ] / -, первый знак буква или цифра, до 100 знаков")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .duplicate:
                Text("Эта модель уже в списке.").font(.caption).foregroundStyle(.secondary)
            case .empty, .valid:
                EmptyView()
            }
            if settings.hasCustomModels(for: executor) {
                Button("Вернуть встроенный список") { settings.setModels([], for: executor) }
            }
            Picker("По умолчанию", selection: defaultModel) {
                Text(ModelName.defaultTitle).tag("")
                Divider()
                ForEach(models, id: \.self) { Text(ModelName.short($0)).tag($0) }
            }
        } header: {
            Text("Модели")
        } footer: {
            Text("«\(ModelName.defaultTitle)» — флаг --model не передаётся: работает LUNA_CLAUDE_MODEL, если она задана, иначе модель из настроек Claude Code. Выбор в панели ввода главнее умолчания.")
        }
    }

    /// Уровень разрешений Claude Code: выбор только из уровней, которые исполнитель объявил в `core.hello`.
    /// Что спрашивать на уровне, решает Claude Code; Luna своих правил поверх не вводит.
    private var permissionsSection: some View {
        let choices = PermissionLevel.choices(declared: permissions.levels(for: executor), saved: settings.permission(for: executor))
        return Section {
            Picker("Уровень", selection: permission) {
                ForEach(choices.levels, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .disabled(!choices.enabled)
            ForEach(choices.levels, id: \.self) { level in
                Text("\(level.title): \(level.explanation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !choices.enabled {
                Text("Ядро не запущено — уровень можно будет выбрать, когда оно ответит.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Разрешения")
        } footer: {
            Text("Задачи по веб-страницам всегда идут только на чтение. Новый уровень действует со следующей задачи.")
        }
        .id("permissions")
    }

    /// Подтверждение в сессиях агентов: Luna не пишет в настройки Claude Code сама — показывает фрагмент,
    /// копирует его и читает `settings.json`, чтобы сказать, найден ли хук.
    private var agentHookSection: some View {
        Section {
            Text("Сессия Claude Code в VS Code или терминале спросит разрешение у Luna: запрос появится в карточке и окне сессии. Диалог в терминале остаётся — отвечать можно и там, и в Luna, побеждает первый ответ. Luna закрыта — сессия спрашивает только в терминале.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let snippet = agentHook.snippet {
                Text("Добавьте в ~/.claude/settings.json:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Скопировать") { agentHook.copySnippet() }
                    Button("Проверить") { agentHook.check() }
                    Spacer()
                    switch agentHook.status {
                    case .found:
                        Label("хук найден", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notFound:
                        Label("хук не найден", systemImage: "circle.dashed").foregroundStyle(.secondary)
                    case .unknown:
                        EmptyView()
                    }
                }
                .font(.caption)
            } else {
                Text("Ядро не запущено — фрагмент появится, когда оно ответит.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Подтверждение в сессиях агентов")
        } footer: {
            Text("Хук слушает только запись файлов и команды (Write, Edit, NotebookEdit, Bash). Остальные вопросы агента остаются в терминале.")
        }
        .id("agentHook")
        .onAppear { agentHook.check() }
    }

    private var permission: Binding<PermissionLevel> {
        Binding(
            get: { settings.permission(for: executor) },
            set: { settings.setPermission($0, for: executor) }
        )
    }

    private func addModel() {
        let models = settings.models(for: executor)
        guard ModelList.verdict(for: navigation.modelDraft, existing: models) == .valid else { return }
        settings.setModels(models + [navigation.modelDraft], for: executor)
        navigation.modelDraft = ""
    }

    private var defaultModel: Binding<String> {
        Binding(
            get: { settings.defaultModel(for: executor) ?? "" },
            set: { settings.setDefaultModel($0.isEmpty ? nil : $0, for: executor) }
        )
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
