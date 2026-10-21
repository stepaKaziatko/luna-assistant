import Foundation

// История чатов (LUNA-76): заголовок, запись, порядок, лимит, удаление, файлы на диске,
// продолжение чата, ход после переключения чата. argv: <временная папка теста>

@main
enum ChatHistoryTests {
    static var failures = 0
    static var work = ""

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        work = CommandLine.arguments[1]
        titleTests()
        recordTests()
        orderAndLimitTests()
        storeTests()
        corruptTests()
        permissionTests()
        continuationTests()
        apiTurnTests()
        openStateTests()
        policyTests()
        if failures > 0 { print("\n\(failures) test(s) failed."); exit(1) }
        print("\nAll tests passed.")
    }

    // MARK: Помощники

    static let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }
    static func answer(_ text: String, source: String? = "Claude Code · подписка · sonnet") -> ChatMessage {
        ChatMessage(role: .assistant, content: text, source: source)
    }

    static func entry(_ n: Int, updated: TimeInterval) -> ChatHistoryEntry {
        ChatHistoryEntry(id: uuid(n), title: "chat \(n)", created: t0, updated: t0.addingTimeInterval(updated),
                         provider: "anthropic", source: nil, projectName: nil)
    }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func record(_ n: Int, updated: TimeInterval = 0, provider: String = "claude_code",
                       project: ChatHistoryProject? = nil, session: ChatHistoryCLISession? = nil) -> ChatHistoryRecord {
        ChatHistoryRecord.make(id: uuid(n), messages: [user("Вопрос \(n)"), answer("Ответ \(n)")],
                               created: t0, now: t0.addingTimeInterval(updated), provider: provider,
                               project: project, cliSession: session, contextLabel: nil)!
    }

    static func store(_ name: String) -> ChatHistoryStore {
        ChatHistoryStore(directory: URL(fileURLWithPath: "\(work)/\(name)/ChatHistory", isDirectory: true))
    }

    static func files(_ s: ChatHistoryStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: s.directory.path)) ?? []).sorted()
    }

    // MARK: 1. Заголовок

    static func titleTests() {
        print("ChatHistory.title")
        check("первая строка вопроса, пробелы по краям убраны", ChatHistory.title(from: "  Как дела?  \nвторая") == "Как дела?")
        check("пустые строки в начале пропускаются", ChatHistory.title(from: "\n\n  \n Привет\nещё") == "Привет")
        let long = String(repeating: "я", count: 100)
        let title = ChatHistory.title(from: long)
        check("длинный — 60 символов и «…»", title.count == 61 && title.hasSuffix("…") && title.hasPrefix("яяя"))
        check("ровно 60 — без «…»", ChatHistory.title(from: String(repeating: "a", count: 60)) == String(repeating: "a", count: 60))
        check("обрезка не оставляет пробел перед «…»",
              ChatHistory.title(from: String(repeating: "a", count: 59) + " bcd") == String(repeating: "a", count: 59) + "…")
        check("пустой вопрос — запасной заголовок", ChatHistory.title(from: "  \n ", fallback: "Чат") == "Чат")
    }

    // MARK: 2. Запись чата

    static func recordTests() {
        print("ChatHistoryRecord.make")
        let noAnswer = ChatHistoryRecord.make(id: uuid(1), messages: [user("Вопрос"), answer("")],
                                              created: nil, now: t0, provider: "anthropic",
                                              project: nil, cliSession: nil, contextLabel: nil)
        check("чат без ответа (заглушка стрима пустая) не сохраняется", noAnswer == nil)
        var notice = answer("Пометка", source: nil)
        notice.isNotice = true
        check("пометка Luna — не ответ модели",
              ChatHistoryRecord.make(id: uuid(1), messages: [user("В"), notice], created: nil, now: t0,
                                     provider: "anthropic", project: nil, cliSession: nil, contextLabel: nil) == nil)
        let ok = ChatHistoryRecord.make(id: uuid(1), messages: [user("Первый\nвопрос"), answer(""), answer("Ответ", source: "Anthropic API · m")],
                                        created: nil, now: t0, provider: "anthropic", project: nil,
                                        cliSession: nil, contextLabel: "Safari — Docs")
        check("после первого ответа — сохраняется", ok != nil)
        check("заголовок по первому вопросу, пустые сообщения не пишутся, подпись последнего ответа",
              ok?.title == "Первый" && ok?.messages.count == 2 && ok?.source == "Anthropic API · m"
                && ok?.created == t0 && ok?.contextLabel == "Safari — Docs")

        let s = store("upsert")
        let first = record(1)
        s.save(first, openID: first.id)
        let again = ChatHistoryRecord.make(id: uuid(1), messages: first.messages + [user("Ещё"), answer("Да")],
                                           created: first.created, now: t0.addingTimeInterval(60), provider: "claude_code",
                                           project: nil, cliSession: nil, contextLabel: nil)!
        s.save(again, openID: again.id)
        check("повторная запись того же чата обновляет строку, а не добавляет вторую",
              s.entries.count == 1 && s.entries[0].updated == t0.addingTimeInterval(60))
        check("…и дату начала не меняет", s.record(uuid(1))?.created == t0 && s.record(uuid(1))?.messages.count == 4)
    }

    // MARK: 3–4. Порядок и лимит

    static func orderAndLimitTests() {
        print("ChatHistory: порядок и лимит")
        let sorted = ChatHistory.sorted([entry(1, updated: 10), entry(2, updated: 30), entry(3, updated: 20)])
        check("новые сверху — по последнему сообщению", sorted.map(\.id) == [uuid(2), uuid(3), uuid(1)])
        let many = (1...101).map { entry($0, updated: TimeInterval($0)) }
        let (kept, removed) = ChatHistory.prune(many, keeping: nil)
        check("лимит по умолчанию — 100", ChatHistory.limit == 100)
        check("101-й чат: удалён самый старый по последнему сообщению",
              kept.count == 100 && removed == [uuid(1)] && !kept.contains { $0.id == uuid(1) })
        let (keptOpen, removedOpen) = ChatHistory.prune(many, keeping: uuid(1))
        check("открытый чат не удаляется, даже самый старый — уходит следующий",
              keptOpen.count == 100 && keptOpen.contains { $0.id == uuid(1) } && removedOpen == [uuid(2)])
        let (small, none) = ChatHistory.prune([entry(1, updated: 1)], limit: 3, keeping: nil)
        check("в пределах лимита ничего не удаляется", small.count == 1 && none.isEmpty)

        let s = store("limit")
        for n in 1...4 { s.save(record(n, updated: TimeInterval(n)), openID: uuid(n)) }
        let five = record(5, updated: 5)
        let (k, r) = ChatHistory.prune(s.entries + [five.entry], limit: 4, keeping: uuid(5))
        check("prune на списке хранилища", k.count == 4 && r == [uuid(1)])
        // Лимит 100 на диске: 101-я запись удаляет файл самого старого.
        let big = store("limit-disk")
        for n in 1...101 { big.save(record(n, updated: TimeInterval(n)), openID: uuid(n)) }
        check("на диске 100 чатов: файл самого старого удалён",
              big.entries.count == 100 && !FileManager.default.fileExists(atPath: big.fileURL(for: uuid(1)).path)
                && FileManager.default.fileExists(atPath: big.fileURL(for: uuid(2)).path))
        let reread = ChatHistoryStore(directory: big.directory)
        check("после перезапуска — те же 100, новые сверху",
              reread.load().count == 100 && reread.entries.first?.id == uuid(101))
    }

    // MARK: 5–6. Хранилище: запись, чтение, удаление

    static func storeTests() {
        print("ChatHistoryStore: запись и чтение")
        let s = store("roundtrip")
        check("нет папки — пустая история без ошибок", s.load().isEmpty)
        let project = ChatHistoryProject(id: uuid(77), name: "luna-assistant", path: "/w/luna")
        let session = ChatHistoryCLISession(id: "sess-1", projectPath: "/w/luna", started: true)
        var messages = [user("Что в README?"), answer("Там описание.")]
        var notice = ChatMessage(role: .assistant, content: "Пометка")
        notice.isNotice = true
        messages.append(notice)
        let original = ChatHistoryRecord.make(id: uuid(9), messages: messages, created: t0, now: t0.addingTimeInterval(5),
                                              provider: "claude_code", project: project, cliSession: session,
                                              contextLabel: "report.txt")!
        s.save(original, openID: original.id)
        let back = ChatHistoryStore(directory: s.directory).record(uuid(9))
        check("запись → чтение: тот же чат целиком", back == original)
        check("те же id сообщений, роли, тексты, подписи, пометки",
              back?.messages.map(\.id) == messages.map(\.id) && back?.messages.map(\.role) == [.user, .assistant, .assistant]
                && back?.messages[1].source == "Claude Code · подписка · sonnet" && back?.messages[2].isNotice == true)
        check("проект и сессия CLI (id, папка, начата), подпись контекста",
              back?.project == project && back?.cliSession == session && back?.contextLabel == "report.txt")
        let raw = (try? String(contentsOf: s.fileURL(for: uuid(9)), encoding: .utf8)) ?? ""
        check("в файле нет полей с содержимым файла контекста (только подпись)",
              raw.contains("report.txt") && !raw.contains("File contents") && !raw.contains("\"data\""))
        check("файлы — index.json и <id>.json", files(s) == ["00000000-0000-4000-8000-000000000009.json", "index.json"])

        print("ChatHistoryStore: удаление")
        s.save(record(10, updated: 10), openID: uuid(10))
        s.delete(uuid(9))
        check("удалённый чат пропал из списка", !s.entries.contains { $0.id == uuid(9) } && s.entries.count == 1)
        check("…и с диска", !FileManager.default.fileExists(atPath: s.fileURL(for: uuid(9)).path))
        check("…и из index.json", ChatHistoryStore(directory: s.directory).load().map(\.id) == [uuid(10)])
        s.clear()
        check("«Очистить историю»: список пуст, файлов чатов нет", s.entries.isEmpty && files(s) == ["index.json"])
        check("пропавший файл чата — nil, строка убрана", {
            let t = store("missing-file")
            t.save(record(1), openID: nil)
            try? FileManager.default.removeItem(at: t.fileURL(for: uuid(1)))
            return t.record(uuid(1)) == nil && t.entries.isEmpty
        }())
    }

    // MARK: 7. Испорченный файл

    static func corruptTests() {
        print("ChatHistoryStore: испорченный файл")
        let s = store("corrupt")
        s.save(record(1), openID: nil)
        let garbage = Data("{ not json".utf8)
        try? garbage.write(to: s.indexURL)
        let fresh = ChatHistoryStore(directory: s.directory)
        check("испорченный index.json — пустая история без падения", fresh.load().isEmpty)
        let aside = files(fresh).filter { $0.hasPrefix("index.corrupt-") }
        let asideURL = fresh.directory.appendingPathComponent(aside.first ?? "нет-отложенного")
        check("испорченный файл отложен рядом с меткой времени, не перезаписан",
              aside.count == 1 && (try? Data(contentsOf: asideURL)) == garbage)
        fresh.save(record(2), openID: nil)
        check("запись дальше — в новый index.json",
              ChatHistoryStore(directory: s.directory).load().map(\.id) == [uuid(2)]
                && (try? Data(contentsOf: asideURL)) == garbage)
        try? Data("oops".utf8).write(to: fresh.fileURL(for: uuid(2)))
        check("испорченный файл чата — nil, отложен, строка убрана",
              fresh.record(uuid(2)) == nil && fresh.entries.isEmpty
                && files(fresh).contains { $0.hasPrefix("00000000-0000-4000-8000-000000000002.corrupt-") })
    }

    // MARK: 8. Права

    static func permissionTests() {
        print("ChatHistoryStore: права")
        let s = store("perm")
        s.save(record(1), openID: nil)
        func mode(_ path: String) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        check("файл чата — 0600", mode(s.fileURL(for: uuid(1)).path) == 0o600)
        check("index.json — 0600", mode(s.indexURL.path) == 0o600)
        check("папка истории — 0700", mode(s.directory.path) == 0o700)
        s.save(record(1, updated: 9), openID: nil)
        check("после перезаписи — по-прежнему 0600", mode(s.fileURL(for: uuid(1)).path) == 0o600)
        check("временных файлов не осталось", !files(s).contains { $0.hasSuffix(".tmp") })
        check("путь по умолчанию — Application Support/Luna/ChatHistory",
              ChatHistoryStore.defaultDirectory.path.hasSuffix("Library/Application Support/Luna/ChatHistory"))
    }

    // MARK: 9. Продолжение чата

    static func continuationTests() {
        print("ChatContinuation.plan")
        let project = ChatHistoryProject(id: uuid(7), name: "luna", path: "/w/luna")
        let session = ChatHistoryCLISession(id: "s-1", projectPath: "/w/luna", started: true)
        let cli = record(1, project: project, session: session)

        let same = ChatContinuation.plan(for: cli, currentProvider: "claude_code", chatSourceName: "Claude Code", projectID: uuid(7))
        check("подписка, та же папка, сессия начата → resume с id чата, проект чата, без пометок",
              same.cliSession == session && same.project == .project(uuid(7)) && same.notices.isEmpty)
        var restored = ChatCLISession(restoring: same.cliSession!.id, projectPath: same.cliSession!.projectPath,
                                      started: same.cliSession!.started)
        check("…ход в папке проекта — --resume s-1", restored.turn(projectPath: "/w/luna") == ("s-1", true))

        let gone = ChatContinuation.plan(for: cli, currentProvider: "claude_code", chatSourceName: "Claude Code", projectID: nil)
        check("проект чата недоступен → новая сессия, «Без проекта», пометка",
              gone.cliSession == nil && gone.project == .none && gone.notices == [.projectUnavailable(name: "luna")])

        let api = record(2, provider: "anthropic")
        let apiNowCLI = ChatContinuation.plan(for: api, currentProvider: "claude_code", chatSourceName: "Anthropic API", projectID: nil)
        check("чат по ключу, сейчас Claude Code → новая сессия и пометка с кнопкой «Anthropic»",
              apiNowCLI.cliSession == nil
                && apiNowCLI.notices == [.sourceDiffers(chatSource: "Anthropic API", switchTo: "anthropic", newCLISession: true)]
                && apiNowCLI.project == .keep)

        let cliNowAPI = ChatContinuation.plan(for: cli, currentProvider: "anthropic", chatSourceName: "Claude Code · подписка", projectID: uuid(7))
        check("чат по подписке, сейчас ключ → пометка с кнопкой «Claude Code», сессия сохранена на случай клика",
              cliNowAPI.notices == [.sourceDiffers(chatSource: "Claude Code · подписка", switchTo: "claude_code", newCLISession: false)]
                && cliNowAPI.cliSession == session && cliNowAPI.project == .project(uuid(7)))

        let apiToAPI = ChatContinuation.plan(for: api, currentProvider: "openai", chatSourceName: "Anthropic API", projectID: nil)
        check("ключ → другой API: без пометки (история уходит текстом), проект не трогается",
              apiToAPI.notices.isEmpty && apiToAPI.cliSession == nil && apiToAPI.project == .keep)

        let free = record(3, session: ChatHistoryCLISession(id: "s-3", projectPath: nil, started: true))
        let freePlan = ChatContinuation.plan(for: free, currentProvider: "claude_code", chatSourceName: "Claude Code", projectID: nil)
        check("подписка без проекта → resume в служебной папке, «Без проекта»",
              freePlan.cliSession?.id == "s-3" && freePlan.project == .none && freePlan.notices.isEmpty)

        // Сессия не начата (первый ход не состоялся) — продолжать нечего: --resume такой сессии
        // упал бы «No conversation found».
        let unstarted = record(4, session: ChatHistoryCLISession(id: "s-4", projectPath: nil, started: false))
        let unstartedPlan = ChatContinuation.plan(for: unstarted, currentProvider: "claude_code", chatSourceName: "Claude Code", projectID: nil)
        check("сессия не начата → новая сессия, не --resume", unstartedPlan.cliSession == nil)

        let both = ChatContinuation.plan(for: cli, currentProvider: "anthropic", chatSourceName: "Claude Code", projectID: nil)
        check("источник другой и проекта нет — обе пометки, источник первым",
              both.notices.count == 2 && both.notices.last == .projectUnavailable(name: "luna"))
    }

    // MARK: 10. Разговор для ключа API

    static func apiTurnTests() {
        print("ChatHistory.apiTurns")
        var notice = ChatMessage(role: .assistant, content: "Пометка")
        notice.isNotice = true
        let turns = ChatHistory.apiTurns(from: [user("Q1"), answer(" A1 "), notice, answer(""), user("Q2"), answer("A2")])
        check("текстом, в том же порядке, роли user/assistant; пометки и пустые не входят",
              turns.map(\.role) == ["user", "assistant", "user", "assistant"] && turns.map(\.text) == ["Q1", "A1", "Q2", "A2"])
        check("пустой чат — пустой разговор", ChatHistory.apiTurns(from: []).isEmpty)
    }

    // MARK: 11. Ход принадлежит своему чату; 5. удаление открытого

    static func openStateTests() {
        print("ChatOpenState")
        var open = ChatOpenState()
        let ticket = open.ticket()
        check("ход своего чата принимается", open.accepts(ticket))
        open.newChat()
        check("после «+» ответ прежнего хода в открытый чат не попадает", !open.accepts(ticket))
        let ticket2 = open.ticket()
        open.open(uuid(5))
        check("после открытия другого чата — тоже", !open.accepts(ticket2) && open.chatID == uuid(5))
        let ticket3 = open.ticket()
        open.open(uuid(5))
        check("повторное открытие того же чата — новое поколение, старый ход не принимается", !open.accepts(ticket3))
        check("удаление другого чата открытый не трогает", !open.deleted(uuid(6)) && open.chatID == uuid(5))
        let before = open.chatID
        check("удаление открытого — страница становится новым чатом", open.deleted(uuid(5)) && open.chatID != before)
    }

    // MARK: 14. Демо и выключенное хранение

    static func policyTests() {
        print("ChatHistory.shouldRecord")
        check("включено, не демо — пишется", ChatHistory.shouldRecord(enabled: true, demo: false))
        check("демо — не пишется", !ChatHistory.shouldRecord(enabled: true, demo: true))
        check("выключено — не пишется", !ChatHistory.shouldRecord(enabled: false, demo: false))
        check("ключ настройки — chatHistoryEnabled", ChatHistory.defaultsKey == "chatHistoryEnabled")
    }
}
