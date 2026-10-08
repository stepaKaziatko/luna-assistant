import Combine
import Foundation

/// Настройки пользователя: шторка, облик Luna и звуки. Хранятся в `UserDefaults`;
/// сочетания клавиш хранит библиотека KeyboardShortcuts там же.
@MainActor
final class LunaSettings: ObservableObject {
    private let defaults: UserDefaults

    /// Как Luna ведёт себя в покое: шторка всегда на экране или только по событию.
    @Published var islandMode: IslandMode { didSet { defaults.set(islandMode.rawValue, forKey: Key.islandMode) } }
    /// Блок с агентами и диалогами выезжает, когда курсор задержался над шторкой.
    @Published var hoverPeek: Bool { didSet { defaults.set(hoverPeek, forKey: Key.hoverPeek) } }
    /// Аватары сессий агентов в свёрнутой шторке.
    @Published var pillAvatars: Bool { didSet { defaults.set(pillAvatars, forKey: Key.pillAvatars) } }
    /// Фраза о главном событии рядом со счётчиками шторки; выключена — в шторке только значки и числа.
    @Published var pillText: Bool { didSet { defaults.set(pillText, forKey: Key.pillText) } }
    @Published var tint: AvatarTint { didSet { defaults.set(tint.rawValue, forKey: Key.tint) } }
    @Published var accessory: AvatarAccessory { didSet { defaults.set(accessory.rawValue, forKey: Key.accessory) } }
    /// Выключено — аватары стоят неподвижно, как при «Уменьшении движения».
    @Published var animateAvatars: Bool { didSet { defaults.set(animateAvatars, forKey: Key.animateAvatars) } }
    @Published var soundsEnabled: Bool { didSet { defaults.set(soundsEnabled, forKey: Key.soundsEnabled) } }
    /// 0…1.
    @Published var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: Key.soundVolume) } }
    /// Звук каждого события по имени системного звука; пустая строка — без звука.
    @Published private(set) var sounds: [SoundEvent: String]

    /// Модели, из которых выбирают в панели ввода, по id исполнителя. Пусто или не задано —
    /// встроенный список (`builtInModels`). В списке только допустимые имена (`ModelList.isValid`), без повторов.
    @Published private(set) var modelLists: [String: [String]]
    /// Последний выбор модели в панели ввода по id исполнителя. Пустая строка — явно выбранная «Модель CLI»
    /// (флаг `--model` не передаётся даже при заданном умолчании). Модели, которой нет в списке, здесь не бывает:
    /// её стирают чтение и смена списка.
    @Published private(set) var modelChoices: [String: String]
    /// Модель по умолчанию по id исполнителя: предвыбор панели, пока в ней ничего не выбрано. Нет — «Модель CLI».
    /// Модели, которой нет в списке, здесь не бывает.
    @Published private(set) var modelDefaults: [String: String]
    /// Уровень разрешений по id исполнителя (`PermissionLevel`). Не задан — `manual`. Что уровень значит,
    /// решает исполнитель; Luna только передаёт его в `task.submit`.
    @Published private(set) var permissions: [String: PermissionLevel]

    /// Встроенные списки моделей. Свой список исполнителя пользователь задаёт в настройках.
    static let builtInModels: [String: [String]] = [ExecutorId.claudeCode.rawValue: ["opus", "sonnet", "haiku"]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        islandMode = defaults.string(forKey: Key.islandMode).flatMap(IslandMode.init) ?? .always
        hoverPeek = defaults.object(forKey: Key.hoverPeek) as? Bool ?? true
        pillAvatars = defaults.object(forKey: Key.pillAvatars) as? Bool ?? true
        pillText = defaults.object(forKey: Key.pillText) as? Bool ?? false
        tint = defaults.string(forKey: Key.tint).flatMap(AvatarTint.init) ?? .silver
        accessory = defaults.string(forKey: Key.accessory).flatMap(AvatarAccessory.init) ?? .none
        animateAvatars = defaults.object(forKey: Key.animateAvatars) as? Bool ?? true
        soundsEnabled = defaults.object(forKey: Key.soundsEnabled) as? Bool ?? true
        soundVolume = min(1, max(0, defaults.object(forKey: Key.soundVolume) as? Double ?? 0.5))
        let stored = defaults.dictionary(forKey: Key.sounds) as? [String: String] ?? [:]
        sounds = Dictionary(uniqueKeysWithValues: SoundEvent.allCases.map { ($0, stored[$0.rawValue] ?? $0.defaultSound) })
        // Повреждённое хранилище (не тот тип, имена не по шаблону) читается как «не задано»: встроенный список, «Модель CLI».
        let lists = (defaults.dictionary(forKey: Key.modelLists) as? [String: [String]] ?? [:]).compactMapValues(Self.cleaned)
        let choices = defaults.dictionary(forKey: Key.modelChoices) as? [String: String] ?? [:]
        let preferred = defaults.dictionary(forKey: Key.modelDefaults) as? [String: String] ?? [:]
        modelLists = lists
        func available(_ executor: String) -> [String] { lists[executor] ?? Self.builtInModels[executor] ?? [] }
        // Выбор и умолчание, которых нет в списке, читаются как «Модель CLI» и стираются из хранилища.
        let validChoices = choices.filter { $0.value.isEmpty || available($0.key).contains($0.value) }
        let validDefaults = preferred.filter { available($0.key).contains($0.value) }
        modelChoices = validChoices
        modelDefaults = validDefaults
        if validChoices.count != choices.count { defaults.set(validChoices, forKey: Key.modelChoices) }
        if validDefaults.count != preferred.count { defaults.set(validDefaults, forKey: Key.modelDefaults) }
        // Незнакомое или повреждённое значение — как «не задано», то есть `manual`.
        let storedPermissions = defaults.dictionary(forKey: Key.permissions) as? [String: Any] ?? [:]
        permissions = storedPermissions.compactMapValues { ($0 as? String).flatMap(PermissionLevel.init) }
    }

    /// Уровень разрешений исполнителя; не задан — `manual`.
    func permission(for executor: String) -> PermissionLevel {
        permissions[executor] ?? .manual
    }

    /// Запоминает уровень исполнителя. Меняет его только человек в настройках; идущие задачи остаются на своём.
    func setPermission(_ level: PermissionLevel, for executor: String) {
        guard permissions[executor] != level else { return }
        var all = permissions
        all[executor] = level
        permissions = all
        defaults.set(all.mapValues(\.rawValue), forKey: Key.permissions)
    }

    /// Список моделей исполнителя: свой или встроенный.
    func models(for executor: String) -> [String] {
        modelLists[executor] ?? Self.builtInModels[executor] ?? []
    }

    /// Задан ли свой список (а не встроенный).
    func hasCustomModels(for executor: String) -> Bool {
        modelLists[executor] != nil
    }

    /// Модель по умолчанию из настроек; nil — «Модель CLI».
    func defaultModel(for executor: String) -> String? {
        modelDefaults[executor]
    }

    /// Предвыбор панели ввода — единственное место, где он решается: последний выбор, если он ещё в списке;
    /// иначе умолчание из настроек; иначе nil — «Модель CLI». Явно выбранная «Модель CLI» — тоже выбор.
    func model(for executor: String) -> String? {
        if let choice = modelChoices[executor] { return choice.isEmpty ? nil : choice }
        return modelDefaults[executor]
    }

    /// Запоминает выбор в панели; nil — «Модель CLI». Пока задано умолчание, это явный выбор и он запоминается;
    /// без умолчания «нет выбора» и «Модель CLI» — одно и то же. Модель вне списка не принимается и сбрасывает выбор.
    func setModel(_ model: String?, for executor: String) {
        var choices = modelChoices
        if let model, models(for: executor).contains(model) {
            choices[executor] = model
        } else if model == nil, modelDefaults[executor] != nil {
            choices[executor] = ""
        } else {
            choices[executor] = nil
        }
        guard choices != modelChoices else { return }
        modelChoices = choices
        defaults.set(choices, forKey: Key.modelChoices)
    }

    /// Задаёт модель по умолчанию; nil — «Модель CLI». Модель вне списка не принимается и сбрасывает умолчание.
    /// Реальная смена стирает последний выбор панели (и явную «Модель CLI»): иначе новое умолчание не увидит никто,
    /// кто уже пользовался панелью. То же значение ничего не стирает.
    func setDefaultModel(_ model: String?, for executor: String) {
        let new = model.flatMap { models(for: executor).contains($0) ? $0 : nil }
        guard new != modelDefaults[executor] else { return }
        var preferred = modelDefaults
        preferred[executor] = new
        modelDefaults = preferred
        defaults.set(preferred, forKey: Key.modelDefaults)
        if modelChoices[executor] != nil {
            var choices = modelChoices
            choices[executor] = nil
            modelChoices = choices
            defaults.set(choices, forKey: Key.modelChoices)
        }
    }

    /// Меняет список моделей исполнителя: имена проверяются и очищаются от повторов (`ModelList.clean`), пустой
    /// результат возвращает встроенный список. Выбор и умолчание, которых в новом списке нет, стираются каждый сам;
    /// остальное живёт, явная «Модель CLI» смену списка переживает.
    func setModels(_ models: [String], for executor: String) {
        var lists = modelLists
        lists[executor] = Self.cleaned(models)
        modelLists = lists
        defaults.set(lists, forKey: Key.modelLists)
        let now = self.models(for: executor)
        if let choice = modelChoices[executor], !choice.isEmpty, !now.contains(choice) {
            var choices = modelChoices
            choices[executor] = nil
            modelChoices = choices
            defaults.set(choices, forKey: Key.modelChoices)
        }
        if let preferred = modelDefaults[executor], !now.contains(preferred) {
            var preferredAll = modelDefaults
            preferredAll[executor] = nil
            modelDefaults = preferredAll
            defaults.set(preferredAll, forKey: Key.modelDefaults)
        }
    }

    /// Допустимые имена без повторов; ничего не осталось — nil (список не задан).
    private static func cleaned(_ models: [String]) -> [String]? {
        let kept = ModelList.clean(models).accepted
        return kept.isEmpty ? nil : kept
    }

    /// Имя звука события; nil — событие без звука.
    func sound(for event: SoundEvent) -> String? {
        let name = sounds[event] ?? event.defaultSound
        return name.isEmpty ? nil : name
    }

    func setSound(_ name: String?, for event: SoundEvent) {
        sounds[event] = name ?? ""
        defaults.set(Dictionary(uniqueKeysWithValues: sounds.map { ($0.key.rawValue, $0.value) }), forKey: Key.sounds)
    }

    /// Облик самой Luna; сессии агентов красятся по проекту и аксессуаров не носят.
    var lunaLook: AvatarLook {
        AvatarLook(hue: tint.hue, saturation: tint.saturation, seed: AvatarLook.luna.seed, accessory: accessory)
    }

    private enum Key {
        static let islandMode = "islandMode"
        static let hoverPeek = "hoverPeek"
        static let pillAvatars = "pillAvatars"
        static let pillText = "pillText"
        static let tint = "avatarTint"
        static let accessory = "avatarAccessory"
        static let animateAvatars = "animateAvatars"
        static let soundsEnabled = "soundsEnabled"
        static let soundVolume = "soundVolume"
        static let sounds = "sounds"
        static let modelLists = "executorModelLists"
        static let modelChoices = "executorModelChoices"
        static let modelDefaults = "executorDefaultModels"
        static let permissions = "executorPermissions"
    }
}

/// Оттенок Luna.
enum AvatarTint: String, CaseIterable, Identifiable {
    case silver, gold, rose, mint, sky, violet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silver: "Серебро"
        case .gold: "Золото"
        case .rose: "Роза"
        case .mint: "Мята"
        case .sky: "Небо"
        case .violet: "Сирень"
        }
    }

    var hue: Double {
        switch self {
        case .silver: 0.62
        case .gold: 0.12
        case .rose: 0.95
        case .mint: 0.42
        case .sky: 0.57
        case .violet: 0.74
        }
    }

    var saturation: Double {
        switch self {
        case .silver: 0.1
        case .gold, .sky: 0.5
        case .rose, .mint, .violet: 0.45
        }
    }
}

/// Что Luna носит.
enum AvatarAccessory: String, CaseIterable, Identifiable {
    case none, ring, cap, glasses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Без всего"
        case .ring: "Кольцо"
        case .cap: "Колпак"
        case .glasses: "Очки"
        }
    }
}
