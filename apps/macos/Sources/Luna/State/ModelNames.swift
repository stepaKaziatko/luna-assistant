import Foundation

/// Показ имени модели: идентификатор исполнителя превращается в короткое имя для панели и карточки.
enum ModelName {
    /// Пункт «нет выбора»: исполнитель сам берёт модель по умолчанию.
    static let defaultTitle = "По умолчанию"

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
