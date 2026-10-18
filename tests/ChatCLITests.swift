import Foundation

@main
enum ChatCLITests {
    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        let home = "/Users/test"

        print("CLIResolver.executable")
        let present: Set<String> = ["/usr/local/bin/claude", "\(home)/.local/bin/claude"]
        check("первый существующий кандидат побеждает (~/.local/bin раньше /usr/local/bin)",
              CLIResolver.executable(.claude, home: home, isExecutable: { present.contains($0) }, nodeVersions: { [] })
                == "\(home)/.local/bin/claude")
        check("нет нигде — nil",
              CLIResolver.executable(.claude, home: home, isExecutable: { _ in false }, nodeVersions: { [] }) == nil)
        check("~/.claude/local/claude ищется только для claude",
              CLIResolver.candidates(for: .claude, home: home).contains("\(home)/.claude/local/claude")
                && !CLIResolver.candidates(for: .codex, home: home).contains("\(home)/.claude/local/codex"))
        let nvm = CLIResolver.candidates(for: .codex, home: home, nodeVersions: ["v18.9.0", "v22.1.0", "v20.5.1"])
            .filter { $0.contains(".nvm") }
        check("nvm: новые версии Node первыми",
              nvm.first == "\(home)/.nvm/versions/node/v22.1.0/bin/codex" && nvm.last == "\(home)/.nvm/versions/node/v18.9.0/bin/codex")
        check("codex ищется той же функцией",
              CLIResolver.executable(.codex, home: home, isExecutable: { $0 == "/opt/homebrew/bin/codex" }, nodeVersions: { [] })
                == "/opt/homebrew/bin/codex")

        print("CLIResolver.environment")
        let base = [
            "ANTHROPIC_API_KEY": "sk-secret", "ANTHROPIC_AUTH_TOKEN": "tok", "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SESSION_ID": "abc", "CLAUDE_PID": "42",
            "HOME": home, "LANG": "ru_RU.UTF-8", "PATH": "/custom/bin",
        ]
        let env = CLIResolver.environment(base: base, executable: "/opt/tools/claude", home: home)
        check("ключ API и токен убраны", env["ANTHROPIC_API_KEY"] == nil && env["ANTHROPIC_AUTH_TOKEN"] == nil)
        check("метки родительской сессии убраны",
              env["CLAUDECODE"] == nil && env["CLAUDE_CODE_ENTRYPOINT"] == nil
                && env["CLAUDE_CODE_SESSION_ID"] == nil && env["CLAUDE_PID"] == nil)
        check("остальное окружение сохранено", env["HOME"] == home && env["LANG"] == "ru_RU.UTF-8")
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        check("PATH: папка бинаря первой, прежний PATH сохранён",
              path.first == "/opt/tools" && path.contains("/custom/bin") && path.contains("\(home)/.local/bin"))

        print("ClaudeAuthStatus.parse")
        let subscription = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#
        check("claude.ai → готов, подписка",
              ClaudeAuthStatus.parse(output: subscription, exitCode: 0) == .ready(authMethod: "claude.ai")
                && ClaudeAuthStatus.parse(output: subscription, exitCode: 0).isSubscription)
        let notLoggedIn = #"{"loggedIn":false,"authMethod":"none"}"#
        check("loggedIn:false → не вошёл", ClaudeAuthStatus.parse(output: notLoggedIn, exitCode: 1) == .notLoggedIn)
        let apiKeyLogin = #"{"loggedIn":true,"authMethod":"api_key"}"#
        let other = ClaudeAuthStatus.parse(output: apiKeyLogin, exitCode: 0)
        check("иной способ входа → готов, но не подписка", other.isReady && !other.isSubscription)
        check("невалидный JSON → не вошёл, без падения",
              ClaudeAuthStatus.parse(output: "Segmentation fault", exitCode: 0) == .notLoggedIn
                && ClaudeAuthStatus.parse(output: "", exitCode: 0) == .notLoggedIn)
        check("loggedIn:true, но код выхода ≠ 0 → не вошёл",
              ClaudeAuthStatus.parse(output: subscription, exitCode: 1) == .notLoggedIn)

