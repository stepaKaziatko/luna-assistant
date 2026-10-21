import Foundation

// MARK: - История чатов Luna (LUNA-76)
//
// Только Foundation: файл собирается тестами одним `swiftc` (scripts/test-chat-history.sh).
//
// Где лежит (решение человека В1): `~/Library/Application Support/Luna/ChatHistory/` —
// `index.json` (список для окна истории) и `<id>.json` на каждый чат. Хранится 100 последних
// чатов, старые удаляются сами при записи. Без шифрования, права файлов 0600, папки 0700.
// Пишется только текст сообщений и подписи: содержимое прикреплённого файла не пишется,
// контекст окна или файла — только подписью. Запись — по законченному ответу и по удалению,
// таймеров нет. Транскрипты Claude Code (`~/.claude/projects`) Luna не трогает.

// MARK: Сообщение чата

enum ChatRole: String, Codable, Sendable { case user, assistant }

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    /// Сохраняется вместе с чатом: открытый из истории чат — те же сообщения, те же id.
    var id = UUID()
    let role: ChatRole
    var content: String   // var for streaming updates
    /// Чем отвечено: «Claude Code · подписка · sonnet». nil — без подписи (сообщения пользователя, старый путь).
    var source: String? = nil
    /// Пометка Luna в чате («прежняя сессия Claude Code недоступна…»): не реплика модели,
    /// в разговор с моделью не уходит.
    var isNotice = false
}

// MARK: Запись чата

struct ChatHistoryProject: Codable, Equatable, Sendable {
    var id: UUID?
    var name: String
    var path: String
}

/// Сессия Claude Code чата: продолжается тем же `--resume` в той же папке.
struct ChatHistoryCLISession: Codable, Equatable, Sendable {
    var id: String
    /// nil — служебная папка чата («Без проекта»).
    var projectPath: String?
    var started: Bool
}

/// Строка окна истории (`index.json`): без сообщений.
struct ChatHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    /// `ChatProvider.rawValue` последнего ответа.
    var provider: String
    /// Подпись последнего ответа, как под ним в чате.
    var source: String?
    var projectName: String?
}

/// Чат целиком (`<id>.json`).
struct ChatHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    var provider: String
    var source: String?
    var project: ChatHistoryProject?
    var cliSession: ChatHistoryCLISession?
    /// Подпись контекста первого вопроса: «Safari — Заголовок окна», «report.pdf». Не содержимое.
    var contextLabel: String?
    var messages: [ChatMessage]

    var entry: ChatHistoryEntry {
        ChatHistoryEntry(id: id, title: title, created: created, updated: updated,
                         provider: provider, source: source, projectName: project?.name)
    }

    /// Запись открытого чата после законченного ответа. nil — в чате ещё нет ни одного ответа
    /// модели (все ходы упали): такой чат в историю не попадает. Пустые сообщения (заглушки
    /// стрима) не пишутся.
    static func make(id: UUID, messages: [ChatMessage], created: Date?, now: Date,
                     provider: String, project: ChatHistoryProject?,
                     cliSession: ChatHistoryCLISession?, contextLabel: String?) -> ChatHistoryRecord? {
        let kept = messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard kept.contains(where: { $0.role == .assistant && !$0.isNotice }) else { return nil }
        let firstQuestion = kept.first(where: { $0.role == .user && !$0.isNotice })?.content ?? ""
        let source = kept.last(where: { $0.role == .assistant && !$0.isNotice })?.source
        return ChatHistoryRecord(id: id, title: ChatHistory.title(from: firstQuestion),
                                 created: created ?? now, updated: now, provider: provider, source: source,
                                 project: project, cliSession: cliSession, contextLabel: contextLabel,
                                 messages: kept)
    }
}

// MARK: Правила

enum ChatHistory {
    /// Решение человека В1: 100 последних чатов.
    static let limit = 100
    static let titleLimit = 60
    static let defaultsKey = "chatHistoryEnabled"

