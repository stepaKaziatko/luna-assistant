import AppKit

/// События, о которых Luna сообщает звуком.
enum SoundEvent: String, CaseIterable, Identifiable {
    /// Сессия агента ждёт ответа или разрешения.
    case attention
    /// Сессия агента закончила ход, пока на неё не смотрели.
    case finished
    /// Готов ответ на задачу Luna.
    case done
    case failure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attention: "Агент ждёт вас"
        case .finished: "Агент закончил ход"
        case .done: "Ответ Luna готов"
        case .failure: "Ошибка задачи"
        }
    }

    /// Имя системного звука macOS.
    var defaultSound: String {
        switch self {
        case .attention: "Ping"
        case .finished: "Pop"
        case .done: "Glass"
        case .failure: "Basso"
        }
    }
}

/// Проигрывает системные звуки macOS — те же, что в «Настройках» системы: своих звуковых файлов
/// у Luna нет. Включены ли звуки, какой у события и с какой громкостью — решают настройки.
@MainActor
final class SoundPlayer {
    private let settings: LunaSettings
    /// Звук живёт, пока играет: по одному на событие, новый сменяет прежний.
    private var playing: [String: NSSound] = [:]

    init(settings: LunaSettings) {
        self.settings = settings
    }

    func play(_ event: SoundEvent) {
        guard settings.soundsEnabled, let name = settings.sound(for: event) else { return }
        start(name, slot: event.rawValue)
    }

    /// Проба звука из настроек: играет и при выключенных звуках.
    func preview(_ name: String) {
        start(name, slot: "preview")
    }

    private func start(_ name: String, slot: String) {
        // Копия: у общего экземпляра `NSSound(named:)` громкость менять нельзя — он один на всех.
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = Float(settings.soundVolume)
        playing[slot]?.stop()
        playing[slot] = sound
        sound.play()
    }

    /// Имена звуков, которые найдёт `NSSound(named:)`: системные и добавленные пользователем.
    static let available: [String] = {
        let folders = [
            URL(fileURLWithPath: "/System/Library/Sounds"),
            URL(fileURLWithPath: "/Library/Sounds"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds"),
        ]
        let names = folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { ["aiff", "aif", "wav", "caf", "m4a", "mp3"].contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
        return Set(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()
}
