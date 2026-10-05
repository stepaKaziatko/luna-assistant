import Combine
import Foundation

/// Настройки пользователя: шторка, облик Luna и звуки. Хранятся в `UserDefaults`;
/// сочетания клавиш хранит библиотека KeyboardShortcuts там же.
@MainActor
final class LunaSettings: ObservableObject {
    private let defaults: UserDefaults

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        static let hoverPeek = "hoverPeek"
        static let pillAvatars = "pillAvatars"
        static let pillText = "pillText"
        static let tint = "avatarTint"
        static let accessory = "avatarAccessory"
        static let animateAvatars = "animateAvatars"
        static let soundsEnabled = "soundsEnabled"
        static let soundVolume = "soundVolume"
        static let sounds = "sounds"
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