    /// Заголовок — первая непустая строка первого вопроса, до `limit` символов с «…».
    static func title(from question: String, limit: Int = titleLimit, fallback: String = "Chat") -> String {
        let line = question.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !line.isEmpty else { return fallback }
        guard line.count > limit else { return line }
        return String(line.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Новые сверху — по последнему сообщению.
    static func sorted(_ entries: [ChatHistoryEntry]) -> [ChatHistoryEntry] {
        entries.sorted { $0.updated == $1.updated ? $0.created > $1.created : $0.updated > $1.updated }
    }

    /// Сверх лимита — удаляются самые старые по последнему сообщению; открытый чат не удаляется.
    static func prune(_ entries: [ChatHistoryEntry], limit: Int = limit,
                      keeping openID: UUID?) -> (kept: [ChatHistoryEntry], removed: [UUID]) {
        var list = sorted(entries)
        var removed: [UUID] = []
        while list.count > limit, let index = list.lastIndex(where: { $0.id != openID }) {
            removed.append(list.remove(at: index).id)
        }
        return (list, removed)
    }

    /// Пишется ли история: не в демо и не при выключенном хранении.
    static func shouldRecord(enabled: Bool, demo: Bool) -> Bool { enabled && !demo }

    /// Разговор для ключа API из сообщений чата: текстом, в том же порядке. Пометки Luna и
    /// пустые сообщения не входят.
    static func apiTurns(from messages: [ChatMessage]) -> [(role: String, text: String)] {
        messages.compactMap { message in
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isNotice, !text.isEmpty else { return nil }
            return (message.role.rawValue, text)
        }
    }
}

// MARK: Открытый чат

/// Какой чат открыт на странице запроса. У хода — билет: ответ, пришедший после «+» или
/// открытия другого чата, в открытый чат не попадает.
struct ChatOpenState: Equatable, Sendable {
    struct Ticket: Equatable, Sendable {
        let chatID: UUID
        let generation: Int
    }

    private(set) var chatID = UUID()
    private(set) var generation = 0

    func ticket() -> Ticket { Ticket(chatID: chatID, generation: generation) }

    func accepts(_ ticket: Ticket) -> Bool { ticket == self.ticket() }

    /// «+», ⌘K, смена проекта.
    mutating func newChat() {
        chatID = UUID()
        generation &+= 1
    }

    /// Чат из истории.
    mutating func open(_ id: UUID) {
        chatID = id
        generation &+= 1
    }

    /// Чат удалён из истории; true — он был открыт, и страница стала новым чатом.
    @discardableResult
    mutating func deleted(_ id: UUID) -> Bool {
        guard id == chatID else { return false }
        newChat()
        return true
    }
}

// MARK: Продолжение чата из истории

/// Пометка над полем ввода у открытого из истории чата.
enum ChatHistoryNotice: Equatable, Sendable {
    /// Чат шёл через подписку, а выбран ключ (или наоборот). Источник Luna сама не меняет:
    /// кнопка `switchTo` меняет его только кликом. `newCLISession` — Claude Code без своей
    /// сессии у этого чата: следующий вопрос начнёт новую сессию без прежнего контекста.
    case sourceDiffers(chatSource: String, switchTo: String, newCLISession: Bool)
    /// Проекта чата больше нет: следующий вопрос Claude Code — новая сессия без прежнего контекста.
    case projectUnavailable(name: String)
}

struct ChatContinuationPlan: Equatable, Sendable {
    /// Сессия Claude Code, которую продолжит следующий ход (`--resume`); nil — новая.
    var cliSession: ChatHistoryCLISession?

    enum Project: Equatable, Sendable {
        case keep               // чат по ключу: проект ему не нужен, выбор не трогается
        case none               // «Без проекта»
        case project(UUID)      // проект чата
    }

    var project: Project
    var notices: [ChatHistoryNotice]
}

enum ChatContinuation {
    static let claudeCodeProvider = "claude_code"

    /// Что сделать, открывая чат из истории. Источник (`currentProvider`) не меняется никогда —
    /// только пометка с кнопкой. `projectID` — id проекта чата в текущем списке, если он есть и
    /// его папка годится; nil — проекта нет.
    static func plan(for record: ChatHistoryRecord, currentProvider: String,
                     chatSourceName: String, projectID: UUID?) -> ChatContinuationPlan {
        let chatIsCLI = record.provider == claudeCodeProvider
        let nowCLI = currentProvider == claudeCodeProvider
        var notices: [ChatHistoryNotice] = []
        var session = record.cliSession.flatMap { $0.started ? $0 : nil }
        var project = ChatContinuationPlan.Project.keep

        if chatIsCLI || session != nil {
            if let chatProject = record.project {
                if let projectID {
                    project = .project(projectID)
                } else {
                    // Папки нет: сессия той папки не продолжится, вопрос уйдёт «Без проекта».
                    project = .none
                    session = nil
                    notices.append(.projectUnavailable(name: chatProject.name))
                }
            } else {
                project = .none
            }
        }

        if chatIsCLI != nowCLI {
            notices.insert(.sourceDiffers(chatSource: chatSourceName, switchTo: record.provider,
                                          newCLISession: nowCLI && session == nil), at: 0)
        }
        return ChatContinuationPlan(cliSession: session, project: project, notices: notices)
    }
}

// MARK: Хранилище

/// Папка истории на диске. Путь подменяемый: тесты пишут во временную папку и настоящую
/// `~/Library/Application Support/Luna` не трогают. Вызывается с главного потока.
final class ChatHistoryStore {
    let directory: URL
    private let fm = FileManager.default
    private(set) var entries: [ChatHistoryEntry] = []
    private var loaded = false

    init(directory: URL) { self.directory = directory }

    static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Luna/ChatHistory", isDirectory: true)
    }

    var indexURL: URL { directory.appendingPathComponent("index.json") }

    func fileURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString.lowercased()).json") }

