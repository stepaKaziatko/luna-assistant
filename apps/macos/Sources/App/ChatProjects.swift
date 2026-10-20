import Foundation

// MARK: - Проекты: локальные папки, в которых задаётся вопрос и работают агенты
//
// Только Foundation: файл собирается тестами одним `swiftc` (scripts/test-chat-projects.sh).
// Список хранится в UserDefaults (`chatProjects`), секретов в нём нет. Флаги `CLAUDE.md` /
// `AGENTS.md` и «папки нет» не хранятся — вычисляются по диску, когда список показывают.

struct ChatProject: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case manual     // «Добавить папку…»
        case claude     // найден в `~/.claude.json`
        case codex      // найден в `~/.codex/config.toml`
    }

    var id: UUID
    /// Нормализованный абсолютный путь (`ChatProjectPath.normalize`).
    var path: String
    var name: String
    var source: Source
    var added: Date
}

// MARK: Путь

enum ChatProjectPath {
    /// `~`, `..`, симлинки и хвостовой `/` дают один и тот же путь. Пустой или относительный — nil.
    static func normalize(_ raw: String, home: String = NSHomeDirectory()) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "~" {
            text = home
        } else if text.hasPrefix("~/") {
            text = home + text.dropFirst(1)
        }
        guard text.hasPrefix("/") else { return nil }
        var path = URL(fileURLWithPath: text).standardizedFileURL.path
        // realpath — как его видит процесс агента (`/tmp` → `/private/tmp`); нет папки — как есть.
        if let real = realpath(path, nil) {
            path = String(cString: real)
            free(real)
        }
        return trimmed(path)
    }

    /// Без обращения к диску: `..`, `.` и хвостовой `/`. Для путей, которые прислали агенты.
    static func standardize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        return trimmed(URL(fileURLWithPath: text).standardizedFileURL.path)
    }

    /// `/a/b` содержит `/a/b` и `/a/b/c`, но не `/a/bc`.
    static func contains(_ root: String, _ path: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }

    private static func trimmed(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

// MARK: Папка на диске

enum ChatProjectFolder: Equatable, Sendable {
    case ready(claudeMD: Bool, agentsMD: Bool)
    case missing        // папку удалили или переименовали
    case noAccess       // macOS не дала прочитать (Документы, Рабочий стол, iCloud)

    var isUsable: Bool {
        if case .ready = self { return true }
        return false
    }

    static func inspect(_ path: String, fileManager fm: FileManager = .default) -> ChatProjectFolder {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        guard (try? fm.contentsOfDirectory(atPath: path)) != nil else { return .noAccess }
        return .ready(claudeMD: fm.fileExists(atPath: path + "/CLAUDE.md"),
                      agentsMD: fm.fileExists(atPath: path + "/AGENTS.md"))
    }
}

// MARK: Список

struct ChatProjectList: Equatable, Sendable {
    static let defaultsKey = "chatProjects"
    static let selectionKey = "chatProjectID"

    private(set) var projects: [ChatProject]

    init(_ projects: [ChatProject] = []) { self.projects = projects }

    enum AddResult: Equatable {
        case added(ChatProject)
        case duplicate(ChatProject)   // та же папка уже в списке
        case invalid                  // не путь
    }

    @discardableResult
    mutating func add(path raw: String, name: String? = nil, source: ChatProject.Source,
                      now: Date = Date(), home: String = NSHomeDirectory()) -> AddResult {
        guard let path = ChatProjectPath.normalize(raw, home: home) else { return .invalid }
        if let existing = projects.first(where: { $0.path == path }) { return .duplicate(existing) }
        let fallback = URL(fileURLWithPath: path).lastPathComponent
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = ChatProject(id: UUID(), path: path, name: title.isEmpty ? fallback : title,
                                  source: source, added: now)
        projects.append(project)
        return .added(project)
    }

    /// Убирает из списка; папка и её файлы не трогаются.
    mutating func remove(id: UUID) {
        projects.removeAll { $0.id == id }
    }

    /// Пустое имя не принимается: остаётся прежнее.
    mutating func rename(id: UUID, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = title
    }

    func project(id: UUID?) -> ChatProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func contains(path: String) -> Bool { projects.contains { $0.path == path } }

    // Хранение: JSON в UserDefaults. Битое значение — пустой список, а не падение.
    static func decode(_ data: Data?) -> ChatProjectList {
        guard let data, let projects = try? JSONDecoder().decode([ChatProject].self, from: data) else {
            return ChatProjectList()
        }
        return ChatProjectList(projects)
    }

    func encoded() -> Data? { try? JSONEncoder().encode(projects) }
}

// MARK: Выбор в запросе

enum ChatProjectSelection {
    /// Сохранённый выбор, если он ещё годится: проект в списке и папка на месте.
    /// Иначе — «Без проекта» (nil).
    static func resolve(savedID: String?, in list: ChatProjectList,
                        folderExists: (String) -> Bool = { ChatProjectFolder.inspect($0) != .missing }) -> ChatProject? {
        guard let savedID, let id = UUID(uuidString: savedID), let project = list.project(id: id),
              folderExists(project.path) else { return nil }
        return project
    }
}

// MARK: Проект агента

enum ChatProjectMatch {
    /// Проект, в котором работает агент: папка `projectDir` (без неё — `cwd`) совпадает с папкой
    /// проекта или лежит внутри неё. Из вложенных проектов берётся самый глубокий.
    static func project(projectDir: String, cwd: String, in projects: [ChatProject]) -> ChatProject? {
        let raw = projectDir.isEmpty ? cwd : projectDir
        guard let dir = ChatProjectPath.standardize(raw) else { return nil }
        return projects
            .filter { ChatProjectPath.contains($0.path, dir) }
            .max { $0.path.count < $1.path.count }
    }
}

// MARK: Импорт известных проектов

enum ChatProjectImport {
    struct Candidate: Equatable, Sendable {
        var path: String
        var source: ChatProject.Source
    }

    /// Ключи объекта `projects` в `~/.claude.json`. Остальное в файле не читается и не хранится.
    static func claudePaths(_ data: Data?) -> [String] {
        guard let data, !data.isEmpty,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = json["projects"] as? [String: Any] else { return [] }
        return projects.keys.sorted()
    }

    /// Заголовки `[projects."<путь>"]` и `[projects.'<путь>']` в `~/.codex/config.toml`.
    /// Разбор минимальный, только этих заголовков: TOML-библиотеки нет, остальное не читается.
    static func codexPaths(_ text: String?) -> [String] {
        guard let text else { return [] }
        var paths: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[projects."), line.hasSuffix("]"), !line.hasPrefix("[[") else { continue }
            let key = line.dropFirst("[projects.".count).dropLast()
            if let path = unquote(String(key)), !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// `"…"` (с экранированием `\"` и `\\`) или `'…'` (буквально). Иное — nil.
    private static func unquote(_ key: String) -> String? {
        guard key.count >= 2, let first = key.first, first == key.last else { return nil }
        let inner = key.dropFirst().dropLast()
        if first == "'" { return inner.contains("'") ? nil : String(inner) }
        guard first == "\"" else { return nil }
        var out = ""
        var escaped = false
        for ch in inner {
            if escaped {
                switch ch {
                case "\"", "\\": out.append(ch)
                default: return nil
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return nil
            } else {
                out.append(ch)
            }
        }
        return escaped ? nil : out
    }

    /// Без домашней папки целиком, `/`, служебных папок Luna, несуществующих и уже добавленных.
    /// Повторы между источниками — один кандидат (первым идёт Claude Code).
    static func candidates(claude: [String], codex: [String], existing: ChatProjectList,
                           home: String, lunaSupport: String,
                           exists: (String) -> Bool) -> [Candidate] {
        let homePath = ChatProjectPath.normalize(home, home: home) ?? home
        let lunaPath = ChatProjectPath.normalize(lunaSupport, home: home) ?? lunaSupport
        var seen = Set<String>()
        var result: [Candidate] = []
        let tagged = claude.map { ($0, ChatProject.Source.claude) } + codex.map { ($0, ChatProject.Source.codex) }
        for (raw, source) in tagged {
            guard let path = ChatProjectPath.normalize(raw, home: home),
                  path != "/", path != homePath,
                  !ChatProjectPath.contains(lunaPath, path),
                  !existing.contains(path: path),
                  !seen.contains(path), exists(path) else { continue }
            seen.insert(path)
            result.append(Candidate(path: path, source: source))
        }
        return result
    }

    /// Читает оба файла (только чтение). Нет файла, битый JSON или TOML — пусто, без ошибки;
    /// источники независимы.
    static func discover(existing: ChatProjectList,
                         home: String = NSHomeDirectory(),
                         lunaSupport: String? = nil,
                         fileManager fm: FileManager = .default) -> [Candidate] {
        let claudeData = fm.contents(atPath: home + "/.claude.json")
        let codexText = fm.contents(atPath: home + "/.codex/config.toml").flatMap { String(data: $0, encoding: .utf8) }
        return candidates(claude: claudePaths(claudeData), codex: codexPaths(codexText), existing: existing,
                          home: home,
                          lunaSupport: lunaSupport ?? home + "/Library/Application Support/Luna",
                          exists: { path in
                              var isDirectory: ObjCBool = false
                              return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                          })
    }
}