        print("ChatSourceSelection")
        let ready = CLIStatus.ready(authMethod: "claude.ai")
        check("первый запуск, Claude Code готов, ключа нет → Claude Code",
              ChatSourceSelection.initialChoice(savedProvider: nil, claude: ready, hasAnthropicKey: false) == .claudeCode)
        check("первый запуск, Claude Code не готов → anthropic",
              ChatSourceSelection.initialChoice(savedProvider: nil, claude: .notLoggedIn, hasAnthropicKey: false) == .anthropic
                && ChatSourceSelection.initialChoice(savedProvider: nil, claude: .missing, hasAnthropicKey: false) == .anthropic
                && ChatSourceSelection.initialChoice(savedProvider: nil, claude: .unknown, hasAnthropicKey: false) == .anthropic)
        check("сохранённый anthropic остаётся anthropic при готовом CLI",
              ChatSourceSelection.initialChoice(savedProvider: "anthropic", claude: ready, hasAnthropicKey: true) == .anthropic
                && !ChatSourceSelection.shouldAutoSelectClaudeCode(savedProvider: "anthropic", claude: ready, hasAnthropicKey: false))
        check("сохранённый ollama не переопределяется",
              !ChatSourceSelection.shouldAutoSelectClaudeCode(savedProvider: "ollama", claude: ready, hasAnthropicKey: false))
        check("ключ API есть — молча на подписку не переводим",
              !ChatSourceSelection.shouldAutoSelectClaudeCode(savedProvider: nil, claude: ready, hasAnthropicKey: true))
        check("автовыбор: первый запуск + готов + без ключа",
              ChatSourceSelection.shouldAutoSelectClaudeCode(savedProvider: nil, claude: ready, hasAnthropicKey: false))
        check("anthropic без ключа и готовый CLI → предложение переключиться",
              ChatSourceSelection.adviceForMissingAnthropicKey(claude: ready) == .offerClaudeCode)
        check("anthropic без ключа и без CLI → прежний текст «API key missing»",
              ChatSourceSelection.adviceForMissingAnthropicKey(claude: .missing) == .keyMissing
                && ChatSourceSelection.adviceForMissingAnthropicKey(claude: .notLoggedIn) == .keyMissing
                && ChatSourceSelection.adviceForMissingAnthropicKey(claude: .unknown) == .keyMissing)

        print("ChatSourceLabel")
        check("Claude Code · подписка · sonnet",
              ChatSourceLabel.claudeCode(model: "sonnet", status: ready, subscriptionWord: "подписка") == "Claude Code · подписка · sonnet")
        check("вход не по подписке: способ вместо слова «подписка»",
              ChatSourceLabel.claudeCode(model: "default", status: other, subscriptionWord: "подписка") == "Claude Code · api_key · default")
        check("Anthropic API · модель",
              ChatSourceLabel.api(name: "Anthropic", isLocal: false, model: "claude-sonnet-4-6") == "Anthropic API · claude-sonnet-4-6")
        check("Ollama · модель (локальная, без «API»)",
              ChatSourceLabel.api(name: "Ollama", isLocal: true, model: "llama3.2") == "Ollama · llama3.2")

        print("ClaudeCodeModels")
        check("default не уходит в --model", ClaudeCodeModels.cliModel(for: "default") == nil && ClaudeCodeModels.cliModel(for: " ") == nil)
        check("алиас уходит как есть", ClaudeCodeModels.cliModel(for: "sonnet") == "sonnet")
        check("список: default, sonnet, opus, haiku", ClaudeCodeModels.ids == ["default", "sonnet", "opus", "haiku"])

        print("ChatCLIPrompt")
        let plain = ChatCLIPrompt.build(query: "Привет")
        check("без контекста — только вопрос", plain == "Привет")
        let win = ChatCLIPrompt.build(query: "Что тут?", window: (app: "Safari", title: "Новости", url: "https://example.com"))
        check("окно: приложение, заголовок и URL перед вопросом",
              win == "Context — App: Safari, Window: Новости, URL: https://example.com\n\nЧто тут?")
        let small = ChatCLIPrompt.fileContext(name: "a.txt", fileExtension: "txt", data: Data("hello".utf8))
        check("текстовый файл передаётся текстом", small == .text(name: "a.txt", contents: "hello"))
        check("PDF и картинки не передаются, только имя",
              ChatCLIPrompt.fileContext(name: "a.pdf", fileExtension: "PDF", data: Data("x".utf8)) == .notPassed(name: "a.pdf")
                && ChatCLIPrompt.fileContext(name: "a.png", fileExtension: "png", data: Data("x".utf8)) == .notPassed(name: "a.png"))
        check("файл крупнее 200 КБ не передаётся",
              ChatCLIPrompt.fileContext(name: "big.txt", fileExtension: "txt", data: Data(count: ChatCLIPrompt.maxFileBytes + 1)) == .notPassed(name: "big.txt"))
        check("нечитаемый файл (nil) не передаётся",
              ChatCLIPrompt.fileContext(name: "x.txt", fileExtension: "txt", data: nil) == .notPassed(name: "x.txt"))
        let withFile = ChatCLIPrompt.build(query: "Кратко", file: small)
        check("файл: имя и содержимое перед вопросом", withFile == "File: a.txt\nFile contents:\nhello\n\nКратко")
        let noFile = ChatCLIPrompt.build(query: "Кратко", file: .notPassed(name: "a.pdf"))
        check("не переданный файл — честная строка, а не пустота", noFile.contains("a.pdf") && noFile.hasSuffix("Кратко"))

        if failures > 0 { print("\n\(failures) test(s) failed."); exit(1) }
        print("\nAll tests passed.")
    }
}