    /// Список при первом обращении. Испорченный `index.json` откладывается рядом с меткой
    /// времени (не перезаписывается молча), история начинается пустой.
    @discardableResult
    func load() -> [ChatHistoryEntry] {
        guard !loaded else { return entries }
        loaded = true
        guard let data = fm.contents(atPath: indexURL.path) else { entries = []; return entries }
        if let list = try? Self.decoder.decode([ChatHistoryEntry].self, from: data) {
            entries = ChatHistory.sorted(list)
        } else {
            setAside(indexURL)
            entries = []
        }
        return entries
    }

    /// Чат целиком; nil — файла нет или он испорчен (тогда он откладывается и убирается из списка).
    func record(_ id: UUID) -> ChatHistoryRecord? {
        load()
        let url = fileURL(for: id)
        guard let data = fm.contents(atPath: url.path) else {
            drop(id)
            return nil
        }
        guard let record = try? Self.decoder.decode(ChatHistoryRecord.self, from: data), record.id == id else {
            setAside(url)
            drop(id)
            return nil
        }
        return record
    }

    /// Записывает чат и список. Повторная запись того же чата обновляет его строку. Сверх лимита
    /// старые чаты удаляются; открытый (`openID`) — никогда.
    func save(_ record: ChatHistoryRecord, openID: UUID?) {
        load()
        guard ensureDirectory() else { return }
        guard let data = try? Self.encoder.encode(record), write(data, to: fileURL(for: record.id)) else { return }
        var list = entries.filter { $0.id != record.id }
        list.append(record.entry)
        let (kept, removed) = ChatHistory.prune(list, keeping: openID ?? record.id)
        for id in removed { try? fm.removeItem(at: fileURL(for: id)) }
        entries = kept
        writeIndex()
    }

    func delete(_ id: UUID) {
        load()
        try? fm.removeItem(at: fileURL(for: id))
        drop(id)
    }

    /// «Очистить историю»: все чаты и список.
    func clear() {
        load()
        for entry in entries { try? fm.removeItem(at: fileURL(for: entry.id)) }
        entries = []
        writeIndex()
    }

    // MARK: Диск

    private func drop(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        writeIndex()
    }

    private func writeIndex() {
        guard ensureDirectory(), let data = try? Self.encoder.encode(entries) else { return }
        _ = write(data, to: indexURL)
    }

    private func ensureDirectory() -> Bool {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDir) { return isDir.boolValue }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }

    /// Атомарно: временный файл с правами 0600 рядом, затем `rename` поверх.
    private func write(_ data: Data, to url: URL) -> Bool {
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            return false
        }
        return true
    }

    private func setAside(_ url: URL) {
        let stamp = Self.stamp(Date())
        let base = url.deletingPathExtension().lastPathComponent
        var target = directory.appendingPathComponent("\(base).corrupt-\(stamp).json")
        var n = 1
        while fm.fileExists(atPath: target.path) {
            n += 1
            target = directory.appendingPathComponent("\(base).corrupt-\(stamp)-\(n).json")
        }
        try? fm.moveItem(at: url, to: target)
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    // Даты — числом (как у JSONEncoder по умолчанию): после чтения те же до долей секунды.
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}
