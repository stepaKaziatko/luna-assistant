import Foundation

/// Показ имени модели: идентификатор исполнителя превращается в короткое имя для панели и карточки.
enum ModelName {
    /// Пункт «нет выбора»: флаг `--model` не передаётся, модель берёт сам CLI (`LUNA_CLAUDE_MODEL` или настройки Claude Code).
    static let defaultTitle = "Модель CLI"

    private static let aliases: Set<String> = ["opus", "sonnet", "haiku"]

    /// `claude-<семейство>-<мажор>[-<минор>][-<дата из 8 цифр>][[1m]]` → «Семейство мажор.минор [1M]»;
    /// алиас `opus`/`sonnet`/`haiku` → «Opus»/«Sonnet»/«Haiku»; всё остальное — как есть.
    ///
    ///     claude-sonnet-4-6          → Sonnet 4.6
    ///     claude-haiku-4-5-20251001  → Haiku 4.5
    ///     claude-opus-4-8[1m]        → Opus 4.8 1M
    static func short(_ id: String) -> String {
        let (base, wideContext) = id.hasSuffix(Self.wideContextSuffix)
            ? (String(id.dropLast(Self.wideContextSuffix.count)), true)
            : (id, false)
        let suffix = wideContext ? " 1M" : ""
        if aliases.contains(base) { return base.capitalized + suffix }

        let parts = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "claude", isFamily(parts[1]), let major = digits(parts[2], max: 3) else { return id }
        var rest = parts.dropFirst(3)
        var version = major
        if let minor = rest.first, let number = digits(minor, max: 2) {
            version += ".\(number)"
            rest = rest.dropFirst()
        }
        if let date = rest.first, date.count == 8, date.allSatisfy(\.isASCIIDigit) { rest = rest.dropFirst() }
        guard rest.isEmpty else { return id }
        return "\(parts[1].capitalized) \(version)\(suffix)"
    }

    private static let wideContextSuffix = "[1m]"

    private static func isFamily(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter }
    }

    /// Число из не более `max` цифр: дата из 8 цифр за версию не сходит.
    private static func digits(_ text: String, max: Int) -> String? {
        guard !text.isEmpty, text.count <= max, text.allSatisfy(\.isASCIIDigit) else { return nil }
        return text
    }
}

/// Список моделей, который пользователь правит в настройках. Имя проверяется тем же шаблоном, что в ядре
/// (`MODEL_PATTERN` в `core/src/tasks/model.ts`): ядро всё равно отклонит несоответствующее, а здесь
/// такая строка не попадает в список и подсвечивается.
enum ModelList {
    /// `^[A-Za-z0-9][A-Za-z0-9._:\[\]/-]{0,99}$` без регулярного выражения: `$` в `NSRegularExpression`
    /// пропускает завершающий перевод строки, а в argv он не должен попасть.
    static func isValid(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (1...100).contains(scalars.count), let first = scalars.first, first.isASCIIAlphanumeric else { return false }
        return scalars.dropFirst().allSatisfy { $0.isASCIIAlphanumeric || "._:[]/-".unicodeScalars.contains($0) }
    }

    struct Parsed: Equatable {
        /// Принятые имена: без повторов, в порядке ввода.
        var accepted: [String] = []
        /// Строки, которые не прошли проверку, — для подсветки.
        var rejected: [String] = []
    }

    /// Текст «по одной модели в строке».
    static func parse(_ text: String) -> Parsed {
        clean(text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init))
    }

    /// Строки списка: края обрезаются, пустые пропускаются, не подошедшие — в `rejected`, повторы убираются
    /// (остаётся первое вхождение).
    static func clean(_ lines: [String]) -> Parsed {
        var result = Parsed()
        var seen = Set<String>()
        for line in lines {
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if !isValid(name) {
                result.rejected.append(name)
            } else if seen.insert(name).inserted {
                result.accepted.append(name)
            }
        }
        return result
    }

    /// Что сказать о строке, которую пользователь набирает в поле «добавить модель».
    enum Verdict: Equatable {
        case empty, valid, duplicate, invalid
    }

    static func verdict(for draft: String, existing: [String]) -> Verdict {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .empty }
        if !isValid(name) { return .invalid }
        return existing.contains(name) ? .duplicate : .valid
    }
}

private extension Unicode.Scalar {
    var isASCIIAlphanumeric: Bool {
        (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

extension TaskInfo {
    /// Подпись под ответом: «Claude Code · Sonnet 4.6 · 12 с»; чего нет — того нет в подписи.
    var resultCaption: String {
        var parts = ["Claude Code"]
        if let model, !model.isEmpty { parts.append(ModelName.short(model)) }
        if let seconds = durationSeconds { parts.append("\(seconds) с") }
        return parts.joined(separator: " · ")
    }
}
