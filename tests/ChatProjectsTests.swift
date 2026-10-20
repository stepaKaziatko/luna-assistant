import Foundation

// Проекты (LUNA-75): список, путь, папка на диске, хранение, проект агента, импорт, группы агентов.
// argv: <папка фикстур tests/fixtures/projects> <рабочая папка теста>

@main
enum ChatProjectsTests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static var fixtures = ""
    static var work = ""
    static let fm = FileManager.default

    static func main() {
        fixtures = CommandLine.arguments[1]
        // realpath: во временной папке `/var` — симлинк на `/private/var`.
        work = ChatProjectPath.normalize(CommandLine.arguments[2]) ?? CommandLine.arguments[2]
        listTests()
        folderTests()
        storageTests()
        selectionTests()
        matchTests()
        importTests()
        groupTests()
        if failures > 0 { print("\n\(failures) test(s) failed."); exit(1) }
        print("\nAll tests passed.")
    }

    static func mkdir(_ path: String) {
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func project(_ path: String, _ name: String) -> ChatProject {
        ChatProject(id: UUID(), path: path, name: name, source: .manual, added: Date(timeIntervalSince1970: 0))
    }

    // MARK: 1. Добавление и путь

    static func listTests() {
        print("ChatProjectList: путь и повторы")
        let home = "\(work)/home"
        mkdir("\(home)/x")
        mkdir("\(work)/a/b")
        try? fm.createSymbolicLink(atPath: "\(work)/link", withDestinationPath: "\(work)/a/b")

        var list = ChatProjectList()
        let first = list.add(path: "~/x", source: .manual, home: home)
        guard case .added(let x) = first else { check("~/x добавлен", false); return }
        check("~/x → абсолютный путь в домашней папке", x.path == "\(home)/x")
        check("имя по умолчанию — имя папки", x.name == "x")
        check("повтор ~/x не добавляется", list.add(path: "\(home)/x/", source: .manual, home: home) == .duplicate(x))

        let ab = list.add(path: "\(work)/a/b/", source: .claude, home: home)
        guard case .added(let b) = ab else { check("/a/b/ добавлен", false); return }
        check("хвостовой / убран", b.path == "\(work)/a/b")
        check("симлинк на /a/b — тот же проект", list.add(path: "\(work)/link", source: .manual, home: home) == .duplicate(b))
        check("/a/./b/../b — тот же проект", list.add(path: "\(work)/a/./b/../b", source: .manual, home: home) == .duplicate(b))
        check("в списке два проекта", list.projects.count == 2)
        check("пустой и относительный путь — не путь",
              list.add(path: "  ", source: .manual) == .invalid && list.add(path: "code/x", source: .manual) == .invalid)
        check("имя можно задать", {
            var l = ChatProjectList()
            if case .added(let p) = l.add(path: "\(work)/a", name: "Альфа", source: .manual, home: home) { return p.name == "Альфа" }
            return false
        }())

        print("ChatProjectList: переименование и удаление")
        list.rename(id: b.id, to: "  Бета  ")
        check("переименован, пробелы по краям убраны", list.project(id: b.id)?.name == "Бета")
        list.rename(id: b.id, to: "   ")
        check("пустое имя не принимается", list.project(id: b.id)?.name == "Бета")
        list.remove(id: x.id)
        check("убранного проекта нет в списке", list.project(id: x.id) == nil && list.projects.count == 1)
        var isDir: ObjCBool = false
        check("папка на диске цела", fm.fileExists(atPath: "\(home)/x", isDirectory: &isDir) && isDir.boolValue)

        print("ChatProjectPath.contains")
        check("/a/b содержит /a/b и /a/b/c", ChatProjectPath.contains("/a/b", "/a/b") && ChatProjectPath.contains("/a/b", "/a/b/c"))
        check("/a/bc не внутри /a/b", !ChatProjectPath.contains("/a/b", "/a/bc"))
    }

    // MARK: 2. Папка на диске

    static func folderTests() {
        print("ChatProjectFolder")
        let dir = "\(work)/folder"
        mkdir(dir)
        check("пустая папка: без CLAUDE.md и AGENTS.md",
              ChatProjectFolder.inspect(dir) == .ready(claudeMD: false, agentsMD: false))
        fm.createFile(atPath: "\(dir)/CLAUDE.md", contents: Data("# x".utf8))
        check("CLAUDE.md найден", ChatProjectFolder.inspect(dir) == .ready(claudeMD: true, agentsMD: false))
        fm.createFile(atPath: "\(dir)/AGENTS.md", contents: Data("# x".utf8))
        check("CLAUDE.md и AGENTS.md", ChatProjectFolder.inspect(dir) == .ready(claudeMD: true, agentsMD: true))

        var list = ChatProjectList()
        list.add(path: dir, source: .manual)
        try? fm.removeItem(atPath: dir)
        check("папку удалили — «нет папки», проект в списке", ChatProjectFolder.inspect(dir) == .missing && list.projects.count == 1)
        fm.createFile(atPath: "\(work)/file", contents: Data())
        check("файл вместо папки — «нет папки»", ChatProjectFolder.inspect("\(work)/file") == .missing)

        let locked = "\(work)/locked"
        mkdir(locked)
        chmod(locked, 0o000)
        check("нет прав на чтение — «нет доступа»", ChatProjectFolder.inspect(locked) == .noAccess)
        chmod(locked, 0o755)
    }

    // MARK: 3. Хранение

    static func storageTests() {
        print("ChatProjectList: UserDefaults")
        let suite = "luna.tests.projects.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { check("UserDefaults", false); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        var list = ChatProjectList()
        list.add(path: "\(work)/a", source: .manual)
        list.add(path: "\(work)/a/b", name: "Бета", source: .codex)
        defaults.set(list.encoded(), forKey: ChatProjectList.defaultsKey)
        let back = ChatProjectList.decode(defaults.data(forKey: ChatProjectList.defaultsKey))
        check("круговой тест: записали и прочитали тот же список", back == list && back.projects.count == 2)
        check("ключ — chatProjects", ChatProjectList.defaultsKey == "chatProjects")
        defaults.set(Data("{битое".utf8), forKey: ChatProjectList.defaultsKey)
        check("битое значение → пустой список", ChatProjectList.decode(defaults.data(forKey: ChatProjectList.defaultsKey)).projects.isEmpty)
        check("нет значения → пустой список", ChatProjectList.decode(nil).projects.isEmpty)
        defaults.set(Data(#"[{"id":"nope"}]"#.utf8), forKey: ChatProjectList.defaultsKey)
        check("чужая структура → пустой список", ChatProjectList.decode(defaults.data(forKey: ChatProjectList.defaultsKey)).projects.isEmpty)
    }

    // MARK: Выбор в запросе (В7)

    static func selectionTests() {
        print("ChatProjectSelection")
        let dir = "\(work)/selected"
        mkdir(dir)
        var list = ChatProjectList()
        guard case .added(let p) = list.add(path: dir, source: .manual) else { check("добавлен", false); return }
        check("сохранённый проект на месте — выбран", ChatProjectSelection.resolve(savedID: p.id.uuidString, in: list) == p)
        check("нет сохранённого — «Без проекта»", ChatProjectSelection.resolve(savedID: nil, in: list) == nil)
        check("битый id — «Без проекта»", ChatProjectSelection.resolve(savedID: "x", in: list) == nil)
        try? fm.removeItem(atPath: dir)
        check("папка пропала — «Без проекта»", ChatProjectSelection.resolve(savedID: p.id.uuidString, in: list) == nil)
        mkdir(dir)
        list.remove(id: p.id)
        check("проект убран — «Без проекта»", ChatProjectSelection.resolve(savedID: p.id.uuidString, in: list) == nil)
    }

    // MARK: 4. Проект агента

    static func matchTests() {
        print("ChatProjectMatch")
        let outer = project("/w/app", "app")
        let inner = project("/w/app/packages/web", "web")
        let other = project("/w/b", "b")
        let all = [outer, inner, other]
        check("projectDir = папка проекта", ChatProjectMatch.project(projectDir: "/w/app", cwd: "", in: all) == outer)
        check("projectDir внутри проекта", ChatProjectMatch.project(projectDir: "/w/app/src", cwd: "", in: all) == outer)
        check("вложенные проекты — самый глубокий",
              ChatProjectMatch.project(projectDir: "/w/app/packages/web/src", cwd: "", in: all) == inner)
        check("пустой projectDir → cwd", ChatProjectMatch.project(projectDir: "", cwd: "/w/b/x", in: all) == other)
        check("projectDir важнее cwd", ChatProjectMatch.project(projectDir: "/w/b", cwd: "/w/app", in: all) == other)
        check("вне списка → nil", ChatProjectMatch.project(projectDir: "/elsewhere", cwd: "", in: all) == nil)
        check("/w/bc не матчится с /w/b", ChatProjectMatch.project(projectDir: "/w/bc", cwd: "", in: all) == nil)
        check("хвостовой / в папке агента", ChatProjectMatch.project(projectDir: "/w/b/", cwd: "", in: all) == other)
        check("пусто и там, и там → nil", ChatProjectMatch.project(projectDir: "", cwd: "", in: all) == nil)
    }

    // MARK: 5–7. Импорт

    static func fingerprint(_ path: String) -> (Data?, Date?) {
        (fm.contents(atPath: path), (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date)
    }

    static func importTests() {
        print("ChatProjectImport: ~/.claude.json")
        let home = "\(work)/import-home"
        mkdir("\(home)/code/alpha")
        mkdir("\(home)/code/beta")
        mkdir("\(home)/code/gamma")
        mkdir("\(home)/Library/Application Support/Luna/chat")
        mkdir("\(home)/.codex")
        func fixture(_ name: String) -> String {
            (try? String(contentsOfFile: "\(fixtures)/\(name)", encoding: .utf8))?.replacingOccurrences(of: "HOME", with: home) ?? ""
        }
        let claudeFile = "\(home)/.claude.json"
        let codexFile = "\(home)/.codex/config.toml"
        try? fixture("claude.json").write(toFile: claudeFile, atomically: true, encoding: .utf8)
        try? fixture("codex-config.toml").write(toFile: codexFile, atomically: true, encoding: .utf8)

        let claudeRaw = ChatProjectImport.claudePaths(fm.contents(atPath: claudeFile))
        check("из claude.json — только ключи projects", Set(claudeRaw) == Set([
            "\(home)/code/alpha", "\(home)/code/beta/", home, "/",
            "\(home)/Library/Application Support/Luna/chat", "\(home)/code/gone",
        ]))
        check("пустой файл → пусто", ChatProjectImport.claudePaths(fm.contents(atPath: "\(fixtures)/empty.json")).isEmpty)
        check("битый JSON → пусто", ChatProjectImport.claudePaths(fm.contents(atPath: "\(fixtures)/claude-broken.json")).isEmpty)
        check("нет файла → пусто", ChatProjectImport.claudePaths(fm.contents(atPath: "\(work)/нет.json")).isEmpty)
        check("JSON без projects → пусто", ChatProjectImport.claudePaths(Data(#"{"projects": 5}"#.utf8)).isEmpty)

        print("ChatProjectImport: ~/.codex/config.toml")
        let codexRaw = ChatProjectImport.codexPaths(try? String(contentsOfFile: codexFile, encoding: .utf8))
        check("[projects.\"…\"] и [projects.'…'], экранирование, другие таблицы мимо",
              codexRaw == ["\(home)/code/alpha", "\(home)/code/gamma", "\(home)/code/with \"quote\""])
        check("битый TOML → пусто",
              ChatProjectImport.codexPaths(try? String(contentsOfFile: "\(fixtures)/codex-broken.toml", encoding: .utf8)).isEmpty)
        check("нет файла → пусто", ChatProjectImport.codexPaths(nil).isEmpty)

        print("ChatProjectImport: отбор кандидатов")
        var existing = ChatProjectList()
        existing.add(path: "\(home)/code/beta", source: .manual)
        let before = [fingerprint(claudeFile), fingerprint(codexFile),
                      fingerprint("\(fixtures)/claude.json"), fingerprint("\(fixtures)/codex-config.toml")]
        let found = ChatProjectImport.discover(existing: existing, home: home)
        check("найдены alpha (Claude Code) и gamma (Codex); дом, /, Luna, пропавшие и уже добавленные — нет",
              found == [ChatProjectImport.Candidate(path: "\(home)/code/alpha", source: .claude),
                        ChatProjectImport.Candidate(path: "\(home)/code/gamma", source: .codex)])
        let after = [fingerprint(claudeFile), fingerprint(codexFile),
                     fingerprint("\(fixtures)/claude.json"), fingerprint("\(fixtures)/codex-config.toml")]
        check("исходные файлы не изменились (содержимое и mtime)",
              zip(before, after).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } && before.allSatisfy { $0.0 != nil })
        let none = ChatProjectImport.discover(existing: ChatProjectList(), home: "\(work)/пустой-дом")
        check("нет ни одного файла → ничего не найдено", none.isEmpty)
        try? "oops".write(toFile: claudeFile, atomically: true, encoding: .utf8)
        let onlyCodex = ChatProjectImport.discover(existing: ChatProjectList(), home: home)
        check("битый ~/.claude.json не мешает Codex", onlyCodex.map(\.path) == ["\(home)/code/alpha", "\(home)/code/gamma"]
              && onlyCodex.allSatisfy { $0.source == .codex })
    }

    // MARK: Агенты по проектам (АК 15)

    static func session(_ id: String, dir: String, phase: AgentPhase = .working, wait: Bool = false,
                        firstSeen: TimeInterval = 0) -> AgentSessionInfo {
        AgentSessionInfo(
            key: AgentSessionKey(pill: "integration_claude", session: id),
            who: AgentSessionWho(project: URL(fileURLWithPath: dir).lastPathComponent, agent: "Claude Code",
                                 cwd: dir, projectDir: dir),
            phase: phase,
            wait: wait ? .permission(tool: "Bash") : nil,
            steps: [], finalLine: nil,
            since: Date(timeIntervalSince1970: firstSeen), firstSeen: Date(timeIntervalSince1970: firstSeen),
            finishedUnseen: false, rateLimited: false)
    }

    static func groupTests() {
        print("AgentProjectGrouping")
        let luna = project("/w/luna", "luna")
        let api = project("/w/api", "api")
        let projects = [luna, api]
        // Порядок списка — как у книги сессий: ждущий вас первым.
        let sessions = [
            session("wait", dir: "/w/api/src", phase: .working, wait: true),
            session("free", dir: "/tmp/x", phase: .working),
            session("l1", dir: "/w/luna", phase: .working),
            session("l2", dir: "/w/luna/app", phase: .idle),
            session("a2", dir: "/w/api", phase: .idle),
        ]
        check("выключено — порядок как сегодня",
              AgentProjectGrouping.displayOrder(sessions, projects: projects, grouped: false) == sessions.map(\.id))
        let groups = AgentProjectGrouping.groups(sessions, projects: projects)
        check("группы: api (ждущий вас) первой, затем luna, «Другие» последней",
              groups.map { $0.project?.name ?? "other" } == ["api", "luna", "other"])
        check("внутри группы — порядок списка (AgentRank)", groups.first?.sessions.map(\.key.session) == ["wait", "a2"])
        check("«Другие» — сессии вне списка проектов", groups.last?.sessions.map(\.key.session) == ["free"] && groups.last?.project == nil)
        check("порядок клавиш = порядок на экране",
              AgentProjectGrouping.displayOrder(sessions, projects: projects, grouped: true)
                == ["wait", "a2", "l1", "l2", "free"].map { "integration_claude|\($0)" })

        let calm = [
            session("o", dir: "/elsewhere", phase: .working),
            session("z", dir: "/w/luna", phase: .working),
            session("y", dir: "/w/api", phase: .working),
        ]
        check("равная срочность — по имени, «Другие» последней",
              AgentProjectGrouping.groups(calm, projects: projects).map { $0.project?.name ?? "other" } == ["api", "luna", "other"])
        let urgentOther = [
            session("o", dir: "/elsewhere", phase: .working, wait: true),
            session("z", dir: "/w/luna", phase: .working),
        ]
        check("ждущий вас в «Других» — «Другие» наверху",
              AgentProjectGrouping.groups(urgentOther, projects: projects).first?.project == nil)
        check("ключ переключателя — agentsGroupByProject", AgentProjectGrouping.defaultsKey == "agentsGroupByProject")
        check("без проектов — одна группа «Другие»",
              AgentProjectGrouping.groups(sessions, projects: []).map(\.id) == ["other"])
    }
}
